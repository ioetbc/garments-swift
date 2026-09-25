import Foundation
import CoreGraphics

// Compile with CanvasGeometry, CanvasDocument, CanvasSpatialIndex, CanvasFixtures,
// CanvasSession and CanvasInteractionController; run the resulting executable.
@main struct MagneticDragChecks {
    @MainActor static func main() {
        let session = CanvasSession()
        let product = CanvasFixtures.products[0]
        let moving = StickerPlacement(id:"moving",productID:product.id,center:.init(),width:100,height:100)
        let target = StickerPlacement(id:"target",productID:product.id,center:.init(x:300),width:100,height:100)
        let document = CanvasDocument(products:[product.id:product],placements:[moving.id:moving,target.id:target],order:[moving.id,target.id])
        // Nearby stationary items must not group on load, during another drag, or on drop.
        let isolated = CanvasSession()
        var clustered = document
        let bystander = StickerPlacement(id:"bystander",productID:product.id,center:.init(x:420),width:100,height:100)
        let remoteA = StickerPlacement(id:"remote-a",productID:product.id,center:.init(x:2000),width:100,height:100)
        let remoteB = StickerPlacement(id:"remote-b",productID:product.id,center:.init(x:2120),width:100,height:100)
        for item in [bystander,remoteA,remoteB] {
            clustered.placements[item.id] = item
            clustered.order.append(item.id)
        }
        isolated.document = clustered
        isolated.refresh()
        precondition(isolated.groups.isEmpty, "Initial proximity must not create groups")
        let firstDrag = CanvasInteractionController(session:isolated)
        firstDrag.liftImage(moving.id,point:.zero)
        firstDrag.drag(point:CGPoint(x:168,y:0))
        precondition(isolated.groups.count == 1 && Set(isolated.groups[0]) == Set([moving.id,target.id]), "Only the dragged item and its target should form a new group, without nearby bystanders")
        firstDrag.cancel()
        precondition(isolated.groups.isEmpty, "Cancelling the first drag must restore the ungrouped layout")
        firstDrag.liftImage(moving.id,point:.zero)
        firstDrag.drag(point:CGPoint(x:168,y:0))
        firstDrag.finish()
        isolated.refresh()
        precondition(isolated.groups.count == 1 && Set(isolated.groups[0]) == Set([moving.id,target.id]), "Dropping and refreshing must retain only the intentional group")

        // Sweep across two adjacent items at minimum zoom, then leave both behind.
        let sweep = CanvasSession()
        sweep.camera.zoom = CanvasConfiguration.zoom.lowerBound
        sweep.document = clustered
        sweep.refresh()
        let sweepDrag = CanvasInteractionController(session:sweep)
        sweepDrag.liftImage(moving.id,point:.zero)
        for x in [260.0,500.0,500.0,1600.0] {
            sweepDrag.drag(point:CGPoint(x:x*sweep.camera.zoom,y:0))
            precondition(sweep.groups.allSatisfy { $0.contains(moving.id) && $0.count == 2 }, "A sweep must not accumulate targets or leave stationary groups behind")
        }
        sweepDrag.finish()
        precondition(sweep.groups.allSatisfy { $0.contains(moving.id) && $0.count == 2 }, "Dropping after a sweep must not commit passed-over neighbours")

        let dense = CanvasSession()
        dense.camera.zoom = CanvasConfiguration.zoom.lowerBound
        dense.document = CanvasFixtures.make(count:50)
        dense.refresh()
        let middle = dense.document.placements["seed-24"]!
        let denseDrag = CanvasInteractionController(session:dense)
        denseDrag.liftImage(middle.id,point:.zero)
        for step in 0...200 {
            denseDrag.drag(point:CGPoint(x:0,y:-Double(step)))
            precondition(dense.groups.allSatisfy { $0.contains(middle.id) && $0.count == 2 }, "Dragging through the 50-item layout must not group stationary items")
            precondition(dense.committedGroups.isEmpty, "Passing over items must not save preview membership")
        }
        denseDrag.cancel()
        precondition(dense.groups.isEmpty, "Cancelling a dense sweep must leave no groups")

        session.document = document
        session.refresh()
        let interaction = CanvasInteractionController(session:session)
        interaction.liftImage(moving.id,point:.zero)
        interaction.drag(point:CGPoint(x:125,y:0))
        let earlyGap = CanvasGeometry.distance(session.document.placements[moving.id]!.bounds,target.bounds)
        precondition(earlyGap > 24 && session.groups.count == 1, "The group border must appear before the old close-range threshold")
        interaction.drag(point:CGPoint(x:168,y:0))
        precondition(session.document.placements[moving.id]!.center.x > 168, "Nearby items should attract the dragged item")
        precondition(session.groups.count == 1, "Attraction should bring the item into grouping range")
        precondition(session.selection == moving.id && interaction.liftedIDs == [moving.id], "Grouping must retain the active item")
        precondition(session.document.placements[target.id] == target, "The neighbour must stay still")
        let attracted = session.document.placements[moving.id]!
        interaction.drag(point:CGPoint(x:168,y:0))
        precondition(session.document.placements[moving.id] == attracted, "Repeated drag events must not accumulate attraction")
        interaction.drag(point:.zero)
        precondition(session.document.placements[moving.id] == moving && session.groups.isEmpty, "Dragging away must release the group")
        interaction.drag(point:CGPoint(x:168,y:0))
        interaction.cancel()
        precondition(session.document == document, "Cancellation must restore the document")
        interaction.liftImage(moving.id,point:.zero)
        interaction.drag(point:CGPoint(x:168,y:0))
        let dropped = session.document.placements[moving.id]
        interaction.finish()
        precondition(session.document.placements[moving.id] == dropped && session.selection == moving.id, "Release must preserve position and selection")

        for zoom in [0.1,1.0,8.0] {
            // Visible pickup edges, rather than the smaller document bounds, trigger the border.
            session.camera.zoom = zoom
            session.document = document
            session.refresh()
            let lifted = CanvasGeometry.liftedBounds(moving,zoom:zoom)
            var neighbour = target
            neighbour.center = .init(x:lifted.maxX+70/zoom+neighbour.width/2,y:lifted.midY)
            session.document.placements[target.id] = neighbour
            session.refresh()
            interaction.liftImage(moving.id,point:.zero)
            interaction.drag(point:.zero)
            precondition(session.groups.count == 1 && session.selection == moving.id, "A visible 70-point gap should preview a group at every zoom")
            interaction.finish()
            precondition(session.groups.count == 1 && session.groupingPreview == nil, "Dropping must commit the preview as a lasting group")

            let rest = min(CanvasConfiguration.magneticRestGap,12/zoom)
            let reach = rest+CanvasConfiguration.magneticReach/zoom
            let a = CGRect(x:0,y:0,width:100,height:100)
            for direction in [-1.0,1.0] {
                var previous: Double?
                for step in 0...1000 {
                    let gap = reach*Double(step)/1000
                    let b = CGRect(x:direction > 0 ? 100+gap : -100-gap,y:0,width:100,height:100)
                    let offset = CanvasGeometry.magneticOffset(a,toward:b,zoom:zoom)
                    precondition(offset.valid && offset.x*direction >= 0 && offset.y == 0)
                    precondition(abs(offset.x)*zoom <= CanvasConfiguration.magneticPull+0.0001)
                    precondition(abs(offset.x) <= max(0,gap-rest)+0.0001, "Pull must not overshoot")
                    if let previous { precondition(abs(offset.x-previous)*zoom < 1, "Pull must vary smoothly") }
                    previous = offset.x
                }
            }
            precondition(CanvasGeometry.magneticOffset(a,toward:a,zoom:zoom) == WorldPoint(), "Overlap must allow free movement")
        }
        for zoom in [0.1,1.0,8.0] {
            let s = CanvasSession()
            s.camera.zoom = zoom
            var neighbour = target
            neighbour.center.x = 120
            let d = CanvasDocument(products:[product.id:product],placements:[moving.id:moving,target.id:neighbour],order:[moving.id,target.id])
            s.document = d; s.committedGroups = [[moving.id,target.id]]; s.refresh()
            let drag = CanvasInteractionController(session:s)
            drag.liftImage(moving.id,point:.zero,timestamp:0)
            drag.drag(point:CGPoint(x:-100,y:0),timestamp:1)
            precondition(-s.document.placements[moving.id]!.center.x*zoom > 65, "A 100-point slow pull must visibly expand the group by at least 65 points at every zoom")
            drag.cancel()
            drag.liftImage(moving.id,point:.zero,timestamp:0)
            drag.drag(point:CGPoint(x:-107.9*zoom,y:0))
            precondition(s.groups.count == 1, "Existing groups should stretch to double the join radius")
            let stretched = s.document.placements[moving.id]!
            precondition(stretched.center.x > -107.9 && stretched.center.x < 0, "Outward dragging should visibly stretch with resistance")
            drag.finish()
            precondition(abs(s.document.placements[moving.id]!.center.x) < 0.0001, "Slow release should return to the resting gap")
            precondition(s.groups.count == 1, "A stretched group must survive release")
            drag.liftImage(moving.id,point:.zero)
            drag.drag(point:CGPoint(x:-3000*zoom,y:0))
            precondition(s.groups.count == 1, "Slow pulling must remain tethered even far beyond the boundary")
            precondition((CanvasGeometry.distance(s.document.placements[moving.id]!.bounds,neighbour.bounds)-20)*zoom < 240, "Resistance must bound stretch in screen points")
            drag.cancel()
            precondition(s.groups.count == 1, "Cancellation restores stretched membership")
            drag.liftImage(moving.id,point:.zero,timestamp:0)
            drag.drag(point:CGPoint(x:-100*zoom,y:0),timestamp:1)
            precondition(s.groups.count == 1, "Slow movement should stretch without detaching")
            drag.drag(point:CGPoint(x:-110*zoom,y:0),timestamp:1+10*zoom/600)
            precondition(s.groups.isEmpty, "A quick pull after a slow stretch must break free using finger velocity")
            drag.cancel()
            precondition(s.groups.count == 1 && s.detachedLinks.isEmpty, "Cancelling a forced release must restore its bonds")

            s.document = d; s.committedGroups = [[moving.id,target.id]]; s.refresh()
            drag.liftImage(moving.id,point:.zero,timestamp:0)
            let movement = min(10.0,10/zoom)
            drag.drag(point:CGPoint(x:-movement*zoom,y:0),timestamp:movement*zoom/1200)
            precondition(s.groups.isEmpty, "Fast outward motion must detach at every zoom")
            drag.finish(); s.refresh()
            precondition(s.groups.isEmpty, "A detached item must not immediately rejoin on release")

            let detachedDocument = s.document
            let detachedLinks = s.detachedLinks
            precondition(!detachedLinks.isEmpty, "A short removal should exercise the nearby detached-link case")
            for id in [moving.id,target.id] {
                drag.liftImage(id,point:.zero)
                drag.drag(point:CGPoint(x:(id == moving.id ? movement : -movement)*zoom,y:0))
                precondition(s.groups.count == 1, "A new drag of either former member must allow regrouping")
                drag.cancel()
                precondition(s.document == detachedDocument && s.groups.isEmpty && s.detachedLinks == detachedLinks, "Cancelling regrouping must restore the detached state")
            }
            drag.liftImage(moving.id,point:.zero)
            drag.drag(point:CGPoint(x:movement*zoom,y:0))
            drag.finish(); s.refresh()
            precondition(s.groups.count == 1 && s.detachedLinks.isEmpty, "Re-forming the pair must persist after release")

            s.document = d; s.committedGroups = [[moving.id,target.id]]; s.detachedLinks = []; s.refresh()
            drag.liftImage(moving.id,point:.zero,timestamp:0)
            drag.drag(point:CGPoint(x:movement*zoom,y:0),timestamp:movement*zoom/1200)
            precondition(s.groups.count == 1, "Fast inward movement must stay grouped")
            drag.cancel()
            precondition(s.document == d && s.groups.count == 1 && s.detachedLinks.isEmpty)
        }
        print("Magnetic drag checks passed")
    }
}
