import Foundation
import PencilKit
import Observation

/// Canvas-only state. Navigation, selection and tool preferences deliberately live outside history.
struct CanvasSnapshot: Equatable {
    var document: CanvasDocument
    var groups: [[String]]
    var detachedLinks: Set<CanvasGroupLink>
    var ink: PKDrawing
}

/// All canvas edits share this timeline. Add new persistent canvas state to CanvasSnapshot.
@Observable @MainActor final class CanvasHistory {
    private struct Edit {
        var before: CanvasSnapshot
        var after: CanvasSnapshot
        var key: String?
    }
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private let limit = 100
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var referencedAssets: Set<String> {
        Set((undoStack + redoStack).flatMap { edit in
            [edit.before, edit.after].flatMap { $0.document.products.values.flatMap(\.referencedAssets) }
        })
    }

    func record(before: CanvasSnapshot, after: CanvasSnapshot, key: String? = nil) {
        guard before != after else { return }
        if let key, redoStack.isEmpty, undoStack.last?.key == key {
            undoStack[undoStack.count - 1].after = after
        } else {
            undoStack.append(Edit(before: before, after: after, key: key))
            if undoStack.count > limit { undoStack.removeFirst() }
        }
        redoStack.removeAll()
    }
    func endCoalescing() {
        if !undoStack.isEmpty { undoStack[undoStack.count - 1].key = nil }
    }
    func undo() -> CanvasSnapshot? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        endCoalescing()
        return edit.before
    }
    func redo() -> CanvasSnapshot? {
        guard var edit = redoStack.popLast() else { return nil }
        edit.key = nil
        undoStack.append(edit)
        return edit.after
    }

    /// Async import enrichment belongs to the imported item, not a new user action.
    /// Carry it into retained versions without resurrecting deleted items or changing their positions.
    func enrichImport(from before: CanvasDocument, to after: CanvasDocument) {
        func enrich(_ snapshot: inout CanvasSnapshot) {
            for (id, product) in after.products where before.products[id] != product {
                guard snapshot.document.products[id] != nil else { continue }
                snapshot.document.products[id] = product
                for (placementID, placement) in snapshot.document.placements where placement.productID == id {
                    guard let old = before.placements[placementID], let new = after.placements[placementID],
                          old.width != new.width || old.height != new.height else { continue }
                    let edge = max(placement.width, placement.height)
                    snapshot.document.placements[placementID]?.width = product.aspect >= 1 ? edge : edge * product.aspect
                    snapshot.document.placements[placementID]?.height = product.aspect >= 1 ? edge / product.aspect : edge
                }
            }
        }
        for index in undoStack.indices { enrich(&undoStack[index].before); enrich(&undoStack[index].after) }
        for index in redoStack.indices { enrich(&redoStack[index].before); enrich(&redoStack[index].after) }
    }
}
