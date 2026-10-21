import Foundation
import Observation
import OSLog

@Observable @MainActor final class ImportCoordinator {
    typealias Artwork = ImportedImageDownload.Artwork
    enum Stage { case loadingPhoto, fetching, downloading, removingBackground }
    enum Phase: Equatable {
        case queued, processing(Stage), ready(note: String?), failed(String)
        var isActive: Bool { switch self { case .queued, .processing: true; case .ready, .failed: false } }
        var isReady: Bool { if case .ready = self { true } else { false } }
    }
    enum Source {
        case link
        case photo(load: () async throws -> Data)
        /// The listing found for an imported photo: imported onto that Product, keeping its photo as a Photo.
        case resolve(product: String, screenshot: String)
    }
    struct Checkpoint { let asset: String; let aspect: Double }
    struct Item: Identifiable {
        let id: UUID
        let record: SharedImport
        let source: Source
        var placementID: String?
        var phase = Phase.queued
        /// The original on the Canvas, so a retry cuts it out again without fetching.
        var checkpoint: Checkpoint?
        var pendingImages: [String] = []
        var displayName: String { if case .photo = source { record.suggestedTitle ?? "Photo" } else { record.url } }
        var status: String {
            switch phase {
            case .queued: "Queued"
            case .processing(.loadingPhoto): "Loading photo…"
            case .processing(.removingBackground): "Removing background…"
            case .processing: "Processing"
            case .ready(let note): note ?? "Ready"
            case .failed(let reason): reason
            }
        }
        var canRetryBackground: Bool { if case .ready(note: .some) = phase { checkpoint != nil } else { false } }
    }
    private(set) var items: [Item] = []
    private var batchIDs: [UUID] = []
    struct Progress {
        let item: Item
        let current: Int
        let total: Int
    }
    /// The item being processed, or next to be: attempts run one at a time in batch order.
    var progress: Progress? {
        guard let (position, item) = batchIDs.enumerated().lazy.compactMap({ position, id in
            self.items.first { $0.id == id && $0.phase.isActive }.map { (position, $0) }
        }).first else { return nil }
        return Progress(item: item, current: position + 1, total: batchIDs.count)
    }
    /// Rows in the Imports sheet that are not finished.
    var pendingCount: Int { items.filter { !$0.phase.isReady }.count }
    private func enqueue(_ item: Item) {
        if !items.contains(where: \.phase.isActive) { batchIDs = [] }
        batchIDs.append(item.id)
        items.append(item)
    }
    @ObservationIgnored private weak var session: CanvasSession?
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    /// The running attempt of each item. Removing an item cancels it, so after each await an attempt only checks for cancellation.
    @ObservationIgnored private var attempts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draining = false
    @ObservationIgnored let inbox: SharedImportInbox
    @ObservationIgnored private let acknowledge: (URL) throws -> Void
    @ObservationIgnored private let fetch: (String) async throws -> GarmsAPI.ImportedProduct
    @ObservationIgnored private let image: (String) async throws -> Artwork
    @ObservationIgnored private let cutout: ((Artwork) async throws -> Artwork?)?
    @ObservationIgnored private let search: (Artwork) async throws -> GarmsAPI.Listing?
    init(session: CanvasSession, inbox: SharedImportInbox = .init(),
         acknowledge: ((URL) throws -> Void)? = nil,
         fetch: ((String) async throws -> GarmsAPI.ImportedProduct)? = nil,
         image: @escaping (String) async throws -> Artwork = { try await ImportedImageDownload.fetch($0) },
         cutout: ((Artwork) async throws -> Artwork?)? = nil,
         search: ((Artwork) async throws -> GarmsAPI.Listing?)? = nil) {
        self.session = session; self.inbox = inbox; self.image = image; self.cutout = cutout
        self.acknowledge = acknowledge ?? { try inbox.acknowledge($0) }
        self.fetch = fetch ?? { [server = session.server] in try await server.importProduct(url: $0) }
        self.search = search ?? { [server = session.server] in try await server.findListing(try await ImportedImageDownload.flattenedJPEG($0)) }
    }
    /// Picks up links shared from other apps, then processes the queue.
    func checkInbox() {
        drain()
        start()
    }
    func importPhoto(title: String = "Imported photo", load: @escaping () async throws -> Data) {
        let record = SharedImport(url: "", suggestedTitle: title)
        enqueue(Item(id: record.id, record: record, source: .photo(load: load)))
        start()
    }
    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        do {
            for file in try inbox.files() {
                let record: SharedImport
                do { record = try inbox.read(file) }
                catch {
                    session?.error = "An invalid shared link was removed from the inbox."
                    do { try acknowledge(file) } catch { session?.error = "An invalid inbox record could not be removed." }
                    continue
                }
                if seen.insert(record.id).inserted { register(record) }
                do { try acknowledge(file) }
                catch { session?.error = "A captured link could not be cleared from the inbox. It will not be duplicated in this session." }
            }
        } catch { session?.error = error.localizedDescription }
    }
    private func register(_ record: SharedImport) {
        guard let session, let key = try? SharedLink.normalized(record.url) else { return }
        if let placement = session.document.placements.values.first(where: {
            guard let product = session.document.products[$0.productID] else { return false }
            return (try? SharedLink.normalized(product.sourceUrl)) == key
        }) {
            session.revealImport(placement.id)
            return
        }
        if let product = session.document.products.values.first(where: { (try? SharedLink.normalized($0.sourceUrl)) == key }) {
            session.placeSticker(of: product.id)
            return
        }
        if items.contains(where: { (try? SharedLink.normalized($0.record.url)) == key && $0.placementID == nil }) { return }
        enqueue(Item(id: record.id, record: record, source: .link))
    }
    func start() {
        guard session?.hasInitialLayout == true, runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            while let id = batchIDs.first(where: { id in self.items.contains { $0.id == id && $0.phase == .queued } }) {
                let attempt = Task { await self.process(id) }
                attempts[id] = attempt
                await attempt.value
                attempts[id] = nil
            }
            runner = nil
        }
    }
    private static let logger = Logger(subsystem: "f.garment-swift-2", category: "Import")
    private func log(_ id: UUID, _ message: String, warning: Bool = false) {
        if warning { Self.logger.warning("\(id.uuidString, privacy: .public) \(message, privacy: .public)") }
        else { Self.logger.info("\(id.uuidString, privacy: .public) \(message, privacy: .public)") }
    }
    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) { change(&items[index]) }
    }
    private func stage(_ id: UUID, _ stage: Stage) { update(id) { $0.phase = .processing(stage) } }

    /// One attempt: put the source's artwork on the Canvas, then save the gallery and cut the original out.
    private func process(_ id: UUID) async {
        guard let session, let item = items.first(where: { $0.id == id }) else { return }
        let started = Date()
        log(id, "Starting processing attempt. Waiting for product artwork.")
        do {
            let (placement, original) = try await artwork(for: item, session)
            try await downloadGallery(id, placement, session)
            var note: String?
            if let original { note = try await removeBackground(id, original, placement, session) }
            update(id) { $0.phase = .ready(note: note) }
            log(id, "Import ready in \(String(format: "%.2f", Date().timeIntervalSince(started)))s.")
            if case .resolve(let product, let screenshot) = item.source {
                session.attachListing(product, url: item.record.url, screenshot: screenshot)
            }
        } catch {
            guard !Task.isCancelled else { return }
            let phase = items.first { $0.id == id }?.phase
            let details = ImportDiagnostics.describe(error)
            log(id, "Import failed during \(String(describing: phase)): " + details, warning: true)
            update(id) { $0.phase = .failed(details) }
        }
    }
    /// Returns the item's Sticker, and the original to cut out: nil for a found listing, which keeps the photo's Cutout.
    private func artwork(for item: Item, _ session: CanvasSession) async throws -> (placement: String, original: Artwork?) {
        let id = item.id
        if let checkpoint = item.checkpoint, let placement = item.placementID, let data = session.importedAssets.data(for: checkpoint.asset) {
            log(id, "Resuming background removal from the saved original (\(data.count) bytes).")
            return (placement, Artwork(data: data, aspect: checkpoint.aspect))
        }
        switch item.source {
        case .photo(let load):
            stage(id, .loadingPhoto)
            log(id, "Loading selected photo and preparing artwork bounded to 2,048 pixels.")
            let data = try await load()
            try Task.checkCancellation()
            let photo = try await ImportedImageDownload.prepare(data)
            try Task.checkCancellation()
            let placement = try install(item, photo, title: nil, price: nil, session)
            log(id, "Photo decoded and original installed on canvas (\(photo.data.count) PNG bytes). Searching the web for its listing.")
            match(placement)
            return (placement, photo)
        case .resolve:
            guard let placement = item.placementID else { throw ImportedImageDownload.ImageError.invalid }
            update(id) { $0.checkpoint = nil }
            stage(id, .fetching)
            log(id, "Fetching the listing for this photo via the imports:product action → Firecrawl.")
            let result = try await fetch(item.record.url)
            try Task.checkCancellation()
            // The photo's Cutout stays on the Canvas, so the Sticker doesn't jump; the listing's images become Photos.
            var seenImages: Set<String> = []
            update(id) { $0.pendingImages = result.imageURLs.filter { seenImages.insert($0).inserted } }
            guard session.updateImport(placement, title: result.title, price: result.price, artwork: nil) != nil else {
                throw ImportedImageDownload.ImageError.invalid
            }
            log(id, "Listing details saved. Title: \(result.title ?? "missing"). Keeping the photo's Cutout.")
            return (placement, nil)
        case .link:
            update(id) { $0.checkpoint = nil }
            stage(id, .fetching)
            log(id, "Fetching product metadata and markdown via the imports:product action → Firecrawl.")
            let result = try await fetch(item.record.url)
            try Task.checkCancellation()
            log(id, "Metadata received. Title: \(result.title ?? "missing"). Image candidate: \(result.imageURLs.isEmpty ? "missing" : "present").")
            guard let address = result.imageURLs.first else { throw ImportedImageDownload.ImageError.detail("The page returned no usable HTTPS product image URL. Cannot download product artwork.") }
            var seenImages: Set<String> = [address]
            update(id) { $0.pendingImages = result.imageURLs.filter { seenImages.insert($0).inserted } }
            stage(id, .downloading)
            log(id, "Downloading image from \(URL(string: address)?.host ?? "unknown host") and decoding to a PNG bounded to 2,048 pixels.")
            let artwork = try await image(address)
            try Task.checkCancellation()
            let placement = try install(item, artwork, title: result.title, price: result.price, session)
            log(id, "Image downloaded, decoded and installed on canvas (\(artwork.data.count) PNG bytes; aspect \(artwork.aspect)).")
            return (placement, artwork)
        }
    }
    /// Places the item's Sticker if it has none yet, and saves `artwork` as its original.
    private func install(_ item: Item, _ artwork: Artwork, title: String?, price: Price?, _ session: CanvasSession) throws -> String {
        var placement = item.placementID
        if placement == nil {
            var record = item.record
            record.suggestedTitle = title ?? record.suggestedTitle
            placement = session.insertImport(record, artwork: artwork)
            update(item.id) { $0.placementID = placement }
        }
        guard let placement, let asset = session.installImportOriginal(placement, title: title, price: price, artwork: artwork) else {
            throw ImportedImageDownload.ImageError.invalid
        }
        update(item.id) { $0.checkpoint = Checkpoint(asset: asset, aspect: artwork.aspect) }
        return placement
    }
    /// Saves the listing's other images as Photos, without background removal. One that fails to download is skipped.
    private func downloadGallery(_ id: UUID, _ placement: String, _ session: CanvasSession) async throws {
        for address in items.first(where: { $0.id == id })?.pendingImages ?? [] {
            stage(id, .downloading)
            do {
                let photo = try await image(address)
                try Task.checkCancellation()
                guard session.appendImportPhoto(placement, artwork: photo) != nil else { throw ImportedImageDownload.ImageError.invalid }
                log(id, "Gallery photo downloaded and saved without background removal.")
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                log(id, "Gallery photo skipped: " + ImportDiagnostics.describe(error), warning: true)
            }
            update(id) { $0.pendingImages.removeFirst() }
        }
        try Task.checkCancellation()
    }
    /// Cuts the garment out of `original`. Returns the note to show when the background is kept instead.
    private func removeBackground(_ id: UUID, _ original: Artwork, _ placement: String, _ session: CanvasSession) async throws -> String? {
        stage(id, .removingBackground)
        log(id, "Removing background with Vision foreground-instance segmentation.")
        let started = Date()
        let extracted: Artwork?
        var warning: String?
        do {
            if let cutout {
                extracted = try await cutout(original)
            } else {
                extracted = try await ForegroundCutoutProcessor.extract(original) { [weak self] line in await self?.log(id, line) }
            }
            if extracted == nil { warning = "Background removal returned no usable cutout. No foreground image was produced." }
        }
        catch is CancellationError { throw CancellationError() }
        catch { extracted = nil; warning = ImportDiagnostics.describe(error) }
        try Task.checkCancellation()
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        guard let extracted, session.applyImportCutout(placement, artwork: extracted) != nil else {
            let reason = warning ?? "A cutout was generated but could not be installed on the canvas."
            log(id, "Background removal finished after \(seconds)s. Original kept. " + reason, warning: true)
            return "Background kept: " + reason
        }
        log(id, "Background removed and cutout installed on canvas in \(seconds)s (\(extracted.data.count) PNG bytes).")
        return nil
    }
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if case .failed = items[index].phase {} else if !items[index].canRetryBackground { return }
        log(id, "Manual retry requested.")
        if !items.contains(where: \.phase.isActive) { batchIDs = [] }
        batchIDs.removeAll { $0 == id }
        batchIDs.append(id)
        items[index].phase = .queued
        start()
    }
    func dismiss(_ id: UUID) {
        let placement = items.first { $0.id == id }?.placementID
        remove { $0.id == id }
        if let placement { session?.deletePlacement(placement) }
    }
    func deleted(_ placement: String) { remove { $0.placementID == placement } }
    private func remove(where match: (Item) -> Bool) {
        for item in items where match(item) {
            attempts[item.id]?.cancel()
            batchIDs.removeAll { $0 == item.id }
        }
        items.removeAll(where: match)
    }

    /// Searches the web for the listing an imported photo shows, and imports the one it finds onto that photo's Product.
    /// Finding nothing, or failing, leaves the Product as it is.
    private func match(_ placement: String) {
        guard let session, let product = session.document.placements[placement].flatMap({ session.document.products[$0.productID] }) else { return }
        let photo = product.original ?? product.cutout
        Task { [weak self, search] in
            // The whole photo, not the Cutout: the shop is read off its interface.
            guard let data = await session.importedAssets.load(photo),
                  let listing = try? await search(.init(data: data, aspect: product.aspect)),
                  let self, session.document.placements[placement] != nil else { return }
            let record = SharedImport(url: listing.url)
            enqueue(Item(id: record.id, record: record, source: .resolve(product: product.id, screenshot: photo), placementID: placement))
            start()
        }
    }
}
