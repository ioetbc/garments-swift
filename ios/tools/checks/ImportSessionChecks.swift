import Foundation
import UIKit

@main struct ImportSessionChecks {
    static func tryCount(_ inbox: SharedImportInbox) -> Int { (try? inbox.files().count) ?? -1 }
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SharedImportInbox(directoryOverride: directory)
        let session = CanvasSession()
        let record = SharedImport(url: "https://shop.example/p?size=L#blue")
        precondition(session.insertImport(record) == nil)
        session.updateViewport(CGSize(width: 390, height: 844))
        let baseline = session.document.order.count
        var requests = 0
        let coordinator = ImportCoordinator(session: session, inbox: inbox, fetch: { url in
            requests += 1
            try await Task.sleep(for: .milliseconds(20))
            return .init(url: url, title: "Imported jacket", imageURL: nil)
        })
        try inbox.enqueue(record)
        try inbox.enqueue(SharedImport(url: record.url))
        try Data("bad".utf8).write(to: directory.appendingPathComponent("bad.json"))
        coordinator.setActive(true); coordinator.setActive(true)
        try await waitFor { coordinator.items.first?.state == "Failed" }
        precondition(requests == 1 && session.document.order.count == baseline + 1)
        precondition(coordinator.items.count == 1 && coordinator.items[0].state == "Failed")
        let remaining = try inbox.files(); precondition(remaining.isEmpty)
        let placementID = coordinator.items[0].placementID!
        let placement = session.document.placements[placementID]!
        let product = session.document.products[placement.productID]!
        precondition(product.title == "Imported jacket" && product.price == nil)
        let data = session.importedAssets.data(for: product.asset)!
        let decoded = CanvasImageWorker.resolve(product.asset, data: data, tier: 192)!
        precondition(decoded.width > 0)
        let store = CanvasAssetStore(); store.library = session.importedAssets
        let key = CanvasAssetStore.Key(asset: product.asset, tier: 192)
        store.needed = [key]; _ = store.image(key); store.reconcile()
        try await Task.sleep(for: .milliseconds(80))
        precondition(store.image(key) != nil)
        store.memoryWarning()
        store.needed = [key]; _ = store.image(key); store.reconcile()
        try await Task.sleep(for: .milliseconds(80))
        precondition(store.image(key) != nil)
        session.document.placements[placementID]?.center = WorldPoint(x: 750, y: 600)
        session.updateImport(placementID, title: "Updated", artwork: .init(data: data, aspect: 0.5))
        let updated = session.document.placements[placementID]!
        precondition(updated.center == WorldPoint(x: 750, y: 600))
        precondition(max(updated.width, updated.height) == max(placement.width, placement.height))
        precondition(session.document.order.count == baseline + 1)
        try session.document.validate()
        coordinator.retry(coordinator.items[0].id)
        coordinator.dismiss(coordinator.items[0].id)
        try await Task.sleep(for: .milliseconds(60))
        precondition(session.document.placements[placementID] == nil)
        precondition(session.document.order.count == baseline)
        // Pause while a deliberately cancellation-insensitive provider is outstanding.
        let second = SharedImport(url: "https://shop.example/second")
        var calls = 0
        let paused = ImportCoordinator(session: session, inbox: inbox, fetch: { url in
            calls += 1
            try? await Task.sleep(for: .milliseconds(50))
            return .init(url: url, title: "Late", imageURL: nil)
        })
        try inbox.enqueue(second); paused.setActive(true)
        try await Task.sleep(for: .milliseconds(10))
        paused.setActive(false)
        try await Task.sleep(for: .milliseconds(20))
        precondition(paused.items[0].state == "Queued")
        paused.setActive(true); paused.setActive(true)
        try await Task.sleep(for: .milliseconds(90))
        precondition(calls == 2 && paused.items[0].state == "Failed")
        let deleting = paused.items[0].placementID!
        paused.retry(second.id)
        try await Task.sleep(for: .milliseconds(10))
        session.deletePlacement(deleting)
        try await Task.sleep(for: .milliseconds(80))
        precondition(session.document.placements[deleting] == nil)
        let readySession = CanvasSession()
        readySession.updateViewport(CGSize(width: 390, height: 844))
        let readyCount = readySession.document.order.count
        let readyRecord = SharedImport(url: "https://shop.example/ready")
        let otherRecord = SharedImport(url: "https://shop.example/other")
        try inbox.enqueue(readyRecord); try inbox.enqueue(otherRecord)
        var active = 0, peak = 0
        let ready = ImportCoordinator(session: readySession, inbox: inbox, fetch: { url in
            active += 1; peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(10))
            return .init(url: url, title: "Ready product", imageURL: "https://cdn.example/image.png")
        }, image: { _ in .init(data: data, aspect: 0.5) })
        ready.setActive(true)
        precondition(readySession.document.order.count == readyCount + 2)
        try await waitFor { ready.items.allSatisfy { $0.state == "Ready" } }
        precondition(peak == 1)
        let saved = ready.items[0].placementID!
        try inbox.enqueue(SharedImport(url: ready.items[0].record.url))
        ready.setActive(true)
        precondition(readySession.document.order.count == readyCount + 2)
        precondition(readySession.selection == saved)
        readySession.deletePlacement(saved)
        try inbox.enqueue(SharedImport(url: ready.items[0].record.url))
        ready.setActive(true)
        try await waitFor { ready.items.allSatisfy { $0.state == "Ready" } }
        precondition(readySession.document.order.count == readyCount + 2)
        try readySession.document.validate()
        let retained = SharedImport(url: "https://shop.example/retained")
        try inbox.enqueue(retained)
        var removals = 0
        let failingRemoval = ImportCoordinator(session: session, inbox: inbox, acknowledge: { _ in
            removals += 1
            throw URLError(.cannotRemoveFile)
        }, fetch: { url in .init(url: url, title: nil, imageURL: nil) })
        failingRemoval.setActive(true); failingRemoval.setActive(true)
        try await waitFor { failingRemoval.items.first?.state == "Failed" }
        precondition(removals == 2 && failingRemoval.items.count == 1)
        precondition(tryCount(inbox) == 1)
        print("Import session checks passed")
    }
}
