import Foundation
import CoreGraphics

@MainActor final class CanvasInteractionController {
    enum State { case idle, cameraPan, cameraPinch, imageDrag, groupDrag, imagePinch }
    let session: CanvasSession
    private(set) var state: State = .idle {
        didSet {
            if state != .idle { session.inspectedPlacement = nil }
        }
    }
    private var original: CanvasDocument?
    private var baseline: [StickerPlacement] = []
    private var start = WorldPoint()
    private var cameraStart = CanvasCamera()
    private var pinchAnchor = WorldPoint()
    private var scaleStart = 1.0
    private var magneticTarget: String?
    private var originalGroups: [[String]] = []
    private var originalDetached: Set<CanvasGroupLink> = []
    private var dragSample: (point: CGPoint, time: TimeInterval)?
    private var releasedMembers: Set<String> = []
    private var springRest: StickerPlacement?
    var isDragging: Bool { state == .imageDrag || state == .groupDrag }
    var liftedIDs: Set<String> { isDragging ? retained : [] }
    var retained: Set<String> { Set(baseline.map(\.id)) }

    init(session:CanvasSession) { self.session = session }
    private func beginObject(state:State, point:CGPoint) {
        if original == nil {
            original = session.document
            originalGroups = session.committedGroups
            originalDetached = session.detachedLinks
        }
        self.state = state; baseline = session.selected
        magneticTarget = nil
        session.elasticLink = nil
        session.groupingPreview = nil
        start = session.camera.world(point,viewport:session.viewport)

    }
    func liftImage(_ id:String, point:CGPoint, timestamp:TimeInterval? = nil) {
        guard state == .idle, session.document.placements[id] != nil else { return }
        session.select(id)
        beginObject(state:.imageDrag,point:point)
        // A fresh drag can intentionally rejoin a former neighbour. Snapshot the
        // exclusions first so cancellation still restores the detached state.
        session.detachedLinks = session.detachedLinks.filter { $0.first != id && $0.second != id }
        dragSample = timestamp.map { (point,$0) }
        session.render?()
    }
    func liftGroup(_ ids:[String], point:CGPoint) {
        guard state == .idle else { return }
        let items = ids.compactMap { session.document.placements[$0] }
        guard items.count > 1 else { return }
        session.select(nil)
        originalGroups = session.committedGroups; originalDetached = session.detachedLinks
        original = session.document; baseline = items; state = .groupDrag
        start = session.camera.world(point,viewport:session.viewport)
        session.render?()
    }
    func beginCamera(point:CGPoint) {
        if original != nil { finish() }
        state = .cameraPan; cameraStart = session.camera; start = WorldPoint(point)
    }
    func drag(point:CGPoint, timestamp:TimeInterval? = nil) {
        switch state {
        case .cameraPan:
            session.camera.center = cameraStart.center-(WorldPoint(point)-start)*(1/cameraStart.zoom)
            session.cameraChanged()
        case .imageDrag,.groupDrag:
            let delta = session.camera.world(point,viewport:session.viewport)-start
            var items = baseline.map { p in var q = p; q.center = p.center+delta; return q }
            if state == .imageDrag, var item = items.first {
                detachIfNeeded(item, point:point, timestamp:timestamp)
                let sticky = resistedPlacement(item)
                let offset = sticky == nil ? magneticOffset(for:item) : WorldPoint()
                item = sticky ?? item
                // Ease in from pickup, even if the item already has a nearby neighbour.
                let progress = min(1,hypot(delta.x,delta.y)*session.camera.zoom/12)
                let pickup = progress*progress*(3-2*progress)
                item.center = item.center + offset*pickup
                items = [item]
                updateGroupingPreview(item)
            }
            apply(items)
        default: break
        }
    }
    // Screen-space speed stays consistent across zoom levels. Reapply the drag
    // against the moved camera even when the finger is stationary.
    func advanceEdgeScroll(point: CGPoint, duration: TimeInterval) {
        guard isDragging, duration.isFinite, duration > 0,
              point.x.isFinite, point.y.isFinite,
              session.viewport.width > 0, session.viewport.height > 0 else { return }
        func speed(_ position: Double, _ length: Double) -> Double {
            let band = min(64.0,length/2)
            let penetration: Double
            if position < band { penetration = -min(1,(band-position)/band) }
            else if position > length-band { penetration = min(1,(position-length+band)/band) }
            else { return 0 }
            return 480*penetration*abs(penetration)
        }
        let velocity = WorldPoint(x:speed(point.x,session.viewport.width),
                                  y:speed(point.y,session.viewport.height))
        guard velocity != WorldPoint() else { return }
        let center = session.camera.center + velocity*(min(duration,1.0/15.0)/session.camera.zoom)
        guard center.valid else { return }
        session.camera.center = center
        // Camera movement must not count as a fast finger pull for detachment.
        drag(point:point)
    }
    // Resist only outward separation. Sliding within the group stays direct.
    private func resistedPlacement(_ item: StickerPlacement) -> StickerPlacement? {
        springRest = nil
        session.elasticLink = nil
        guard releasedMembers.isEmpty,
              let group = originalGroups.first(where: { $0.contains(item.id) }),
              let pickup = baseline.first else { return nil }
        let neighbours = group.filter { $0 != item.id }.compactMap { session.document.placements[$0] }
        guard let target = neighbours.min(by: {
            CanvasGeometry.distance(item.bounds,$0.bounds) < CanvasGeometry.distance(item.bounds,$1.bounds)
        }) else { return nil }
        session.elasticLink = (item.id,target.id)
        let rest = min(CanvasConfiguration.detachRadius-1,
                       neighbours.map { CanvasGeometry.distance(pickup.bounds,$0.bounds) }.min() ?? 0)
        let a = item.bounds, b = target.bounds
        let gap = WorldPoint(x:b.minX > a.maxX ? b.minX-a.maxX : (b.maxX < a.minX ? b.maxX-a.minX : 0),
                             y:b.minY > a.maxY ? b.minY-a.maxY : (b.maxY < a.minY ? b.maxY-a.minY : 0))
        let distance = hypot(gap.x,gap.y)
        guard distance > rest else { return item }
        // An asymptotic rubber band: more pulling produces progressively less movement.
        // Keep stretch independent of the normal membership radius and canvas zoom.
        let limit = 240/session.camera.zoom
        let pull = (distance-rest)*0.95
        let stretch = limit*pull/(limit+pull)
        var result = item
        result.center = item.center + gap*((distance-rest-stretch)/distance)
        var returned = item
        returned.center = item.center + gap*((distance-rest)/distance)
        springRest = returned
        return result
    }
    private func detachIfNeeded(_ item: StickerPlacement, point: CGPoint, timestamp: TimeInterval?) {
        guard let timestamp else { return }
        defer { dragSample = (point,timestamp) }
        guard let last = dragSample, timestamp > last.time, timestamp-last.time <= 0.15,
              var old = baseline.first,
              let group = session.groups.first(where: { $0.contains(item.id) }) else { return }
        old.center = old.center + session.camera.world(last.point,viewport:session.viewport)-start
        let neighbours = group.filter { $0 != item.id }.compactMap { session.document.placements[$0] }
        let oldGap = neighbours.map { CanvasGeometry.distance(old.bounds,$0.bounds) }.min() ?? 0
        let newGap = neighbours.map { CanvasGeometry.distance(item.bounds,$0.bounds) }.min() ?? 0
        // Measure increasing edge separation, so sideways/inward motion cannot break a bond.
        let outwardSpeed = (newGap-oldGap)*session.camera.zoom/(timestamp-last.time)
        let fingerSpeed = hypot(point.x-last.point.x,point.y-last.point.y)/(timestamp-last.time)
        guard min(outwardSpeed,fingerSpeed) >= CanvasConfiguration.detachSpeed else { return }
        releasedMembers.formUnion(neighbours.map(\.id))
        for neighbour in neighbours { session.detachedLinks.insert(CanvasGroupLink(item.id,neighbour.id)) }
        magneticTarget = nil
        session.groupingPreview = nil
    }
    private func canAttract(_ moving: String, _ target: String) -> Bool {
        !releasedMembers.contains(target) && !session.detachedLinks.contains(CanvasGroupLink(moving,target))
    }
    private func updateGroupingPreview(_ item: StickerPlacement) {
        let visible = CanvasGeometry.liftedBounds(item,zoom:session.camera.zoom)
        let radius = CanvasConfiguration.groupingPreviewRadius/session.camera.zoom
        let candidates = session.index.query(visible.insetBy(dx:-radius,dy:-radius)).subtracting(retained)
            .sorted().compactMap { session.document.placements[$0] }
            .filter { target in
                let existing = originalGroups.contains { $0.contains(item.id) && $0.contains(target.id) }
                return canAttract(item.id,target.id) && CanvasGeometry.distance(visible,target.bounds) <= radius
                    && (!existing || CanvasGeometry.distance(item.bounds,target.bounds) <= CanvasConfiguration.detachRadius)
            }
        let target = candidates.min { CanvasGeometry.distance(visible,$0.bounds) < CanvasGeometry.distance(visible,$1.bounds) }
        session.groupingPreview = target.map { (moving:item.id,target:$0.id) }
    }
    private func magneticOffset(for item:StickerPlacement) -> WorldPoint {
        let zoom = session.camera.zoom
        let reach = min(CanvasConfiguration.magneticRestGap,12/zoom) + CanvasConfiguration.magneticReach/zoom
        // Keep the same neighbour until we leave its field, avoiding competing pulls.
        if let id = magneticTarget, canAttract(item.id,id),
           let target = session.document.placements[id],
           CanvasGeometry.distance(item.bounds,target.bounds) < reach {
            return CanvasGeometry.magneticOffset(item.bounds,toward:target.bounds,zoom:zoom)
        }
        magneticTarget = session.index.query(item.bounds.insetBy(dx:-reach,dy:-reach))
            .subtracting(retained).filter { canAttract(item.id,$0) }.sorted().min { a,b in
                CanvasGeometry.distance(item.bounds,session.index.bounds[a]!) <
                    CanvasGeometry.distance(item.bounds,session.index.bounds[b]!)
            }
        guard let id = magneticTarget, let target = session.document.placements[id] else { return WorldPoint() }
        return CanvasGeometry.magneticOffset(item.bounds,toward:target.bounds,zoom:zoom)
    }
    // Decide from the touches, never from a previously selected image.
    // Both fingers must be inside one image, with at least one on opaque pixels.
    func pinchTarget(_ points:[CGPoint], hit:(CGPoint)->String?) -> String? {
        guard points.count == 2 else { return nil }
        let hits = Set(points.compactMap(hit))
        let world = points.map { session.camera.world($0,viewport:session.viewport) }
        return session.document.order.reversed().first { id in
            guard hits.contains(id), let p = session.document.placements[id] else { return false }
            return world.allSatisfy { p.bounds.contains($0.cg) }
        }
    }
    func prepareSecondFinger(target:String?, midpoint:CGPoint) {
        if let target {
            if original != nil, state == .groupDrag || session.selection != target { finish() }
            session.select(target); beginObject(state:.imagePinch,point:midpoint)
        } else { beginCamera(point:midpoint) }
        session.render?()
    }
    func pinchStart(midpoint:CGPoint, recognizerScale:Double, target:String?) {
        if let target {
            session.select(target); beginObject(state:.imagePinch,point:midpoint)
        } else {
            if original != nil { finish() }
            state = .cameraPinch; cameraStart = session.camera
        }
        pinchAnchor = session.camera.world(midpoint,viewport:session.viewport)
        scaleStart = recognizerScale
    }
    func pinch(midpoint:CGPoint, scale:Double) {
        let factor = scale/scaleStart
        if state == .cameraPinch {
            session.camera.pinch(anchor:pinchAnchor,midpoint:midpoint,zoom:cameraStart.zoom*factor,viewport:session.viewport)
            session.cameraChanged()
        } else if state == .imagePinch {
            apply(CanvasGeometry.scaled(baseline,anchor:pinchAnchor,destination:session.camera.world(midpoint,viewport:session.viewport),scale:factor))
        }
    }
    private func apply(_ items:[StickerPlacement]) {
        guard items.allSatisfy(\.valid) else { return }
        for p in items { session.document.placements[p.id] = p; session.index.update(p) }
        session.refresh(rebuild:false)
    }
    func finish() {
        let returning = state == .imageDrag ? springRest : nil
        if let returning {
            session.document.placements[returning.id] = returning
            session.groupingPreview = nil
        }
        if state == .imageDrag, let preview = session.groupingPreview,
           var item = session.document.placements[preview.moving],
           let target = session.document.placements[preview.target] {
            // Commit the preview as a real proximity group when the lifted image shrinks.
            let a = item.bounds, b = target.bounds
            let gap = WorldPoint(x:b.minX > a.maxX ? b.minX-a.maxX : (b.maxX < a.minX ? b.maxX-a.minX : 0),
                                 y:b.minY > a.maxY ? b.minY-a.maxY : (b.maxY < a.minY ? b.maxY-a.minY : 0))
            let distance = hypot(gap.x,gap.y)
            let existing = originalGroups.contains { $0.contains(item.id) && $0.contains(target.id) }
            if !existing && distance > CanvasConfiguration.joinRadius {
                item.center = item.center + gap*((distance-CanvasConfiguration.joinRadius+1)/distance)
                session.document.placements[item.id] = item
            }
            // Only the target under the item at release becomes lasting membership.
            session.committedGroups = session.groups
        }
        let before = original
        clear()
        if let before { session.complete(before) }
        else { session.render?() }
    }
    func cancel() {
        if let original {
            session.document = original
            session.committedGroups = originalGroups
            session.detachedLinks = originalDetached
        }
        else if state == .cameraPan || state == .cameraPinch { session.camera = cameraStart }
        clear(); session.refresh()
    }
    private func clear() { session.elasticLink = nil; springRest = nil; dragSample = nil; releasedMembers = []; originalGroups = []; originalDetached = []; original = nil; baseline = []; magneticTarget = nil; session.groupingPreview = nil; state = .idle }
}
