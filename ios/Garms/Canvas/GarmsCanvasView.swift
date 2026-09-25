import UIKit

@MainActor private final class CanvasGlideTarget: NSObject {
    weak var view: GarmsCanvasView?
    @objc func tick(_ link: CADisplayLink) { view?.advanceGlide(link) }
}

@MainActor private final class CanvasTitleAnimationTarget: NSObject {
    weak var view: GarmsCanvasView?
    @objc func tick(_ link: CADisplayLink) { view?.advanceTitleAnimation(link) }
}

@MainActor private final class CanvasEdgeScrollTarget: NSObject {
    weak var view: GarmsCanvasView?
    @objc func tick(_ link: CADisplayLink) { view?.advanceEdgeScroll(link) }
}

// Passive observer captures touch-down eligibility before UIKit's movement thresholds.
@MainActor private final class CanvasTouchObserver: UIGestureRecognizer {
    var touchesByID: [ObjectIdentifier:UITouch] = [:]
    var began: (([CGPoint]) -> Void)?
    var lifted: ((Int,Bool) -> Void)?
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) {
        for touch in touches { touchesByID[ObjectIdentifier(touch)] = touch }
        began?(touchesByID.values.sorted { $0.timestamp < $1.timestamp }.map { $0.location(in:view) })
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent) { end(touches,cancelled:false) }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent) { end(touches,cancelled:true) }
    private func end(_ touches:Set<UITouch>,cancelled:Bool) {
        for touch in touches { touchesByID[ObjectIdentifier(touch)] = nil }
        lifted?(touchesByID.count,cancelled)
        if touchesByID.isEmpty { state = .failed }
    }
    override func reset() { touchesByID.removeAll() }
    override func canPrevent(_ prevented:UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventing:UIGestureRecognizer) -> Bool { false }
}
@MainActor private final class CanvasGroupAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

