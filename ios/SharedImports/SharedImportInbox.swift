import Foundation

nonisolated struct SharedImportInbox: Sendable {
    var directoryOverride: URL?
    func directory() throws -> URL {
        if let directoryOverride { return directoryOverride }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedLink.appGroup) else {
            throw SharedLink.LinkError.container
        }
        return root.appendingPathComponent("PendingImports", isDirectory: true)
    }
    func enqueue(_ item: SharedImport) throws {
        _ = try SharedLink.normalized(item.url)
        let directory = try directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
    }
    func files() throws -> [URL] {
        let directory = try directory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func read(_ file: URL) throws -> SharedImport {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16384 else { throw SharedLink.LinkError.invalid }
        let item = try JSONDecoder().decode(SharedImport.self, from: Data(contentsOf: file))
        guard item.schemaVersion == 1 else { throw SharedLink.LinkError.invalid }
        _ = try SharedLink.normalized(item.url)
        return item
    }
    func acknowledge(_ file: URL) throws { try FileManager.default.removeItem(at: file) }
}
