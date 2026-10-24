import AppKit

/// The small floating icon at the top right of the screen: click to show the stack, click again to hide it. It is a
/// little clay-colored pouch with a gentle smile and two cards peeking out, with a badge for how many items are stored.
/// It lives in the menu-bar process (a window of a few hundred KB, no pictures) and is updated when something changes,
/// not by polling.
enum StackIcon {
    static let diameter: CGFloat = 46                  // the pouch's area
    static let badgeRoom: CGFloat = 8                  // the badge sticks out past it (top and right)
    static let ringRoom: CGFloat = 6                   // the "open" plate sticks out past it (all around), with room for its shadow
    private static var panel: NSPanel?
    private static var view: StackIconView?

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "hideStackIcon") }

    /// Where the icon sits on `screen`: the top right corner, under the menu bar.
    static func circle(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        return NSRect(x: v.maxX - 12 - badgeRoom - diameter, y: v.maxY - 8 - badgeRoom - diameter, width: diameter, height: diameter)
    }

    /// True when the icon is shown on `screen`, so the stack makes room for it.
    static func isShown(on screen: NSScreen) -> Bool { isEnabled && screen == NSScreen.screens.first }

    /// Shows or hides the icon according to the setting.
    static func apply() {
        guard isEnabled, let screen = NSScreen.screens.first else {
            panel?.orderOut(nil)
            return
        }
        let side = diameter + badgeRoom + ringRoom
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false      // the pouch draws its own shadow
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = StackIconView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            p.contentView = v
            panel = p
            view = v
        }
        let c = circle(on: screen)
        panel?.setFrame(NSRect(x: c.minX - ringRoom, y: c.minY - ringRoom, width: side, height: side), display: true)
        panel?.orderFrontRegardless()
        refresh()
    }

    /// Re-reads the item count and whether the stack is showing.
    static func refresh() {
        view?.update(count: StackStore.count(), active: Session.isStackShowing)
    }
}

/// The icon, drawn in code: the pouch (clay gradient, with a smile) with a pocket square tucked in, its folded points
/// showing, like the one in a gentleman's breast pocket; a count badge; a dashed empty pouch when nothing is stored; and
/// a warm plate behind it while the stack is open.
final class StackIconView: NSView {
    private(set) var count = 0              // what the badge shows
    private var active = false
    private let d = StackIcon.diameter
    private var origin: NSPoint { NSPoint(x: StackIcon.ringRoom, y: StackIcon.ringRoom) }

    func update(count: Int, active: Bool) {
        self.count = count
        self.active = active
        toolTip = count == 0 ? "Stack (empty)" : "Stack (\(count))"
        needsDisplay = true
    }

    // MARK: drawing

