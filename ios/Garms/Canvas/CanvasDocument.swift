import Foundation
import CoreGraphics

nonisolated struct Product: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var category: String? = nil
    /// File key of the Cutout.
    var cutout: String
    var aspect: Double
    var sourceUrl: String
    var notes: String? = nil
    var original: String? = nil
    var photos: [String] = []
    var price: Price? = nil
    // Field names on the wire, so the document's rows are also the change set's rows.
    enum CodingKeys: String, CodingKey {
        case id = "key", title, category, cutout, aspect, sourceUrl, notes, original, photos, price
    }
    var detailAssets: [String] {
        var seen: Set<String> = []
        return ([cutout, original].compactMap { $0 } + photos).filter { seen.insert($0).inserted }
    }

    func matchesSearch(_ query: String) -> Bool {
        CanvasSearch.matches(title + " " + (category ?? ""), query: query)
    }
}

/// A snapshot of what the listing cost, in integer minor units.
nonisolated struct Price: Codable, Equatable, Sendable {
    var amount: Int
    var currency: String
    init(amount: Int, currency: String) { self.amount = amount; self.currency = currency }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Convex numbers are doubles; accept 25000.0 as 25000.
        let amount = try c.decode(Double.self, forKey: .amount)
        guard let exact = Int(exactly: amount) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: c, debugDescription: "Price is not whole minor units.")
        }
        self.amount = exact
        currency = try c.decode(String.self, forKey: .currency)
    }
    private static func digits(_ currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.maximumFractionDigits
    }
    init(major: Decimal, currency: String) {
        var scaled = major * pow(10, Self.digits(currency)), rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        self.init(amount: NSDecimalNumber(decimal: rounded).intValue, currency: currency)
    }
    var major: Decimal { Decimal(amount) / pow(10, Self.digits(currency)) }
    var formatted: String { major.formatted(.currency(code: currency)) }
}

nonisolated enum CanvasSearch {
    static func matches(_ text: String, query: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .map { $0 == "grey" ? "gray" : $0 }
        }
        let titleWords = words(text)
        let terms = words(query)
        return terms.allSatisfy { term in
            titleWords.contains { terms.count > 1 && term.count == 1 ? $0 == term : $0.contains(term) }
        }
    }
}

nonisolated struct StickerPlacement: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var productID: String
    var center: WorldPoint
    var width: Double
    var height: Double
    /// Fractional stacking key; higher draws on top. Reordering rewrites only this Sticker.
    var z: String
    var bounds: CGRect { CGRect(x: center.x-width/2, y: center.y-height/2, width: width, height: height) }
    /// Reshapes to a new image aspect, keeping the centre and longest edge.
    mutating func fit(aspect: Double) {
        let edge = max(width, height)
        width = aspect >= 1 ? edge : edge * aspect
        height = aspect >= 1 ? edge / aspect : edge
    }
    // Stored as a flat row: key, product, x, y, width, height, z.
    enum CodingKeys: String, CodingKey { case id = "key", productID = "product", x, y, width, height, z }
    init(id: String = UUID().uuidString, productID: String, center: WorldPoint, width: Double, height: Double, z: String) {
        self.id = id; self.productID = productID; self.center = center; self.width = width; self.height = height; self.z = z
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), productID: try c.decode(String.self, forKey: .productID),
                  center: WorldPoint(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y)),
                  width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height),
                  z: try c.decode(String.self, forKey: .z))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(productID, forKey: .productID)
        try c.encode(center.x, forKey: .x); try c.encode(center.y, forKey: .y)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height); try c.encode(z, forKey: .z)
    }
    var valid: Bool {
        center.valid && width.isFinite && height.isFinite && width > 0 && height > 0 &&
        CanvasConfiguration.edge.contains(max(width,height))
    }
}

nonisolated struct CanvasGroupColour: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var rgb: (Double, Double, Double) { (red, green, blue) }
}

nonisolated struct CanvasNamedGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var members: [String]
    var name: String
    var backgroundColour: CanvasGroupColour? = nil
    var notes: String? = nil
    var isRecentUploads = false
    var emptyCenter: WorldPoint? = nil
    enum CodingKeys: String, CodingKey {
        case id = "key", members, name, backgroundColour = "colour", notes, isRecentUploads, emptyCenter
    }

    func bounds(in document: CanvasDocument) -> CGRect {
        let bounds = CanvasGeometry.union(members.compactMap { document.placements[$0] })
        guard bounds.isNull, let center = emptyCenter else { return bounds }
        return CGRect(x: center.x - 90, y: center.y - 75, width: 180, height: 150)
    }

    static let placeholderNames = [
        "To buy summer", "Things to buy soon", "Etsy ending soon", "Waiting for a sale",
        "Holiday wishlist", "Everyday basics", "Winter layers", "Shoes to consider",
        "For the weekend", "Work outfit ideas", "Secondhand finds", "Saved for payday"
    ]
}

