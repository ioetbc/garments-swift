import UIKit
import ImageIO

/// Product images by file key: uploaded once, cached on disk, downloaded when another device added them.
@MainActor final class ImportedAssetLibrary {
    private let sync: CanvasSync
    private let directory = URL.cachesDirectory.appending(path: "GarmsFiles", directoryHint: .isDirectory)
    /// Download URLs for files this device has not cached, from the latest snapshot.
    var urls: [String: URL] = [:] { didSet { if urls != oldValue { urlsChanged?() } } }
    var urlsChanged: (() -> Void)?
    var failure: ((String) -> Void)?

    init(sync: CanvasSync) {
        self.sync = sync
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func file(_ key: String) -> URL? {
        guard !key.isEmpty, !key.contains("/"), !key.contains("..") else { return nil }
        return directory.appending(path: key)
    }
    /// Cached bytes, without touching the network.
    func data(for key: String) -> Data? { file(key).flatMap { try? Data(contentsOf: $0) } }
    /// Cached bytes, or downloaded and cached.
    func load(_ key: String) async -> Data? {
        if let data = data(for: key) { return data }
        guard let url = urls[key], let destination = file(key),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? data.write(to: destination, options: .atomic)
        return data
    }
    /// Caches new image bytes under a fresh key and uploads them; Products can reference the key immediately.
    func insert(_ data: Data) -> String {
        let key = "import-" + UUID().uuidString
        if let destination = file(key) { try? data.write(to: destination, options: .atomic) }
        sync.upload(data, key: key) { [weak self] error in
            if let error { self?.failure?("An image couldn't be saved to your account, so other devices won't show it. \(error.localizedDescription)") }
        }
        return key
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
        return try await prepare(data)
    }
    static func prepare(_ data: Data) async throws -> Artwork {
        try Task.checkCancellation()
        return try await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Double,
                  let height = props[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 80_000_000,
                  let image = CanvasImageWorker.decode(data: data, tier: 2048) else { throw ImageError.detail("Image decoding failed or dimensions exceed 20,000 pixels / 80 megapixels.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw ImageError.detail("Could not encode the image as PNG.") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ImageError.detail("Could not encode the image as PNG.") }
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
