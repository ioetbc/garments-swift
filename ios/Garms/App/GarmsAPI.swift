import Foundation

/// Server work the app can't do itself, run for the signed-in User.
@MainActor protocol GarmsServer: AnyObject, Sendable {
    /// Whether the app is connected to the server right now.
    func isConnected() async -> Bool
    /// A product page's title, Price and images.
    func importProduct(url: String) async throws -> GarmsAPI.ImportedProduct
    /// A page's Markdown and its availability classification.
    func scrapePage(url: String) async throws -> GarmsAPI.ScrapedPage
    /// Writes an import processing log to the server's logs.
    func sendImportLog(_ report: String) async throws
    /// The listing a Screenshot, flattened to JPEG, most likely shows. Costs one vision model call and one web search.
    func findListing(_ jpeg: Data) async throws -> Product.Match.Candidate?
}

/// What the server sends back.
enum GarmsAPI {
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
}
