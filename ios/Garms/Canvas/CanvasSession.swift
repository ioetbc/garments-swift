import SwiftUI
import Observation

@Observable @MainActor final class CanvasSession {
    @ObservationIgnored var document = CanvasDocument()
    @ObservationIgnored var camera = CanvasCamera()
    @ObservationIgnored var viewport = CGSize.zero
    var hasInitialLayout: Bool { hasLoaded && viewport.width > 0 && viewport.height > 0 }
    /// The first snapshot has arrived; until then the Canvas is empty and not editable.
    private(set) var hasLoaded = false
    /// Offline, the Canvas stays viewable but every edit is refused.
    private(set) var isOnline = true
    /// Set by the interaction controller so remote snapshots never land under a finger.
    @ObservationIgnored var gestureInProgress = false
    @ObservationIgnored let sync: CanvasSync
    @ObservationIgnored let server: GarmsServer
    @ObservationIgnored private var pendingRemote: CanvasRemote?
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var viewportSave: Task<Void, Never>?
    static let offlineMessage = "You're offline, so the canvas is read-only. Your changes can't be saved until you reconnect."
    @ObservationIgnored let index = CanvasSpatialIndex()
    @ObservationIgnored var groups: [[String]] = []
    @ObservationIgnored var committedGroups: [[String]] = []
    @ObservationIgnored var detachedLinks: Set<CanvasGroupLink> = []
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
    /// A Product Awaiting match whose row in the Imports sheet a tap on its Sticker asked to show.
    var revealedMatch: String?
    var error: String?

    /// Records a successful check on the Product. Failed checks keep the last known Availability.
    func recordAvailability(_ classification: GarmsAPI.ProductClassification, productID: String) {
        guard classification.error == nil, isOnline, document.products[productID] != nil else { return }
        let before = snapshot()
        let availability = Availability(state: .init(rawValue: classification.status) ?? .unknown,
                                        checkedAt: Date().timeIntervalSince1970 * 1000)
        document.products[productID]?.availability = availability
        // A fact about the listing, not an edit: carry it into history without touching anything undoable.
        history.patchProduct(productID) { $0.availability = availability }
        revision &+= 1
        render?()
        save(from: before.document, before.detachedLinks)
    }

    func opacity(for placement: StickerPlacement) -> Float {
        if dimmedPlacementIDs.contains(placement.id) { return 0.1 }
        return document.products[placement.productID]?.availability?.isUnavailable == true ? 0.35 : 1
    }

