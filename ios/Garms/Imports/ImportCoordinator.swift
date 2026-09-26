import Foundation
import Observation

@Observable @MainActor final class ImportCoordinator {
    struct Item: Identifiable {
        let id: UUID
        let record: SharedImport
        var placementID: String?
        var state = "Queued"
        var failure: String?
        var attempt = UUID()
    }
    private(set) var items: [Item] = []
    @ObservationIgnored private weak var session: CanvasSession?
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var processor: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var draining = false
    @ObservationIgnored let inbox: SharedImportInbox
    @ObservationIgnored private let acknowledge: (URL) throws -> Void
    @ObservationIgnored private let fetch: (String) async throws -> GarmsAPI.ImportedProduct
    @ObservationIgnored private let image: (String) async throws -> ImportedImageDownload.Artwork
    init(session: CanvasSession, inbox: SharedImportInbox = .init(),
         acknowledge: ((URL) throws -> Void)? = nil,
         fetch: @escaping (String) async throws -> GarmsAPI.ImportedProduct = { try await GarmsAPI.importProduct(url: $0) },
         image: @escaping (String) async throws -> ImportedImageDownload.Artwork = { try await ImportedImageDownload.fetch($0) }) {
        self.session = session; self.inbox = inbox; self.fetch = fetch; self.image = image
        self.acknowledge = acknowledge ?? { try inbox.acknowledge($0) }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { drain(); start() }
        else {
            processor?.cancel()
            for index in items.indices where items[index].state == "Processing" {
                items[index].attempt = UUID(); items[index].state = "Queued"
            }
        }
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
        items.append(Item(id: record.id, record: record))
    }
    func start() {
        guard active, processor == nil, session?.hasInitialLayout == true else { return }
        // Make every captured link visible as soon as layout is ready, even while
        // an earlier item is waiting on the network.
        for index in items.indices where items[index].placementID == nil && items[index].state == "Queued" {
            items[index].placementID = session?.insertImport(items[index].record)
        }
        processor = Task { [weak self] in
            guard let self else { return }
            await process()
            processor = nil
            if active && items.contains(where: { $0.state == "Queued" }) { start() }
        }
    }
    private func process() async {
        while active && !Task.isCancelled, let index = items.firstIndex(where: { $0.state == "Queued" }) {
            guard let session else { return }
            if items[index].placementID == nil {
                items[index].placementID = session.insertImport(items[index].record)
            }
            guard let placement = items[index].placementID else {
                items[index].state = "Failed"; items[index].failure = "Could not place the saved link."; continue
            }
            let id = items[index].id, attempt = UUID(), url = items[index].record.url
            items[index].attempt = attempt; items[index].state = "Processing"; items[index].failure = nil
            do {
                let result = try await fetch(url)
                try Task.checkCancellation()
                guard valid(id, attempt, placement) else { continue }
                session.updateImport(placement, title: result.title, artwork: nil)
                guard let address = result.imageURL else { throw ImportedImageDownload.ImageError.invalid }
                let artwork = try await image(address)
                try Task.checkCancellation()
                guard valid(id, attempt, placement), let current = items.firstIndex(where: { $0.id == id }) else { continue }
                session.updateImport(placement, title: result.title, artwork: artwork)
                items[current].state = "Ready"
            } catch {
                guard !Task.isCancelled, valid(id, attempt, placement), let current = items.firstIndex(where: { $0.id == id }) else { continue }
                items[current].state = "Failed"; items[current].failure = error.localizedDescription
            }
        }
    }
    private func valid(_ id: UUID, _ attempt: UUID, _ placement: String) -> Bool {
        active && items.contains { $0.id == id && $0.attempt == attempt } && session?.document.placements[placement] != nil
    }
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.state == "Failed" }) else { return }
        items[index].attempt = UUID(); items[index].failure = nil; items[index].state = "Queued"; start()
    }
    func dismiss(_ id: UUID) {
        let placement = items.first { $0.id == id }?.placementID
        items.removeAll { $0.id == id }
        if let placement { session?.deletePlacement(placement) }
    }
    func deleted(_ placement: String) { items.removeAll { $0.placementID == placement } }
}
