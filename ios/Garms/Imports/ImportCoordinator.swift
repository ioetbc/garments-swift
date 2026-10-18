import Foundation
import Observation
import OSLog
import ImageIO

@Observable @MainActor final class ImportCoordinator {
    enum Stage { case loadingPhoto, fetching, downloading, removingBackground }
    struct Checkpoint { let asset: String; let aspect: Double }
    struct Item: Identifiable {
        let id: UUID
        let record: SharedImport
        var photoLoader: (() async throws -> Data)?
        var isPhoto = false
        /// Photos marks this image as a Screenshot, so its listing is searched for once it is on the Canvas.
        var isScreenshot = false
        var searched = false
        var displayName: String { isPhoto ? record.suggestedTitle ?? "Photo" : record.url }
        var placementID: String?
        var state = "Queued"
        var failure: String?
        var stage: Stage?
        var note: String?
        var checkpoint: Checkpoint?
        var pendingImages: [String] = []
        var canRetryBackground: Bool { state == "Ready" && note != nil && checkpoint != nil }
        var logs: [String] = ["Queued for import."]
        var diagnosticReport: String {
            "Import: \(id.uuidString)\nSource: \(isPhoto ? "Photos" : record.url)\nState: \(state)\n" + logs.joined(separator: "\n")
        }
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
        guard active, let item = items.first(where: { $0.state == "Processing" }) ?? batchIDs.compactMap({ id in items.first { $0.id == id && $0.state == "Queued" } }).first,
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
    @ObservationIgnored private var active = false
    @ObservationIgnored private var draining = false
    @ObservationIgnored let inbox: SharedImportInbox
    @ObservationIgnored private let acknowledge: (URL) throws -> Void
    @ObservationIgnored private let fetch: (String) async throws -> GarmsAPI.ImportedProduct
    @ObservationIgnored private let image: (String) async throws -> ImportedImageDownload.Artwork
    @ObservationIgnored private let cutout: ((ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork?)?
    @ObservationIgnored private let search: (ImportedImageDownload.Artwork) async throws -> [Product.Match.Candidate]
    init(session: CanvasSession, inbox: SharedImportInbox = .init(),
         acknowledge: ((URL) throws -> Void)? = nil,
         fetch: @escaping (String) async throws -> GarmsAPI.ImportedProduct = { try await GarmsAPI.importProduct(url: $0) },
         image: @escaping (String) async throws -> ImportedImageDownload.Artwork = { try await ImportedImageDownload.fetch($0) },
         cutout: ((ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork?)? = nil,
         search: ((ImportedImageDownload.Artwork) async throws -> [Product.Match.Candidate])? = nil) {
        self.session = session; self.inbox = inbox; self.fetch = fetch; self.image = image; self.cutout = cutout
        self.acknowledge = acknowledge ?? { try inbox.acknowledge($0) }
        self.search = search ?? { [sync = session.sync] in try await sync.findCandidates(try await Self.searchImage($0)) }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { drain(); start() }
        else {
            processor?.cancel()
            for index in items.indices where items[index].state == "Processing" {
                log(items[index].id, "Paused because the app became inactive; processing will resume.")
                items[index].attempt = UUID(); items[index].state = "Queued"
            }
        }
    }
    func loadTestLinks(_ links: [String]) {
        do {
            let links = try links.map(SharedLink.normalized)
            var existing = Set(items.compactMap { try? SharedLink.normalized($0.record.url) })
            for url in links where existing.insert(url).inserted {
                let record = SharedImport(url: url)
                // Bundled canvas fixtures may already use these URLs. Create a real
                // import so the test still exercises fetching and image processing.
                enqueue(Item(id: record.id, record: record))
            }
            start()
        } catch { session?.error = error.localizedDescription }
    }
    /// `screenshotCheck` says how `screenshot` was decided, for the import log.
    func importPhoto(title: String = "Imported photo", screenshot: Bool, screenshotCheck: String = "", load: @escaping () async throws -> Data) {
        let record = SharedImport(url: "", suggestedTitle: title)
        var item = Item(id: record.id, record: record, photoLoader: load, isPhoto: true, isScreenshot: screenshot)
        if !screenshotCheck.isEmpty { item.logs.append(screenshotCheck + (screenshot ? "" : " Not searched for its listing.")) }
        enqueue(item)
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
        guard active, session?.hasInitialLayout == true else { return }
        // A search interrupted by the app closing never finished, so it runs now; a finished one never runs again.
        for product in awaitingMatch where product.match?.status == .searching { runSearch(product.id) }
        guard processor == nil else { return }
        processor = Task { [weak self] in
            guard let self else { return }
            await process()
            processor = nil
            if active && items.contains(where: { $0.state == "Queued" }) { start() }
        }
    }
    private static let logger = Logger(subsystem: "f.garment-swift-2", category: "Import")
    private func log(_ id: UUID, _ message: String, warning: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let line = "[\(Date().ISO8601Format())] \(warning ? "WARNING" : "INFO") \(message)"
        items[index].logs.append(line)
        if items[index].logs.count > 300 { items[index].logs.removeFirst() }
        if warning { Self.logger.warning("\(id.uuidString, privacy: .public) \(message, privacy: .public)") }
        else { Self.logger.info("\(id.uuidString, privacy: .public) \(message, privacy: .public)") }
    }
    private func process() async {
        while active && !Task.isCancelled, let id = batchIDs.first(where: { id in items.contains { $0.id == id && $0.state == "Queued" } }),
              let index = items.firstIndex(where: { $0.id == id }) {
            guard let session else { return }
            var placement = items[index].placementID
            let id = items[index].id, attempt = UUID(), url = items[index].record.url
            items[index].attempt = attempt; items[index].state = "Processing"; items[index].failure = nil
            items[index].note = nil
            let started = Date()
            log(id, "Starting processing attempt \(attempt.uuidString). Waiting for product artwork.")
            do {
                let source: ImportedImageDownload.Artwork
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
                    source = try await ImportedImageDownload.prepare(data)
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement),
                          let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    if placement == nil {
                        placement = session.insertImport(items[current].record, artwork: source)
                        items[current].placementID = placement
                    }
                    guard let placement,
                          let asset = session.installImportOriginal(placement, title: nil, price: nil, artwork: source) else {
                        throw ImportedImageDownload.ImageError.invalid
                    }
                    items[current].checkpoint = Checkpoint(asset: asset, aspect: source.aspect)
                    items[current].photoLoader = nil
                    log(id, "Photo decoded and original installed on canvas (\(source.data.count) PNG bytes).")
                } else {
                    items[index].checkpoint = nil
                    items[index].stage = .fetching
                    log(id, "Fetching product metadata and markdown via API /api/import → Firecrawl.")
                    let result = try await fetch(url)
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement) else { continue }
                    for line in result.diagnostics ?? [] { log(id, "Server: " + line) }
                    log(id, "Metadata received. Title: \(result.title ?? "missing"). Image candidate: \(result.imageURL == nil ? "missing" : "present").")
                    guard let address = result.imageURLs?.first ?? result.imageURL else { throw ImportedImageDownload.ImageError.detail("The page returned no usable HTTPS product image URL. Cannot download product artwork.") }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    var seenImages: Set<String> = [address]
                    items[current].pendingImages = (result.imageURLs ?? []).filter { seenImages.insert($0).inserted }
                    items[current].stage = .downloading
                    log(id, "Downloading image from \(URL(string: address)?.host ?? "unknown host") and decoding to a PNG bounded to 2,048 pixels.")
                    source = try await image(address)
                    try Task.checkCancellation()
                    guard valid(id, attempt, placement) else { continue }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    if placement == nil {
                        var record = items[current].record
                        record.suggestedTitle = result.title ?? record.suggestedTitle
                        placement = session.insertImport(record, artwork: source)
                        items[current].placementID = placement
                    }
                    guard let placement,
                          let asset = session.installImportOriginal(placement, title: result.title, price: result.price, artwork: source) else {
                        throw ImportedImageDownload.ImageError.invalid
                    }
                    guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                    items[current].checkpoint = Checkpoint(asset: asset, aspect: source.aspect)
                    log(id, "Image downloaded, decoded and installed on canvas (\(source.data.count) PNG bytes; aspect \(source.aspect)).")
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
                items[current].state = "Ready"
                items[current].stage = nil
                if installed == nil {
                    let reason = warning ?? "A cutout was generated but could not be installed on the canvas."
                    items[current].note = "Background kept: " + reason
                    log(id, "Background removal finished after \(String(format: "%.2f", Date().timeIntervalSince(cutoutStarted)))s. Original kept. " + reason, warning: true)
                } else {
                    log(id, "Background removed and cutout installed on canvas in \(String(format: "%.2f", Date().timeIntervalSince(cutoutStarted)))s (\(extracted?.data.count ?? 0) PNG bytes).")
                }
                log(id, "Import ready in \(String(format: "%.2f", Date().timeIntervalSince(started)))s.")
                if items[current].isScreenshot && !items[current].searched,
                   let productID = session.document.placements[placement]?.productID {
                    items[current].searched = true
                    log(id, "Screenshot: searching the web for its listing.")
                    runSearch(productID)
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
        guard active, items.contains(where: { $0.id == id && $0.attempt == attempt }) else { return false }
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

    // MARK: Awaiting match

    /// Products imported from a Screenshot whose link is not yet resolved, oldest first. Each is a row in the Imports sheet.
    var awaitingMatch: [Product] {
        guard let session else { return [] }
        _ = session.revision
        let document = session.document
        let z = Dictionary(document.placements.values.map { ($0.productID, $0.z) }, uniquingKeysWith: min)
        return document.products.values.filter { $0.match != nil }
            .sorted { (z[$0.id] ?? "", $0.id) < (z[$1.id] ?? "", $1.id) }
    }
    /// Products whose confirmed link is being imported.
    private(set) var loadingMatches: Set<String> = []
    /// A short note about the last resolution, such as a merge into an existing Product.
    var notice: String?
    @ObservationIgnored private var searching: Set<String> = []

    private func runSearch(_ productID: String) {
        guard let session, session.document.products[productID] != nil, searching.insert(productID).inserted else { return }
        session.setMatch(productID, .init(status: .searching))
        Task { [weak self, search] in
            var match = Product.Match(status: .failed)
            // The whole Screenshot, not the Cutout: the shop is read off its interface.
            if let product = session.document.products[productID], let data = await session.importedAssets.load(product.originalAsset ?? product.asset) {
                do {
                    let candidates = try await search(.init(data: data, aspect: product.aspect))
                    match = .init(status: candidates.isEmpty ? .notFound : .found, candidates: Array(candidates.prefix(5)))
                } catch {}
            }
            self?.searching.remove(productID)
            // Resolved meanwhile (confirmed, pasted or skipped): the result is no longer wanted.
            guard session.document.products[productID]?.match?.status == .searching else { return }
            session.setMatch(productID, match)
            // The search returns the one listing it is surest of: import it straight away.
            if let found = match.candidates.first { self?.confirm(productID, url: found.url) }
        }
    }
    /// Searches again after a failed search.
    func retrySearch(_ productID: String) {
        guard session?.document.products[productID]?.match?.status == .failed else { return }
        runSearch(productID)
    }
    /// Imports this link onto the Product Awaiting match: a tapped Candidate match or a pasted link.
    /// A link already saved on another Product links the Sticker to that Product instead.
    func confirm(_ productID: String, url: String) {
        guard let session, session.document.products[productID]?.match != nil, !loadingMatches.contains(productID) else { return }
        notice = nil
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = try? SharedLink.normalized(url) else { notice = SharedLink.LinkError.invalid.localizedDescription; return }
        if let existing = session.document.products.values.first(where: { $0.id != productID && (try? SharedLink.normalized($0.product_url)) == key }) {
            session.mergeProduct(productID, into: existing.id)
            notice = "Already saved — linked to your existing item."
            return
        }
        loadingMatches.insert(productID)
        Task { [weak self, fetch, image, cutout] in
            do {
                let page = try await fetch(url)
                var addresses: [String] = []
                for address in (page.imageURLs ?? []) + [page.imageURL].compactMap({ $0 }) where !addresses.contains(address) { addresses.append(address) }
                guard let first = addresses.first else { throw ImportedImageDownload.ImageError.detail("The page has no product image.") }
                let original = try await image(first)
                let extracted = if let cutout { try? await cutout(original) } else { try? await ForegroundCutoutProcessor.extract(original) }
                var photos: [ImportedImageDownload.Artwork] = []
                for address in addresses.dropFirst() {
                    if let photo = try? await image(address) { photos.append(photo) }
                }
                self?.loadingMatches.remove(productID)
                session.resolveMatch(productID, url: url, page: page, original: original, cutout: extracted.flatMap { $0 }, photos: photos)
            } catch {
                self?.loadingMatches.remove(productID)
                guard var match = session.document.products[productID]?.match else { return }
                match.status = .loadFailed
                session.setMatch(productID, match)
            }
        }
    }
    /// None of these, or Skip: keeps the Product as imported, with no link.
    func skipMatch(_ productID: String) {
        notice = nil
        session?.setMatch(productID, nil)
    }
    /// The image sent to search: the Screenshot flattened onto white, as JPEG.
    nonisolated static func searchImage(_ artwork: ImportedImageDownload.Artwork) async throws -> Data {
        try await Task.detached {
            guard let image = CanvasImageWorker.decode(data: artwork.data, tier: 1024),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ImportedImageDownload.ImageError.detail("The Screenshot could not be prepared for searching.")
            }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            context.draw(image, in: bounds)
            let output = NSMutableData()
            guard let flat = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                throw ImportedImageDownload.ImageError.detail("The Screenshot could not be prepared for searching.")
            }
            CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImportedImageDownload.ImageError.detail("The Screenshot could not be prepared for searching.") }
            return output as Data
        }.value
    }
}
