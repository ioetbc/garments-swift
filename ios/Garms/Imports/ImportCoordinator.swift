import Foundation
import Observation
import OSLog

@Observable @MainActor final class ImportCoordinator {
    enum Stage { case fetching, downloading, removingBackground }
    struct Checkpoint { let asset: String; let aspect: Double }
    struct Item: Identifiable {
        let id: UUID
        let record: SharedImport
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
            "Import: \(id.uuidString)\nURL: \(record.url)\nState: \(state)\n" + logs.joined(separator: "\n")
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
    init(session: CanvasSession, inbox: SharedImportInbox = .init(),
         acknowledge: ((URL) throws -> Void)? = nil,
         fetch: @escaping (String) async throws -> GarmsAPI.ImportedProduct = { try await GarmsAPI.importProduct(url: $0) },
         image: @escaping (String) async throws -> ImportedImageDownload.Artwork = { try await ImportedImageDownload.fetch($0) },
         cutout: ((ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork?)? = nil) {
        self.session = session; self.inbox = inbox; self.fetch = fetch; self.image = image; self.cutout = cutout
        self.acknowledge = acknowledge ?? { try inbox.acknowledge($0) }
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
        if items.contains(where: { (try? SharedLink.normalized($0.record.url)) == key && $0.placementID == nil }) { return }
        enqueue(Item(id: record.id, record: record))
    }
    func start() {
        guard active, processor == nil, session?.hasInitialLayout == true else { return }
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
                          let asset = session.installImportOriginal(placement, title: result.title, artwork: source) else {
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
}
