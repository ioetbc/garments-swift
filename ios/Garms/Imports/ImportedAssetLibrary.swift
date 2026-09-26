import UIKit
import ImageIO

@MainActor final class ImportedAssetLibrary {
    private var sources: [String: Data] = [:]
    func data(for key: String) -> Data? { sources[key] }
    func insert(_ data: Data) -> String {
        let key = "import-" + UUID().uuidString
        sources[key] = data
        return key
    }
    func retain(_ keys: Set<String>) { sources = sources.filter { keys.contains($0.key) } }

}

nonisolated final class HTTPSImageRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" && request.url?.user == nil && request.url?.password == nil ? request : nil)
    }
}
nonisolated enum ImportedImageDownload {
    struct Artwork: Sendable { let data: Data; let aspect: Double }
    static func fetch(_ address: String) async throws -> Artwork {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw SharedLink.LinkError.invalid }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: HTTPSImageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw ImageError.detail("Image download returned a non-HTTP response.") }
        guard response.statusCode == 200 else { throw ImageError.detail("Image download failed: HTTP \(response.statusCode).") }
        guard response.mimeType?.hasPrefix("image/") == true else { throw ImageError.detail("Image download rejected Content-Type: \(response.mimeType ?? "missing").") }
        guard response.expectedContentLength <= 10 * 1024 * 1024 else { throw ImageError.detail("Image Content-Length exceeds the 10 MB limit: \(response.expectedContentLength) bytes.") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 10 * 1024 * 1024 { throw ImageError.detail("Downloaded image exceeds the 10 MB limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Double,
                  let height = props[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 80_000_000,
                  let image = CanvasImageWorker.decode(data: data, tier: 2048) else { throw ImageError.detail("Image decoding failed or dimensions exceed 20,000 pixels / 80 megapixels.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw ImageError.detail("Could not encode the downloaded image as PNG.") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ImageError.detail("Could not encode the downloaded image as PNG.") }
            return Artwork(data: output as Data, aspect: Double(image.width) / Double(image.height))
        }.value
    }
    enum ImageError: LocalizedError {
        case invalid, detail(String)
        var errorDescription: String? {
            switch self {
            case .invalid: "The image could not be installed. The saved link is still available."
            case .detail(let message): message
            }
        }
    }
}
