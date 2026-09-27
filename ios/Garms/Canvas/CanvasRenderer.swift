import UIKit

@MainActor final class CanvasRenderer {
    let world = CALayer()
    let paperDots = CAShapeLayer()
    private var paperCamera: CanvasCamera?
    private var paperSize = CGSize.zero
    let assets = CanvasAssetStore()
    private(set) var layers: [String:CALayer] = [:]
    private var pool: [CALayer] = []
    private var origin = WorldPoint()
    private var currentTiers: [String:Int] = [:]
    private var previousLiftedIDs: Set<String> = []
    private let groupPlate = CAShapeLayer()
    private var groupBackgrounds: [String: CAShapeLayer] = [:]
    private var lastZoom = 1.0
    private var zoomChanged = Date.distantPast
    func reconcile(session: CanvasSession, retained: Set<String> = [], liftedIDs: Set<String> = [], displayScale: Double = 2) {
        let camera = session.camera, size = session.viewport
        guard size.width > 0, size.height > 0 else { return }
        let a = camera.world(CGPoint(x:-200,y:-200),viewport:size)
        let b = camera.world(CGPoint(x:size.width+200,y:size.height+200),viewport:size)
        let visible = session.index.query(CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)).union(retained)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updatePaper(camera:camera,size:size,displayScale:displayScale)
        if hypot(camera.center.x-origin.x,camera.center.y-origin.y) > 4096 { origin = camera.center }
        world.anchorPoint = .zero; world.position = .zero
        world.setAffineTransform(CGAffineTransform(a:camera.zoom,b:0,c:0,d:camera.zoom,tx:size.width/2+(origin.x-camera.center.x)*camera.zoom,ty:size.height/2+(origin.y-camera.center.y)*camera.zoom))
        for id in Array(layers.keys) where !visible.contains(id) {
            if let layer = layers.removeValue(forKey:id) { layer.removeFromSuperlayer(); layer.removeAllAnimations(); layer.transform = CATransform3DIdentity; layer.shadowOpacity = 0; layer.contents = nil; if pool.count < 64 { pool.append(layer) } }
            currentTiers[id] = nil
        }
        if lastZoom != camera.zoom { zoomChanged = Date(); lastZoom = camera.zoom }
        let groupLift = liftedIDs.count > 1
        let liftedBounds = CanvasGeometry.union(liftedIDs.compactMap { session.document.placements[$0] })
        let liftCenter = liftedBounds.isNull ? WorldPoint() : WorldPoint(x:liftedBounds.midX,y:liftedBounds.midY)
        let liftScale = CanvasConfiguration.liftScale
        updateGroupBackgrounds(session: session, liftedIDs: liftedIDs)
        let oldPlateOpacity = groupPlate.presentation()?.opacity ?? groupPlate.opacity
        if groupLift {
            if groupPlate.superlayer == nil { world.addSublayer(groupPlate) }
            let rect = liftedBounds.insetBy(dx:-9/camera.zoom,dy:-9/camera.zoom)
            groupPlate.bounds = CGRect(origin:.zero,size:rect.size)
            groupPlate.position = (liftCenter-origin).cg
            let path = UIBezierPath(rect:groupPlate.bounds).cgPath
            groupPlate.path = path; groupPlate.shadowPath = path
            let colour = session.document.namedGroups?.first { Set($0.members) == liftedIDs }?.backgroundColour
            groupPlate.fillColor = colour.map { uiColour($0).cgColor } ?? UIColor.white.cgColor
            groupPlate.strokeColor = nil
        }
        groupPlate.zPosition = groupLift ? CGFloat(session.document.order.count) : -1
        styleLift(groupPlate,lifted:groupLift,wasLifted:previousLiftedIDs.count > 1,
                  translation:CGPoint(x:0,y:groupLift ? -CanvasConfiguration.liftOffset/camera.zoom : 0),
                  scale:groupLift ? liftScale : 1,shadow:groupLift,zoom:camera.zoom)
        groupPlate.opacity = groupLift ? 1 : 0
        if groupLift != (previousLiftedIDs.count > 1) {
            animate(groupPlate,key:"opacity",from:NSNumber(value:oldPlateOpacity),to:NSNumber(value:groupPlate.opacity))
        }
        assets.needed.removeAll(keepingCapacity:true)
        for (rank,id) in session.document.order.enumerated() where visible.contains(id) {
            guard let p = session.document.placements[id], let product = session.document.products[p.productID] else { continue }
            let layer: CALayer
            let isNewLayer = layers[id] == nil
            if let existing = layers[id] { layer = existing }
            else { layer = pool.popLast() ?? CALayer(); layer.contentsGravity = .resize; layers[id] = layer; world.addSublayer(layer) }
            let opacity = session.opacity(for: p)
            if isNewLayer {
                // Recycled layers must not inherit another product's opacity.
                layer.opacity = opacity
            } else if layer.opacity != opacity {
                let previousOpacity = layer.presentation()?.opacity ?? layer.opacity
                layer.opacity = opacity
                animate(layer,key:"opacity",from:NSNumber(value:previousOpacity),to:NSNumber(value:opacity))
            }
            let lifted = liftedIDs.contains(id)
            if lifted && !previousLiftedIDs.contains(id) { layer.removeAnimation(forKey:"position") }
            let scale = lifted ? liftScale : 1
            let pixels = max(p.width,p.height)*camera.zoom*displayScale*scale
            let desired = assets.tier(for:pixels)
            var tier = currentTiers[id] ?? desired
            if Double(tier) < pixels*0.8 || (desired < tier && Date().timeIntervalSince(zoomChanged) > 0.5) || desired == 128 { tier = desired }
            currentTiers[id] = tier
            let key = CanvasAssetStore.Key(asset:product.asset,tier:tier)
            assets.needed.insert(key)
            layer.contents = assets.image(key)
            let position = (p.center-origin).cg
            if layer.position != position {
                let previousPosition = layer.presentation()?.position ?? layer.position
                layer.position = position
                if previousLiftedIDs.contains(id) && !lifted {
                    springPosition(layer,from:previousPosition,to:position)
                }
            }
            let bounds = CGRect(x:0,y:0,width:p.width,height:p.height)
            if layer.bounds != bounds { layer.bounds = bounds }
            // Scale every member around the same center so the group lifts as one piece.
            let offset = lifted && groupLift ? (p.center-liftCenter)*(scale-1) : WorldPoint()
            let translation = CGPoint(x:offset.x,y:offset.y+(lifted ? -CanvasConfiguration.liftOffset/camera.zoom : 0))
            styleLift(layer,lifted:lifted,wasLifted:previousLiftedIDs.contains(id),
                      translation:translation,scale:scale,shadow:lifted && !groupLift,zoom:camera.zoom)
            layer.zPosition = CGFloat(lifted ? session.document.order.count+rank+1 : rank)
        }
        previousLiftedIDs = liftedIDs
        assets.reconcile(); CATransaction.commit()
    }
    private func uiColour(_ colour: CanvasGroupColour) -> UIColor {
        let rgb = colour.rgb
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private func updateGroupBackgrounds(session: CanvasSession, liftedIDs: Set<String>) {
        let groups = (session.document.namedGroups ?? []).filter { $0.backgroundColour != nil }
        let ids = Set(groups.map(\.id))
        for id in Array(groupBackgrounds.keys) where !ids.contains(id) {
            groupBackgrounds.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for group in groups {
            guard let colour = group.backgroundColour else { continue }
            let rect = group.bounds(in: session.document)
                .insetBy(dx: -9/session.camera.zoom, dy: -9/session.camera.zoom)
            guard !rect.isNull else { continue }
            let layer = groupBackgrounds[group.id] ?? CAShapeLayer()
            if layer.superlayer == nil { world.addSublayer(layer); groupBackgrounds[group.id] = layer }
            layer.bounds = CGRect(origin: .zero, size: rect.size)
            layer.position = (WorldPoint(x: rect.midX, y: rect.midY) - origin).cg
            layer.path = UIBezierPath(rect: layer.bounds).cgPath
            layer.fillColor = uiColour(colour).cgColor
            layer.opacity = session.dimmedGroupIDs.contains(group.id) ? 0.1 : 1
            layer.zPosition = -2
            let lifted = group.members.count > 1 && Set(group.members).isSubset(of: liftedIDs)
            let wasLifted = group.members.count > 1 && Set(group.members).isSubset(of: previousLiftedIDs)
            styleLift(layer, lifted: lifted, wasLifted: wasLifted,
                      translation: CGPoint(x: 0, y: lifted ? -CanvasConfiguration.liftOffset/session.camera.zoom : 0),
                      scale: lifted ? CanvasConfiguration.liftScale : 1, shadow: false, zoom: session.camera.zoom)
        }
    }

    // Presentation frames include the actual pickup/release animation, not just its destination.
    func displayedGroupBounds(_ group: CanvasNamedGroup, session: CanvasSession) -> CGRect {
        var rect = CGRect.null
        for id in group.members {
            if let layer = layers[id] {
                rect = rect.union((layer.presentation() ?? layer).frame.offsetBy(dx: origin.x, dy: origin.y))
            } else if let item = session.document.placements[id] {
                rect = rect.union(item.bounds)
            }
        }
        if rect.isNull { rect = group.bounds(in: session.document) }
        guard !rect.isNull else { return rect }
        let point = session.camera.screen(WorldPoint(x: rect.minX, y: rect.minY), viewport: session.viewport)
        var screen = CGRect(x: point.x, y: point.y, width: rect.width * session.camera.zoom, height: rect.height * session.camera.zoom)
        // Leave room for the lifted plate's scaled padding as well as coloured backgrounds.
        screen = screen.insetBy(dx: -9 * CanvasConfiguration.liftScale, dy: -9 * CanvasConfiguration.liftScale)
        return screen
    }

    private func updatePaper(camera:CanvasCamera, size:CGSize, displayScale:Double) {
        paperDots.contentsScale = displayScale
        guard paperCamera != camera || paperSize != size else { return }
        paperCamera = camera; paperSize = size
        paperDots.frame = CGRect(origin:.zero,size:size)
        paperDots.fillColor = UIColor(white:0.78,alpha:1).cgColor
        // Keep the grid anchored in world space; show coarser dots when zoomed out.
        var worldSpacing = 24.0
        while worldSpacing*camera.zoom < 12 { worldSpacing *= 2 }
        let spacing = worldSpacing*camera.zoom
        let origin = camera.screen(WorldPoint(),viewport:size)
        let startX = origin.x-floor(origin.x/spacing)*spacing
        let startY = origin.y-floor(origin.y/spacing)*spacing
        let radius = min(1.5,max(0.65,0.9*camera.zoom))
        let path = CGMutablePath()
        for x in stride(from:startX-spacing,through:size.width+radius,by:spacing) {
            for y in stride(from:startY-spacing,through:size.height+radius,by:spacing) {
                path.addEllipse(in:CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2))
            }
        }
        paperDots.path = path
    }
    private func styleLift(_ layer:CALayer, lifted:Bool, wasLifted:Bool, translation:CGPoint, scale:Double, shadow:Bool, zoom:Double) {
        let oldTransform = layer.presentation()?.transform ?? layer.transform
        let oldOpacity = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        let lift = CATransform3DScale(CATransform3DMakeTranslation(translation.x,translation.y,0),scale,scale,1)
        layer.transform = lift
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 16/zoom; layer.shadowOffset = CGSize(width:0,height:12/zoom)
        layer.shadowOpacity = shadow ? 0.45 : 0
        if lifted != wasLifted {
            animate(layer,key:"transform",from:NSValue(caTransform3D:oldTransform),to:NSValue(caTransform3D:layer.transform))
            animate(layer,key:"shadowOpacity",from:NSNumber(value:oldOpacity),to:NSNumber(value:layer.shadowOpacity))
        }
    }
    private func springPosition(_ layer: CALayer, from: CGPoint, to: CGPoint) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let spring = CASpringAnimation(keyPath:"position")
        spring.fromValue = NSValue(cgPoint:from); spring.toValue = NSValue(cgPoint:to)
        spring.mass = 1; spring.stiffness = 240; spring.damping = 20
        spring.duration = spring.settlingDuration
        layer.add(spring,forKey:"position")
    }
    private func animate(_ layer:CALayer, key:String, from:Any, to:Any) {
        let animation = CABasicAnimation(keyPath:key)
        animation.fromValue = from; animation.toValue = to
        animation.duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.16
        animation.timingFunction = CAMediaTimingFunction(name:.easeOut)
        layer.add(animation,forKey:key)
    }

}
