import Foundation
import UIKit

/// Screenshot imports: searching for the listing, and resolving the Candidate matches.
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
    static let jacket = Product.Match.Candidate(url: "https://shop.example/jacket", title: "Jacket", domain: "shop.example", thumbnail: "https://cdn.example/j.jpg")

    /// A laid-out session whose imports search with `search`, fetch pages with `fetch` and download with `image`.
    @MainActor static func imports(
        search: @escaping (ImportedImageDownload.Artwork) async throws -> [Product.Match.Candidate],
        fetch: @escaping (String) async throws -> GarmsAPI.ImportedProduct = { _ in preconditionFailure("No page should be fetched") },
        image: @escaping (String) async throws -> ImportedImageDownload.Artwork = { _ in listing },
        session: CanvasSession? = nil
    ) -> (CanvasSession, ImportCoordinator) {
        let session = session ?? CanvasFixtures.session(laidOut: true).0
        let coordinator = ImportCoordinator(session: session,
            inbox: SharedImportInbox(directoryOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            fetch: fetch, image: image, cutout: { $0.aspect == listing.aspect ? png(width: 60, height: 40, colour: .blue) : nil },
            search: search)
        coordinator.setActive(true)
        return (session, coordinator)
    }

    /// Imports one Screenshot and waits until its search has finished.
    @MainActor static func importScreenshot(_ coordinator: ImportCoordinator, _ session: CanvasSession) async throws -> Product {
        coordinator.importPhoto(title: "Imported photo 1", screenshot: true) { screenshot.data }
        try await waitFor { coordinator.awaitingMatch.contains { $0.match?.status != .searching } }
        return coordinator.awaitingMatch.last!
    }

    @MainActor static func main() async throws {
        // A Screenshot import lands on the Canvas, then stays Awaiting match when no listing is found.
        do {
            var searched: [ImportedImageDownload.Artwork] = []
            let (session, coordinator) = imports(search: { searched.append($0); return [] })
            let product = try await importScreenshot(coordinator, session)
            precondition(product.match == .init(status: .notFound))
            precondition(searched.count == 1 && searched[0].data == session.importedAssets.data(for: product.originalAsset ?? product.asset))
            precondition(session.document.placements.values.contains { $0.productID == product.id })
            // Tapping its Sticker opens its row in the Imports sheet, not Product details.
            let sticker = session.document.placements.values.first { $0.productID == product.id }!
            session.select(sticker.id, showDetails: true)
            precondition(session.inspectedPlacement == nil && session.revealedMatch == product.id)
            // A fresh coordinator over the same document rebuilds the row.
            let (_, reopened) = imports(search: { _ in preconditionFailure("A finished search must not run again") }, session: session)
            precondition(reopened.awaitingMatch.map(\.id) == [product.id])
        }
        // A photo that is not a Screenshot imports as before and is never searched.
        do {
            let (session, coordinator) = imports(search: { _ in preconditionFailure("Only Screenshots are searched") })
            coordinator.importPhoto(title: "Imported photo 1", screenshot: false) { screenshot.data }
            try await waitFor { coordinator.items.first?.state == "Ready" }
            try await Task.sleep(for: .milliseconds(30))
            precondition(coordinator.awaitingMatch.isEmpty)
            let sticker = session.document.placements[coordinator.items[0].placementID!]!
            session.select(sticker.id, showDetails: true)
            precondition(session.inspectedPlacement == sticker && session.revealedMatch == nil)
        }
        // A found listing is imported onto the Product straight away.
        do {
            var fetched: [String] = []
            let (session, coordinator) = imports(search: { _ in [jacket] }, fetch: { url in
                fetched.append(url)
                return .init(url: url, title: "Red Jacket", imageURL: "https://cdn.example/1.jpg", price: Price(amount: 4500, currency: "GBP"))
            })
            coordinator.importPhoto(title: "Imported photo 1", screenshot: true) { screenshot.data }
            try await waitFor { session.document.products.values.contains { $0.product_url == jacket.url && $0.match == nil } }
            let done = session.document.products.values.first { $0.product_url == jacket.url }!
            precondition(fetched == [jacket.url] && done.title == "Red Jacket" && done.price == Price(amount: 4500, currency: "GBP"))
            precondition(coordinator.awaitingMatch.isEmpty)
        }
        // After nothing is found, confirming a link imports that page onto the Product; pasting one does the same.
        var resolved: [Product] = []
        for resolve in ["confirm", "paste"] {
            var fetched: [String] = [], downloads: [String] = []
            let (session, coordinator) = imports(search: { _ in [] }, fetch: { url in
                fetched.append(url)
                return .init(url: url, title: "Red Jacket", imageURL: "https://cdn.example/1.jpg",
                             imageURLs: ["https://cdn.example/1.jpg", "https://cdn.example/2.jpg"], price: Price(amount: 4500, currency: "GBP"))
            }, image: { downloads.append($0); return listing })
            let product = try await importScreenshot(coordinator, session)
            let sticker = session.document.placements.values.first { $0.productID == product.id }!
            let group = session.document.namedGroups!.first { $0.members.contains(sticker.id) }!.id
            coordinator.confirm(product.id, url: resolve == "confirm" ? jacket.url : "  \(jacket.url)\n")
            try await waitFor { session.document.products[product.id]?.match == nil }
            let done = session.document.products[product.id]!
            precondition(fetched == [jacket.url] && downloads == ["https://cdn.example/1.jpg", "https://cdn.example/2.jpg"])
            precondition(done.product_url == jacket.url && done.title == "Red Jacket" && done.price == Price(amount: 4500, currency: "GBP"))
            precondition(done.aspect == 1.5 && session.importedAssets.data(for: done.originalAsset!) == listing.data)
            precondition(done.galleryAssets.count == 2 && done.galleryAssets[0] == product.originalAsset)
            let moved = session.document.placements[sticker.id]!
            precondition(moved.center == sticker.center && moved.z == sticker.z && max(moved.width, moved.height) == max(sticker.width, sticker.height))
            precondition(abs(moved.width / moved.height - 1.5) < 0.0001)
            precondition(session.document.namedGroups!.first { $0.id == group }!.members.contains(sticker.id))
            precondition(coordinator.awaitingMatch.isEmpty && !coordinator.loadingMatches.contains(product.id))
            session.select(sticker.id, showDetails: true)
            precondition(session.inspectedPlacement?.id == sticker.id)
            // Undo steps back over the import itself, never back to Awaiting match.
            session.undo()
            precondition(session.document.products[product.id] == nil || session.document.products[product.id]?.match == nil)
            session.redo()
            precondition(session.document.products[product.id] == done)
            resolved.append(done)
        }
        precondition(resolved[0].title == resolved[1].title && resolved[0].product_url == resolved[1].product_url)
        // None of these and Skip end Awaiting match and leave the Product's details alone.
        do {
            let (session, coordinator) = imports(search: { _ in [] })
            let product = try await importScreenshot(coordinator, session)
            precondition(product.match?.status == .notFound)
            coordinator.skipMatch(product.id)
            var expected = product; expected.match = nil
            precondition(session.document.products[product.id] == expected && coordinator.awaitingMatch.isEmpty)
        }
        // A failed search keeps Awaiting match; Retry search searches again.
        do {
            var attempts = 0
            let (session, coordinator) = imports(search: { _ in
                attempts += 1
                if attempts == 1 { throw URLError(.notConnectedToInternet) }
                return []
            })
            let product = try await importScreenshot(coordinator, session)
            precondition(product.match == .init(status: .failed) && attempts == 1)
            coordinator.retrySearch(product.id)
            try await waitFor { session.document.products[product.id]?.match?.status == .notFound }
            precondition(attempts == 2)
        }
        // A page that can't be imported leaves the Product Awaiting match, with its candidates.
        do {
            let (session, coordinator) = imports(search: { _ in [jacket] }, fetch: { _ in throw URLError(.badServerResponse) })
            let product = try await importScreenshot(coordinator, session)
            try await waitFor { session.document.products[product.id]?.match?.status == .loadFailed }
            precondition(session.document.products[product.id]?.match?.candidates == [jacket])
            precondition(session.document.products[product.id]?.asset == product.asset)
        }
        // Confirming a link another Product already has links the Sticker to that Product, where it stands.
        do {
            let (session, coordinator) = imports(search: { _ in [] })
            let existing = session.document.products.values.sorted { $0.id < $1.id }.first!
            let product = try await importScreenshot(coordinator, session)
            let sticker = session.document.placements.values.first { $0.productID == product.id }!
            // Compared as the shared-link rule does: scheme and host casing ignored.
            coordinator.confirm(product.id, url: existing.product_url.replacingOccurrences(of: "https://www.", with: "HTTPS://WWW."))
            let merged = session.document.placements[sticker.id]!
            precondition(session.document.products[product.id] == nil)
            let target = try SharedLink.normalized(session.document.products[merged.productID]!.product_url)
            let wanted = try SharedLink.normalized(existing.product_url)
            precondition(target == wanted)
            precondition(merged.center == sticker.center && coordinator.notice == "Already saved — linked to your existing item.")
            precondition(coordinator.awaitingMatch.isEmpty)
        }
        // Shared-link imports record the page's Price too.
        do {
            let (session, coordinator) = imports(search: { _ in preconditionFailure("Links are not searched") }, fetch: { url in
                .init(url: url, title: "Coat", imageURL: "https://cdn.example/1.jpg", price: Price(amount: 9900, currency: "EUR"))
            })
            coordinator.loadTestLinks(["https://shop.example/coat"])
            try await waitFor { coordinator.items.first?.state == "Ready" }
            let sticker = session.document.placements[coordinator.items[0].placementID!]!
            precondition(session.document.products[sticker.productID]?.price == Price(amount: 9900, currency: "EUR"))
        }
        print("Match checks passed")
    }
}
