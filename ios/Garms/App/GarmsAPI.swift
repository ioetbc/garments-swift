import Foundation

/// Server work the app can't do itself, run for the signed-in User.
@MainActor protocol GarmsServer: AnyObject, Sendable {
    /// A product page's title, Price and images.
    func importProduct(url: String) async throws -> GarmsAPI.ImportedProduct
    /// The listing a Screenshot, flattened to JPEG, most likely shows. Costs one vision model call and one web search.
    func findListing(_ jpeg: Data) async throws -> GarmsAPI.Listing?
}

/// What the server sends back.
enum GarmsAPI {
    nonisolated struct ImportedProduct: Decodable, Sendable {
        let url: String
        let title: String?
        var imageURLs: [String] = []
        var price: Price? = nil
    }
    /// A web page that is probably the listing a Screenshot shows.
    nonisolated struct Listing: Decodable, Sendable {
        let url: String
    }
}
