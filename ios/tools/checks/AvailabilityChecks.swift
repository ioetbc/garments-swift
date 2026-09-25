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
        let session = CanvasSession()
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
        session.updateAvailability(.init(status: "available", error: nil), productID: product.id)
        precondition(session.classification(for: sharedURLProduct)?.status == "sold")
        precondition(session.classification(for: product)?.status == "available")
        for status in ["out_of_stock", "sold", "listing_ended", "removed"] {
            session.updateAvailability(.init(status: status, error: nil), productID: product.id)
            precondition(session.opacity(for: placement) == 0.35)
        }
        for status in ["available", "unknown", "unexpected"] {
            session.updateAvailability(.init(status: status, error: nil), productID: product.id)
            precondition(session.opacity(for: placement) == 1)
        }
        session.updateAvailability(.init(status: "sold", error: nil), productID: product.id)
        session.searchQuery = "no matching products"
        precondition(session.opacity(for: placement) == 0.1)
        session.searchQuery = ""
        precondition(session.opacity(for: placement) == 0.35)
        let failed = CanvasSession()
        await failed.loadAvailability { _ in throw URLError(.notConnectedToInternet) }
        precondition(failed.availability.isEmpty)
        precondition(failed.document.placements.values.allSatisfy { failed.opacity(for: $0) == 1 })
        let cancelled = CanvasSession()
        let task = Task {
            await cancelled.loadAvailability { _ in
                try await Task.sleep(for: .seconds(10))
                return .init(status: "sold", error: nil)
            }
        }
        task.cancel()
        await task.value
        precondition(cancelled.availability.isEmpty)
        print("Availability checks passed: independent product requests and statuses, concurrency limit, fading, search, recovery, failures and cancellation")
    }
}
