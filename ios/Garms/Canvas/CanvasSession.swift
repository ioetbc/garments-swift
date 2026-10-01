import SwiftUI
import Observation
import PencilKit

@Observable @MainActor final class CanvasSession {
    @ObservationIgnored var document = CanvasFixtures.make()
    @ObservationIgnored var camera = CanvasCamera()
    @ObservationIgnored var viewport = CGSize.zero
    @ObservationIgnored private(set) var hasInitialLayout = false
    @ObservationIgnored let index = CanvasSpatialIndex()
    @ObservationIgnored var groups: [[String]] = []
    @ObservationIgnored var committedGroups: [[String]] = []
    @ObservationIgnored var detachedLinks: Set<CanvasGroupLink> = []
    @ObservationIgnored var elasticLink: (moving: String, target: String)?
    @ObservationIgnored var groupingPreview: (moving: String, target: String)?
    @ObservationIgnored var render: (() -> Void)?
    @ObservationIgnored var resolveInteraction: (() -> Void)?
    @ObservationIgnored let importedAssets = ImportedAssetLibrary()
    @ObservationIgnored lazy var imports = ImportCoordinator(session: self)
    let history = CanvasHistory()
    var revision = 0
    var selection: String?
    var inspectedPlacement: StickerPlacement?
    var inspectedGroup: CanvasNamedGroup?
    var error: String?
    var isDrawing = false
    @ObservationIgnored var inkDrawing = PKDrawing()
    private(set) var availability: [String: GarmsAPI.ProductClassification] = [:]

    private(set) var showOtherCanvases = true
    @ObservationIgnored private var otherCanvasesCamera: CanvasCamera?
    var displayedCanvases: [CanvasProfile] { showOtherCanvases ? visibleCanvases : [] }

    func isVisible(_ placement: StickerPlacement) -> Bool {
        showOtherCanvases || placement.canvasUsername == nil
    }

    func isVisible(_ group: CanvasNamedGroup) -> Bool {
        group.members.isEmpty || group.members.contains { id in
            document.placements[id].map { isVisible($0) } ?? false
        }
    }

    func toggleOtherCanvases() {
        resolveInteraction?()
        inspectedPlacement = nil
        inspectedGroup = nil
        selection = nil
        if showOtherCanvases {
            otherCanvasesCamera = camera
            showOtherCanvases = false
            revealCanvas(nil)
        } else {
            showOtherCanvases = true
            if let previous = otherCanvasesCamera { camera = previous }
            cameraChanged()
        }
    }

    var visibleCanvases: [CanvasProfile] {
        let _ = revision
        return document.visibleCanvases ?? []
    }

    var followedCanvases: [CanvasProfile] {
        visibleCanvases.filter { isFollowing($0) }
    }

    func isFollowing(_ user: CanvasProfile) -> Bool {
        let _ = revision
        return document.followedUsernames?.contains(user.username) == true
    }

    func previewCanvas(_ user: CanvasProfile) {
        openCanvas(user, following: false)
    }

    func follow(_ user: CanvasProfile) {
        openCanvas(user, following: true)
    }

    private func openCanvas(_ user: CanvasProfile, following: Bool) {
        guard hasInitialLayout else { return }
        resolveInteraction?()
        showOtherCanvases = true
        let before = snapshot()
        if following && !isFollowing(user) {
            document.followedUsernames = (document.followedUsernames ?? []) + [user.username]
        }
        if visibleCanvases.contains(user) {
            complete(before.document, baseline: before)
            if !following { revealCanvas(user.username) }
            return
        }
        var copy = CanvasFixtures.canvas(for: user)
        let source = copy.canvasBounds(user.username)
        var occupied = (document.namedGroups ?? []).reduce(document.canvasBounds(nil)) {
            $0.union($1.bounds(in: document))
        }
        if occupied.isNull { occupied = CGRect(x: camera.center.x, y: camera.center.y, width: 0, height: 0) }
        let delta = WorldPoint(x: occupied.maxX + CanvasConfiguration.canvasSpacing - source.minX, y: occupied.minY - source.minY)
        for id in copy.order {
            if var placement = copy.placements[id] {
                placement.center = placement.center + delta
                copy.placements[id] = placement
            }
        }
        document.products.merge(copy.products) { _, new in new }
        document.placements.merge(copy.placements) { _, new in new }
        document.order += copy.order
        document.namedGroups = (document.namedGroups ?? []) + (copy.namedGroups ?? [])
        document.visibleCanvases = visibleCanvases + [user]
        complete(before.document, baseline: before)
        revealCanvas(user.username)
    }

    func unfollow(_ user: CanvasProfile) {
        resolveInteraction?()
        let before = snapshot()
        let ids = Set(document.canvasMembers(user.username))
        let products = Set(ids.compactMap { document.placements[$0]?.productID })
        document.placements = document.placements.filter { !ids.contains($0.key) }
        document.products = document.products.filter { !products.contains($0.key) }
        document.order.removeAll { ids.contains($0) }
        document.namedGroups?.removeAll { $0.members.contains(where: ids.contains) }
        document.visibleCanvases?.removeAll { $0.id == user.id }
        document.followedUsernames?.removeAll { $0 == user.username }
        complete(before.document, baseline: before)
        revealCanvas(nil)
    }

