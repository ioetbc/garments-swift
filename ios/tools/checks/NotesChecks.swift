import Foundation

@main struct NotesChecks {
    @MainActor static func main() throws {
        let session = CanvasSession()
        session.committedGroups = CanvasFixtures.fit(&session.document, viewport: .init(width: 390, height: 844))
        session.refresh()
        let productID = session.document.placements[session.document.order[0]]!.productID
        let groupID = session.document.namedGroups!.first!.id
        let notes = "Size M — try on first.\nCompare with the blue one. 🧥\n"

        // Older documents without notes still decode; multiline text round-trips intact.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let original = try decoder.decode(CanvasDocument.self, from: encoder.encode(session.document))
        precondition(original.products[productID]?.notes == nil)
        session.updateProductNotes(productID, notes: notes)
        session.updateGroupNotes(groupID, notes: notes)
        let restored = try decoder.decode(CanvasDocument.self, from: encoder.encode(session.document))
        precondition(restored.products[productID]?.notes == notes)
        precondition(restored.namedGroups?.first { $0.id == groupID }?.notes == notes)

        session.refresh()
        precondition(session.document.namedGroups?.first { $0.id == groupID }?.notes == notes)
        session.undo()
        precondition(session.document.namedGroups?.first { $0.id == groupID }?.notes == nil)
        session.redo()
        precondition(session.document.namedGroups?.first { $0.id == groupID }?.notes == notes)
        session.history.endCoalescing()
        session.updateProductNotes(productID, notes: "")
        precondition(session.document.products[productID]?.notes == nil)
        session.undo()
        precondition(session.document.products[productID]?.notes == notes)

        // Async import enrichment must preserve each undo snapshot's own notes.
        let importing = CanvasSession()
        let id = importing.document.placements[importing.document.order[0]]!.productID
        importing.updateProductNotes(id, notes: notes)
        let before = importing.document
        importing.document.products[id]?.title = "Enriched title"
        importing.history.enrichImport(from: before, to: importing.document)
        importing.undo()
        precondition(importing.document.products[id]?.notes == nil)
        precondition(importing.document.products[id]?.title == "Enriched title")
        importing.redo()
        precondition(importing.document.products[id]?.notes == notes)
        print("Notes checks passed")
    }
}
