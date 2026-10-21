import Foundation
import UIKit
import Vision

@MainActor final class CutoutGate {
    var pending: [CheckedContinuation<ImportedImageDownload.Artwork?, any Error>] = []
    var calls = 0
    var peak = 0
    func run(_ source: ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork? {
        calls += 1
        return try await withCheckedThrowingContinuation {
            pending.append($0); peak = max(peak, pending.count)
        }
    }
    func finish(_ value: ImportedImageDownload.Artwork?) { pending.removeFirst().resume(returning: value) }
}

@main struct ForegroundCutoutChecks {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
    @MainActor static func main() async throws {
        let inferenceError = NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue)
        var attempts: [Bool] = [], diagnostics: [String] = []
        let recovered = try ForegroundCutoutProcessor.withInferenceRecovery(operation: { useGPU in
            attempts.append(useGPU)
            if !useGPU { throw inferenceError }
            return 42
        }, diagnostic: { diagnostics.append($0) })
        precondition(recovered == 42 && attempts == [false, true] && diagnostics.count == 3)
        // No retry loop, and no retry for input errors or cancellation.
        for error in [inferenceError, NSError(domain: VNErrorDomain, code: VNErrorCode.invalidImage.rawValue), CancellationError() as Error] {
            attempts = []
            do {
                let _: Int = try ForegroundCutoutProcessor.withInferenceRecovery(operation: { useGPU in
                    attempts.append(useGPU); throw error
                }, diagnostic: { _ in })
                preconditionFailure("Expected failure")
            } catch {
                precondition(attempts == ((error as NSError).code == inferenceError.code && (error as NSError).domain == VNErrorDomain ? [false, true] : [false]))
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SharedImportInbox(directoryOverride: directory)
        let session = CanvasFixtures.session(laidOut: true).0
        let baseline = session.document.order.count
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let png = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 100))
            context.fill(CGRect(x: 70, y: 0, width: 30, height: 100))
        }.pngData()!
        let source = ImportedImageDownload.Artwork(data: png, aspect: 1)
        let cutout = ImportedImageDownload.Artwork(data: png, aspect: 0.5)
        let decoded = CanvasImageWorker.decode(data: png, tier: 192)!
        let mask = CanvasImageWorker.mask(decoded)!
        precondition(mask.hit(u: 0.1, v: 0.5) && mask.hit(u: 0.9, v: 0.5) && !mask.hit(u: 0.5, v: 0.5))
        let gate = CutoutGate()
        var fetches = 0, downloads = 0
        let coordinator = ImportCoordinator(session: session, inbox: inbox, fetch: { url in
            fetches += 1
            return .init(url: url, title: "Two shoes", imageURLs: ["https://cdn.example/shoes.png"])
        }, image: { _ in downloads += 1; return source }, cutout: { try await gate.run($0) })
        let record = SharedImport(url: "https://shop.example/shoes")
        try inbox.enqueue(record)
        coordinator.checkInbox()
        try await waitFor { gate.calls == 1 }
        let id = coordinator.items[0].placementID!
        let productID = session.document.placements[id]!.productID
        let original = session.document.products[productID]!.cutout
        precondition(session.document.products[productID]!.original == original)
        precondition(session.importedAssets.data(for: original) == png)
        precondition(coordinator.items[0].phase == .processing(.removingBackground))
        precondition(fetches == 1 && downloads == 1 && gate.peak == 1)
        // Resolve an active interaction before rereading geometry.
        session.resolveInteraction = {
            session.stage {
                $0.document.placements[id]?.center = .init(x: 800, y: 600)
                $0.document.placements[id]?.width = 280
                $0.document.placements[id]?.height = 280
            }
        }
        let order = session.document.order
        let camera = session.camera
        let selection = session.selection
        let revision = session.revision
        gate.finish(cutout)
        try await waitFor { coordinator.items[0].phase.isReady }
        session.resolveInteraction = nil
        let product = session.document.products[productID]!
        let placement = session.document.placements[id]!
        precondition(product.original == original && product.cutout != original)
        precondition(session.importedAssets.data(for: product.cutout) == png && session.importedAssets.data(for: original) == png)
        precondition(placement.center == .init(x: 800, y: 600) && max(placement.width, placement.height) == 280)
        precondition(session.document.order == order && session.document.order.count == baseline + 1)
        precondition(session.camera.center == camera.center && session.camera.zoom == camera.zoom && session.selection == selection)
        precondition(session.revision > revision && product.sourceUrl == record.url)
        try session.document.validate()
        let store = CanvasAssetStore(); store.library = session.importedAssets
        let key = CanvasAssetStore.Key(asset: product.cutout, tier: 192)
        store.needed = [key]; _ = store.image(key); store.reconcile()
        try await waitFor { store.masks[product.cutout] != nil }
        precondition(!store.hit(placement, product: product, point: placement.center))
        precondition(store.hit(placement, product: product, point: .init(x: placement.bounds.minX + placement.width * 0.1, y: placement.center.y)))
        precondition(store.hit(placement, product: product, point: .init(x: placement.bounds.minX + placement.width * 0.9, y: placement.center.y)))
        store.memoryWarning()
        precondition(session.importedAssets.data(for: original) != nil && session.importedAssets.data(for: product.cutout) != nil)
        store.needed = [key]; _ = store.image(key); store.reconcile()
        try await waitFor { store.masks[product.cutout] != nil }
        // Another product can independently own the same original.
        let other = session.insertImport(SharedImport(url: "https://shop.example/other"), artwork: source)!
        let otherProduct = session.document.placements[other]!.productID
        session.stage { $0.document.products[otherProduct]?.original = original }
        session.deletePlacement(id); coordinator.deleted(id)
        // Removing Stickers keeps the Products, so their files stay cached.
        session.deletePlacement(other)
        precondition(session.importedAssets.data(for: product.cutout) != nil && session.importedAssets.data(for: original) != nil)
        // Both deletion entry points discard late results without resurrecting the Sticker.
        for dismiss in [false, true] {
            let record = SharedImport(url: "https://shop.example/delete-\(dismiss)")
            try inbox.enqueue(record); coordinator.checkInbox()
            try await waitFor { !gate.pending.isEmpty }
            let item = coordinator.items.last!
            let placementID = item.placementID!
            let oldProduct = session.document.products[session.document.placements[placementID]!.productID]!
            if dismiss { coordinator.dismiss(item.id) }
            else { session.deletePlacement(placementID); coordinator.deleted(placementID) }
            gate.finish(cutout)
            await Task.yield()
            precondition(session.document.placements[placementID] == nil)
            precondition(session.document.products[oldProduct.id]?.cutout == oldProduct.cutout)
        }
        // Empty and thrown extraction outcomes are successful original imports.
        for throwsError in [false, true] {
            var calls = 0, imageCalls = 0, cutoutCalls = 0
            let fallback = ImportCoordinator(session: session, inbox: inbox, fetch: { url in
                calls += 1
                return .init(url: url, title: nil, imageURLs: ["https://cdn.example/image.png"])
            }, image: { _ in imageCalls += 1; return source }, cutout: { _ in
                cutoutCalls += 1
                if cutoutCalls > 1 { return cutout }
                if throwsError { throw URLError(.cannotDecodeContentData) }
                return nil
            })
            try inbox.enqueue(SharedImport(url: "https://shop.example/fallback-\(throwsError)"))
            fallback.checkInbox()
            try await waitFor { fallback.items.first?.phase.isReady == true }
            let item = fallback.items[0]
            guard case .ready(let note?) = item.phase else { preconditionFailure("A kept background is noted") }
            precondition(note.hasPrefix("Background kept:") && calls == 1)
            precondition(note.contains(throwsError ? "NSURLErrorDomain" : "no usable cutout"))
            let product = session.document.products[session.document.placements[item.placementID!]!.productID]!
            precondition(product.cutout == product.original)
            fallback.retry(item.id)
            try await waitFor { fallback.items[0].phase.isReady && cutoutCalls == 2 }
            precondition(calls == 1 && imageCalls == 1 && fallback.items[0].phase == .ready(note: nil))
            precondition(!fallback.items[0].canRetryBackground)
            let retriedProduct = session.document.products[session.document.placements[item.placementID!]!.productID]!
            precondition(retriedProduct.cutout != retriedProduct.original)
        }
        let fixture = CanvasFixtures.products[0]
        let decodedFixture = try JSONDecoder().decode(Product.self, from: JSONEncoder().encode(fixture))
        precondition(decodedFixture == fixture && decodedFixture.original == nil)
        try session.document.validate()
        print("Foreground cutout checks passed")
    }
}
