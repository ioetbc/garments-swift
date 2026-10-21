import Foundation
import Observation
import OSLog

@Observable @MainActor final class ImportCoordinator {
    enum Stage { case loadingPhoto, fetching, downloading, removingBackground }
    struct Checkpoint { let asset: String; let aspect: Double }
    struct Item: Identifiable {
        let id: UUID
        let record: SharedImport
        var photoLoader: (() async throws -> Data)?
        /// A photo's listing is searched for once it is on the Canvas.
        var isPhoto = false
        var searched = false
        /// Set when this link import is the listing found for an imported photo: that Product, and its photo to keep as a Photo.
        var resolving: (product: String, screenshot: String)?
        var displayName: String { isPhoto ? record.suggestedTitle ?? "Photo" : record.url }
        var placementID: String?
        var state = "Queued"
        var failure: String?
        var stage: Stage?
        var note: String?
        var checkpoint: Checkpoint?
        var pendingImages: [String] = []
        var canRetryBackground: Bool { state == "Ready" && note != nil && checkpoint != nil }
        var attempt = UUID()
    }
    private(set) var items: [Item] = []
    private var batchIDs: [UUID] = []
    struct Progress {
        let item: Item
        let current: Int
        let total: Int
    }
    var progress: Progress? {
        guard let item = items.first(where: { $0.state == "Processing" }) ?? batchIDs.compactMap({ id in items.first { $0.id == id && $0.state == "Queued" } }).first,
              let position = batchIDs.firstIndex(of: item.id) else { return nil }
        return Progress(item: item, current: position + 1, total: batchIDs.count)
    }
    private func enqueue(_ item: Item) {
        if !items.contains(where: { $0.state == "Queued" || $0.state == "Processing" }) { batchIDs = [] }
        batchIDs.append(item.id)
        items.append(item)
    }
    @ObservationIgnored private weak var session: CanvasSession?
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var processor: Task<Void, Never>?
    @ObservationIgnored private var draining = false
    @ObservationIgnored let inbox: SharedImportInbox
    @ObservationIgnored private let acknowledge: (URL) throws -> Void
    @ObservationIgnored private let fetch: (String) async throws -> GarmsAPI.ImportedProduct
    @ObservationIgnored private let image: (String) async throws -> ImportedImageDownload.Artwork
    @ObservationIgnored private let cutout: ((ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork?)?
    @ObservationIgnored private let search: (ImportedImageDownload.Artwork) async throws -> GarmsAPI.Listing?
    init(session: CanvasSession, inbox: SharedImportInbox = .init(),
         acknowledge: ((URL) throws -> Void)? = nil,
         fetch: ((String) async throws -> GarmsAPI.ImportedProduct)? = nil,
         image: @escaping (String) async throws -> ImportedImageDownload.Artwork = { try await ImportedImageDownload.fetch($0) },
         cutout: ((ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork?)? = nil,
         search: ((ImportedImageDownload.Artwork) async throws -> GarmsAPI.Listing?)? = nil) {
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
        enqueue(Item(id: record.id, record: record, photoLoader: load, isPhoto: true))
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
            return (try? SharedLink.normalized(product.product_url)) == key
        }) {
            session.revealImport(placement.id)
            return
        }
        if let product = session.document.products.values.first(where: { (try? SharedLink.normalized($0.product_url)) == key }) {
            session.placeSticker(of: product.id)
            return
        }
        if items.contains(where: { (try? SharedLink.normalized($0.record.url)) == key && $0.placementID == nil }) { return }
        enqueue(Item(id: record.id, record: record))
    }
    func start() {
        guard session?.hasInitialLayout == true, processor == nil else { return }
        processor = Task { [weak self] in
            guard let self else { return }
            await process()
            processor = nil
            if items.contains(where: { $0.state == "Queued" }) { start() }
        }
    }
    private static let logger = Logger(subsystem: "f.garment-swift-2", category: "Import")
    private func log(_ id: UUID, _ message: String, warning: Bool = false) {
        if warning { Self.logger.warning("\(id.uuidString, privacy: .public) \(message, privacy: .public)") }
        else { Self.logger.info("\(id.uuidString, privacy: .public) \(message, privacy: .public)") }
    }
    private func process() async {
        while !Task.isCancelled, let id = batchIDs.first(where: { id in items.contains { $0.id == id && $0.state == "Queued" } }),
              let index = items.firstIndex(where: { $0.id == id }) {
            guard let session else { return }
            var placement = items[index].placementID
            let id = items[index].id, attempt = UUID(), url = items[index].record.url
            items[index].attempt = attempt; items[index].state = "Processing"; items[index].failure = nil
            items[index].note = nil
            let started = Date()
            log(id, "Starting processing attempt \(attempt.uuidString). Waiting for product artwork.")
            do {
                // nil when importing a photo's found listing: it keeps the photo's Cutout.
                let source: ImportedImageDownload.Artwork?
                if let checkpoint = items[index].checkpoint, let data = session.importedAssets.data(for: checkpoint.asset) {
                    source = .init(data: data, aspect: checkpoint.aspect)
                    log(id, "Resuming background removal from the saved original (\(data.count) bytes).")
                } else if items[index].isPhoto {
                    items[index].stage = .loadingPhoto
                    log(id, "Loading selected photo and preparing artwork bounded to 2,048 pixels.")
                    guard let load = items[index].photoLoader else {
                        throw ImportedImageDownload.ImageError.detail("The original photo is no longer available. Select it again from Photos.")
                    }
                    let data = try await load()
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement) else { continue }
                    let photo = try await ImportedImageDownload.prepare(data)
                    source = photo
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement),
                          let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    if placement == nil {
                        placement = session.insertImport(items[current].record, artwork: photo)
                        items[current].placementID = placement
                    }
                    guard let placement,
                          let asset = session.installImportOriginal(placement, title: nil, price: nil, artwork: photo) else {
                        throw ImportedImageDownload.ImageError.invalid
                    }
                    items[current].checkpoint = Checkpoint(asset: asset, aspect: photo.aspect)
                    items[current].photoLoader = nil
                    log(id, "Photo decoded and original installed on canvas (\(photo.data.count) PNG bytes).")
                } else if items[index].resolving != nil, let placement {
                    items[index].checkpoint = nil
                    items[index].stage = .fetching
                    log(id, "Fetching the listing for this photo via the imports:product action → Firecrawl.")
                    let result = try await fetch(url)
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement), let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    // The photo's Cutout stays on the Canvas, so the Sticker doesn't jump; the listing's images become Photos.
                    var seenImages: Set<String> = []
                    items[current].pendingImages = (result.imageURLs ?? result.imageURL.map { [$0] } ?? []).filter { seenImages.insert($0).inserted }
                    guard session.updateImport(placement, title: result.title, price: result.price, artwork: nil) != nil else {
                        throw ImportedImageDownload.ImageError.invalid
                    }
                    source = nil
                    log(id, "Listing details saved. Title: \(result.title ?? "missing"). Keeping the photo's Cutout.")
                } else {
                    items[index].checkpoint = nil
                    items[index].stage = .fetching
                    log(id, "Fetching product metadata and markdown via the imports:product action → Firecrawl.")
                    let result = try await fetch(url)
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement) else { continue }
                    log(id, "Metadata received. Title: \(result.title ?? "missing"). Image candidate: \(result.imageURL == nil ? "missing" : "present").")
                    guard let address = result.imageURLs?.first ?? result.imageURL else { throw ImportedImageDownload.ImageError.detail("The page returned no usable HTTPS product image URL. Cannot download product artwork.") }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    var seenImages: Set<String> = [address]
                    items[current].pendingImages = (result.imageURLs ?? []).filter { seenImages.insert($0).inserted }
                    items[current].stage = .downloading
                    log(id, "Downloading image from \(URL(string: address)?.host ?? "unknown host") and decoding to a PNG bounded to 2,048 pixels.")
                    let artwork = try await image(address)
                    source = artwork
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement) else { continue }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    if placement == nil {
                        var record = items[current].record
                        record.suggestedTitle = result.title ?? record.suggestedTitle
                        placement = session.insertImport(record, artwork: artwork)
                        items[current].placementID = placement
                    }
                    guard let placement,
                          let asset = session.installImportOriginal(placement, title: result.title, price: result.price, artwork: artwork) else {
                        throw ImportedImageDownload.ImageError.invalid
                    }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    items[current].checkpoint = Checkpoint(asset: asset, aspect: artwork.aspect)
                    log(id, "Image downloaded, decoded and installed on canvas (\(artwork.data.count) PNG bytes; aspect \(artwork.aspect)).")
                }
                guard let placement, valid(id, attempt, placement) else { continue }
                while let current = items.firstIndex(where: { $0.id == id }), let address = items[current].pendingImages.first {
                    items[current].stage = .downloading
                    do {
                        let photo = try await image(address)
                        try Task.checkCancellation()
                        guard valid(id, attempt, placement) else { break }
                        guard session.appendImportPhoto(placement, artwork: photo) != nil else { throw ImportedImageDownload.ImageError.invalid }
                        log(id, "Gallery photo downloaded and saved without background removal.")
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard valid(id, attempt, placement) else { break }
                        log(id, "Gallery photo skipped: " + ImportDiagnostics.describe(error), warning: true)
                    }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { break }
                    items[current].pendingImages.removeFirst()
                }
                try Task.checkCancellation()
                guard valid(id, attempt, placement), let current = items.firstIndex(where: { $0.id == id }) else { continue }
                if let source {
                    items[current].stage = .removingBackground
                    log(id, "Removing background with Vision foreground-instance segmentation.")
                    let cutoutStarted = Date()
                    let extracted: ImportedImageDownload.Artwork?
                    var warning: String?
                    do {
                        if let cutout {
                            extracted = try await cutout(source)
                        } else {
                            extracted = try await ForegroundCutoutProcessor.extract(source) { [weak self] line in
                                await self?.logCutoutDiagnostic(line, id: id, attempt: attempt, placement: placement)
                            }
                        }
                        if extracted == nil { warning = "Background removal returned no usable cutout. No foreground image was produced." }
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch { extracted = nil; warning = ImportDiagnostics.describe(error) }
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement) else { continue }
                    let installed = extracted.flatMap { session.applyImportCutout(placement, artwork: $0) }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    if installed == nil {
                        let reason = warning ?? "A cutout was generated but could not be installed on the canvas."
                        items[current].note = "Background kept: " + reason
                        log(id, "Background removal finished after \(String(format: "%.2f", Date().timeIntervalSince(cutoutStarted)))s. Original kept. " + reason, warning: true)
                    } else {
                        log(id, "Background removed and cutout installed on canvas in \(String(format: "%.2f", Date().timeIntervalSince(cutoutStarted)))s (\(extracted?.data.count ?? 0) PNG bytes).")
                    }
                }
                guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                items[current].state = "Ready"
                items[current].stage = nil
                log(id, "Import ready in \(String(format: "%.2f", Date().timeIntervalSince(started)))s.")
                if let resolving = items[current].resolving {
                    session.attachListing(resolving.product, url: url, screenshot: resolving.screenshot)
                }
                if items[current].isPhoto && !items[current].searched {
                    items[current].searched = true
                    log(id, "Searching the web for this photo's listing.")
                    runSearch(placement)
                }
            } catch {
                guard !Task.isCancelled, valid(id, attempt, placement), let current = items.firstIndex(where: { $0.id == id }) else { continue }
                let stage = String(describing: items[current].stage)
                let details = ImportDiagnostics.describe(error)
                log(id, "Import failed during \(stage): " + details, warning: true)
                items[current].stage = nil
                items[current].state = "Failed"; items[current].failure = details
            }
        }
    }
    private func valid(_ id: UUID, _ attempt: UUID, _ placement: String?) -> Bool {
        guard items.contains(where: { $0.id == id && $0.attempt == attempt }) else { return false }
        return placement.map { session?.document.placements[$0] != nil } ?? true
    }
    private func logCutoutDiagnostic(_ line: String, id: UUID, attempt: UUID, placement: String) {
        guard valid(id, attempt, placement) else { return }
        log(id, line)
    }
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && ($0.state == "Failed" || $0.canRetryBackground) }) else { return }
        log(id, "Manual retry requested.")
        if !items.contains(where: { $0.state == "Queued" || $0.state == "Processing" }) { batchIDs = [] }
        batchIDs.removeAll { $0 == id }
        batchIDs.append(id)
        items[index].attempt = UUID(); items[index].failure = nil; items[index].state = "Queued"; start()
    }
    func dismiss(_ id: UUID) {
        let placement = items.first { $0.id == id }?.placementID
        batchIDs.removeAll { $0 == id }
        items.removeAll { $0.id == id }
        if let placement { session?.deletePlacement(placement) }
    }
    func deleted(_ placement: String) {
        let removed = Set(items.filter { $0.placementID == placement }.map(\.id))
        batchIDs.removeAll { removed.contains($0) }
        items.removeAll { $0.placementID == placement }
    }

    /// Rows in the Imports sheet that are not finished.
    var pendingCount: Int { items.filter { $0.state != "Ready" }.count }

    /// Searches the web for the listing an imported photo shows, and imports the one it finds onto that photo's Product.
    /// Finding nothing, or failing, leaves the Product as it is.
    private func runSearch(_ placement: String) {
        guard let session, let product = session.document.placements[placement].flatMap({ session.document.products[$0.productID] }) else { return }
        let photo = product.originalAsset ?? product.asset
        Task { [weak self, search] in
            // The whole photo, not the Cutout: the shop is read off its interface.
            guard let data = await session.importedAssets.load(photo),
                  let listing = try? await search(.init(data: data, aspect: product.aspect)),
                  let self, session.document.placements[placement] != nil else { return }
            let record = SharedImport(url: listing.url)
            enqueue(Item(id: record.id, record: record, resolving: (product.id, photo), placementID: placement))
            start()
        }
    }
}
