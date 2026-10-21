import Foundation
import ConvexMobile

/// GarmsServer over Convex actions, through the signed-in client.
@MainActor final class ConvexGarmsServer: GarmsServer {
    private let client: ConvexClientWithAuth<String>

    init(client: ConvexClientWithAuth<String>) { self.client = client }

    func importProduct(url: String) async throws -> GarmsAPI.ImportedProduct {
        _ = try SharedLink.normalized(url)
        return try await client.action("imports:product", with: ["url": url])
    }

    func findListing(_ jpeg: Data) async throws -> GarmsAPI.Listing? {
        var args: [String: ConvexEncodable?] = ["image": jpeg.base64EncodedString()]
        if let region = Locale.current.region?.identifier, region.count == 2 { args["region"] = region }
        return try await client.action("matches:search", with: args)
    }
}
