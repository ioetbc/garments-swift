import Foundation

enum GarmsAPI {
    private struct HealthResponse: Decodable {
        let status: String
        let message: String
    }

    private enum ConnectionError: LocalizedError {
        case notConfigured, invalidResponse, invalidURL, server(Int), message(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "The server address has not been configured."
            case .invalidResponse: "The server returned an unexpected response."
            case .invalidURL: "Enter a valid http or https page URL."
            case .message(let message): message
            case .server(let code): "The server returned an error (\(code)). Try again."
            }
        }
    }

    private static func baseURL() throws -> URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "GARMS_API_BASE_URL") as? String
        #if DEBUG
        let address = ProcessInfo.processInfo.environment["GARMS_API_BASE_URL"]
            ?? configured ?? "http://localhost:3000"
        let allowedSchemes = ["http", "https"]
        #else
        let address = configured ?? ""
        let allowedSchemes = ["https"]
        #endif
        guard let baseURL = URL(string: address),
              let scheme = baseURL.scheme, allowedSchemes.contains(scheme),
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw ConnectionError.notConfigured
        }
        return baseURL
    }

    static func checkConnection() async throws -> String {
        var request = URLRequest(
            url: try baseURL().appendingPathComponent("api/health"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }
        guard response.statusCode == 200 else { throw ConnectionError.server(response.statusCode) }
        guard let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
              health.status == "ok", !health.message.isEmpty else {
            throw ConnectionError.invalidResponse
        }
        return health.message
    }

    struct ScrapedPage: Decodable {
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

    private struct ScrapeRequest: Encodable { let url: String }
    private struct ErrorResponse: Decodable { let error: String; var diagnostics: [String]? = nil }

    struct ImportedProduct: Decodable, Sendable {
        let url: String
        let title: String?
        let imageURL: String?
        var imageURLs: [String]? = nil
        var diagnostics: [String]? = nil
    }
    static func sendImportLog(_ report: String) async throws {
        var request = URLRequest(url: try baseURL().appendingPathComponent("api/import/diagnostics"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(report.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard response.statusCode == 200 else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw ConnectionError.message("Send log failed (HTTP \(response.statusCode)): " + (error?.error ?? "Unexpected server response."))
        }
    }

    static func importProduct(url: String) async throws -> ImportedProduct {
        _ = try SharedLink.normalized(url)
        var request = URLRequest(url: try baseURL().appendingPathComponent("api/import"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ScrapeRequest(url: url))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard response.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let details = (["Import API HTTP \(response.statusCode): " + (failure?.error ?? "Unexpected server response.")] + (failure?.diagnostics ?? [])).joined(separator: "\n")
            throw ConnectionError.message(details)
        }
        return try JSONDecoder().decode(ImportedProduct.self, from: data)
    }

    static func scrapePage(url address: String) async throws -> ScrapedPage {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageURL = URL(string: address),
              let scheme = pageURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = pageURL.host, !host.isEmpty,
              pageURL.user == nil, pageURL.password == nil else {
            throw ConnectionError.invalidURL
        }
        var request = URLRequest(
            url: try baseURL().appendingPathComponent("api/scrape"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 95
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ScrapeRequest(url: pageURL.absoluteString))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }
        guard response.statusCode == 200 else {
            if let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ConnectionError.message(error.error)
            }
            throw ConnectionError.server(response.statusCode)
        }
        guard let page = try? JSONDecoder().decode(ScrapedPage.self, from: data),
              !page.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionError.invalidResponse
        }
        return page
    }

}
