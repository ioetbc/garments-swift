import Foundation

@main struct SearchChecks {
    @MainActor static func main() {
        let products = CanvasFixtures.products
        func matches(_ query: String) -> [SampleProduct] {
            products.filter { $0.matchesSearch(query) }
        }
        precondition(matches("").count == products.count)
        precondition(matches(" \n ").count == products.count)
        precondition(matches("LEMAIRE").count == 3)
        precondition(matches("blue").count == 3)
        precondition(matches("beige lemaire").map(\.id) == ["lemaire-beige-loose-silk-shirt"])
        precondition(matches("  black   heels  ").count == 2)
        precondition(matches("shushu tong white").count == 1)
        precondition(matches("t-shirt").count == 2)
        precondition(matches("grey").map(\.id) == matches("gray").map(\.id))
        precondition(matches("carré").count == 1)
        precondition(matches("lemaire blue").isEmpty)
        precondition(matches("nonexistent").isEmpty)
        let session = CanvasSession()
        session.updateViewport(CGSize(width: 390, height: 844))
        let group = session.document.namedGroups!.first!
        session.updateGroup(group.id, name: "Summer café picks", backgroundColour: .init(red: 0.84, green: 0.92, blue: 0.83))
        session.searchQuery = "CAFE summer"
        precondition(session.dimmedPlacementIDs == Set(session.document.order).subtracting(group.members))
        precondition(!session.dimmedGroupIDs.contains(group.id))
        // Identical products elsewhere must not match solely because this group does.
        let productID = session.document.placements[group.members[0]]!.productID
        let duplicate = session.document.placements.values.first {
            $0.productID == productID && !group.members.contains($0.id)
        }!
        precondition(session.dimmedPlacementIDs.contains(duplicate.id))
        session.updateGroup(group.id, name: "Alpine picks", backgroundColour: .init(red: 0.84, green: 0.92, blue: 0.83))
        precondition(session.dimmedPlacementIDs == Set(session.document.order))
        session.searchQuery = "alpine"
        precondition(session.dimmedPlacementIDs == Set(session.document.order).subtracting(group.members))
        session.searchQuery = "lemaire"
        for placement in session.document.placements.values {
            let matches = session.document.products[placement.productID]!.matchesSearch("lemaire")
            precondition(session.dimmedPlacementIDs.contains(placement.id) == !matches)
        }
        session.searchQuery = "alpine"
        let detachedID = group.members[0]
        session.document.placements[detachedID]!.center = .init(x: 10000, y: 10000)
        session.refresh()
        precondition(session.dimmedPlacementIDs.contains(detachedID))
        session.searchQuery = " \n "
        precondition(session.dimmedPlacementIDs.isEmpty && session.dimmedGroupIDs.isEmpty)
        let liveColour = CanvasGroupColour(red: 0.123, green: 0.456, blue: 0.789)
        session.updateGroup(group.id, name: " ", backgroundColour: liveColour)
        let updated = session.document.namedGroups!.first { $0.id == group.id }!
        precondition(updated.name == "Alpine picks")
        precondition(updated.backgroundColour == liveColour)
        session.updateGroup(group.id, name: updated.name, backgroundColour: nil)
        precondition(session.document.namedGroups!.first { $0.id == group.id }!.backgroundColour == nil)
        print("Search and live editing checks passed: products, group titles, duplicate placements, renaming and membership changes")
    }
}
