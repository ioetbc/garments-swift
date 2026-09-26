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
    func placeholder() -> String {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 220), format: format).image { context in
            UIColor.secondarySystemBackground.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 220))
            let text = "↗\nSaved link" as NSString
            text.draw(in: CGRect(x: 25, y: 65, width: 250, height: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.label])
        }
        return insert(image.pngData()!)
    }
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
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= 10 * 1024 * 1024 else { throw ImageError.invalid }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 10 * 1024 * 1024 { throw ImageError.invalid }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Double,
                  let height = props[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 80_000_000,
                  let image = CanvasImageWorker.decode(data: data, tier: 2048) else { throw ImageError.invalid }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw ImageError.invalid }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ImageError.invalid }
            return Artwork(data: output as Data, aspect: Double(image.width) / Double(image.height))
        }.value
    }
    enum ImageError: LocalizedError {
        case invalid
        var errorDescription: String? { "The image could not be loaded. The saved link is still available." }
    }
}
