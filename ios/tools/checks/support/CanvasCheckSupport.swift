import Foundation

/// GarmsServer for checks: every call is unexpected unless a check passes its own closure to the code under test.
@MainActor final class FakeGarmsServer: GarmsServer {
    func importProduct(url: String) async throws -> GarmsAPI.ImportedProduct { throw URLError(.notConnectedToInternet) }
    func findListing(_ jpeg: Data) async throws -> GarmsAPI.Listing? { nil }
}

/// In-memory CanvasSync: records what the session sends and delivers snapshots on demand.
@MainActor final class FakeCanvasSync: CanvasSync {
    var remote: CanvasRemote
    private(set) var applied: [CanvasChangeSet] = []
    private(set) var viewports: [CanvasRemote.Viewport] = []
    private(set) var deletedProducts: [String] = []
    private(set) var uploads: [String: Data] = [:]
    private var online: (@MainActor (Bool) -> Void)?

    init(remote: CanvasRemote) { self.remote = remote }

    func connect(snapshot: @escaping @MainActor (CanvasRemote) -> Void, online: @escaping @MainActor (Bool) -> Void) {
        self.online = online
        online(true)
        snapshot(remote)
    }
    func apply(_ changes: CanvasChangeSet, completion: @escaping @MainActor (Error?) -> Void) {
        applied.append(changes)
        completion(nil)
    }
    func saveViewport(_ viewport: CanvasRemote.Viewport) { viewports.append(viewport) }
    func deleteProduct(_ id: String, completion: @escaping @MainActor (Error?) -> Void) {
        deletedProducts.append(id)
        completion(nil)
    }
    func upload(_ data: Data, key: String, completion: @escaping @MainActor (Error?) -> Void) {
        uploads[key] = data
        completion(nil)
    }
    func setOnline(_ value: Bool) { online?(value) }
}

extension CanvasSession {
    /// Moves a Sticker as one committed edit, like a finished drag.
    func move(_ id: String, x: Double, y: Double) {
        let before = document
        document.placements[id]!.center = document.placements[id]!.center + WorldPoint(x: x, y: y)
        complete(before)
    }
}

extension CanvasFixtures {
    static let viewport = CGSize(width: 390, height: 844)

    /// A stored Canvas holding the fixture Products, optionally laid out in Groups, plus Recent uploads.
    static func remote(count: Int = 100, laidOut: Bool = false) -> CanvasRemote {
        var document = make(count: count)
        var groups: [[String]] = []
        if laidOut { groups = fit(&document, viewport: viewport) }
        document.reconcileGroupNames(groups)
        let bounds = CanvasGeometry.union(Array(document.placements.values))
        document.namedGroups?.append(CanvasNamedGroup(
            members: [], name: "Recent uploads", backgroundColour: .init(red: 0.22, green: 1, blue: 0.08),
            isRecentUploads: true,
            emptyCenter: WorldPoint(x: bounds.isNull ? 0 : bounds.maxX + 250, y: viewport.height / 2)))
        return CanvasRemote(document: document, detachedLinks: [],
                            viewport: .init(x: viewport.width / 2, y: viewport.height / 2, zoom: 1))
    }

    /// A loaded session over a fake sync, sized like a phone.
    @MainActor static func session(count: Int = 100, laidOut: Bool = false, sized: Bool = true) -> (CanvasSession, FakeCanvasSync) {
        let sync = FakeCanvasSync(remote: remote(count: count, laidOut: laidOut))
        let session = CanvasSession(sync: sync, server: FakeGarmsServer())
        if sized { session.updateViewport(viewport) }
        return (session, sync)
    }
}
