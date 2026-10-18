import Foundation
import Combine
import ConvexMobile

/// Server work the app can't do itself, run as Convex actions for the signed-in User.
enum GarmsAPI {
    /// Set once at launch; every call goes through the signed-in Convex client.
    static var client: ConvexClientWithAuth<String>?

    private enum ConnectionError: LocalizedError {
        case notConfigured, offline, invalidURL

        var errorDescription: String? {
            switch self {
            case .notConfigured: "The server connection has not been configured."
            case .offline: "Not connected to Garms. Check your internet connection."
            case .invalidURL: "Enter a valid http or https page URL."
            }
        }
    }

    private static func convex() throws -> ConvexClientWithAuth<String> {
        guard let client else { throw ConnectionError.notConfigured }
        return client
    }

    static func checkConnection() async throws -> String {
        let state = await try convex().watchWebSocketState().values.first { _ in true }
        guard state == .connected else { throw ConnectionError.offline }
        return "Connected to Garms."
    }

    nonisolated struct ScrapedPage: Decodable, Sendable {
        let url: String
        let markdown: String
        let title: String?
        let statusCode: Int?
        let classification: ProductClassification?
    }

    nonisolated struct ProductClassification: Decodable, Sendable {
        let status: String
        let error: String?

        var isUnavailable: Bool {
            status == "sold"
        }

        var label: String {
            if let error, !error.isEmpty { return "Couldn’t check" }
            return switch status {
            case "sold": "Sold"
            case "available": "Available"
            default: "Unknown"
            }
        }
    }

    nonisolated struct ImportedProduct: Decodable, Sendable {
        let url: String
        let title: String?
        let imageURL: String?
        var imageURLs: [String]? = nil
        var price: Price? = nil
        var diagnostics: [String]? = nil
    }
    /// Writes the report to the Convex deployment's logs.
    static func sendImportLog(_ report: String) async throws {
        let _: String? = try await convex().action("imports:log", with: ["report": report])
    }

    static func importProduct(url: String) async throws -> ImportedProduct {
        _ = try SharedLink.normalized(url)
        return try await convex().action("imports:product", with: ["url": url])
    }

    static func scrapePage(url address: String) async throws -> ScrapedPage {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageURL = URL(string: address),
              let scheme = pageURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = pageURL.host, !host.isEmpty,
              pageURL.user == nil, pageURL.password == nil else {
            throw ConnectionError.invalidURL
        }
        return try await convex().action("imports:scrape", with: ["url": pageURL.absoluteString])
    }
}
