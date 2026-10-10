import Foundation
import Observation

/// What this device holds for the signed-in User: their open Canvas, its image cache and
/// last snapshot, and links waiting in the share inbox. Torn down when the User signs out,
/// deletes themselves, or their session ends.
@Observable @MainActor final class LocalUser {
    /// Image cache and last Canvas snapshot. Not partitioned per User, so teardown wipes it whole.
    static var directory = URL.cachesDirectory.appending(path: "Garms", directoryHint: .isDirectory)

    private(set) var canvas: CanvasSession?
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private let inbox: SharedImportInbox
    @ObservationIgnored private let makeSync: () -> CanvasSync

    init(inbox: SharedImportInbox = .init(), makeSync: @escaping () -> CanvasSync) {
        self.inbox = inbox
        self.makeSync = makeSync
    }

    /// Follows the signed-in Clerk user id: opens their Canvas, and tears down when there is
    /// no User or a different one. A cached launch keeps the device's data for offline viewing.
    func follow(_ id: String?) {
        if id == nil || (owner != nil && id != owner) { teardown() }
        owner = id
        if id != nil, canvas == nil { canvas = CanvasSession(sync: makeSync()) }
    }

    private func teardown() {
        canvas = nil
        try? FileManager.default.removeItem(at: Self.directory)
        if let directory = try? inbox.directory() { try? FileManager.default.removeItem(at: directory) }
    }
}
