import Foundation

@main struct SharedImportChecks {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        check(try SharedLink.normalized(" HTTPS://SHOP.Example/p%2f?Size=L#Blue ") == "https://shop.example/p%2f?Size=L#Blue")
        check(try SharedLink.extract(urls: ["https://shop.example/a", "https://SHOP.example/a"], texts: ["https://different.example"]) == "https://shop.example/a")
        check(try SharedLink.extract(urls: [], texts: ["Buy this https://shop.example/a?size=L#blue now"]) == "https://shop.example/a?size=L#blue")
        for values in [["https://a.example", "https://b.example"], ["file:///tmp/a"], ["https://a:b@shop.example"], ["https:///"], ["https://shop.example/" + String(repeating: "x", count: 4096)]] {
            do { _ = try SharedLink.extract(urls: values, texts: []); fatalError("Accepted invalid links") } catch { }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SharedImportInbox(directoryOverride: directory)
        let a = SharedImport(url: "https://shop.example/a?size=L"), b = SharedImport(url: "https://shop.example/b")
        try inbox.enqueue(a); try inbox.enqueue(b)
        try Data("unfinished".utf8).write(to: directory.appendingPathComponent("ignored.tmp"))
        let files = try inbox.files()
        precondition(files.count == 2)
        check(Set(try files.map { try inbox.read($0).id }) == Set([a.id, b.id]))
        try inbox.acknowledge(files[0])
        check(try inbox.files().count == 1)
        print("Shared import checks passed")
    }
}
