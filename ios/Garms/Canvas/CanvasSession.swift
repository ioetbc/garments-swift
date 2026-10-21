import SwiftUI
import Observation

@Observable @MainActor final class CanvasSession {
    /// Changes only through `edit`, or `stage` for a gesture's uncommitted frames.
    @ObservationIgnored private(set) var document = CanvasDocument()
    @ObservationIgnored var camera = CanvasCamera()
    @ObservationIgnored var viewport = CGSize.zero
    var hasInitialLayout: Bool { hasLoaded && viewport.width > 0 && viewport.height > 0 }
    /// The first snapshot has arrived; until then the Canvas is empty and not editable.
    private(set) var hasLoaded = false
    /// Offline, the Canvas stays viewable but every edit is refused.
    private(set) var isOnline = true
    @ObservationIgnored let sync: CanvasSync
    @ObservationIgnored let server: GarmsServer
    @ObservationIgnored private var viewportSave: Task<Void, Never>?
    static let offlineMessage = "You're offline, so the canvas is read-only. Your changes can't be saved until you reconnect."
    @ObservationIgnored let index = CanvasSpatialIndex()
    @ObservationIgnored var groups: [[String]] = []
    @ObservationIgnored private(set) var detachedLinks: Set<CanvasGroupLink> = []
    // ponytail: presentation-only, never saved or recorded, so the gesture sets these directly.
    @ObservationIgnored var elasticLink: (moving: String, target: String)?
    @ObservationIgnored var groupingPreview: (moving: String, target: String)?
    @ObservationIgnored var render: (() -> Void)?
    @ObservationIgnored var resolveInteraction: (() -> Void)?
    @ObservationIgnored let importedAssets: ImportedAssetLibrary
    @ObservationIgnored lazy var imports = ImportCoordinator(session: self)
    let history = CanvasHistory()
    var revision = 0
    var selection: String?
    var inspectedPlacement: StickerPlacement?
    var inspectedGroup: CanvasNamedGroup?
    var error: String?

