import Foundation

@main struct FollowCanvasChecks {
    @MainActor static func main() throws {
        let preview = CanvasSession()
        preview.updateViewport(CGSize(width: 390, height: 844))
        let previewUser = CanvasFixtures.users[0]
        preview.previewCanvas(previewUser)
        precondition(preview.visibleCanvases == [previewUser])
        precondition(preview.followedCanvases.isEmpty)
        let previewPlacements = preview.document.placements
        preview.follow(previewUser)
        precondition(preview.isFollowing(previewUser))
        precondition(preview.document.placements == previewPlacements)
        preview.undo()
        precondition(!preview.isFollowing(previewUser) && preview.visibleCanvases == [previewUser])
        preview.redo()
        precondition(preview.isFollowing(previewUser))

        let session = CanvasSession()
        session.updateViewport(CGSize(width: 390, height: 844))
        let original = session.document
        let user = CanvasFixtures.users[0]
        precondition(CanvasFixtures.matchingUsers(" @GENEVIEVE_123 ") == [user])
        precondition(CanvasFixtures.matchingUsers("@missing").isEmpty)
        session.follow(user)
        try session.document.validate()
        let copied = session.document
        let ids = copied.canvasMembers(user.username)
        precondition(ids.count == 480 && session.followedCanvases == [user])
        precondition(original.placements.allSatisfy { copied.placements[$0.key] == $0.value })
        precondition(original.products.allSatisfy { copied.products[$0.key] == $0.value })
        precondition(!copied.canvasBounds(nil).intersects(copied.canvasBounds(user.username)))
        let source = CanvasFixtures.canvas(for: user)
        let groups = source.namedGroups!
        for group in groups {
            precondition(copied.namedGroups!.contains(group))
        }
        let delta = copied.placements[ids[0]]!.center - source.placements[ids[0]]!.center
        for id in ids {
            let difference = copied.placements[id]!.center - source.placements[id]!.center
            precondition(abs(difference.x - delta.x) < 0.0001 && abs(difference.y - delta.y) < 0.0001)
        }
        session.follow(user)
        precondition(session.document == copied, "Following twice must not duplicate a canvas")
        precondition(CanvasFixtures.matchingUsers("") == CanvasFixtures.users)
        precondition(CanvasFixtures.matchingUsers("daisy") == [CanvasFixtures.users[1]])
        session.searchQuery = "lemaire"
        let searchCamera = session.camera
        for placement in copied.placements.values {
            let matches = copied.products[placement.productID]!.matchesSearch("lemaire")
            precondition(session.dimmedPlacementIDs.contains(placement.id) == !matches)
        }
        session.searchQuery = groups[0].name
        precondition(Set(groups[0].members).isDisjoint(with: session.dimmedPlacementIDs))
        precondition(!session.dimmedGroupIDs.contains(groups[0].id))
        precondition(session.camera == searchCamera, "Searching should preserve the current view")
        session.searchQuery = "@genevieve_123"
        precondition(session.dimmedPlacementIDs == Set(copied.order))
        session.searchQuery = ""
        precondition(session.dimmedPlacementIDs.isEmpty && session.dimmedGroupIDs.isEmpty)
        session.undo()
        precondition(session.document == original)
        session.redo()
        precondition(session.document == copied)

        // Picking up a child moves the parent canvas without changing its internal layout.
        let interaction = CanvasInteractionController(session: session)
        let start = session.camera.screen(copied.placements[ids[0]]!.center, viewport: session.viewport)
        interaction.liftImage(ids[0], point: start)
        precondition(interaction.retained == Set(ids))
        interaction.drag(point: CGPoint(x: start.x + 50, y: start.y + 20))
        interaction.finish()
        for group in groups { precondition(session.document.namedGroups!.contains(group)) }
        precondition(original.placements.allSatisfy { session.document.placements[$0.key] == $0.value })

        // Even a forced preview cannot merge owners.
        session.elasticLink = (original.order[0], ids[0])
        session.refresh()
        precondition(!session.groups.contains { $0.contains(ids[0]) && $0.contains(original.order[0]) })
        session.elasticLink = nil
        session.follow(CanvasFixtures.users[1])
        precondition(!session.document.canvasBounds(user.username).intersects(session.document.canvasBounds(CanvasFixtures.users[1].username)))
        session.unfollow(user)
        precondition(session.document.canvasMembers(user.username).isEmpty)
        precondition(session.followedCanvases.count == 1)
        session.undo()
        precondition(session.document.canvasMembers(user.username).count == 480)
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(session.document))
        precondition(decoded == session.document)
        print("Follow canvas checks passed: lookup, copies, grouping, isolation, movement, deduplication, undo/redo and coding")
    }
}
