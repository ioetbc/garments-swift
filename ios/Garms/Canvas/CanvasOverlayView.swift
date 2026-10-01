import UIKit

@MainActor final class CanvasOverlayView: UIView {
    weak var session: CanvasSession?
    var liftedIDs: Set<String> = []
    var displayedGroupBounds: ((CanvasNamedGroup) -> CGRect)?
    struct Title {
        var group: CanvasNamedGroup
        var frame: CGRect
    }
    struct CanvasHeader {
        var user: CanvasProfile
        var isOwn: Bool
        var title: String { isOwn ? "Your canvas" : user.title }
        var boundary: CGRect
        var label: CGRect
        var button: CGRect
    }
    private(set) var canvasHeaders: [CanvasHeader] = []
    private(set) var titles: [Title] = []
    private var titleOpacity: CGFloat = 1
    private var titleFont: UIFont { UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)) }

    func updateTitles() {
        guard let session else { titles = []; canvasHeaders = []; return }
        let own = CanvasProfile(username: session.document.username ?? "you", displayName: "You")
        let owners = session.displayedCanvases.isEmpty ? [] : [own] + session.displayedCanvases
        canvasHeaders = owners.compactMap { user in
            let isOwn = user.username == own.username
            var world = session.document.canvasBounds(isOwn ? nil : user.username)
            if isOwn, let recent = session.document.namedGroups?.first(where: \.isRecentUploads) {
                world = world.union(recent.bounds(in: session.document))
            }
            guard !world.isNull else { return nil }
            let members = session.document.canvasMembers(isOwn ? nil : user.username)
            let canvasGroup = CanvasNamedGroup(members: members, name: "", emptyCenter: nil)
            var content = displayedGroupBounds?(canvasGroup) ?? screenRect(world, session)
            if isOwn, let recent = session.document.namedGroups?.first(where: \.isRecentUploads), recent.members.isEmpty {
                content = content.union(screenRect(recent.bounds(in: session.document), session))
            }
            // Anchor to the displayed products, not the former padded border.
            // Background padding scales with the canvas; the label gap stays readable.
            let frame = content
            let title = isOwn ? "Your canvas" : user.title
            let titleWidth = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]).width
            let usernameWidth = ("@" + user.username as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 12)]).width
            let buttonWidth: CGFloat = isOwn ? 0.0 : (session.isFollowing(user) ? 44.0 : 76.0)
            let labelWidth: CGFloat = min(max(titleWidth, usernameWidth).rounded(.up) + 16,
                                 max(120, bounds.width - 48 - buttonWidth - 4))
            let label = CGRect(x: frame.minX + 8, y: frame.minY - 56, width: labelWidth, height: 50)
            let button = isOwn ? CGRect.null : CGRect(x: label.maxX + 4, y: label.minY + 3, width: buttonWidth, height: 44)
            return CanvasHeader(user: user, isOwn: isOwn, boundary: frame, label: label, button: button)
        }
        // Show titles at the default zoom; fade out in the overview to avoid crowding.
        // Remove hidden titles from hit testing and VoiceOver.
        let progress = min(1, max(0, (session.camera.zoom - 0.5) / 0.25))
        titleOpacity = CGFloat(progress * progress * (3 - 2 * progress))
        guard titleOpacity > 0 else { titles = []; return }
        titles = (session.document.namedGroups ?? []).filter { session.isVisible($0) }.compactMap { group in
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
    func canvasLabel(at point: CGPoint) -> CanvasProfile? {
        canvasHeaders.reversed().first { !$0.isOwn && $0.label.contains(point) }?.user
    }

    func canvasFollowButton(at point: CGPoint) -> CanvasProfile? {
        canvasHeaders.reversed().first { !$0.isOwn && $0.button.contains(point) }?.user
    }

    private func drawCanvasHeaders() {
        guard let session else { return }
        for header in canvasHeaders {
            let colour = header.isOwn ? UIColor.secondaryLabel : UIColor.systemIndigo
            // Owner labels and follow controls stay readable at overview zoom.
            UIColor.systemBackground.withAlphaComponent(0.96).setFill()
            UIBezierPath(roundedRect: header.label, cornerRadius: 10).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (header.title as NSString).draw(in: header.label.insetBy(dx: 8, dy: 5), withAttributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: colour, .paragraphStyle: paragraph
            ])
            ("@" + header.user.username as NSString).draw(in: CGRect(
                x: header.label.minX + 8, y: header.label.minY + 27,
                width: header.label.width - 16, height: 18), withAttributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph
            ])
            guard !header.isOwn else { continue }
            let following = session.isFollowing(header.user)
            (following ? UIColor.secondarySystemBackground : colour).setFill()
            UIBezierPath(roundedRect: header.button, cornerRadius: 22).fill()
            if following {
                let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                UIImage(systemName: "checkmark", withConfiguration: configuration)?
                    .withTintColor(colour, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: header.button.midX - 10, y: header.button.midY - 10, width: 20, height: 20))
                continue
            }
            let text = "Follow"
            let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            let size = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(at: CGPoint(x: header.button.midX - size.width / 2,
                y: header.button.midY - size.height / 2), withAttributes: [
                .font: font, .foregroundColor: following ? colour : UIColor.white
            ])
        }
    }

    override init(frame:CGRect) {
        super.init(frame:frame)
        isUserInteractionEnabled = false; backgroundColor = .clear; isOpaque = false
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect:CGRect) {
        drawCanvasHeaders()
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
        let padding = CanvasConfiguration.groupBackgroundPadding * session.camera.zoom
        ctx.stroke(screenRect(groupBounds,session).insetBy(dx: -padding, dy: -padding))
    }
    func screenRect(_ r: CGRect, _ session: CanvasSession) -> CGRect {
        let p = session.camera.screen(.init(x:r.minX,y:r.minY),viewport:bounds.size)
        return CGRect(x:p.x,y:p.y,width:r.width*session.camera.zoom,height:r.height*session.camera.zoom)
    }
    // Keep the group's edge hit band, and optionally include interior whitespace.
    func group(at point:CGPoint, includingInterior:Bool = false) -> [String]? {
        guard let session else { return nil }
        return session.groups.filter { group in
            guard group.contains(where: { id in session.document.placements[id].map { session.isVisible($0) } ?? false }) else { return false }
            let items = group.compactMap { session.document.placements[$0] }
            let padding = CanvasConfiguration.groupBackgroundPadding * session.camera.zoom
            let rect = screenRect(CanvasGeometry.union(items),session).insetBy(dx: -padding, dy: -padding)
            return rect.insetBy(dx:-12,dy:-12).contains(point) &&
                (includingInterior || !rect.insetBy(dx:12,dy:12).contains(point))
        }.min { a,b in
            let ra = CanvasGeometry.union(a.compactMap { session.document.placements[$0] })
            let rb = CanvasGeometry.union(b.compactMap { session.document.placements[$0] })
            return ra.width*ra.height < rb.width*rb.height
        }
    }
}