    func opacity(for placement: StickerPlacement) -> Float {
        dimmedPlacementIDs.contains(placement.id) ? 0.1 : 1
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
        let namedGroups = document.namedGroups
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

    init(sync: CanvasSync, server: GarmsServer) {
        self.sync = sync
        self.server = server
        importedAssets = ImportedAssetLibrary(sync: sync)
        importedAssets.failure = { [weak self] in self?.error = $0 }
        refresh()
        sync.connect(snapshot: { [weak self] in self?.receive($0) },
                     online: { [weak self] in self?.isOnline = $0 })
    }
    func updateViewport(_ size: CGSize) {
        viewport = size
        imports.start()
    }

    /// Applies a stored snapshot: the cached one, then the server's once at launch.
    func receive(_ remote: CanvasRemote) {
        importedAssets.urls.merge(remote.files.compactMapValues(URL.init(string:))) { $1 }
        if !hasLoaded {
            let opened = CanvasCamera(center: .init(x: remote.viewport.x, y: remote.viewport.y), zoom: remote.viewport.zoom)
            camera = opened.valid ? opened : CanvasCamera()
            hasLoaded = true
        }
        let incoming = remote.document
        if incoming != document || remote.detachedLinks != detachedLinks {
            for id in document.placements.keys where incoming.placements[id] == nil { imports.deleted(id) }
            load(CanvasSnapshot(document: incoming, detachedLinks: remote.detachedLinks))
            elasticLink = nil
            groupingPreview = nil
            if let group = inspectedGroup { inspectedGroup = document.namedGroups.first { $0.id == group.id } }
        }
        refresh()
        imports.start()
    }
    /// Refuses an edit while offline, saying why.
    private func editable() -> Bool {
        if !isOnline { error = Self.offlineMessage }
        return isOnline
    }
    /// Sends the rows that changed since `before`. Last write wins per row.
    private func save(from before: CanvasSnapshot) {
        let changes = CanvasChangeSet(from: before.document, before.detachedLinks, to: document, detachedLinks)
        guard !changes.isEmpty else { return }
        sync.apply(changes) { [weak self] failure in
            if let failure { self?.error = "Your last change couldn't be saved, so this canvas may not match your other devices. \(failure.localizedDescription)" }
        }
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
        let committed = CanvasProximity.groups(document:document,index:index,preview:elasticLink,previous:document.committedGroups,detached:detachedLinks)
        groups = CanvasProximity.groups(document:document,index:index,preview:elasticLink ?? groupingPreview,previous:committed,detached:detachedLinks)
        document.reconcileGroupNames(committed)
        updateSearchMatches()
        render?()
    }
    func inspectGroup(_ id: String) {
        resolveInteraction?()
        inspectedPlacement = nil
        inspectedGroup = document.namedGroups.first { $0.id == id }
    }
    func updateGroup(_ id: String, name: String, backgroundColour: CanvasGroupColour?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editGroup(id, key: "group-") { group in
            // Keep the last valid title while the field is cleared for replacement.
            if !trimmed.isEmpty { group.name = String(trimmed.prefix(60)) }
            group.backgroundColour = backgroundColour
        }
    }
    func updateGroupNotes(_ id: String, notes: String) {
        editGroup(id, key: "group-notes-") { $0.notes = notes.isEmpty ? nil : notes }
    }
    private func editGroup(_ id: String, key: String, _ change: (inout CanvasNamedGroup) -> Void) {
        edit(history: .record(key: key + id)) { snapshot in
            if let index = snapshot.document.namedGroups.firstIndex(where: { $0.id == id }) { change(&snapshot.document.namedGroups[index]) }
        }
    }
    /// One edit to a Product's own fields, shown on every Sticker of it. Edits with the same key coalesce in undo.
    func editProduct(_ id: String, key: String, _ change: (inout Product) -> Void) {
        edit(history: .record(key: key + id)) { snapshot in
            if snapshot.document.products[id] != nil { change(&snapshot.document.products[id]!) }
        }
    }
    func updateProductNotes(_ id: String, notes: String) {
        editProduct(id, key: "product-notes-") { $0.notes = notes.isEmpty ? nil : notes }
    }
    func updateProductTitle(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editProduct(id, key: "product-title-") { $0.title = trimmed }
    }
    func updateProductCategory(_ id: String, category: String) {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        editProduct(id, key: "product-category-") { $0.category = trimmed.isEmpty ? nil : trimmed }
    }
    func updateProductPrice(_ id: String, price: Price?) {
        editProduct(id, key: "product-price-") { $0.price = price }
    }

    func select(_ id: String?, showDetails: Bool = false) {
        selection = id
        inspectedPlacement = showDetails ? id.flatMap { document.placements[$0] } : nil
        render?()
    }
    func deletePlacement(_ id: String) {
        resolveInteraction?()
        guard document.placements[id] != nil else { return }
        // The Product stays; sharing its link again places it again.
        edit { $0.document.placements[id] = nil }
        if document.placements[id] == nil { imports.deleted(id) }
    }
    /// Deletes the Product, every Sticker of it and its stored files. Not undoable: the files are gone.
    func deleteProduct(_ id: String) {
        resolveInteraction?()
        guard document.products[id] != nil, editable() else { return }
        let removed = Set(document.placements.values.filter { $0.productID == id }.map(\.id))
        document.products[id] = nil
        for placement in removed { document.placements[placement] = nil; imports.deleted(placement) }
        for index in document.namedGroups.indices { document.namedGroups[index].members.removeAll(where: removed.contains) }
        detachedLinks = detachedLinks.filter { !removed.contains($0.first) && !removed.contains($0.second) }
        inspectedPlacement = nil
        refresh()
        history.clear()
        sync.deleteProduct(id) { [weak self] failure in
            if let failure { self?.error = "The product couldn't be deleted. \(failure.localizedDescription)" }
        }
    }
    /// Places another Sticker of an existing Product in Recent uploads.
    @discardableResult
    func placeSticker(of productID: String) -> String? {
        guard hasInitialLayout, let product = document.products[productID] else { return nil }
        resolveInteraction?()
        guard let id = edit({ $0.document.addToRecentUploads(productID: productID, aspect: product.aspect, fallback: camera.center) }),
              document.placements[id] != nil else { return nil }
        revealImport(id)
        return id
    }
    func snapshot() -> CanvasSnapshot {
        CanvasSnapshot(document: document, detachedLinks: detachedLinks)
    }
    private func load(_ snapshot: CanvasSnapshot) {
        document = snapshot.document
        detachedLinks = snapshot.detachedLinks
    }
    /// A gesture's uncommitted frame: shown, but neither saved nor recorded until the gesture ends with `edit(from:)`.
    func stage(_ change: (inout CanvasSnapshot) -> Void) {
        var next = snapshot()
        change(&next)
        load(next)
    }
    enum EditHistory {
        /// A new undo step; consecutive edits with the same key coalesce.
        case record(key: String? = nil)
        /// Async import enrichment, carried into existing undo steps instead of adding one.
        case enrich
        case none
    }
    /// The one way Canvas state is committed. Offline or invalid, the Canvas returns to `baseline`
    /// (the current state, unless a gesture staged frames since); otherwise it refreshes, records and saves.
    @discardableResult
    func edit<T>(history: EditHistory = .record(), from baseline: CanvasSnapshot? = nil, _ mutate: (inout CanvasSnapshot) -> T) -> T {
        let before = baseline ?? snapshot()
        var next = snapshot()
        let result = mutate(&next)
        if baseline == nil && next == before { return result }
        if !isOnline { error = Self.offlineMessage; next = before }
        do { try next.document.validate() } catch { self.error = error.localizedDescription; next = before }
        load(next)
        refresh()
        switch history {
        case .record(let key): self.history.record(before: before, after: snapshot(), key: key)
        case .enrich: self.history.enrichImport(from: before.document, to: document)
        case .none: break
        }
        save(from: before)
        return result
    }
    func undo() {
        resolveInteraction?()
        guard history.canUndo, editable(), let state = history.undo() else { return }
        restore(state)
    }
    func redo() {
        resolveInteraction?()
        guard history.canRedo, editable(), let state = history.redo() else { return }
        restore(state)
    }
    private func restore(_ state: CanvasSnapshot) {
        for id in document.placements.keys where state.document.placements[id] == nil {
            imports.deleted(id)
        }
        elasticLink = nil
        groupingPreview = nil
        inspectedPlacement = nil
        inspectedGroup = nil
        // Undo and redo sync like any other edit.
        edit(history: .none) { $0 = state }
    }
    func revealImport(_ id: String) {
        resolveInteraction?()
        searchQuery = ""
        if let placement = document.placements[id] { camera.center = placement.center; cameraChanged() }
        select(id)
    }
    /// Panning and zooming render immediately and save the Viewport once it settles, outside undo.
    func cameraChanged() {
        render?()
        guard hasLoaded else { return }
        viewportSave?.cancel()
        viewportSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, isOnline else { return }
            sync.saveViewport(.init(x: camera.center.x, y: camera.center.y, zoom: camera.zoom))
        }
    }
}
