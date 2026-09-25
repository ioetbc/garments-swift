import SwiftUI
import Observation

@Observable @MainActor final class CanvasSession {
    @ObservationIgnored var document = CanvasFixtures.make()
    @ObservationIgnored var camera = CanvasCamera()
    @ObservationIgnored var viewport = CGSize.zero
    @ObservationIgnored private var hasInitialLayout = false
    @ObservationIgnored let index = CanvasSpatialIndex()
    @ObservationIgnored var groups: [[String]] = []
    @ObservationIgnored var committedGroups: [[String]] = []
    @ObservationIgnored var detachedLinks: Set<CanvasGroupLink> = []
    @ObservationIgnored var elasticLink: (moving: String, target: String)?
    @ObservationIgnored var groupingPreview: (moving: String, target: String)?
    @ObservationIgnored var render: (() -> Void)?
    @ObservationIgnored var resolveInteraction: (() -> Void)?
    var selection: String?
    var inspectedPlacement: StickerPlacement?
    var inspectedGroup: CanvasNamedGroup?
    var error: String?
    private(set) var availability: [String: GarmsAPI.ProductClassification] = [:]

    func classification(for product: SampleProduct) -> GarmsAPI.ProductClassification? {
        availability[product.id]
    }

    func updateAvailability(_ classification: GarmsAPI.ProductClassification, productID: String) {
        availability[productID] = classification
        render?()
    }

    func opacity(for placement: StickerPlacement) -> Float {
        if dimmedPlacementIDs.contains(placement.id) { return 0.1 }
        guard let product = document.products[placement.productID] else { return 1 }
        return classification(for: product)?.isUnavailable == true ? 0.35 : 1
    }

    func loadAvailability(
        fetch: @escaping @MainActor @Sendable (String) async throws -> GarmsAPI.ProductClassification? = {
            try await GarmsAPI.scrapePage(url: $0).classification
        }
    ) async {
        let productIDs = Set(document.placements.values.map(\.productID))
        let products = productIDs.compactMap { document.products[$0] }
            .filter { !$0.product_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.id < $1.id }
        // Bound startup requests while updating the canvas as each result arrives.
        await withTaskGroup(of: (String, GarmsAPI.ProductClassification?).self) { group in
            var remaining = products.makeIterator()
            func enqueue(_ product: SampleProduct) {
                group.addTask {
                    guard !Task.isCancelled else { return (product.id, nil) }
                    return (product.id, try? await fetch(product.product_url))
                }
            }
            for _ in 0..<3 {
                if let product = remaining.next() { enqueue(product) }
            }
            for await (productID, classification) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let classification { updateAvailability(classification, productID: productID) }
                if let next = remaining.next() { enqueue(next) }
            }
        }
    }
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            updateSearchMatches()
            render?()
        }
    }
    @ObservationIgnored private(set) var dimmedPlacementIDs: Set<String> = []
    @ObservationIgnored private(set) var dimmedGroupIDs: Set<String> = []

    private func updateSearchMatches() {
        let namedGroups = document.namedGroups ?? []
        let groupMatches = Set(namedGroups.filter { CanvasSearch.matches($0.name, query: searchQuery) }.flatMap(\.members))
        let productMatches = Set(document.products.values.filter { $0.matchesSearch(searchQuery) }.map(\.id))
        dimmedPlacementIDs = Set(document.placements.values.filter {
            !groupMatches.contains($0.id) && !productMatches.contains($0.productID)
        }.map(\.id))
        dimmedGroupIDs = Set(namedGroups.filter {
            $0.members.allSatisfy { dimmedPlacementIDs.contains($0) }
        }.map(\.id))
    }
    var selected: [StickerPlacement] { selection.flatMap { document.placements[$0] }.map { [$0] } ?? [] }

    init() {
        refresh()
    }
    func updateViewport(_ size: CGSize) {
        viewport = size
        guard !hasInitialLayout, size.width > 0, size.height > 0 else { return }
        committedGroups = CanvasFixtures.fit(&document,viewport:size)
        camera = CanvasCamera(center:.init(x:size.width/2,y:size.height/2),zoom:1)
        hasInitialLayout = true
        refresh()
    }
    func refresh(rebuild: Bool = true) {
        if rebuild { index.rebuild(document) }
        if selected.isEmpty { selection = nil; inspectedPlacement = nil }
        detachedLinks = detachedLinks.filter { link in
            guard let a = document.placements[link.first], let b = document.placements[link.second] else { return false }
            return CanvasGeometry.distance(a.bounds,b.bounds) <= CanvasConfiguration.detachRadius
        }
        // A preview is presentation state, never membership for the next drag frame.
        committedGroups = CanvasProximity.groups(document:document,index:index,preview:elasticLink,previous:committedGroups,detached:detachedLinks)
        groups = CanvasProximity.groups(document:document,index:index,preview:elasticLink ?? groupingPreview,previous:committedGroups,detached:detachedLinks)
        document.reconcileGroupNames(committedGroups)
        updateSearchMatches()
        render?()
    }
    func inspectGroup(_ id: String) {
        resolveInteraction?()
        inspectedPlacement = nil
        inspectedGroup = document.namedGroups?.first { $0.id == id }
    }
    func updateGroup(_ id: String, name: String, backgroundColour: CanvasGroupColour?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = document.namedGroups?.firstIndex(where: { $0.id == id }) else { return }
        // Keep the last valid title while the field is cleared for replacement.
        if !trimmed.isEmpty { document.namedGroups?[index].name = String(trimmed.prefix(60)) }
        document.namedGroups?[index].backgroundColour = backgroundColour
        updateSearchMatches()
        render?()
    }
    func select(_ id: String?, showDetails: Bool = false) {
        selection = id
        inspectedPlacement = showDetails ? id.flatMap { document.placements[$0] } : nil
        render?()
    }
    func deletePlacement(_ id: String) {
        resolveInteraction?()
        guard document.placements[id] != nil else { return }
        let before = document
        document.placements[id] = nil
        document.order.removeAll { $0 == id }
        complete(before)
    }
    func complete(_ before: CanvasDocument) {
        do { try document.validate() }
        catch { document = before; self.error = error.localizedDescription }
        refresh()
    }
    // These also provide non-gesture equivalents for VoiceOver.
    func nudge(x: Double, y: Double) {
        guard let p = selected.first else { return }
        let before = document
        document.placements[p.id]?.center = p.center + .init(x:x/camera.zoom,y:y/camera.zoom)
        complete(before)
    }
    func resize(_ factor: Double) {
        guard let p = selected.first else { return }
        let before = document
        document.placements[p.id] = CanvasGeometry.scaled([p],anchor:p.center,destination:p.center,scale:factor).first
        complete(before)
    }
    func cameraChanged() { render?() }
}
