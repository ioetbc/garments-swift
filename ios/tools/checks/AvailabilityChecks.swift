import Foundation

@main struct AvailabilityChecks {
    @MainActor final class Requests {
        var urls: [String] = []
        var active = 0
        var peak = 0
        func fetch(_ url: String) async throws -> GarmsAPI.ProductClassification? {
            urls.append(url)
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            return .init(status: "sold", error: nil)
        }
    }

    @MainActor static func main() async {
        let errorResult = GarmsAPI.ProductClassification(status: "unknown", error: "The availability provider is currently experiencing high demand. Please retry shortly.")
        precondition(errorResult.label == "Couldn’t check")
        precondition(!errorResult.isUnavailable)
        precondition(GarmsAPI.ProductClassification(status: "unknown", error: nil).label == "Unknown")
        let (session, sync) = CanvasFixtures.session()
        let requests = Requests()
        await session.loadAvailability { try await requests.fetch($0) }
        let productIDs = Set(session.document.placements.values.map(\.productID))
        let expected = productIDs.compactMap { session.document.products[$0]?.product_url }
        precondition(requests.urls.sorted() == expected.sorted())
        precondition(requests.urls.count == expected.count)
        precondition(requests.peak <= 3)
        precondition(session.document.placements.values.allSatisfy { session.opacity(for: $0) == 0.35 })
        let placement = session.document.placements.values.first!
        let product = session.document.products[placement.productID]!
        let sharedURLProduct = session.document.products.values.first {
            $0.id != product.id && $0.product_url == product.product_url
        }!
        session.recordAvailability(.init(status: "available", error: nil), productID: product.id)
        precondition(session.document.products[sharedURLProduct.id]?.availability?.state == .sold)
        precondition(session.document.products[product.id]?.availability?.state == .available)
        // Results are saved on the Product, outside undo.
        precondition(sync.applied.last?.products.map(\.id) == [product.id] && !session.history.canUndo)
        for status in ["sold", "out_of_stock", "removed"] {
            session.recordAvailability(.init(status: status, error: nil), productID: product.id)
            precondition(session.opacity(for: placement) == 0.35)
        }
        for status in ["available", "unknown", "unexpected", "listing_ended"] {
            session.recordAvailability(.init(status: status, error: nil), productID: product.id)
            precondition(session.opacity(for: placement) == 1)
        }
        // A result never undoes, or is undone by, the User's own edits.
        session.updateProductPrice(product.id, price: Price(amount: 100, currency: "EUR"))
        session.recordAvailability(.init(status: "available", error: nil), productID: product.id)
        session.undo()
        precondition(session.document.products[product.id]?.price == product.price)
        precondition(session.document.products[product.id]?.availability?.state == .available)
        // A failed check keeps the last known Availability.
        session.recordAvailability(.init(status: "sold", error: nil), productID: product.id)
        session.recordAvailability(.init(status: "available", error: "Timed out"), productID: product.id)
        precondition(session.document.products[product.id]?.availability?.state == .sold)
        session.searchQuery = "no matching products"
        precondition(session.opacity(for: placement) == 0.1)
        session.searchQuery = ""
        precondition(session.opacity(for: placement) == 0.35)
        // Products checked within the last day are not scraped again on launch.
        let again = Requests()
        await session.loadAvailability { try await again.fetch($0) }
        precondition(again.urls.isEmpty)
        await session.loadAvailability(now: Date().addingTimeInterval(25 * 60 * 60)) { try await again.fetch($0) }
        precondition(again.urls.count == expected.count)
        let failed = CanvasFixtures.session().0
        await failed.loadAvailability { _ in throw URLError(.notConnectedToInternet) }
        precondition(failed.document.products.values.allSatisfy { $0.availability == nil })
        precondition(failed.document.placements.values.allSatisfy { failed.opacity(for: $0) == 1 })
        let cancelled = CanvasFixtures.session().0
        let task = Task {
            await cancelled.loadAvailability { _ in
                try await Task.sleep(for: .seconds(10))
                return .init(status: "sold", error: nil)
            }
        }
        task.cancel()
        await task.value
        precondition(cancelled.document.products.values.allSatisfy { $0.availability == nil })
        print("Availability checks passed: independent product requests and statuses, concurrency limit, fading, search, recovery, failures and cancellation")
    }
}