@MainActor final class GarmsCanvasView: UIView, UIGestureRecognizerDelegate {
    let session: CanvasSession
    let renderer = CanvasRenderer()
    let overlay = CanvasOverlayView()
    let interaction: CanvasInteractionController
    private let touchObserver = CanvasTouchObserver()
    private var firstPoint = CGPoint.zero
    private var secondTarget: String?
    private var multiTouch = false
    private var waitForLift = false
    private var pinchActive = false
    private var manipulated = false
    private var onePan: UIPanGestureRecognizer!
    private var twoPan: UIPanGestureRecognizer!
    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var holdRecognizer: UILongPressGestureRecognizer!
    private let pickupFeedback = UIImpactFeedbackGenerator(style:.medium)
    private var elements: [String:UIAccessibilityElement] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var settle: Task<Void,Never>?
    private var edgeScrollLink: CADisplayLink?
    private var edgeScrollTimestamp: CFTimeInterval = 0
    private var glideLink: CADisplayLink?
    private var glideVelocity = WorldPoint()
    private var glideTimestamp: CFTimeInterval = 0
    private var titleAnimationLink: CADisplayLink?
    private var titleAnimationDeadline: CFTimeInterval = 0
    private var previousTitleLiftedIDs: Set<String> = []
    init(session:CanvasSession) {
        self.session = session; interaction = CanvasInteractionController(session:session); super.init(frame:.zero)
        isMultipleTouchEnabled = true; clipsToBounds = true
        backgroundColor = .white
        layer.addSublayer(renderer.paperDots)
        layer.addSublayer(renderer.world); addSubview(overlay); overlay.session = session
        overlay.displayedGroupBounds = { [weak self] group in
            guard let self else { return .null }
            return self.renderer.displayedGroupBounds(group, session: self.session)
        }
        session.render = { [weak self] in self?.render() }
        session.resolveInteraction = { [weak self] in self?.cancelInteraction() }
        renderer.assets.changed = { [weak self] in self?.render() }
        renderer.assets.failure = { [weak session] in session?.error = $0 }
        configureGestures()
        notificationTokens.append(NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInteraction() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderer.assets.memoryWarning() }
        })
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configureGestures() {
        touchObserver.cancelsTouchesInView = false
        touchObserver.began = { [weak self] points in self?.touchesArrived(points) }
        touchObserver.lifted = { [weak self] count,cancelled in
            guard let self else { return }
            if cancelled { self.cancelInteraction() }
            if self.multiTouch && count < 2 { self.waitForLift = true }
            if count == 0 {
                self.stopEdgeScroll()
                // Defer until recognizer end callbacks have resolved this transaction.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.touchObserver.touchesByID.isEmpty else { return }
                    if self.interaction.state != .idle { self.interaction.finish() }
                    self.waitForLift = false; self.multiTouch = false; self.pinchActive = false
                }
            }
        }
        addGestureRecognizer(touchObserver)
        let tap = UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
        onePan = UIPanGestureRecognizer(target:self,action:#selector(panned(_:))); onePan.maximumNumberOfTouches = 2
        twoPan = UIPanGestureRecognizer(target:self,action:#selector(twoPanned(_:))); twoPan.minimumNumberOfTouches = 2; twoPan.maximumNumberOfTouches = 2
        pinchRecognizer = UIPinchGestureRecognizer(target:self,action:#selector(pinched(_:)))
        holdRecognizer = UILongPressGestureRecognizer(target:self,action:#selector(held(_:)))
        holdRecognizer.minimumPressDuration = 0.35
        holdRecognizer.allowableMovement = 10
        for recognizer in [tap,onePan!,twoPan!,pinchRecognizer!,holdRecognizer!] { recognizer.delegate = self; addGestureRecognizer(recognizer) }
        tap.require(toFail:onePan); tap.require(toFail:pinchRecognizer); tap.require(toFail:holdRecognizer)
    }
    private func touchesArrived(_ points:[CGPoint]) {
        stopGlide()
        if points.count == 1 {
            firstPoint = points[0]; manipulated = false; secondTarget = nil
            if hit(firstPoint) != nil || dragGroup(at:firstPoint) != nil { pickupFeedback.prepare() }
        }
        guard points.count == 2, !multiTouch, !waitForLift else { return }
        stopEdgeScroll()
        multiTouch = true; manipulated = true
        secondTarget = interaction.pinchTarget(points,hit:hit)
        let midpoint = CGPoint(x:(points[0].x+points[1].x)/2,y:(points[0].y+points[1].y)/2)
        interaction.prepareSecondFinger(target:secondTarget,midpoint:midpoint)
    }
    func hit(_ point:CGPoint) -> String? {
        let world = session.camera.world(point,viewport:bounds.size)
        let ids = session.index.query(CGRect(x:world.x-0.5,y:world.y-0.5,width:1,height:1))
        return session.document.order.reversed().first { id in
            guard ids.contains(id), let p = session.document.placements[id], let product = session.document.products[p.productID] else { return false }
            return renderer.assets.hit(p,product:product,point:world)
        }
    }
    private func dragGroup(at point:CGPoint) -> [String]? {
        // Use the same alpha-aware image hit test as individual garment pickup.
        if let title = overlay.title(at: point) { return title.group.members }
        return overlay.group(at:point,includingInterior:hit(point) == nil)
    }
    @objc private func tapped(_ r:UITapGestureRecognizer) {
        guard !manipulated, !waitForLift else { return }
        let point = r.location(in: self)
        if let title = overlay.title(at: point) {
            session.inspectGroup(title.group.id)
        } else {
            session.select(hit(point), showDetails:true)
        }
    }
    @objc private func panned(_ r:UIPanGestureRecognizer) {
        guard !multiTouch, !waitForLift, !interaction.isDragging else { return }
        switch r.state {
        case .began:
            manipulated = true
            interaction.beginCamera(point:firstPoint)
            interaction.drag(point:r.location(in:self))
        case .changed: interaction.drag(point:r.location(in:self))
        case .ended:
            finishCameraPan(r)
        case .cancelled,.failed: interaction.cancel()
        default: break
        }
    }
    @objc private func held(_ r:UILongPressGestureRecognizer) {
        guard !multiTouch, !waitForLift else { return }
        switch r.state {
        case .began:
            if let group = dragGroup(at:firstPoint) {
                interaction.liftGroup(group,point:r.location(in:self))
            } else if let id = hit(firstPoint) {
                interaction.liftImage(id,point:r.location(in:self),timestamp:ProcessInfo.processInfo.systemUptime)
            }
            guard interaction.isDragging else { return }
            manipulated = true
            pickupFeedback.impactOccurred()
            startEdgeScroll()
        case .changed:
            if interaction.isDragging { interaction.drag(point:r.location(in:self),timestamp:ProcessInfo.processInfo.systemUptime) }
        case .ended:
            stopEdgeScroll()
            if interaction.isDragging { interaction.finish(); waitForLift = true }
        case .cancelled,.failed:
            stopEdgeScroll()
            if interaction.isDragging { interaction.cancel(); waitForLift = true }
        default: break
        }
    }
    override func gestureRecognizerShouldBegin(_ recognizer:UIGestureRecognizer) -> Bool {
        guard recognizer === holdRecognizer else { return true }
        return !multiTouch && !waitForLift &&
            interaction.state == .idle && (dragGroup(at:firstPoint) != nil || hit(firstPoint) != nil)
    }
    @objc private func twoPanned(_ r:UIPanGestureRecognizer) {
        // The touch observer may set waitForLift before UIKit delivers .ended.
        if r.state == .ended, !pinchActive, secondTarget == nil, interaction.state == .cameraPan {
            finishCameraPan(r); waitForLift = true; return
        }
        guard !pinchActive, !waitForLift, secondTarget == nil else { return }
        switch r.state {
        case .began:
            guard r.numberOfTouches == 2 else { return }
            manipulated = true; interaction.beginCamera(point:r.location(in:self))
        case .changed:
            guard r.numberOfTouches == 2 else { return }
            interaction.drag(point:r.location(in:self))
        case .ended: interaction.finish(); waitForLift = true
        case .cancelled,.failed: if interaction.state == .cameraPan { interaction.cancel() }
        default: break
        }
    }
    @objc private func pinched(_ r:UIPinchGestureRecognizer) {
        switch r.state {
        case .began:
            guard !waitForLift, r.numberOfTouches == 2 else { return }; manipulated = true; pinchActive = true
            interaction.pinchStart(midpoint:r.location(in:self),recognizerScale:r.scale,target:secondTarget)
        case .changed:
            // On release UIKit can still report a change with only one touch.
            // Its location is no longer the pinch midpoint, so keep the last pose.
            guard pinchActive, !waitForLift, r.numberOfTouches == 2 else { return }
            interaction.pinch(midpoint:r.location(in:self),scale:r.scale)
        case .ended: if pinchActive { interaction.finish(); pinchActive = false; waitForLift = true; scheduleSettle() }
        case .cancelled,.failed: if pinchActive { interaction.cancel(); pinchActive = false; waitForLift = true }
        default: break
        }
    }
    func gestureRecognizer(_ a:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith b:UIGestureRecognizer) -> Bool {
        if a is UITapGestureRecognizer || b is UITapGestureRecognizer { return false }
        return true // All continuous callbacks are gated by the single interaction owner above.
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if session.viewport != bounds.size { cancelInteraction() }
        overlay.frame = bounds; session.updateViewport(bounds.size); render()
    }
    func render() {
        renderer.reconcile(session:session,retained:interaction.retained,liftedIDs:interaction.liftedIDs,
                           displayScale:traitCollection.displayScale)
        if previousTitleLiftedIDs != interaction.liftedIDs {
            previousTitleLiftedIDs = interaction.liftedIDs
            titleAnimationDeadline = CACurrentMediaTime() + 0.8
            if titleAnimationLink == nil, window != nil {
                let target = CanvasTitleAnimationTarget(); target.view = self
                let link = CADisplayLink(target: target, selector: #selector(CanvasTitleAnimationTarget.tick(_:)))
                titleAnimationLink = link
                link.add(to: .main, forMode: .common)
            }
        }
        overlay.liftedIDs = interaction.liftedIDs
        overlay.updateTitles()
        overlay.setNeedsDisplay(); updateAccessibility()
    }
    fileprivate func advanceTitleAnimation(_ link: CADisplayLink) {
        overlay.updateTitles()
        overlay.setNeedsDisplay()
        updateAccessibility()
        if (link.timestamp >= titleAnimationDeadline && !interaction.isDragging) || window == nil {
            titleAnimationLink?.invalidate(); titleAnimationLink = nil
        }
    }
    private func scheduleSettle() {
        settle?.cancel(); settle = Task { [weak self] in try? await Task.sleep(for:.milliseconds(650)); guard !Task.isCancelled else { return }; self?.render() }
    }
    private func finishCameraPan(_ recognizer: UIPanGestureRecognizer) {
        guard interaction.state == .cameraPan else { return }
        let velocity = WorldPoint(recognizer.velocity(in:self))
        interaction.finish()
        stopGlide()
        guard velocity.valid, hypot(velocity.x,velocity.y) > 40, window != nil else { return }
        glideVelocity = velocity
        glideTimestamp = CACurrentMediaTime()
        let target = CanvasGlideTarget(); target.view = self
        let link = CADisplayLink(target:target,selector:#selector(CanvasGlideTarget.tick(_:)))
        glideLink = link
        link.add(to:.main,forMode:.common)
    }
    fileprivate func advanceGlide(_ link: CADisplayLink) {
        guard interaction.state == .idle else { stopGlide(); return }
        let elapsed = link.timestamp-glideTimestamp
        guard elapsed > 0 else { return }
        glideTimestamp = link.timestamp
        // Exponential friction integrated over time keeps travel consistent at
        // 60/120 Hz. Cap a stalled frame so resuming never causes a large jump.
        let duration = min(elapsed,1.0/15.0)
        let friction = 4.0
        let decay = exp(-friction*duration)
        session.camera.center = session.camera.center-glideVelocity*((1-decay)/friction/session.camera.zoom)
        glideVelocity = glideVelocity*decay
        session.cameraChanged()
        if hypot(glideVelocity.x,glideVelocity.y) < 8 { stopGlide(); scheduleSettle() }
    }
    private func startEdgeScroll() {
        stopEdgeScroll()
        guard window != nil else { return }
        edgeScrollTimestamp = CACurrentMediaTime()
        let target = CanvasEdgeScrollTarget(); target.view = self
        let link = CADisplayLink(target:target,selector:#selector(CanvasEdgeScrollTarget.tick(_:)))
        edgeScrollLink = link
        link.add(to:.main,forMode:.common)
    }
    fileprivate func advanceEdgeScroll(_ link: CADisplayLink) {
        guard interaction.isDragging, !multiTouch, !waitForLift,
              window != nil, holdRecognizer.numberOfTouches == 1,
              holdRecognizer.state == .began || holdRecognizer.state == .changed else {
            stopEdgeScroll(); return
        }
        let elapsed = link.timestamp-edgeScrollTimestamp
        guard elapsed > 0 else { return }
        edgeScrollTimestamp = link.timestamp
        interaction.advanceEdgeScroll(point:holdRecognizer.location(in:self),duration:elapsed)
    }
    private func stopEdgeScroll() {
        edgeScrollLink?.invalidate(); edgeScrollLink = nil
    }
    private func stopGlide() {
        glideLink?.invalidate(); glideLink = nil; glideVelocity = WorldPoint()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInteraction() }
    }
    func cancelInteraction() { stopEdgeScroll(); stopGlide(); interaction.cancel(); pinchActive = false; waitForLift = !touchObserver.touchesByID.isEmpty }
    private func updateAccessibility() {
        let ids = session.document.order.filter { renderer.layers[$0] != nil }
        for id in Array(elements.keys) where !ids.contains(id) { elements[id] = nil }
        for id in ids {
            guard let p = session.document.placements[id], let product = session.document.products[p.productID] else { continue }
            let element = elements[id] ?? UIAccessibilityElement(accessibilityContainer:self)
            element.accessibilityLabel = product.title + ", " + product.category
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = overlay.screenRect(p.bounds,session)
            func action(_ title:String,_ body:@escaping (CanvasSession)->Void) -> UIAccessibilityCustomAction {
                UIAccessibilityCustomAction(name:title) { [weak self] _ in guard let self else { return false }; self.cancelInteraction(); self.session.select(id); body(self.session); return true }
            }
            element.accessibilityCustomActions = [action("Select") { $0.select(id,showDetails:true) }, action("Move right") { $0.nudge(x:20,y:0) },action("Move left") { $0.nudge(x:-20,y:0) },action("Move up") { $0.nudge(x:0,y:-20) },action("Move down") { $0.nudge(x:0,y:20) },action("Enlarge") { $0.resize(1.1) },action("Shrink") { $0.resize(1/1.1) }]
            elements[id] = element
        }
        let groupElements = overlay.titles.map { title in
            let element = CanvasGroupAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = title.group.name
            element.accessibilityHint = "Edit group name and background colour"
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = title.frame
            element.activate = { [weak self] in self?.session.inspectGroup(title.group.id) }
            return element
        }
        accessibilityElements = groupElements + ids.compactMap { elements[$0] }
    }
    func shutdown() {
        cancelInteraction(); settle?.cancel(); titleAnimationLink?.invalidate(); titleAnimationLink = nil; session.render = nil; session.resolveInteraction = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }; notificationTokens.removeAll()
    }
}
