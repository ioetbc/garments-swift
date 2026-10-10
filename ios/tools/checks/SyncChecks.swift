import Foundation

@main struct SyncChecks {
    @MainActor static func main() {
        // A nudge saves exactly that Sticker; undo saves the inverse.
        do {
            let (session, sync) = CanvasFixtures.session(laidOut: true)
            let id = session.document.order[0]
            let original = session.document.placements[id]!
            session.select(id)
            session.nudge(x: 30, y: 10)
            precondition(sync.applied.count == 1)
            let moved = sync.applied[0]
            precondition(moved.stickers.map(\.key) == [id] && moved.stickers[0].x == original.center.x + 30)
            precondition(moved.products.isEmpty && moved.groups.isEmpty && moved.deletedStickers.isEmpty)
            session.undo()
            precondition(sync.applied.count == 2 && sync.applied[1].stickers == [CanvasRemote.Sticker(original)])
        }

        // A snapshot from another device waits for the gesture under the finger to finish.
        do {
            let (session, sync) = CanvasFixtures.session(laidOut: true)
            let interaction = CanvasInteractionController(session: session)
            let target = session.document.order[0]
            let other = session.document.order[1]
            let start = session.camera.screen(session.document.placements[target]!.center, viewport: session.viewport)
            interaction.liftImage(target, point: start)
            interaction.drag(point: CGPoint(x: start.x + 40, y: start.y + 300))
            var remote = sync.remote
            let index = remote.stickers.firstIndex { $0.key == other }!
            let before = remote.stickers[index].x
            remote.stickers[index].x += 500
            sync.push(remote)
            precondition(session.document.placements[other]!.center.x == before, "applied mid-gesture")
            interaction.finish()
            precondition(session.document.placements[other]!.center.x == remote.stickers[index].x, "not applied after the gesture")
        }

        // A snapshot that predates this device's in-flight save is held until the save lands.
        do {
            let (session, sync) = CanvasFixtures.session(laidOut: true)
            let id = session.document.order[0]
            session.select(id)
            sync.holdWrites = true
            session.nudge(x: 30, y: 0)
            let nudged = session.document.placements[id]!
            sync.push(sync.remote)
            precondition(session.document.placements[id] == nudged)
            var saved = sync.remote
            saved.stickers[saved.stickers.firstIndex { $0.key == id }!] = .init(nudged)
            sync.push(saved)
            sync.completeWrites()
            precondition(session.document.placements[id] == nudged)
        }

        // Offline, the Canvas is read-only and says why.
        do {
            let (session, sync) = CanvasFixtures.session(laidOut: true)
            let id = session.document.order[0]
            session.select(id)
            session.nudge(x: 30, y: 0)
            sync.setOnline(false)
            let document = session.document
            session.nudge(x: 30, y: 0)
            session.undo()
            session.updateProductNotes(session.document.placements[id]!.productID, notes: "Offline note")
            session.deleteProduct(session.document.placements[id]!.productID)
            precondition(session.document == document && sync.applied.count == 1 && sync.deletedProducts.isEmpty)
            precondition(session.error == CanvasSession.offlineMessage)
            let interaction = CanvasInteractionController(session: session)
            interaction.liftImage(id, point: .zero)
            precondition(!interaction.isDragging)
        }

        // Removing a Sticker keeps its Product; Delete product removes every Sticker of it.
        do {
            let (session, sync) = CanvasFixtures.session(count: 20, laidOut: true)
            let productID = CanvasFixtures.products[0].id
            let stickers = session.document.placements.values.filter { $0.productID == productID }.map(\.id)
            precondition(stickers.count == 2)
            for id in stickers { session.deletePlacement(id) }
            precondition(session.document.products[productID] != nil)
            precondition(sync.applied.allSatisfy { $0.deletedProducts.isEmpty })
            precondition(session.document.products[productID]!.matchesSearch("jacquemus"))
            let placed = session.placeSticker(of: productID)!
            precondition(session.document.namedGroups!.first(where: \.isRecentUploads)!.members == [placed])
            session.placeSticker(of: productID)

            session.deleteProduct(productID)
            precondition(sync.deletedProducts == [productID] && session.document.products[productID] == nil)
            precondition(!session.document.placements.values.contains { $0.productID == productID })
            precondition(session.document.namedGroups!.allSatisfy { $0.members.allSatisfy { session.document.placements[$0] != nil } })
            precondition(!session.history.canUndo)
        }

        // Bringing a Sticker to the front rewrites only its own stacking key.
        do {
            let (session, sync) = CanvasFixtures.session(laidOut: true)
            let bottom = session.document.order[0]
            session.bringToFront(bottom)
            precondition(session.document.order.last == bottom)
            precondition(sync.applied.count == 1 && sync.applied[0].stickers.map(\.key) == [bottom])
            precondition(CanvasStacking.after("0099") == "009A" && CanvasStacking.after("z") == "z1" && "z" < CanvasStacking.after("z"))
        }

        // Panning saves the Viewport, never an edit or an undo step.
        do {
            let (session, sync) = CanvasFixtures.session(laidOut: true)
            session.camera.center = session.camera.center + WorldPoint(x: 400, y: 0)
            session.cameraChanged()
            precondition(sync.applied.isEmpty && !session.history.canUndo)
        }

        // A stored Canvas round-trips into an equal document, Groups and detached links included.
        do {
            let (session, _) = CanvasFixtures.session(laidOut: true)
            let members = session.document.namedGroups!.first { !$0.isRecentUploads }!.members
            session.detachedLinks = [CanvasGroupLink(members[0], members[1])]
            let stored = CanvasRemote(document: session.document, detachedLinks: session.detachedLinks)
            let decoded = try! JSONDecoder().decode(CanvasRemote.self, from: JSONEncoder().encode(stored))
            precondition(decoded.document == session.document && decoded.links == session.detachedLinks)
            let changes = CanvasChangeSet(from: CanvasDocument(), [], to: decoded.document, decoded.links)
            precondition(changes.stickers.count == session.document.placements.count && changes.links.count == 1)

            // Loading, grouping and naming leave a stored Canvas exactly as it was.
            let (reopened, reopenedSync) = CanvasFixtures.session(laidOut: true)
            precondition(reopened.document == reopenedSync.remote.document)
        }

        // Totals never add different currencies and admit unpriced items; search matches Category.
        do {
            var document = CanvasFixtures.make(count: 3)
            let ids = document.order
            let group = CanvasNamedGroup(members: ids, name: "Mixed")
            document.products[document.placements[ids[1]]!.productID]!.price = Price(amount: 1999, currency: "EUR")
            document.products[document.placements[ids[2]]!.productID]!.price = nil
            let totals = document.totals(for: group)
            precondition(totals.byCurrency == ["GBP": 250, "EUR": Decimal(string: "19.99")!] && totals.hasUnpriced)
            precondition(Price(major: Decimal(string: "19.99")!, currency: "EUR").amount == 1999)
            precondition(Price(major: 5000, currency: "JPY").amount == 5000)
            var coat = CanvasFixtures.products[0]
            coat.category = "Overshirt"
            precondition(coat.matchesSearch("overshirt") && !CanvasFixtures.products[0].matchesSearch("overshirt"))
        }

        print("Sync checks passed: change sets, undo, gestures, in-flight saves, offline, deletion, stacking, viewport, round trip, totals and search")
    }
}
