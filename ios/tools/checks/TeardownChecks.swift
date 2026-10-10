import Foundation

@main struct TeardownChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        LocalUser.directory = root.appending(path: "cache", directoryHint: .isDirectory)
        let inbox = SharedImportInbox(directoryOverride: root.appending(path: "inbox", directoryHint: .isDirectory))
        let user = LocalUser(inbox: inbox) { FakeCanvasSync(remote: CanvasFixtures.remote(count: 3)) }

        user.follow("user_a")
        weak var session = user.canvas
        precondition(session?.hasLoaded == true)
        let key = session!.importedAssets.insert(Data("png".utf8))
        precondition(session!.importedAssets.data(for: key) != nil)
        try inbox.enqueue(SharedImport(url: "https://shop.example/coat"))

        // A cached launch reopens the same User without wiping anything.
        user.follow("user_a")
        precondition(user.canvas === session && session!.importedAssets.data(for: key) != nil)

        user.follow(nil)
        precondition(user.canvas == nil && session == nil, "Teardown must drop the session")
        precondition(!FileManager.default.fileExists(atPath: LocalUser.directory.path), "Teardown must empty the image cache")
        precondition(try! inbox.files().isEmpty, "Teardown must empty the share inbox")

        user.follow("user_a")
        weak var first = user.canvas
        try inbox.enqueue(SharedImport(url: "https://shop.example/shoe"))
        user.follow("user_b")
        precondition(first == nil && user.canvas != nil && user.canvas!.importedAssets.data(for: key) == nil)
        precondition(try! inbox.files().isEmpty, "A different User never receives the last User's shared links")

        print("Teardown checks passed: session dropped, image cache and share inbox emptied, cached launch kept.")
    }
}
