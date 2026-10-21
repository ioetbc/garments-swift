import Foundation

/// The boundary between a Canvas being edited on this device and where it is stored.
/// Completions and handlers run on the main actor.
@MainActor protocol CanvasSync: AnyObject {
    /// Delivers the whole Canvas as last cached, then as stored, and connectivity changes.
    func connect(snapshot: @escaping @MainActor (CanvasRemote) -> Void, online: @escaping @MainActor (Bool) -> Void)
    /// Saves one committed edit's row changes in a single transaction.
    func apply(_ changes: CanvasChangeSet, completion: @escaping @MainActor (Error?) -> Void)
    /// Saves where the Canvas is being viewed. Never part of an edit.
    func saveViewport(_ viewport: CanvasRemote.Viewport)
    /// Deletes a Product, all its Stickers and its stored files.
    func deleteProduct(_ id: String, completion: @escaping @MainActor (Error?) -> Void)
    /// Stores image bytes under a file key that Products can already reference.
    func upload(_ data: Data, key: String, completion: @escaping @MainActor (Error?) -> Void)
}

/// One Canvas as stored: the rows the server returns, plus URLs for the files it references.
nonisolated struct CanvasRemote: Codable, Equatable, Sendable {
    struct Viewport: Codable, Equatable, Sendable { var x: Double; var y: Double; var zoom: Double }
    var viewport: Viewport
    var products: [Product]
    var stickers: [StickerPlacement]
    var groups: [CanvasNamedGroup]
    var detachedLinks: Set<CanvasGroupLink>
    var files: [String: String] = [:]

    init(document: CanvasDocument, detachedLinks: Set<CanvasGroupLink>, viewport: Viewport = .init(x: 0, y: 0, zoom: 1)) {
        self.viewport = viewport
        products = document.products.values.sorted { $0.id < $1.id }
        stickers = document.placements.values.sorted { $0.id < $1.id }
        groups = document.namedGroups
        self.detachedLinks = detachedLinks
    }
    var document: CanvasDocument {
        CanvasDocument(
            namedGroups: groups,
            products: Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { $1 }),
            placements: Dictionary(stickers.map { ($0.id, $0) }, uniquingKeysWith: { $1 }))
    }
}

/// Row-level upserts and deletes between two versions of a Canvas.
nonisolated struct CanvasChangeSet: Encodable, Equatable, Sendable {
    var products: [Product] = []
    var deletedProducts: [String] = []
    var stickers: [StickerPlacement] = []
    var deletedStickers: [String] = []
    var groups: [CanvasNamedGroup] = []
    var deletedGroups: [String] = []
    var links: [CanvasGroupLink] = []
    var deletedLinks: [CanvasGroupLink] = []

    var isEmpty: Bool { self == CanvasChangeSet() }

    init() {}
    init(from before: CanvasDocument, _ beforeLinks: Set<CanvasGroupLink>, to after: CanvasDocument, _ afterLinks: Set<CanvasGroupLink>) {
        func diff<Row: Equatable>(_ old: [String: Row], _ new: [String: Row]) -> (upserts: [Row], deletes: [String]) {
            (new.keys.sorted().compactMap { old[$0] == new[$0] ? nil : new[$0] },
             old.keys.filter { new[$0] == nil }.sorted())
        }
        (products, deletedProducts) = diff(before.products, after.products)
        (stickers, deletedStickers) = diff(before.placements, after.placements)
        func byID(_ groups: [CanvasNamedGroup]) -> [String: CanvasNamedGroup] {
            Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
        (groups, deletedGroups) = diff(byID(before.namedGroups), byID(after.namedGroups))
        let sort: (CanvasGroupLink, CanvasGroupLink) -> Bool = { ($0.first, $0.second) < ($1.first, $1.second) }
        links = afterLinks.subtracting(beforeLinks).sorted(by: sort)
        deletedLinks = beforeLinks.subtracting(afterLinks).sorted(by: sort)
    }
}
