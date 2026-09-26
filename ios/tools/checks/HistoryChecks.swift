import PencilKit
import UIKit

@main struct HistoryChecks {
    @MainActor static func main() {
        let session = CanvasSession()
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

        let canvas = CanvasInkView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        canvas.updateCamera()
        session.render = { canvas.updateCamera() }
        let path = PKStrokePath(controlPoints: [CGPoint(x: 30, y: 50), CGPoint(x: 70, y: 90)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        let ink = session.inkDrawing
        session.camera.zoom = 2
        canvas.updateCamera()
        session.undo()
        precondition(session.inkDrawing.strokes.isEmpty && canvas.drawing.strokes.isEmpty)
        precondition(session.camera.zoom == 2)
        session.undo()
        precondition(session.document.placements[id] != nil)
        session.redo()
        session.redo()
        precondition(session.inkDrawing == ink && canvas.drawing.strokes.count == 1)
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        session.undo()
        precondition(session.inkDrawing.strokes.isEmpty)

        let gestureSession = CanvasSession()
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
        let imported = CanvasSession()
        imported.updateViewport(CGSize(width: 390, height: 844))
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
        precondition(!imported.history.canRedo && imported.importedAssets.data(for: enriched.asset) == nil)

        let groupSession = CanvasSession()
        groupSession.updateViewport(CGSize(width: 390, height: 844))
        let group = groupSession.document.namedGroups!.first!
        groupSession.updateGroup(group.id, name: "New", backgroundColour: nil)
        groupSession.updateGroup(group.id, name: "New title", backgroundColour: .init(red: 1, green: 0, blue: 0))
        groupSession.undo()
        precondition(groupSession.document.namedGroups!.first { $0.id == group.id } == group)
        precondition(!groupSession.history.canUndo)
        groupSession.redo()
        precondition(groupSession.document.namedGroups!.first { $0.id == group.id }!.name == "New title")

        let noOp = CanvasSession()
        noOp.select(noOp.document.order[0])
        noOp.nudge(x: 0, y: 0)
        precondition(!noOp.history.canUndo)
        let valid = noOp.document
        noOp.document.order.append("invalid")
        noOp.complete(valid)
        precondition(noOp.document == valid && !noOp.history.canUndo)

        print("History checks passed: movement, resizing, deletion, branching, mixed ink/item history, camera independence and gesture cancellation.")
    }
}
