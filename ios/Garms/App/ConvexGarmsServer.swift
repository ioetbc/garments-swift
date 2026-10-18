import Foundation
import Combine
import ConvexMobile

/// GarmsServer over Convex actions, through the signed-in client.
@MainActor final class ConvexGarmsServer: GarmsServer {
    private let client: ConvexClientWithAuth<String>

    init(client: ConvexClientWithAuth<String>) { self.client = client }

    private enum InvalidURL: LocalizedError {
        case page
        var errorDescription: String? { "Enter a valid http or https page URL." }
    }

    func isConnected() async -> Bool {
        await client.watchWebSocketState().values.first { _ in true } == .connected
    }

    func importProduct(url: String) async throws -> GarmsAPI.ImportedProduct {
        _ = try SharedLink.normalized(url)
        return try await client.action("imports:product", with: ["url": url])
    }

    func scrapePage(url address: String) async throws -> GarmsAPI.ScrapedPage {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageURL = URL(string: address),
              let scheme = pageURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = pageURL.host, !host.isEmpty,
              pageURL.user == nil, pageURL.password == nil else {
            throw InvalidURL.page
        }
        return try await client.action("imports:scrape", with: ["url": pageURL.absoluteString])
    }

    func sendImportLog(_ report: String) async throws {
        let _: String? = try await client.action("imports:log", with: ["report": report])
    }

    func findListing(_ jpeg: Data) async throws -> Product.Match.Candidate? {
        var args: [String: ConvexEncodable?] = ["image": jpeg.base64EncodedString()]
        if let region = Locale.current.region?.identifier, region.count == 2 { args["region"] = region }
        return try await client.action("matches:search", with: args)
    }
}
