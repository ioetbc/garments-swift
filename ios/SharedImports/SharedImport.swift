import Foundation

nonisolated struct SharedImport: Codable, Sendable, Identifiable {
    var schemaVersion = 1
    var id = UUID()
    var url: String
    var suggestedTitle: String?
    var createdAt = Date()
}

nonisolated enum SharedLink {
    static let appGroup = "group.f.garment-swift-2.imports"
    static func normalized(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 4096, let url = URLComponents(string: value),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let range = value.range(of: "://") else { throw LinkError.invalid }
        // Change only scheme and host casing; retain escaped path, query and fragment verbatim.
        let rest = value[range.upperBound...]
        let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        return scheme.lowercased() + "://" + rest[..<end].lowercased() + rest[end...]
    }
    static func extract(urls: [String], texts: [String]) throws -> String {
        var candidates = urls
        if candidates.isEmpty {
            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            candidates = texts.flatMap { text in
                detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    Range(match.range, in: text).map { String(text[$0]) }
                }
            }
        }
        let normalized = try candidates.map(normalized)
        guard Set(normalized).count == 1, let first = candidates.first else { throw LinkError.ambiguous }
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    enum LinkError: LocalizedError {
        case invalid, ambiguous, container
        var errorDescription: String? {
            switch self {
            case .invalid: "Share a valid HTTP(S) link without credentials (up to 4,096 characters)."
            case .ambiguous: "Share exactly one unique web link."
            case .container: "The shared inbox is unavailable. Check App Group signing and try again."
            }
        }
    }
}