    func revealCanvas(_ username: String?) {
        resolveInteraction?()
        searchQuery = ""
        selection = nil
        let bounds = document.canvasBounds(username).insetBy(dx: -60, dy: -100)
        guard !bounds.isNull, viewport.width > 0, viewport.height > 0 else { return }
        camera.center = .init(x: bounds.midX, y: bounds.midY)
        camera.zoom = max(CanvasConfiguration.zoom.lowerBound,
            min(1, min(viewport.width / bounds.width, max(100, viewport.height - 200) / bounds.height)))
        cameraChanged()
    }

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
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dimmedPlacementIDs = []
            dimmedGroupIDs = []
            return
        }
        let groupMatches = Set(namedGroups.filter { CanvasSearch.matches($0.name, query: searchQuery) }.flatMap(\.members))
        let productMatches = Set(document.products.values.filter { $0.matchesSearch(searchQuery) }.map(\.id))
        dimmedPlacementIDs = Set(document.placements.values.filter {
            !groupMatches.contains($0.id) && !productMatches.contains($0.productID)
        }.map(\.id))
        dimmedGroupIDs = Set(namedGroups.filter {
            $0.members.isEmpty
                ? !CanvasSearch.matches($0.name, query: searchQuery)
                : $0.members.allSatisfy { dimmedPlacementIDs.contains($0) }
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
        let bounds = CanvasGeometry.union(Array(document.placements.values))
        let center = WorldPoint(x: bounds.isNull ? size.width / 2 : bounds.maxX + 250, y: size.height / 2)
        document.namedGroups = (document.namedGroups ?? []) + [CanvasNamedGroup(
            id: CanvasNamedGroup.recentUploadsID, members: [], name: "Recent uploads",
            backgroundColour: .init(red: 0.22, green: 1, blue: 0.08), emptyCenter: center)]
        hasInitialLayout = true
        refresh()
        imports.start()
    }
    func refresh(rebuild: Bool = true) {
        revision &+= 1
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
        let before = snapshot()
        // Keep the last valid title while the field is cleared for replacement.
        if !trimmed.isEmpty { document.namedGroups?[index].name = String(trimmed.prefix(60)) }
        document.namedGroups?[index].backgroundColour = backgroundColour
        refresh()
        history.record(before: before, after: snapshot(), key: "group-" + id)
        pruneImportedAssets()
    }
    func updateProductNotes(_ id: String, notes: String) {
        guard let product = document.products[id], product.notes ?? "" != notes else { return }
        let before = snapshot()
        document.products[id]?.notes = notes.isEmpty ? nil : notes
        revision &+= 1
        history.record(before: before, after: snapshot(), key: "product-notes-" + id)
        pruneImportedAssets()
    }

    func updateGroupNotes(_ id: String, notes: String) {
        guard let index = document.namedGroups?.firstIndex(where: { $0.id == id }),
              document.namedGroups?[index].notes ?? "" != notes else { return }
        let before = snapshot()
        document.namedGroups?[index].notes = notes.isEmpty ? nil : notes
        revision &+= 1
        history.record(before: before, after: snapshot(), key: "group-notes-" + id)
        pruneImportedAssets()
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
        let used = Set(document.placements.values.map(\.productID))
        document.products = document.products.filter { $0.value.isImported != true || used.contains($0.key) }
        complete(before)
        if document.placements[id] == nil { imports.deleted(id) }
    }
    func snapshot(document: CanvasDocument? = nil) -> CanvasSnapshot {
        CanvasSnapshot(document: document ?? self.document, groups: committedGroups,
                       detachedLinks: detachedLinks, ink: inkDrawing)
    }
    func complete(_ before: CanvasDocument, baseline: CanvasSnapshot? = nil, recordHistory: Bool = true) {
        let previous = baseline ?? snapshot(document: before)
        do { try document.validate() }
        catch {
            document = before
            self.error = error.localizedDescription
            refresh()
            return
        }
        refresh()
        if recordHistory { history.record(before: previous, after: snapshot()) }
        else { history.enrichImport(from: before, to: document) }
        pruneImportedAssets()
    }
    func updateInk(_ drawing: PKDrawing, key: String? = nil) {
        let before = snapshot()
        inkDrawing = drawing
        history.record(before: before, after: snapshot(), key: key)
        pruneImportedAssets()
    }
    func undo() {
        resolveInteraction?()
        guard let state = history.undo() else { return }
        restore(state)
    }
    func redo() {
        resolveInteraction?()
        guard let state = history.redo() else { return }
        restore(state)
    }
    private func restore(_ state: CanvasSnapshot) {
        for id in document.placements.keys where state.document.placements[id] == nil {
            imports.deleted(id)
        }
        document = state.document
        committedGroups = state.groups
        detachedLinks = state.detachedLinks
        elasticLink = nil
        groupingPreview = nil
        inkDrawing = state.ink
        inspectedPlacement = nil
        inspectedGroup = nil
        refresh()
        pruneImportedAssets()
    }
    func revealImport(_ id: String) {
        resolveInteraction?()
        searchQuery = ""
        if let placement = document.placements[id] { camera.center = placement.center }
        select(id)
    }
    func insertImport(_ record: SharedImport, artwork: ImportedImageDownload.Artwork) -> String? {
        guard hasInitialLayout, artwork.aspect.isFinite, artwork.aspect > 0 else { return nil }
        resolveInteraction?()
        guard let recentIndex = document.namedGroups?.firstIndex(where: \.isRecentUploads),
              let recent = document.namedGroups?[recentIndex] else { return nil }
        let before = document
        let baseline = snapshot()
        let productID = UUID().uuidString
        let asset = importedAssets.insert(artwork.data)
        let product = SampleProduct(id: productID, title: record.suggestedTitle ?? URL(string: record.url)?.host ?? "Saved link", category: "", asset: asset, aspect: artwork.aspect, product_url: record.url, isImported: true)
        let edge = CanvasConfiguration.initialImageEdge
        let width = product.aspect >= 1 ? edge : edge * product.aspect
        let height = product.aspect >= 1 ? edge / product.aspect : edge
        let bounds = recent.bounds(in: document)
        let center = recent.members.isEmpty ? WorldPoint(x: bounds.midX, y: bounds.midY)
            : WorldPoint(x: bounds.maxX + CanvasConfiguration.magneticRestGap + width / 2, y: bounds.midY)
        let placement = StickerPlacement(productID: productID, center: center, width: width, height: height)
        document.products[productID] = product
        document.placements[placement.id] = placement
        document.order.append(placement.id)
        document.namedGroups?[recentIndex].members.append(placement.id)
        document.namedGroups?[recentIndex].emptyCenter = center
        committedGroups.removeAll { group in group.contains(where: recent.members.contains) }
        committedGroups.append(recent.members + [placement.id])
        complete(before, baseline: baseline)
        guard document.placements[placement.id] != nil else { pruneImportedAssets(); return nil }
        searchQuery = ""
        revealImport(placement.id)
        return placement.id
    }
    private func pruneImportedAssets() {
        importedAssets.retain(Set(document.products.values.flatMap { $0.referencedAssets }).union(history.referencedAssets))
    }
    @discardableResult
    func appendImportPhoto(_ id: String, artwork: ImportedImageDownload.Artwork) -> String? {
        guard let placement = document.placements[id], var product = document.products[placement.productID],
              artwork.aspect.isFinite, artwork.aspect > 0 else { return nil }
        let before = document
        let asset = importedAssets.insert(artwork.data)
        product.galleryAssets = (product.galleryAssets ?? []) + [asset]
        document.products[product.id] = product
        complete(before, recordHistory: false)
        pruneImportedAssets()
        return document.products[product.id] == product ? asset : nil
    }
    @discardableResult
    func installImportOriginal(_ id: String, title: String?, artwork: ImportedImageDownload.Artwork) -> String? {
        updateImport(id, title: title, artwork: artwork, original: true)
    }
    @discardableResult
    func applyImportCutout(_ id: String, artwork: ImportedImageDownload.Artwork) -> String? {
        guard let placement = document.placements[id], document.products[placement.productID]?.originalAsset != nil else { return nil }
        return updateImport(id, title: nil, artwork: artwork, original: false)
    }
    @discardableResult
    func updateImport(_ id: String, title: String?, artwork: ImportedImageDownload.Artwork?, original: Bool = true) -> String? {
        guard document.placements[id] != nil else { return nil }
        resolveInteraction?()
        guard var placement = document.placements[id], var product = document.products[placement.productID] else { return nil }
        if let artwork { guard artwork.aspect.isFinite, artwork.aspect > 0 else { return nil } }
        let before = document
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { product.title = title }
        if let artwork {
            product.asset = importedAssets.insert(artwork.data)
            if original { product.originalAsset = product.asset }
            product.aspect = artwork.aspect
            let edge = max(placement.width, placement.height)
            placement.width = artwork.aspect >= 1 ? edge : edge * artwork.aspect
            placement.height = artwork.aspect >= 1 ? edge / artwork.aspect : edge
        }
        document.products[product.id] = product
        document.placements[id] = placement
        complete(before, recordHistory: false)
        pruneImportedAssets()
        return document.products[product.id] == product ? product.asset : nil
    }
    // These also provide non-gesture equivalents for VoiceOver.
    func nudge(x: Double, y: Double) {
        guard let p = selected.first else { return }
        let before = document
        let ids = p.canvasUsername.map { document.canvasMembers($0) } ?? [p.id]
        for id in ids {
            if let item = document.placements[id] {
                document.placements[id]?.center = item.center + .init(x:x/camera.zoom,y:y/camera.zoom)
            }
        }
        complete(before)
    }
    func resize(_ factor: Double) {
        guard let p = selected.first, p.canvasUsername == nil else { return }
        let before = document
        document.placements[p.id] = CanvasGeometry.scaled([p],anchor:p.center,destination:p.center,scale:factor).first
        complete(before)
    }
    func cameraChanged() { render?() }
}
