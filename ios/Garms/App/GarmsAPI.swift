import Foundation

/// Server work the app can't do itself, run for the signed-in User.
@MainActor protocol GarmsServer: AnyObject, Sendable {
    /// Whether the app is connected to the server right now.
    func isConnected() async -> Bool
    /// A product page's title, Price and images.
    func importProduct(url: String) async throws -> GarmsAPI.ImportedProduct
    /// Writes an import processing log to the server's logs.
    func sendImportLog(_ report: String) async throws
    /// The listing a Screenshot, flattened to JPEG, most likely shows. Costs one vision model call and one web search.
    func findListing(_ jpeg: Data) async throws -> Product.Match.Candidate?
}

/// What the server sends back.
enum GarmsAPI {
    nonisolated struct ImportedProduct: Decodable, Sendable {
        let url: String
        let title: String?
        let imageURL: String?
        var imageURLs: [String]? = nil
        var price: Price? = nil
        var diagnostics: [String]? = nil
    }
}
