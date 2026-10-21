import Foundation
import CoreGraphics

@MainActor final class CanvasInteractionController {
    enum State { case idle, cameraPan, cameraPinch, imageDrag, groupDrag }
    let session: CanvasSession
    private(set) var state: State = .idle {
        didSet {
            if state != .idle { session.inspectedPlacement = nil }
        }
    }
    private var original: CanvasSnapshot?
    private var baseline: [StickerPlacement] = []
    private var start = WorldPoint()
    private var cameraStart = CanvasCamera()
    private var pinchAnchor = WorldPoint()
    private var scaleStart = 1.0
    private var magneticTarget: String?
    private var dragSample: (point: CGPoint, time: TimeInterval)?
    private var releasedMembers: Set<String> = []
    private var springRest: StickerPlacement?
    var isDragging: Bool { state == .imageDrag || state == .groupDrag }
    var liftedIDs: Set<String> { isDragging ? retained : [] }
    var retained: Set<String> { Set(baseline.map(\.id)) }

    init(session:CanvasSession) { self.session = session }
    private func beginObject(state:State, point:CGPoint) {
        if original == nil { original = session.snapshot() }
        self.state = state; baseline = session.selected
        magneticTarget = nil
        session.elasticLink = nil
        session.groupingPreview = nil
        start = session.camera.world(point,viewport:session.viewport)

    }
    func liftImage(_ id:String, point:CGPoint, timestamp:TimeInterval? = nil) {
        guard state == .idle, session.document.placements[id] != nil else { return }
        guard session.isOnline else { session.error = CanvasSession.offlineMessage; return }
        session.select(id)
        beginObject(state:.imageDrag,point:point)
        // A fresh drag can intentionally rejoin a former neighbour. Snapshot the
        // exclusions first so cancellation still restores the detached state.
        session.stage { $0.detachedLinks = $0.detachedLinks.filter { $0.first != id && $0.second != id } }
        dragSample = timestamp.map { (point,$0) }
        session.render?()
    }
    func liftGroup(_ ids:[String], point:CGPoint) {
        guard state == .idle else { return }
        let items = ids.compactMap { session.document.placements[$0] }
        guard items.count > 1 else { return }
        guard session.isOnline else { session.error = CanvasSession.offlineMessage; return }
        session.select(nil)
        original = session.snapshot(); baseline = items; state = .groupDrag
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
              let group = original?.document.committedGroups.first(where: { $0.contains(item.id) }),
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
        session.stage { snapshot in for neighbour in neighbours { snapshot.detachedLinks.insert(CanvasGroupLink(item.id,neighbour.id)) } }
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
                let existing = original?.document.committedGroups.contains { $0.contains(item.id) && $0.contains(target.id) } == true
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
    /// A second finger always moves the camera, ending any drag.
    func prepareSecondFinger(midpoint:CGPoint) {
        beginCamera(point:midpoint)
        session.render?()
    }
    func pinchStart(midpoint:CGPoint, recognizerScale:Double) {
        if original != nil { finish() }
        state = .cameraPinch; cameraStart = session.camera
        pinchAnchor = session.camera.world(midpoint,viewport:session.viewport)
        scaleStart = recognizerScale
    }
    func pinch(midpoint:CGPoint, scale:Double) {
        guard state == .cameraPinch else { return }
        session.camera.pinch(anchor:pinchAnchor,midpoint:midpoint,zoom:cameraStart.zoom*scale/scaleStart,viewport:session.viewport)
        session.cameraChanged()
    }
    private func apply(_ items:[StickerPlacement]) {
        guard items.allSatisfy(\.valid) else { return }
        session.stage { snapshot in for p in items { snapshot.document.placements[p.id] = p } }
        for p in items { session.index.update(p) }
        session.refresh(rebuild:false)
    }
    func finish() {
        guard let original else { clear(); session.render?(); return }
        let returning = state == .imageDrag ? springRest : nil
        // A spring-back release cancels the grouping preview.
        let preview = state == .imageDrag && returning == nil ? session.groupingPreview : nil
        let groups = session.groups
        clear()
        session.edit(from: original) { snapshot in
            if let returning { snapshot.document.placements[returning.id] = returning }
            guard let preview, var item = snapshot.document.placements[preview.moving],
                  let target = snapshot.document.placements[preview.target] else { return }
            // Commit the preview as a real proximity group when the lifted image shrinks.
            let a = item.bounds, b = target.bounds
            let gap = WorldPoint(x:b.minX > a.maxX ? b.minX-a.maxX : (b.maxX < a.minX ? b.maxX-a.minX : 0),
                                 y:b.minY > a.maxY ? b.minY-a.maxY : (b.maxY < a.minY ? b.maxY-a.minY : 0))
            let distance = hypot(gap.x,gap.y)
            let existing = original.document.committedGroups.contains { $0.contains(item.id) && $0.contains(target.id) }
            if !existing && distance > CanvasConfiguration.joinRadius {
                item.center = item.center + gap*((distance-CanvasConfiguration.joinRadius+1)/distance)
                snapshot.document.placements[item.id] = item
            }
            // Only the target under the item at release becomes lasting membership.
            snapshot.document.reconcileGroupNames(groups)
        }
    }
    func cancel() {
        if let original { session.stage { $0 = original } }
        else if state == .cameraPan || state == .cameraPinch { session.camera = cameraStart }
        clear(); session.refresh()
    }
    private func clear() { session.elasticLink = nil; springRest = nil; dragSample = nil; releasedMembers = []; original = nil; baseline = []; magneticTarget = nil; session.groupingPreview = nil; state = .idle }
}