// Membership is derived from positions; titles follow the largest surviving overlap.
nonisolated struct CanvasDocument: Codable, Equatable, Sendable {
    var namedGroups: [CanvasNamedGroup] = []
    var products: [String: Product] = [:]
    var placements: [String: StickerPlacement] = [:]
    /// Sticker ids from bottom to top.
    // ponytail: sorted on every read; cache alongside `placements` if large canvases drop frames.
    var order: [String] {
        placements.values.sorted { ($0.z, $0.id) < ($1.z, $1.id) }.map(\.id)
    }
    /// A stacking key above every Sticker on the Canvas.
    /// Membership in the form proximity grouping continues from.
    var committedGroups: [[String]] {
        namedGroups.filter { $0.members.count > 1 || $0.isRecentUploads && !$0.members.isEmpty }.map(\.members)
    }
    var topZ: String { CanvasStacking.after(placements.values.map(\.z).max()) }
    func validate() throws {
        guard products.allSatisfy({ $0.key == $0.value.id && $0.value.aspect.isFinite && $0.value.aspect > 0 }),
              placements.allSatisfy({ $0.key == $0.value.id && $0.value.valid && products[$0.value.productID] != nil })
        else { throw CanvasError.invalidDocument }
    }
}

nonisolated enum CanvasError: LocalizedError {
    case invalidDocument
    var errorDescription: String? {
        "The canvas is invalid. The change has been reverted."
    }
}

nonisolated enum CanvasStacking {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    /// A key that sorts after `key`, comparing as plain ASCII strings on every platform.
    // ponytail: only "after" exists because Stickers only move to the top; add "between" for arbitrary reordering.
    static func after(_ key: String?) -> String {
        guard var chars = key.map(Array.init), let last = chars.last, let index = digits.firstIndex(of: last) else { return "a" }
        if index + 1 < digits.count { chars[chars.count - 1] = digits[index + 1] } else { chars.append("1") }
        return String(chars)
    }
}

extension CanvasDocument {
    /// Known prices per currency, never added across currencies, and whether any member is unpriced.
    func totals(for group: CanvasNamedGroup) -> (byCurrency: [String: Decimal], hasUnpriced: Bool) {
        let productIDs = Set(group.members.compactMap { placements[$0]?.productID })
        let prices = productIDs.map { products[$0]?.price }
        var totals: [String: Decimal] = [:]
        for price in prices.compactMap({ $0 }) { totals[price.currency, default: 0] += price.major }
        return (totals, prices.contains { $0 == nil })
    }

    mutating func reconcileGroupNames(_ groups: [[String]]) {
        let previous = namedGroups
        // Match the largest overlap first so a small split cannot steal the title.
        let candidates = groups.indices.flatMap { newIndex in
            previous.indices.compactMap { oldIndex -> (new: Int, old: Int, overlap: Int)? in
                let overlap = Set(groups[newIndex]).intersection(previous[oldIndex].members).count
                return overlap > 0 ? (newIndex, oldIndex, overlap) : nil
            }
        }.sorted {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.old != $1.old { return $0.old < $1.old }
            return $0.new < $1.new
        }
        var matches: [Int: Int] = [:]
        var used: Set<Int> = []
        for candidate in candidates where matches[candidate.new] == nil && !used.contains(candidate.old) {
            matches[candidate.new] = candidate.old
            used.insert(candidate.old)
        }
        var usedNames = Set(matches.values.map { previous[$0].name })
        namedGroups = groups.indices.map { index in
            if let old = matches[index] {
                var group = previous[old]
                // Keep the stored order when membership is unchanged, so loading never rewrites a Group.
                if Set(group.members) != Set(groups[index]) { group.members = groups[index] }
                return group
            }
            let base = CanvasNamedGroup.placeholderNames.first { !usedNames.contains($0) }
                ?? CanvasNamedGroup.placeholderNames[0]
            var name = base
            var suffix = 2
            while usedNames.contains(name) { name = "\(base) \(suffix)"; suffix += 1 }
            usedNames.insert(name)
            return CanvasNamedGroup(members: groups[index], name: name)
        }
        if let recent = previous.first(where: \.isRecentUploads),
           !namedGroups.contains(where: \.isRecentUploads) {
            var empty = recent
            empty.members = []
            namedGroups.append(empty)
        }
    }

    /// Places a Sticker of `productID` at the end of Recent uploads, or at `fallback` when it is empty and unplaced.
    mutating func addToRecentUploads(productID: String, aspect: Double, fallback: WorldPoint) -> String? {
        guard let recentIndex = namedGroups.firstIndex(where: \.isRecentUploads) else { return nil }
        let recent = namedGroups[recentIndex]
        let edge = CanvasConfiguration.initialImageEdge
        var placement = StickerPlacement(productID: productID, center: WorldPoint(), width: edge, height: edge, z: topZ)
        placement.fit(aspect: aspect)
        let bounds = recent.bounds(in: self)
        let center = recent.members.isEmpty || bounds.isNull ? recent.emptyCenter ?? fallback
            : WorldPoint(x: bounds.maxX + CanvasConfiguration.magneticRestGap + placement.width / 2, y: bounds.midY)
        placement.center = center
        placements[placement.id] = placement
        namedGroups[recentIndex].members.append(placement.id)
        namedGroups[recentIndex].emptyCenter = center
        return placement.id
    }
}
