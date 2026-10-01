import UIKit

@main struct CanvasVisibilityChecks {
    @MainActor static func main() {
        let session = CanvasSession()
        session.updateViewport(CGSize(width: 390, height: 844))
        let renderer = CanvasRenderer()
        let overlay = CanvasOverlayView(frame: CGRect(origin: .zero, size: session.viewport))
        overlay.session = session
        overlay.displayedGroupBounds = { renderer.displayedGroupBounds($0, session: session) }
        func render(retained: Set<String> = [], lifted: Set<String> = []) {
            renderer.reconcile(session: session, retained: retained, liftedIDs: lifted)
            // Inspect settled animation destinations deterministically.
            for layer in renderer.world.sublayers ?? [] { layer.removeAllAnimations() }
            overlay.updateTitles()
        }
        render()
        precondition(overlay.canvasHeaders.isEmpty)
        let user = CanvasFixtures.users[0]
        session.follow(user)
        let group = CanvasNamedGroup(members: session.document.canvasMembers(user.username), name: "")
        session.camera.zoom = 1
        render()
        let backgrounds = (renderer.world.sublayers ?? []).filter { $0.zPosition == -2 }
        precondition(!backgrounds.isEmpty)
        let backgroundSizes = backgrounds.map(\.bounds.size)
        for zoom in [0.02, 0.1, 1.0, 4.0] {
            session.camera.zoom = zoom
            render()
            // Zoom only changes the shared world transform, never the backgrounds’
            // underlying size, so their padding shrinks with the product artwork.
            for (layer, size) in zip(backgrounds, backgroundSizes) {
                precondition(layer.bounds.size == size,
                             "Group backgrounds must scale proportionally with products")
            }
            precondition(abs(renderer.world.affineTransform().a - zoom) < 0.001)
            precondition(overlay.canvasHeaders.count == 2)
            let content = renderer.displayedGroupBounds(group, session: session)
            let header = overlay.canvasHeaders.first { !$0.isOwn }!
            precondition(abs(content.minY - header.label.maxY - 6) < 0.001,
                         "Canvas label gap must stay constant at every zoom")
            precondition(abs(header.label.minX - content.minX - 8) < 0.001)
        }
        session.camera.zoom = 0.02
        render()
        let header = overlay.canvasHeaders.first { !$0.isOwn }!
        let pickup = CGPoint(x: header.label.midX, y: header.label.midY)
        precondition(overlay.canvasLabel(at: pickup) == user)
        let interaction = CanvasInteractionController(session: session)
        interaction.liftGroup(group.members, point: pickup)
        render(retained: interaction.retained, lifted: interaction.liftedIDs)
        let lifted = overlay.canvasHeaders.first { !$0.isOwn }!.boundary
        precondition(lifted.width > header.boundary.width)
        precondition(lifted.contains(renderer.displayedGroupBounds(group, session: session)))
        interaction.drag(point: CGPoint(x: pickup.x + 60, y: pickup.y + 30))
        render(retained: interaction.retained, lifted: interaction.liftedIDs)
        let moved = overlay.canvasHeaders.first { !$0.isOwn }!.boundary
        precondition(abs(moved.minX - lifted.minX - 60) < 0.001)
        precondition(abs(moved.minY - lifted.minY - 30) < 0.001)
        // Product layer positions can lag a drag frame or be recycled. The shared
        // canvas anchor must still match the current document and camera.
        for layer in renderer.layers.values { layer.position.x -= 500 }
        overlay.updateTitles()
        precondition(overlay.canvasHeaders.first { !$0.isOwn }!.boundary == moved)
        renderer.reconcile(session: session, retained: [], liftedIDs: interaction.liftedIDs)
        overlay.updateTitles()
        precondition(overlay.canvasHeaders.first { !$0.isOwn }!.boundary == moved)
        interaction.finish()
        render()
        precondition(overlay.canvasHeaders.first { !$0.isOwn }!.boundary.width < moved.width)
        let document = session.document
        let camera = session.camera
        session.toggleOtherCanvases()
        render()
        precondition(overlay.canvasHeaders.isEmpty)
        precondition(session.isFollowing(user))
        precondition(session.document == document)
        precondition(renderer.layers.keys.allSatisfy { session.document.placements[$0]?.canvasUsername == nil })
        precondition(overlay.titles.allSatisfy { session.isVisible($0.group) })
        precondition(!session.isVisible(group))
        session.toggleOtherCanvases()
        render()
        precondition(overlay.canvasHeaders.count == 2)
        precondition(session.camera == camera && session.document == document)
        session.toggleOtherCanvases()
        session.previewCanvas(user)
        precondition(session.showOtherCanvases && session.visibleCanvases.count == 1)
        session.unfollow(user)
        render()
        precondition(overlay.canvasHeaders.isEmpty)
        print("Canvas visibility checks passed: conditional labels, constant zoom spacing, animated lift/drag/release, hiding, restoration and search reveal")
    }
}
