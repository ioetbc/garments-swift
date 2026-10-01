import Foundation
import CoreGraphics

nonisolated struct WorldPoint: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    static func +(l: Self, r: Self) -> Self { .init(x: l.x+r.x, y: l.y+r.y) }
    static func -(l: Self, r: Self) -> Self { .init(x: l.x-r.x, y: l.y-r.y) }
    static func *(l: Self, r: Double) -> Self { .init(x: l.x*r, y: l.y*r) }
    var cg: CGPoint { .init(x: x, y: y) }
    init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = p.x; y = p.y }
    var valid: Bool { x.isFinite && y.isFinite && abs(x) < 1e12 && abs(y) < 1e12 }
}
nonisolated enum CanvasConfiguration {
    static let zoom = 0.02...18.0
    static let canvasSpacing = 5_000.0
    // World-space padding scales with products as the camera zooms.
    static let groupBackgroundPadding = 9.0
    static let edge = 1.0...8192.0
    static let initialImageEdge = 150.0 // Screen points at insertion; world points for fixtures at zoom 1.
    static let cell = 512.0
    static let maxItemCells = 64
    static let maxQueryCells = 4096
    static let joinRadius = 64.0
    static let detachRadius = joinRadius * 2
    static let detachSpeed = 450.0 // Outward screen points per second.
    static let magneticRestGap = 12.0
    // Presentation-only pickup feedback; placements keep their original dimensions.
    static let liftScale = 1.6
    static let liftOffset = 28.0 // Screen points, independent of canvas zoom.
    static let groupingPreviewRadius = 80.0 // Screen points.
    // Screen points: the pull feels consistent at every zoom level.
    static let magneticReach = 110.0
    static let magneticPull = 52.0
    static let cacheBytes = 96 * 1024 * 1024
    static let tiers = [128, 256, 512, 1024, 2048]
}
nonisolated struct CanvasCamera: Codable, Equatable, Sendable {
    var center = WorldPoint()
    var zoom = 1.0
    func screen(_ p: WorldPoint, viewport: CGSize) -> CGPoint {
        CGPoint(x: viewport.width/2+(p.x-center.x)*zoom, y: viewport.height/2+(p.y-center.y)*zoom)
    }
    func world(_ p: CGPoint, viewport: CGSize) -> WorldPoint {
        .init(x: center.x+(p.x-viewport.width/2)/zoom, y: center.y+(p.y-viewport.height/2)/zoom)
    }
    mutating func pinch(anchor: WorldPoint, midpoint: CGPoint, zoom proposed: Double, viewport: CGSize) {
        zoom = min(CanvasConfiguration.zoom.upperBound, max(CanvasConfiguration.zoom.lowerBound, proposed))
        center = anchor - WorldPoint(x: (midpoint.x-viewport.width/2)/zoom, y: (midpoint.y-viewport.height/2)/zoom)
    }
    var valid: Bool { center.valid && zoom.isFinite && CanvasConfiguration.zoom.contains(zoom) }
}
nonisolated enum CanvasGeometry {
    static func liftedBounds(_ item: StickerPlacement, zoom: Double) -> CGRect {
        item.bounds.insetBy(dx:-item.width*(CanvasConfiguration.liftScale-1)/2,
                            dy:-item.height*(CanvasConfiguration.liftScale-1)/2)
            .offsetBy(dx:0,dy:-CanvasConfiguration.liftOffset/zoom)
    }
    static func magneticOffset(_ moving: CGRect, toward target: CGRect, zoom: Double) -> WorldPoint {
        let gap = WorldPoint(
            x: target.minX > moving.maxX ? target.minX-moving.maxX : (target.maxX < moving.minX ? target.maxX-moving.minX : 0),
            y: target.minY > moving.maxY ? target.minY-moving.maxY : (target.maxY < moving.minY ? target.maxY-moving.minY : 0))
        let distance = hypot(gap.x,gap.y)
        let rest = min(CanvasConfiguration.magneticRestGap, 12/zoom)
        let reach = rest + CanvasConfiguration.magneticReach/zoom
        guard distance > rest, distance < reach else { return WorldPoint() }
        let progress = (reach-distance)/(reach-rest)
        let strength = progress*progress*(3-2*progress)
        let pull = min(distance-rest,CanvasConfiguration.magneticPull/zoom)*strength
        return gap*(pull/distance)
    }
    static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        hypot(max(b.minX-a.maxX, a.minX-b.maxX, 0), max(b.minY-a.maxY, a.minY-b.maxY, 0))
    } 
    static func union(_ items: [StickerPlacement]) -> CGRect { items.reduce(CGRect.null) { $0.union($1.bounds) } }
    static func clampedScale(_ scale: Double, items: [StickerPlacement]) -> Double {
        let low = items.map { CanvasConfiguration.edge.lowerBound / max($0.width,$0.height) }.max() ?? 1
        let high = items.map { CanvasConfiguration.edge.upperBound / max($0.width,$0.height) }.min() ?? 1
        return min(high,max(low,scale))
    }
    static func scaled(_ items: [StickerPlacement], anchor: WorldPoint, destination: WorldPoint, scale: Double) -> [StickerPlacement] {
        let s = clampedScale(scale, items: items)
        return items.map { item in
            var p = item; p.center = destination + (item.center-anchor)*s
            p.width *= s; p.height *= s; return p
        }
    }
}
