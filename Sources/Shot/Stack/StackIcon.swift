import AppKit

/// The small floating icon at the top right of the screen: click to show the stack, click again to hide it. It is a
/// little clay-colored pouch with a gentle smile and two cards peeking out, with a badge for how many items are stored.
/// It lives in the menu-bar process (a window of a few hundred KB, no pictures) and is updated when something changes,
/// not by polling.
enum StackIcon {
    static let diameter: CGFloat = 46                  // the pouch's area
    static let badgeRoom: CGFloat = 8                  // the badge sticks out past it (top and right)
    static let ringRoom: CGFloat = 14                  // the "open" plate sticks out past it (all around), with room for its shadow to fade out
    private static var panel: NSPanel?
    private static var view: StackIconView?

    /// Whether the icon is showing (the shortcut, the menu and Settings turn it on and off).
    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "hideStackIcon") }

    /// Shows or hides the whole icon. Hiding it also closes the stack if it is open.
    static func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(!visible, forKey: "hideStackIcon")
        if !visible { Session.hideStack() }
        apply()
    }

    static func toggleVisible() { setVisible(!isEnabled) }

    /// Stores what is on the clipboard (text, a link, or a picture) in the stack, without any dragging: for the shortcut,
    /// the menu, and Option-click on the icon. The stack shows for a moment so you can see it went in; if there is nothing
    /// it can take, there is a beep.
    static func storeClipboard() {
        let v = homeScreen.visibleFrame
        if StackDrop.accepts(NSPasteboard.general), StackDrop.store(NSPasteboard.general, around: CGPoint(x: v.midX, y: v.midY)) > 0 {
            Session.stackStored()
        } else {
            NSSound.beep()
        }
    }

    // Where the icon was left, as ["screen": display id, "dx": ..., "dy": ...]: dx and dy are how far the pouch's top right
    // corner is from the top right corner of that screen's usable area. Until it is dragged it sits just under the menu bar
    // in the corner of the main screen.
    private static let positionKey = "stackIconPosition"

    private static func displayID(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    /// The screen the icon is on: the one it was last left on, or the main one (also if that display is gone).
    static var homeScreen: NSScreen {
        let saved = UserDefaults.standard.dictionary(forKey: positionKey)?["screen"] as? Int
        return NSScreen.screens.first { displayID($0) == saved } ?? NSScreen.screens[0]
    }

    private static var offset: CGPoint {
        if let d = UserDefaults.standard.dictionary(forKey: positionKey), let x = d["dx"] as? Double, let y = d["dy"] as? Double { return CGPoint(x: x, y: y) }
        return CGPoint(x: 12 + badgeRoom, y: 8 + badgeRoom)
    }

    /// Keeps the pouch (and its badge and plate) fully on the screen.
    private static func clamped(_ r: NSRect, in v: NSRect) -> NSRect {
        NSRect(x: min(max(r.minX, v.minX + ringRoom), v.maxX - diameter - badgeRoom),
               y: min(max(r.minY, v.minY + ringRoom), v.maxY - diameter - badgeRoom), width: diameter, height: diameter)
    }

    /// Where the icon sits on `screen`.
    static func circle(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame, o = offset
        return clamped(NSRect(x: v.maxX - o.x - diameter, y: v.maxY - o.y - diameter, width: diameter, height: diameter), in: v)
    }

    /// Everything that counts as the icon on `screen`: its pouch, the plate, and the badge.
    static func hitRect(on screen: NSScreen) -> NSRect {
        let c = circle(on: screen)
        return NSRect(x: c.minX - ringRoom, y: c.minY - ringRoom, width: diameter + ringRoom + badgeRoom, height: diameter + ringRoom + badgeRoom)
    }

    /// Moves the icon (dragged by the user) so its window's bottom left corner is at `origin`: onto whichever screen it was
    /// dragged to, kept fully on that screen, and remembered.
    static func move(toWindowOrigin origin: NSPoint) {
        guard let panel = panel else { return }
        let wanted = NSRect(x: origin.x + ringRoom, y: origin.y + ringRoom, width: diameter, height: diameter)
        let middle = NSPoint(x: wanted.midX, y: wanted.midY)
        let target = NSScreen.screens.first { $0.frame.contains(middle) } ?? homeScreen
        let v = target.visibleFrame
        let c = clamped(wanted, in: v)
        panel.setFrameOrigin(NSPoint(x: c.minX - ringRoom, y: c.minY - ringRoom))
        UserDefaults.standard.set(["screen": displayID(target), "dx": Double(v.maxX - c.maxX), "dy": Double(v.maxY - c.maxY)], forKey: positionKey)
    }

    /// Shows or hides the icon according to the setting.
    static func apply() {
        guard isEnabled, !NSScreen.screens.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let screen = homeScreen
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
/// showing, like the one in a gentleman's breast pocket, and a count badge; the same pouch without those when nothing is
/// stored; and a warm plate behind it while the stack is open.
final class StackIconView: NSView {
    private(set) var count = 0              // what the badge shows
    private var active = false
    private var dropping = false            // something is being dragged over the icon
    private let d = StackIcon.diameter
    private var origin: NSPoint { NSPoint(x: StackIcon.ringRoom, y: StackIcon.ringRoom) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(StackDrop.types)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(count: Int, active: Bool) {
        self.count = count
        self.active = active
        toolTip = (count == 0 ? "Stack (empty)" : "Stack (\(count))") + "\nClick: open or close\nOption-click: store the clipboard"
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
        if active || dropping {
            // The stack is open, or something is held over the icon ready to drop: it sits on a soft peach plate (darker than the cream pocket square, so that still shows).
            fill(NSBezierPath(roundedRect: NSRect(x: origin.x - 4, y: origin.y - 4, width: d + 8, height: d + 8), xRadius: 16, yRadius: 16),
                 (Warm.color(0xFBDABA), Warm.color(0xEFB98C)))
        }
        if count > 0 {
            // A pocket square in the top of the pouch: a sand one behind with a single point, a cream one in front folded
            // into two points. The bottoms are hidden by the pouch. They rise a little while the stack is open.
            let lift: CGFloat = active ? 3 : 0
            fill(softPolygon([CGPoint(x: 12, y: 18), CGPoint(x: 24, y: -1), CGPoint(x: 36, y: 18)], radius: 2.5, lift: lift), Warm.sand)
            fill(softPolygon([CGPoint(x: 6, y: 18), CGPoint(x: 15, y: 3), CGPoint(x: 22, y: 12), CGPoint(x: 31, y: 6), CGPoint(x: 40, y: 18)],
                             radius: 2.5, lift: lift), Warm.cream)
        }
        // The pouch is the same with or without anything in it; empty, it just has no pocket square and no badge, and it
        // sits a little higher, in the middle of the space the pocket square would use.
        NSGraphicsContext.saveGraphicsState()
        if count == 0 {
            let up = NSAffineTransform()
            up.translateX(by: 0, yBy: 7)
            up.concat()
        }
        fill(pouchPath(), Warm.clay)
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: origin.x + 15, y: origin.y + 17))
        smile.curve(to: NSPoint(x: origin.x + 31, y: origin.y + 17), controlPoint1: NSPoint(x: origin.x + 19, y: origin.y + 11),
                    controlPoint2: NSPoint(x: origin.x + 27, y: origin.y + 11))
        Warm.color(0xFFF4E3).setStroke()
        smile.lineWidth = 2.5
        smile.lineCapStyle = .round
        smile.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if count > 0 { drawBadge() }
    }

    /// The count: a solid berry-red badge with a cream number, no outline (only a soft shadow sets it apart).
    private func drawBadge() {
        let text = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Warm.color(0xFFF4E3)])
        let h: CGFloat = 21, w = max(h, text.size().width + 12)
        let badge = NSBezierPath(roundedRect: NSRect(x: origin.x + d - w + 3, y: origin.y + d - h + 3, width: w, height: h), xRadius: h / 2, yRadius: h / 2)
        fill(badge, Warm.badge, edge: false)
        text.draw(at: NSPoint(x: badge.bounds.midX - text.size().width / 2, y: badge.bounds.midY - text.size().height / 2))
    }

    // MARK: drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard StackDrop.accepts(sender.draggingPasteboard) else { return [] }
        dropping = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropping = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { StackDrop.accepts(sender.draggingPasteboard) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        needsDisplay = true
        let v = StackIcon.homeScreen.visibleFrame
        guard StackDrop.store(sender.draggingPasteboard, around: CGPoint(x: v.midX, y: v.midY)) > 0 else { return false }
        Session.stackStored()          // the stack shows for two seconds so you can see it went in
        return true
    }

    // MARK: mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A click shows or hides the stack; pressing and moving drags the icon (and the open stack follows it).
    private var grab: NSPoint?             // where in the window the pointer took hold
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        grab = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = grab, let window = window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let origin = NSPoint(x: pointer.x - grab.x, y: pointer.y - grab.y)
        if !dragged {
            guard hypot(origin.x - window.frame.origin.x, origin.y - window.frame.origin.y) > 4 else { return }
            dragged = true
            NSCursor.closedHand.push()
        }
        StackIcon.move(toWindowOrigin: origin)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            NSCursor.pop()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            // Option-click stores the clipboard (no dragging needed); a plain click opens or closes the stack.
            if event.modifierFlags.contains(.option) { StackIcon.storeClipboard() } else { Session.toggleStack() }
        }
        grab = nil
        dragged = false
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