    /// A shape with a vertical gradient, a soft warm shadow, and a faint light edge so it has a little body.
    private func fill(_ path: NSBezierPath, _ g: Warm.Gradient, edge: Bool = true) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Warm.ink.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 3.5
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        g.top.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: g.top, ending: g.bottom)?.draw(in: path.bounds, angle: -90)
        if edge {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A rounded rectangle at (left, top) from the pouch area's top left corner.
    private func rounded(_ left: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: origin.x + left, y: origin.y + d - top - h, width: w, height: h), xRadius: r, yRadius: r)
    }

    /// A polygon with softly rounded corners, given in the pouch area's top left coordinates. Used for the folded points of
    /// the pocket square.
    private func softPolygon(_ points: [CGPoint], radius: CGFloat, lift: CGFloat) -> NSBezierPath {
        let v = points.map { NSPoint(x: origin.x + $0.x, y: origin.y + d - $0.y + lift) }
        let p = NSBezierPath()
        p.move(to: NSPoint(x: (v[v.count - 1].x + v[0].x) / 2, y: (v[v.count - 1].y + v[0].y) / 2))
        for i in 0..<v.count { p.appendArc(from: v[i], to: v[(i + 1) % v.count], radius: radius) }
        p.close()
        return p
    }

    /// The pouch: square-ish shoulders, a rounded belly.
    private func pouchPath() -> NSBezierPath {
        let l = origin.x, r = origin.x + d, top = origin.y + d - 14, bottom = origin.y
        let p = NSBezierPath()
        p.move(to: NSPoint(x: l, y: top - 7))
        p.curve(to: NSPoint(x: l + 7, y: top), controlPoint1: NSPoint(x: l, y: top - 3), controlPoint2: NSPoint(x: l + 3, y: top))
        p.line(to: NSPoint(x: r - 7, y: top))
        p.curve(to: NSPoint(x: r, y: top - 7), controlPoint1: NSPoint(x: r - 3, y: top), controlPoint2: NSPoint(x: r, y: top - 3))
        p.line(to: NSPoint(x: r, y: bottom + 16))
        p.curve(to: NSPoint(x: r - 16, y: bottom), controlPoint1: NSPoint(x: r, y: bottom + 6), controlPoint2: NSPoint(x: r - 7, y: bottom))
        p.line(to: NSPoint(x: l + 16, y: bottom))
        p.curve(to: NSPoint(x: l, y: bottom + 16), controlPoint1: NSPoint(x: l + 7, y: bottom), controlPoint2: NSPoint(x: l, y: bottom + 6))
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        if active && count > 0 {
            // The stack is open: the icon sits on a soft peach plate (darker than the cream pocket square, so that still shows).
            fill(NSBezierPath(roundedRect: NSRect(x: origin.x - 4, y: origin.y - 4, width: d + 8, height: d + 8), xRadius: 16, yRadius: 16),
                 (Warm.color(0xFBDABA), Warm.color(0xEFB98C)))
        }
        let pouch = pouchPath()
        if count == 0 {
            // Nothing stored: an empty pouch, dashed, on a faint dark wash so it shows on light wallpapers too.
            Warm.ink.withAlphaComponent(0.28).setFill()
            pouch.fill()
            Warm.color(0xFFF4E3, 0.9).setStroke()
            pouch.lineWidth = 1.5
            pouch.setLineDash([5, 3], count: 2, phase: 0)
            pouch.stroke()
            return
        }
        // A pocket square in the top of the pouch: a sand one behind with a single point, a cream one in front folded
        // into two points. The bottoms are hidden by the pouch. They rise a little while the stack is open.
        let lift: CGFloat = active ? 3 : 0
        fill(softPolygon([CGPoint(x: 12, y: 18), CGPoint(x: 24, y: -1), CGPoint(x: 36, y: 18)], radius: 2.5, lift: lift), Warm.sand)
        fill(softPolygon([CGPoint(x: 6, y: 18), CGPoint(x: 15, y: 3), CGPoint(x: 22, y: 12), CGPoint(x: 31, y: 6), CGPoint(x: 40, y: 18)],
                         radius: 2.5, lift: lift), Warm.cream)
        fill(pouch, Warm.clay)
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: origin.x + 15, y: origin.y + 17))
        smile.curve(to: NSPoint(x: origin.x + 31, y: origin.y + 17), controlPoint1: NSPoint(x: origin.x + 19, y: origin.y + 11),
                    controlPoint2: NSPoint(x: origin.x + 27, y: origin.y + 11))
        Warm.color(0xFFF4E3).setStroke()
        smile.lineWidth = 2.5
        smile.lineCapStyle = .round
        smile.stroke()

        drawBadge()
    }

    /// The count: a solid berry-red badge with a cream number, no outline (only a soft shadow sets it apart).
    private func drawBadge() {
        let text = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Warm.color(0xFFF4E3)])
        let h: CGFloat = 21, w = max(h, text.size().width + 12)
        let badge = NSBezierPath(roundedRect: NSRect(x: origin.x + d - w + 5, y: origin.y + d - h + 5, width: w, height: h), xRadius: h / 2, yRadius: h / 2)
        fill(badge, Warm.badge, edge: false)
        text.draw(at: NSPoint(x: badge.bounds.midX - text.size().width / 2, y: badge.bounds.midY - text.size().height / 2))
    }

    // MARK: mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { Session.toggleStack() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
