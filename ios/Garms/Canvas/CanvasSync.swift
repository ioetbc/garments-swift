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
    var stickers: [Sticker]
    var groups: [CanvasNamedGroup]
    var detachedLinks: [Link]
    var files: [String: String] = [:]

    nonisolated struct Sticker: Codable, Equatable, Sendable {
        var key: String
        var product: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var z: String
        init(_ p: StickerPlacement) {
            key = p.id; product = p.productID; x = p.center.x; y = p.center.y; width = p.width; height = p.height; z = p.z
        }
        var placement: StickerPlacement {
            StickerPlacement(id: key, productID: product, center: .init(x: x, y: y), width: width, height: height, z: z)
        }
    }
    nonisolated struct Link: Codable, Hashable, Sendable {
        var first: String
        var second: String
        init(_ link: CanvasGroupLink) { first = link.first; second = link.second }
        var link: CanvasGroupLink { CanvasGroupLink(first, second) }
    }

    init(document: CanvasDocument, detachedLinks: Set<CanvasGroupLink>, viewport: Viewport = .init(x: 0, y: 0, zoom: 1)) {
        self.viewport = viewport
        products = document.products.values.sorted { $0.id < $1.id }
        stickers = document.placements.values.sorted { $0.id < $1.id }.map(Sticker.init)
        groups = document.namedGroups ?? []
        self.detachedLinks = detachedLinks.map(Link.init).sorted { ($0.first, $0.second) < ($1.first, $1.second) }
    }
    var document: CanvasDocument {
        CanvasDocument(
            namedGroups: groups,
            products: Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { $1 }),
            placements: Dictionary(stickers.map { ($0.key, $0.placement) }, uniquingKeysWith: { $1 }))
    }
    var links: Set<CanvasGroupLink> { Set(detachedLinks.map(\.link)) }
    /// Persisted membership in the form proximity grouping continues from.
    var committedGroups: [[String]] {
        groups.filter { $0.members.count > 1 || $0.isRecentUploads && !$0.members.isEmpty }.map(\.members)
    }
}

/// Row-level upserts and deletes between two versions of a Canvas.
nonisolated struct CanvasChangeSet: Encodable, Equatable, Sendable {
    var products: [Product] = []
    var deletedProducts: [String] = []
    var stickers: [CanvasRemote.Sticker] = []
    var deletedStickers: [String] = []
    var groups: [CanvasNamedGroup] = []
    var deletedGroups: [String] = []
    var links: [CanvasRemote.Link] = []
    var deletedLinks: [CanvasRemote.Link] = []

    var isEmpty: Bool { self == CanvasChangeSet() }

    init() {}
    init(from before: CanvasDocument, _ beforeLinks: Set<CanvasGroupLink>, to after: CanvasDocument, _ afterLinks: Set<CanvasGroupLink>) {
        func diff<Row: Equatable>(_ old: [String: Row], _ new: [String: Row]) -> (upserts: [Row], deletes: [String]) {
            (new.keys.sorted().compactMap { old[$0] == new[$0] ? nil : new[$0] },
             old.keys.filter { new[$0] == nil }.sorted())
        }
        (products, deletedProducts) = diff(before.products, after.products)
        (stickers, deletedStickers) = diff(before.placements.mapValues(CanvasRemote.Sticker.init),
                                           after.placements.mapValues(CanvasRemote.Sticker.init))
        func byID(_ groups: [CanvasNamedGroup]?) -> [String: CanvasNamedGroup] {
            Dictionary((groups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
        (groups, deletedGroups) = diff(byID(before.namedGroups), byID(after.namedGroups))
        let sort: (CanvasRemote.Link, CanvasRemote.Link) -> Bool = { ($0.first, $0.second) < ($1.first, $1.second) }
        links = afterLinks.subtracting(beforeLinks).map(CanvasRemote.Link.init).sorted(by: sort)
        deletedLinks = beforeLinks.subtracting(afterLinks).map(CanvasRemote.Link.init).sorted(by: sort)
    }
}
