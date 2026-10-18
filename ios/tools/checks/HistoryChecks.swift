import UIKit

@main struct HistoryChecks {
    @MainActor static func main() {
        let session = CanvasFixtures.session().0
        let id = session.document.order[0]
        session.select(id)
        let original = session.document
        session.nudge(x: 30, y: 10)
        let moved = session.document
        precondition(session.history.canUndo)
        session.resize(1.1)
        session.undo()
        precondition(session.document == moved)
        session.undo()
        precondition(session.document == original && !session.history.canUndo)
        session.redo()
        precondition(session.document == moved)
        session.nudge(x: 10, y: 0)
        precondition(!session.history.canRedo)
        let beforeDelete = session.document
        session.deletePlacement(id)
        precondition(session.document.placements[id] == nil)
        session.undo()
        precondition(session.document == beforeDelete)
        session.redo()
        precondition(session.document.placements[id] == nil)

        session.camera.zoom = 2
        session.undo()
        precondition(session.document.placements[id] != nil)
        precondition(session.camera.zoom == 2)
        session.redo()
        precondition(session.document.placements[id] == nil)

        let gestureSession = CanvasFixtures.session().0
        let interaction = CanvasInteractionController(session: gestureSession)
        let target = gestureSession.document.order[0]
        let start = gestureSession.document.placements[target]!.center.cg
        let initial = gestureSession.snapshot()
        interaction.liftImage(target, point: start)
        interaction.drag(point: CGPoint(x: start.x + 200, y: start.y + 200))
        interaction.cancel()
        precondition(!gestureSession.history.canUndo && gestureSession.snapshot() == initial)
        interaction.liftImage(target, point: start)
        interaction.drag(point: CGPoint(x: start.x + 200, y: start.y + 200))
        interaction.finish()
        let finished = gestureSession.snapshot()
        gestureSession.undo()
        precondition(gestureSession.snapshot() == initial)
        gestureSession.redo()
        precondition(gestureSession.snapshot() == finished)
        let imported = CanvasFixtures.session(laidOut: true).0
        let importedID = imported.insertImport(SharedImport(url: "https://shop.example/item"),
            artwork: .init(data: Data([1]), aspect: 1))!
        imported.updateImport(importedID, title: "Enriched", artwork: .init(data: Data([2]), aspect: 0.5))
        let productID = imported.document.placements[importedID]!.productID
        let enriched = imported.document.products[productID]!
        imported.undo()
        precondition(imported.document.placements[importedID] == nil && !imported.history.canUndo)
        precondition(imported.importedAssets.data(for: enriched.asset) == Data([2]))
        imported.redo()
        precondition(imported.document.products[productID] == enriched)
        precondition(imported.document.placements[importedID]!.height == 2 * imported.document.placements[importedID]!.width)
        imported.undo()
        imported.select(imported.document.order[0])
        imported.nudge(x: 5, y: 0)
        // The Product's files stay cached: undo history no longer decides what is kept.
        precondition(!imported.history.canRedo && imported.importedAssets.data(for: enriched.asset) == Data([2]))

        let groupSession = CanvasFixtures.session(laidOut: true).0
        let group = groupSession.document.namedGroups!.first!
        groupSession.updateGroup(group.id, name: "New", backgroundColour: nil)
        groupSession.updateGroup(group.id, name: "New title", backgroundColour: .init(red: 1, green: 0, blue: 0))
        groupSession.undo()
        precondition(groupSession.document.namedGroups!.first { $0.id == group.id } == group)
        precondition(!groupSession.history.canUndo)
        groupSession.redo()
        precondition(groupSession.document.namedGroups!.first { $0.id == group.id }!.name == "New title")

        let noOp = CanvasFixtures.session().0
        noOp.select(noOp.document.order[0])
        noOp.nudge(x: 0, y: 0)
        precondition(!noOp.history.canUndo)
        let valid = noOp.document
        noOp.document.placements[noOp.document.order[0]]!.width = .nan
        noOp.complete(valid)
        precondition(noOp.document == valid && !noOp.history.canUndo)

        print("History checks passed: movement, resizing, deletion, branching, camera independence and gesture cancellation.")
    }
}
