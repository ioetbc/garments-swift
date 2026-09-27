import UIKit

@MainActor final class CanvasOverlayView: UIView {
    weak var session: CanvasSession?
    var liftedIDs: Set<String> = []
    var displayedGroupBounds: ((CanvasNamedGroup) -> CGRect)?
    struct Title {
        var group: CanvasNamedGroup
        var frame: CGRect
    }
    private(set) var titles: [Title] = []
    private var titleOpacity: CGFloat = 1
    private var titleFont: UIFont { UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)) }

    func updateTitles() {
        guard let session else { titles = []; return }
        // Show titles at the default zoom; fade out in the overview to avoid crowding.
        // Remove hidden titles from hit testing and VoiceOver.
        let progress = min(1, max(0, (session.camera.zoom - 0.5) / 0.25))
        titleOpacity = CGFloat(progress * progress * (3 - 2 * progress))
        guard titleOpacity > 0 else { titles = []; return }
        titles = (session.document.namedGroups ?? []).compactMap { group in
            let worldBounds = group.bounds(in: session.document)
            guard !worldBounds.isNull else { return nil }
            let rect = displayedGroupBounds?(group) ?? screenRect(worldBounds, session)
            let width = min(max(120, rect.width), 280, ceil((group.name as NSString).size(withAttributes: [.font: titleFont]).width) + 16)
            let height = max(44, titleFont.lineHeight + 16)
            // Keep the visible pill four points above the group, accounting for its inset.
            let frame = CGRect(x: rect.minX, y: rect.minY - height + 7 - 4, width: width, height: height)
            guard frame.intersects(bounds) else { return nil }
            return Title(group: group, frame: frame)
        }
    }
    func title(at point: CGPoint) -> Title? {
        titles.reversed().first { $0.frame.contains(point) }
    }
    private func drawTitles() {
        guard let context = UIGraphicsGetCurrentContext(), titleOpacity > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(titleOpacity)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for title in titles {
            context.setAlpha(titleOpacity * (session?.dimmedGroupIDs.contains(title.group.id) == true ? 0.1 : 1))
            let pill = title.frame.insetBy(dx: 0, dy: 7)
            UIColor.white.withAlphaComponent(0.94).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 9).fill()
            let text = CGRect(x: pill.minX + 8, y: pill.midY - titleFont.lineHeight / 2,
                              width: pill.width - 16, height: titleFont.lineHeight)
            (title.group.name as NSString).draw(in: text, withAttributes: [
                .font: titleFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraph
            ])
        }
    }
    override init(frame:CGRect) {
        super.init(frame:frame)
        isUserInteractionEnabled = false; backgroundColor = .clear; isOpaque = false
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect:CGRect) {
        drawTitles()
        guard let ctx = UIGraphicsGetCurrentContext(), let session,
              liftedIDs.count == 1, let id = liftedIDs.first,
              let item = session.document.placements[id] else { return }
        let liftedBounds = CanvasGeometry.liftedBounds(item,zoom:session.camera.zoom)
        let radius = CanvasConfiguration.groupingPreviewRadius/session.camera.zoom
        // Include tentative grouping, but hide the outline when an elastic link stretches away.
        let nearGroup = session.groups.first { group in
            group.contains(id) && group.contains { otherID in
                guard otherID != id, let other = session.document.placements[otherID] else { return false }
                return CanvasGeometry.distance(liftedBounds,other.bounds) <= radius
            }
        }
        guard let nearGroup else { return }
        let groupBounds = nearGroup.reduce(CGRect.null) { bounds, memberID in
            guard let member = session.document.placements[memberID] else { return bounds }
            return bounds.union(memberID == id ? liftedBounds : member.bounds)
        }
        ctx.setStrokeColor(UIColor(red:0.2,green:0.36,blue:0.29,alpha:1).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(screenRect(groupBounds,session).insetBy(dx:-9,dy:-9))
    }
    func screenRect(_ r: CGRect, _ session: CanvasSession) -> CGRect {
        let p = session.camera.screen(.init(x:r.minX,y:r.minY),viewport:bounds.size)
        return CGRect(x:p.x,y:p.y,width:r.width*session.camera.zoom,height:r.height*session.camera.zoom)
    }
    // Keep the group's edge hit band, and optionally include interior whitespace.
    func group(at point:CGPoint, includingInterior:Bool = false) -> [String]? {
        guard let session else { return nil }
        return session.groups.filter { group in
            let items = group.compactMap { session.document.placements[$0] }
            let rect = screenRect(CanvasGeometry.union(items),session).insetBy(dx:-9,dy:-9)
            return rect.insetBy(dx:-12,dy:-12).contains(point) &&
                (includingInterior || !rect.insetBy(dx:12,dy:12).contains(point))
        }.min { a,b in
            let ra = CanvasGeometry.union(a.compactMap { session.document.placements[$0] })
            let rb = CanvasGeometry.union(b.compactMap { session.document.placements[$0] })
            return ra.width*ra.height < rb.width*rb.height
        }
    }
}
