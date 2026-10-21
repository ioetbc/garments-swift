import Foundation
import UIKit

/// Photo imports: searching for the listing, and importing the one found onto the Product.
@main struct MatchChecks {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
    static func png(width: Int, height: Int, colour: UIColor) -> ImportedImageDownload.Artwork {
        let data = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            colour.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
        return .init(data: data, aspect: Double(width) / Double(height))
    }
    static let screenshot = png(width: 30, height: 60, colour: .red)
    static let listing = png(width: 80, height: 40, colour: .blue)
    static let jacket = GarmsAPI.Listing(url: "https://shop.example/jacket")

    /// A laid-out session whose imports search with `search`, fetch pages with `fetch` and download with `image`.
    @MainActor static func imports(
        search: @escaping (ImportedImageDownload.Artwork) async throws -> GarmsAPI.Listing?,
        fetch: @escaping (String) async throws -> GarmsAPI.ImportedProduct = { _ in preconditionFailure("No page should be fetched") },
        image: @escaping (String) async throws -> ImportedImageDownload.Artwork = { _ in listing }
    ) -> (CanvasSession, ImportCoordinator, SharedImportInbox) {
        let session = CanvasFixtures.session(laidOut: true).0
        let inbox = SharedImportInbox(directoryOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = ImportCoordinator(session: session, inbox: inbox,
            fetch: fetch, image: image, cutout: { $0.aspect == listing.aspect ? png(width: 60, height: 40, colour: .blue) : nil },
            search: search)
        return (session, coordinator, inbox)
    }

    /// Imports one photo and waits until it is on the Canvas.
    @MainActor static func importPhoto(_ coordinator: ImportCoordinator, _ session: CanvasSession) async throws -> Product {
        coordinator.importPhoto(title: "Imported photo 1") { screenshot.data }
        try await waitFor { coordinator.items.first?.state == "Ready" }
        return session.document.products[session.document.placements[coordinator.items[0].placementID!]!.productID]!
    }

    @MainActor static func main() async throws {
        // A photo is searched with its whole image; when nothing is found it stays as imported.
        do {
            var searched: [ImportedImageDownload.Artwork] = []
            let (session, coordinator, _) = imports(search: { searched.append($0); return nil })
            let product = try await importPhoto(coordinator, session)
            try await waitFor { searched.count == 1 }
            try await Task.sleep(for: .milliseconds(30))
            precondition(searched[0].data == session.importedAssets.data(for: product.originalAsset ?? product.asset))
            precondition(session.document.products[product.id] == product && product.product_url.isEmpty)
            precondition(coordinator.items.count == 1 && coordinator.pendingCount == 0)
        }
        // A found listing is imported onto the Product straight away, where its Sticker stands.
        do {
            var fetched: [String] = [], downloads: [String] = []
            let (session, coordinator, _) = imports(search: { _ in jacket }, fetch: { url in
                fetched.append(url)
                return .init(url: url, title: "Red Jacket", imageURL: "https://cdn.example/1.jpg",
                             imageURLs: ["https://cdn.example/1.jpg", "https://cdn.example/2.jpg"], price: Price(amount: 4500, currency: "GBP"))
            }, image: { downloads.append($0); return listing })
            let product = try await importPhoto(coordinator, session)
            let sticker = session.document.placements.values.first { $0.productID == product.id }!
            try await waitFor { session.document.products[product.id]?.product_url == jacket.url }
            let done = session.document.products[product.id]!
            precondition(fetched == [jacket.url] && downloads == ["https://cdn.example/1.jpg", "https://cdn.example/2.jpg"])
            precondition(done.title == "Red Jacket" && done.price == Price(amount: 4500, currency: "GBP"))
            // The photo's art stays; the listing's images become Photos after it.
            precondition(done.asset == product.asset && done.originalAsset == product.originalAsset && done.aspect == product.aspect)
            precondition(done.galleryAssets.count == 3 && done.galleryAssets[0] == product.originalAsset)
            precondition(session.document.placements[sticker.id] == sticker)
            try await waitFor { coordinator.pendingCount == 0 }
            session.undo()
            session.redo()
            precondition(session.document.products[product.id] == done)
        }
        // A listing that can't be imported shows as a failed import that can be retried.
        do {
            var attempts = 0
            let (session, coordinator, _) = imports(search: { _ in jacket }, fetch: { url in
                attempts += 1
                if attempts == 1 { throw URLError(.badServerResponse) }
                return .init(url: url, title: "Red Jacket", imageURL: "https://cdn.example/1.jpg")
            })
            let product = try await importPhoto(coordinator, session)
            try await waitFor { coordinator.items.last?.state == "Failed" }
            precondition(session.document.products[product.id] == product && coordinator.pendingCount == 1)
            coordinator.retry(coordinator.items.last!.id)
            try await waitFor { session.document.products[product.id]?.product_url == jacket.url }
            try await waitFor { coordinator.pendingCount == 0 }
        }
        // Shared links are not searched, and record the page's Price.
        do {
            let (session, coordinator, inbox) = imports(search: { _ in preconditionFailure("Links are not searched") }, fetch: { url in
                .init(url: url, title: "Coat", imageURL: "https://cdn.example/1.jpg", price: Price(amount: 9900, currency: "EUR"))
            })
            try inbox.enqueue(SharedImport(url: "https://shop.example/coat"))
            coordinator.checkInbox()
            try await waitFor { coordinator.items.first?.state == "Ready" }
            let sticker = session.document.placements[coordinator.items[0].placementID!]!
            precondition(session.document.products[sticker.productID]?.price == Price(amount: 9900, currency: "EUR"))
        }
        print("Match checks passed")
    }
}
