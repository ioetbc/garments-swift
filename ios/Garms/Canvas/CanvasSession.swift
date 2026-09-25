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
