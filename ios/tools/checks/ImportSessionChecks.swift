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
        let png = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 60)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 60))
        }.pngData()!
        let artwork = ImportedImageDownload.Artwork(data: png, aspect: 0.5)
        precondition(session.insertImport(record, artwork: artwork) == nil)
        session.updateViewport(CGSize(width: 390, height: 844))
        let baseline = session.document.order.count
        var requests = 0
        let coordinator = ImportCoordinator(session: session, inbox: inbox, fetch: { url in
            requests += 1
            try await Task.sleep(for: .milliseconds(20))
            return .init(url: url, title: "Imported jacket", imageURL: "https://cdn.example/image.png")
        }, image: { _ in artwork }, cutout: { _ in nil })
        try inbox.enqueue(record)
        try inbox.enqueue(SharedImport(url: record.url))
        try Data("bad".utf8).write(to: directory.appendingPathComponent("bad.json"))
        coordinator.setActive(true); coordinator.setActive(true)
        try await waitFor { coordinator.items.first?.state == "Ready" }
        precondition(requests == 1 && session.document.order.count == baseline + 1)
        precondition(coordinator.items.count == 1 && coordinator.items[0].state == "Ready")
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
        precondition(paused.items[0].placementID == nil)
        precondition(session.document.order.count == baseline)
        precondition(paused.progress == nil)
        paused.retry(second.id)
        try await Task.sleep(for: .milliseconds(10))
        paused.dismiss(second.id)
        try await Task.sleep(for: .milliseconds(80))
        precondition(paused.items.isEmpty && session.document.order.count == baseline)
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
        }, image: { _ in .init(data: data, aspect: 0.5) }, cutout: { _ in nil })
        ready.setActive(true)
        precondition(readySession.document.order.count == readyCount)
        precondition(ready.progress?.current == 1 && ready.progress?.total == 2)
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
        let testSession = CanvasSession()
        var testFetches = 0, testImages = 0, testCutouts = 0
        let testImports = ImportCoordinator(session: testSession, inbox: SharedImportInbox(directoryOverride: directory.appendingPathComponent("test-links")), fetch: { url in
            testFetches += 1
            return .init(url: url, title: "Test import", imageURL: "https://cdn.example/test.png")
        }, image: { _ in
            testImages += 1
            return .init(data: data, aspect: 0.5)
        }, cutout: { _ in
            testCutouts += 1
            return nil
        })
        testImports.setActive(true)
        let fixtureLink = CanvasFixtures.products[0].product_url
        testImports.loadTestLinks([fixtureLink, fixtureLink])
        testImports.loadTestLinks([fixtureLink])
        precondition(testImports.items.count == 1 && testFetches == 0)
        testSession.updateViewport(CGSize(width: 390, height: 844))
        let testBaseline = testSession.document.order.count
        testImports.start()
        try await waitFor { testImports.items.first?.state == "Ready" }
        precondition(testFetches == 1 && testImages == 1 && testCutouts == 1)
        precondition(testSession.document.order.count == testBaseline + 1)
        testImports.loadTestLinks([fixtureLink])
        precondition(testImports.items.count == 1)
        testImports.dismiss(testImports.items[0].id)
        testImports.loadTestLinks([fixtureLink])
        try await waitFor { testImports.items.first?.state == "Ready" }
        precondition(testFetches == 2 && testImages == 2 && testCutouts == 2)
        testImports.setActive(false)
        // Keep each image in processing long enough to inspect the banner's batch and thumbnail.
        let batchSession = CanvasSession()
        batchSession.updateViewport(CGSize(width: 390, height: 844))
        let batchBaseline = batchSession.document.order.count
        var pending: CheckedContinuation<ImportedImageDownload.Artwork?, Never>?
        let batch = ImportCoordinator(session: batchSession,
            inbox: SharedImportInbox(directoryOverride: directory.appendingPathComponent("batch")),
            fetch: { url in .init(url: url, title: "Batch product", imageURL: "https://cdn.example/image.png") },
            image: { _ in artwork }, cutout: { _ in
                await withCheckedContinuation { pending = $0 }
            })
        batch.setActive(true)
        batch.loadTestLinks((1...4).map { "https://shop.example/batch-\($0)" })
        precondition(batchSession.document.order.count == batchBaseline)
        var thumbnails: Set<String> = []
        for number in 1...4 {
            try await waitFor { pending != nil }
            let progress = batch.progress!
            precondition(progress.current == number && progress.total == 4)
            precondition(progress.item.stage == .removingBackground)
            let thumbnail = progress.item.checkpoint!.asset
            precondition(batchSession.importedAssets.data(for: thumbnail) == png)
            precondition(thumbnails.insert(thumbnail).inserted)
            let continuation = pending!; pending = nil; continuation.resume(returning: nil)
        }
        try await waitFor { batch.progress == nil }
        precondition(batchSession.document.order.count == batchBaseline + 4)
        batch.retry(batch.items[0].id)
        try await waitFor { pending != nil }
        precondition(batch.progress?.current == 1 && batch.progress?.total == 1)
        batch.setActive(false)
        precondition(batch.progress == nil)
        let continuation = pending!; pending = nil; continuation.resume(returning: nil)
        // Gallery downloads preserve ordering, skip failures, and never invoke cutout processing.
        let gallerySession = CanvasSession()
        gallerySession.updateViewport(CGSize(width: 390, height: 844))
        var galleryDownloads: [String] = [], galleryCutouts = 0
        let firstURL = "https://cdn.example/first.png", secondURL = "https://cdn.example/second.png"
        let badURL = "https://cdn.example/bad.png", thirdURL = "https://cdn.example/third.png"
        let gallery = ImportCoordinator(session: gallerySession,
            inbox: SharedImportInbox(directoryOverride: directory.appendingPathComponent("gallery")),
            fetch: { url in .init(url: url, title: "Gallery", imageURL: firstURL, imageURLs: [firstURL, secondURL, secondURL, badURL, thirdURL]) },
            image: { address in
                galleryDownloads.append(address)
                if address == badURL { throw URLError(.badServerResponse) }
                return artwork
            }, cutout: { _ in
                galleryCutouts += 1
                return galleryCutouts == 1 ? nil : artwork
            })
        gallery.setActive(true); gallery.loadTestLinks(["https://shop.example/gallery"])
        try await waitFor { gallery.items.first?.state == "Ready" }
        precondition(galleryDownloads == [firstURL, secondURL, badURL, thirdURL] && galleryCutouts == 1)
        let galleryPlacement = gallery.items[0].placementID!
        let galleryProductID = gallerySession.document.placements[galleryPlacement]!.productID
        let originals = gallerySession.document.products[galleryProductID]!.detailAssets
        precondition(originals.count == 3)
        gallery.retry(gallery.items[0].id)
        try await waitFor { gallery.items.first?.state == "Ready" }
        let galleryProduct = gallerySession.document.products[galleryProductID]!
        precondition(galleryCutouts == 2 && galleryDownloads.count == 4)
        precondition(galleryProduct.detailAssets.count == 4 && Array(galleryProduct.detailAssets.dropFirst()) == originals)
        precondition(galleryProduct.detailAssets.allSatisfy { gallerySession.importedAssets.data(for: $0) != nil })
        gallery.dismiss(gallery.items[0].id)
        // Deleted artwork remains available to undo until its history is evicted.
        precondition(galleryProduct.detailAssets.allSatisfy { gallerySession.importedAssets.data(for: $0) != nil })
        gallerySession.undo()
        precondition(gallerySession.document.products[galleryProductID] == galleryProduct)
        gallerySession.redo()
        precondition(gallerySession.document.placements[galleryPlacement] == nil)
        // A cancelled secondary download resumes without downloading the primary again.
        let resumeSession = CanvasSession()
        resumeSession.updateViewport(CGSize(width: 390, height: 844))
        var resumeDownloads: [String] = [], resumeCutouts = 0
        let resume = ImportCoordinator(session: resumeSession,
            inbox: SharedImportInbox(directoryOverride: directory.appendingPathComponent("gallery-resume")),
            fetch: { url in .init(url: url, title: "Gallery", imageURL: firstURL, imageURLs: [firstURL, secondURL]) },
            image: { address in
                resumeDownloads.append(address)
                if address == secondURL { try? await Task.sleep(for: .milliseconds(80)) }
                return artwork
            }, cutout: { _ in resumeCutouts += 1; return artwork })
        resume.setActive(true); resume.loadTestLinks(["https://shop.example/resume-gallery"])
        try await waitFor { resumeDownloads.count == 2 }
        resume.setActive(false)
        try await Task.sleep(for: .milliseconds(30))
        resume.setActive(true)
        try await waitFor { resume.items.first?.state == "Ready" }
        precondition(resumeDownloads == [firstURL, secondURL, secondURL] && resumeCutouts == 1)
        let resumeProductID = resumeSession.document.placements[resume.items[0].placementID!]!.productID
        precondition(resumeSession.document.products[resumeProductID]?.galleryAssets?.count == 1)
        let legacy = try JSONDecoder().decode(GarmsAPI.ImportedProduct.self, from: Data(#"{"url":"https://shop.example","title":null,"imageURL":"https://cdn.example/first.png"}"#.utf8))
        precondition(legacy.imageURLs == nil && legacy.imageURL == firstURL)
        print("Import session checks passed")
    }
}
