import Foundation
import CoreGraphics

@main struct InitialLayoutChecks {
    @MainActor static func main() throws {
        for viewport in [CGSize(width:390,height:844), CGSize(width:844,height:390), CGSize(width:1024,height:1366)] {
            for count in 0...105 {
                var document = CanvasFixtures.make(count:count)
                let originalOrder = document.order
                let groups = CanvasFixtures.fit(&document,viewport:viewport)
                try document.validate()
                precondition(document.order == originalOrder)
                if count >= 3 {
                    precondition(groups.allSatisfy { (3...5).contains($0.count) })
                    precondition(Set(groups.flatMap { $0 }) == Set(document.order))
                }
                let index = CanvasSpatialIndex()
                index.rebuild(document)
                let retained = CanvasProximity.groups(document:document,index:index,previous:groups)
                precondition(Set(retained.map { Set($0) }) == Set(groups.map { Set($0) }), "Seeded groups must survive refresh")
                for item in document.placements.values {
                    precondition(abs(max(item.width, item.height) - CanvasConfiguration.initialImageEdge) < 0.0001, "Fixtures must match the initial import size")
                    let product = document.products[item.productID]!
                    precondition(abs(item.width/item.height-product.aspect) < 0.0001)
                    for other in document.placements.values where other.id != item.id {
                        precondition(!item.bounds.intersects(other.bounds), "Initial items must not overlap")
                    }
                }
                let bounds = groups.map { ids in CanvasGeometry.union(ids.compactMap { document.placements[$0] }) }
                for a in bounds.indices {
                    for b in bounds.indices where a < b {
                        precondition(CanvasGeometry.distance(bounds[a],bounds[b]) > 8, "Clusters need visible breathing room")
                    }
                }
                var repeated = CanvasFixtures.make(count:count)
                CanvasFixtures.fit(&repeated,viewport:viewport)
                precondition(repeated == document, "The initial arrangement must be repeatable")
            }
            let session = CanvasSession()
            session.updateViewport(viewport)
            precondition(session.groups.count > 1 && session.groups.allSatisfy { (3...5).contains($0.count) })
            let arranged = session.document
            session.updateViewport(CGSize(width:viewport.height,height:viewport.width))
            precondition(session.document == arranged, "Viewport changes must not rearrange an existing canvas")
        }
        print("Initial layout checks passed")
    }
}