    // ponytail: launch-time checks until a server cron owns Availability; skips anything checked in the last day.
    func loadAvailability(
        now: Date = Date(),
        fetch: (@MainActor @Sendable (String) async throws -> GarmsAPI.ProductClassification?)? = nil
    ) async {
        let fetch = fetch ?? { [server] in try await server.scrapePage(url: $0).classification }
        let productIDs = Set(document.placements.values.map(\.productID))
        let stale = now.timeIntervalSince1970 * 1000 - 24 * 60 * 60 * 1000
        let products = productIDs.compactMap { document.products[$0] }
            .filter { !$0.product_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { ($0.availability?.checkedAt ?? 0) < stale }
            .sorted { $0.id < $1.id }
        // Bound startup requests while updating the canvas as each result arrives.
        await withTaskGroup(of: (String, GarmsAPI.ProductClassification?).self) { group in
            var remaining = products.makeIterator()
            func enqueue(_ product: Product) {
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
                if let classification { recordAvailability(classification, productID: productID) }
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

    /// Applies a stored snapshot, unless a gesture or one of this device's writes is still in flight.
    func receive(_ remote: CanvasRemote) {
        importedAssets.urls.merge(remote.files.compactMapValues(URL.init(string:))) { $1 }
        guard !gestureInProgress, writesInFlight == 0 else { pendingRemote = remote; return }
        pendingRemote = nil
        if !hasLoaded {
            let opened = CanvasCamera(center: .init(x: remote.viewport.x, y: remote.viewport.y), zoom: remote.viewport.zoom)
            camera = opened.valid ? opened : CanvasCamera()
            hasLoaded = true
        }
        let incoming = remote.document
        if incoming != document || remote.links != detachedLinks {
            document = incoming
            committedGroups = remote.committedGroups
            detachedLinks = remote.links
            elasticLink = nil
            groupingPreview = nil
            if let group = inspectedGroup { inspectedGroup = document.namedGroups?.first { $0.id == group.id } }
        }
        refresh()
        imports.start()
    }
    /// Called when a gesture has committed or been cancelled.
    func endGesture() {
        gestureInProgress = false
        flushRemote()
    }
    private func flushRemote() {
        if let pendingRemote, !gestureInProgress, writesInFlight == 0 { receive(pendingRemote) }
    }
    /// Refuses an edit while offline, saying why.
    private func editable() -> Bool {
        if !isOnline { error = Self.offlineMessage }
        return isOnline
    }
    /// Sends the rows that changed since `before`. Last write wins per row.
    private func save(from before: CanvasDocument, _ beforeLinks: Set<CanvasGroupLink>) {
        let changes = CanvasChangeSet(from: before, beforeLinks, to: document, detachedLinks)
        guard !changes.isEmpty else { return }
        writesInFlight += 1
        sync.apply(changes) { [weak self] failure in
            guard let self else { return }
            writesInFlight -= 1
            if let failure { error = "Your last change couldn't be saved, so this canvas may not match your other devices. \(failure.localizedDescription)" }
            flushRemote()
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
        var group = document.namedGroups![index]
        // Keep the last valid title while the field is cleared for replacement.
        if !trimmed.isEmpty { group.name = String(trimmed.prefix(60)) }
        group.backgroundColour = backgroundColour
        guard group != document.namedGroups![index], editable() else { return }
        let before = snapshot()
        document.namedGroups?[index] = group
        refresh()
        history.record(before: before, after: snapshot(), key: "group-" + id)
        save(from: before.document, before.detachedLinks)
    }
    /// One edit to a Product's own fields, shown on every Sticker of it. Edits with the same key coalesce in undo.
    func editProduct(_ id: String, key: String, _ change: (inout Product) -> Void) {
        guard var product = document.products[id] else { return }
        change(&product)
        guard product != document.products[id], editable() else { return }
        let before = snapshot()
        document.products[id] = product
        revision &+= 1
        updateSearchMatches()
        render?()
        history.record(before: before, after: snapshot(), key: key + id)
        save(from: before.document, before.detachedLinks)
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

    func updateGroupNotes(_ id: String, notes: String) {
        guard let index = document.namedGroups?.firstIndex(where: { $0.id == id }),
              document.namedGroups?[index].notes ?? "" != notes, editable() else { return }
        let before = snapshot()
        document.namedGroups?[index].notes = notes.isEmpty ? nil : notes
        revision &+= 1
        history.record(before: before, after: snapshot(), key: "group-notes-" + id)
        save(from: before.document, before.detachedLinks)
    }

    func select(_ id: String?, showDetails: Bool = false) {
        selection = id
        let placement = showDetails ? id.flatMap { document.placements[$0] } : nil
        // A Product Awaiting match is resolved in the Imports sheet, not its details.
        if let placement, document.products[placement.productID]?.match != nil {
            inspectedPlacement = nil
            revealedMatch = placement.productID
        } else {
            inspectedPlacement = placement
        }
        render?()
    }
    func deletePlacement(_ id: String) {
        resolveInteraction?()
        guard document.placements[id] != nil else { return }
        let before = document
        // The Product stays: it is still findable through search and can be placed again.
        document.placements[id] = nil
        complete(before)
        if document.placements[id] == nil { imports.deleted(id) }
    }
    /// Deletes the Product, every Sticker of it and its stored files. Not undoable: the files are gone.
    func deleteProduct(_ id: String) {
        resolveInteraction?()
        guard document.products[id] != nil, editable() else { return }
        let removed = Set(document.placements.values.filter { $0.productID == id }.map(\.id))
        document.products[id] = nil
        for placement in removed { document.placements[placement] = nil; imports.deleted(placement) }
        for index in (document.namedGroups ?? []).indices { document.namedGroups?[index].members.removeAll(where: removed.contains) }
        committedGroups = committedGroups.map { $0.filter { !removed.contains($0) } }
        detachedLinks = detachedLinks.filter { !removed.contains($0.first) && !removed.contains($0.second) }
        inspectedPlacement = nil
        refresh()
        history.clear()
        writesInFlight += 1
        sync.deleteProduct(id) { [weak self] failure in
            guard let self else { return }
            writesInFlight -= 1
            if let failure { error = "The product couldn't be deleted. \(failure.localizedDescription)" }
            flushRemote()
        }
    }
    /// Draws the Sticker above every other; only its own stacking key changes.
    func bringToFront(_ id: String) {
        guard document.placements[id] != nil, document.order.last != id else { return }
        let before = document
        let top = document.topZ
        document.placements[id]?.z = top
        complete(before)
    }
    /// Places another Sticker of an existing Product in Recent uploads.
    @discardableResult
    func placeSticker(of productID: String) -> String? {
        guard hasInitialLayout, let product = document.products[productID] else { return nil }
        resolveInteraction?()
        let before = document
        let baseline = snapshot()
        guard let id = addToRecentUploads(productID: productID, aspect: product.aspect) else { return nil }
        complete(before, baseline: baseline)
        guard document.placements[id] != nil else { return nil }
        searchQuery = ""
        revealImport(id)
        return id
    }
    private func addToRecentUploads(productID: String, aspect: Double) -> String? {
        guard let recentIndex = document.namedGroups?.firstIndex(where: \.isRecentUploads),
              let recent = document.namedGroups?[recentIndex] else { return nil }
        let edge = CanvasConfiguration.initialImageEdge
        let width = aspect >= 1 ? edge : edge * aspect
        let height = aspect >= 1 ? edge / aspect : edge
        let bounds = recent.bounds(in: document)
        let center = recent.members.isEmpty || bounds.isNull ? recent.emptyCenter ?? camera.center
            : WorldPoint(x: bounds.maxX + CanvasConfiguration.magneticRestGap + width / 2, y: bounds.midY)
        let placement = StickerPlacement(productID: productID, center: center, width: width, height: height, z: document.topZ)
        document.placements[placement.id] = placement
        document.namedGroups?[recentIndex].members.append(placement.id)
        document.namedGroups?[recentIndex].emptyCenter = center
        committedGroups.removeAll { group in group.contains(where: recent.members.contains) }
        committedGroups.append(recent.members + [placement.id])
        return placement.id
    }
    func snapshot(document: CanvasDocument? = nil) -> CanvasSnapshot {
        CanvasSnapshot(document: document ?? self.document, groups: committedGroups,
                       detachedLinks: detachedLinks)
    }
    func complete(_ before: CanvasDocument, baseline: CanvasSnapshot? = nil, recordHistory: Bool = true) {
        let previous = baseline ?? snapshot(document: before)
        guard isOnline else {
            document = before
            committedGroups = previous.groups
            detachedLinks = previous.detachedLinks
            error = Self.offlineMessage
            refresh()
            return
        }
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
        save(from: previous.document, previous.detachedLinks)
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
        let before = snapshot()
        document = state.document
        committedGroups = state.groups
        detachedLinks = state.detachedLinks
        elasticLink = nil
        groupingPreview = nil
        inspectedPlacement = nil
        inspectedGroup = nil
        refresh()
        // Undo and redo sync like any other edit.
        save(from: before.document, before.detachedLinks)
    }
    func revealImport(_ id: String) {
        resolveInteraction?()
        searchQuery = ""
        if let placement = document.placements[id] { camera.center = placement.center; cameraChanged() }
        select(id)
    }
    func insertImport(_ record: SharedImport, artwork: ImportedImageDownload.Artwork) -> String? {
        guard hasInitialLayout, artwork.aspect.isFinite, artwork.aspect > 0 else { return nil }
        resolveInteraction?()
        guard document.namedGroups?.contains(where: \.isRecentUploads) == true else { return nil }
        let before = document
        let baseline = snapshot()
        let productID = UUID().uuidString
        let asset = importedAssets.insert(artwork.data)
        document.products[productID] = Product(id: productID, title: record.suggestedTitle ?? URL(string: record.url)?.host ?? "Saved link", asset: asset, aspect: artwork.aspect, product_url: record.url)
        guard let id = addToRecentUploads(productID: productID, aspect: artwork.aspect) else { return nil }
        complete(before, baseline: baseline)
        guard document.placements[id] != nil else { return nil }
        searchQuery = ""
        revealImport(id)
        return id
    }
    @discardableResult
    func appendImportPhoto(_ id: String, artwork: ImportedImageDownload.Artwork) -> String? {
        guard let placement = document.placements[id], var product = document.products[placement.productID],
              artwork.aspect.isFinite, artwork.aspect > 0 else { return nil }
        let before = document
        let asset = importedAssets.insert(artwork.data)
        product.galleryAssets.append(asset)
        document.products[product.id] = product
        complete(before, recordHistory: false)
        return document.products[product.id] == product ? asset : nil
    }
    @discardableResult
    func installImportOriginal(_ id: String, title: String?, price: Price?, artwork: ImportedImageDownload.Artwork) -> String? {
        updateImport(id, title: title, price: price, artwork: artwork, original: true)
    }
    @discardableResult
    func applyImportCutout(_ id: String, artwork: ImportedImageDownload.Artwork) -> String? {
        guard let placement = document.placements[id], document.products[placement.productID]?.originalAsset != nil else { return nil }
        return updateImport(id, title: nil, price: nil, artwork: artwork, original: false)
    }
    @discardableResult
    func updateImport(_ id: String, title: String?, price: Price?, artwork: ImportedImageDownload.Artwork?, original: Bool = true) -> String? {
        guard document.placements[id] != nil else { return nil }
        resolveInteraction?()
        guard let placement = document.placements[id], var product = document.products[placement.productID] else { return nil }
        if let artwork { guard artwork.aspect.isFinite, artwork.aspect > 0 else { return nil } }
        let before = document
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { product.title = title }
        if let price { product.price = price }
        if let artwork {
            product.asset = importedAssets.insert(artwork.data)
            if original { product.originalAsset = product.asset }
            product.aspect = artwork.aspect
            // Every Sticker shows the Product's image, so each keeps its centre and longest edge at the new aspect.
            for (sticker, shown) in document.placements where shown.productID == product.id {
                document.placements[sticker]?.fit(aspect: artwork.aspect)
            }
        }
        document.products[product.id] = product
        complete(before, recordHistory: false)
        return document.products[product.id] == product ? product.asset : nil
    }
    /// Records the search state of a Product imported from a Screenshot; nil ends Awaiting match.
    /// A fact about the import, not an undoable edit.
    func setMatch(_ productID: String, _ match: Product.Match?) {
        guard document.products[productID] != nil, document.products[productID]?.match != match else { return }
        resolveInteraction?()
        let before = document
        document.products[productID]?.match = match
        complete(before, recordHistory: false)
    }
    /// Ends Awaiting match once its listing has been imported onto the Product like a shared link:
    /// records the link and keeps the Screenshot as the first Photo.
    func resolveMatch(_ productID: String, url: String, screenshot: String) {
        guard var product = document.products[productID], product.match != nil else { return }
        resolveInteraction?()
        let before = document
        product.product_url = url
        product.galleryAssets.insert(screenshot, at: 0)
        product.match = nil
        document.products[productID] = product
        complete(before, recordHistory: false)
    }
    /// Re-points every Sticker of `productID` at `existing`, which already holds the same link, and deletes `productID`.
    /// Stickers stay where they are.
    func mergeProduct(_ productID: String, into existing: String) {
        guard productID != existing, document.products[productID] != nil, let target = document.products[existing] else { return }
        resolveInteraction?()
        let before = document
        for (id, placement) in document.placements where placement.productID == productID {
            document.placements[id]?.productID = existing
            document.placements[id]?.fit(aspect: target.aspect)
        }
        document.products[productID] = nil
        complete(before)
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
