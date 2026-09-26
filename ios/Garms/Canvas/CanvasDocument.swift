import Foundation
import CoreGraphics

nonisolated struct SampleProduct: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var category: String
    var asset: String
    var aspect: Double
    var product_url: String

    // Sample pricing until saved listing prices are available.
    var price: Decimal { 250 }

    // Bundled titles include the brand, colour and product name.
    func matchesSearch(_ query: String) -> Bool {
        CanvasSearch.matches(title, query: query)
    }
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
    var bounds: CGRect { CGRect(x: center.x-width/2, y: center.y-height/2, width: width, height: height) }
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

    static let placeholderNames = [
        "To buy summer", "Things to buy soon", "Etsy ending soon", "Waiting for a sale",
        "Holiday wishlist", "Everyday basics", "Winter layers", "Shoes to consider",
        "For the weekend", "Work outfit ideas", "Secondhand finds", "Saved for payday"
    ]
}

// Membership is derived from positions; titles follow the largest surviving overlap.
nonisolated struct CanvasDocument: Codable, Equatable, Sendable {
    var namedGroups: [CanvasNamedGroup]? = nil
    var schemaVersion = 1
    var products: [String: SampleProduct] = [:]
    var placements: [String: StickerPlacement] = [:]
    var order: [String] = []
    func validate() throws {
        guard schemaVersion == 1, Set(order).count == order.count, Set(order) == Set(placements.keys),
              products.allSatisfy({ $0.key == $0.value.id && $0.value.aspect.isFinite && $0.value.aspect > 0 }),
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

extension CanvasDocument {
    func sum(for group: CanvasNamedGroup) -> Decimal {
        let productIDs = Set(group.members.compactMap { placements[$0]?.productID })
        return productIDs.reduce(Decimal.zero) { total, id in
            total + (products[id]?.price ?? .zero)
        }
    }

    mutating func reconcileGroupNames(_ groups: [[String]]) {
        let previous = namedGroups ?? []
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
                group.members = groups[index]
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
    }
}
