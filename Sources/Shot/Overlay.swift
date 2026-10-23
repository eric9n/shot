import AppKit
import Carbon
import Darwin

extension Annotation {
    var textRect: NSRect {
        let sz = (text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        return NSRect(origin: points[0], size: sz)
    }

    var bounds: NSRect {
        if tool == .text { return textRect }
        let xs = points.map(\.x), ys = points.map(\.y)
        return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    func hit(_ p: CGPoint) -> Bool {
        let tol: CGFloat = 8
        let b = bounds
        switch tool {
        case .text:
            return b.insetBy(dx: -4, dy: -4).contains(p)
        case .move:
            return false
        case .mosaic:
            return b.contains(p)
        case .rect:
            return b.insetBy(dx: -tol, dy: -tol).contains(p)
                && !(b.width > 2 * tol && b.height > 2 * tol && b.insetBy(dx: tol, dy: tol).contains(p))
        case .ellipse:
            let a = b.width / 2, c = b.height / 2
            guard a > 0, c > 0 else { return false }
            let d = sqrt(pow((p.x - b.midX) / a, 2) + pow((p.y - b.midY) / c, 2))
            return abs(d - 1) * min(a, c) <= tol
        case .pen, .line, .arrow:
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Annotation.dist(p, points[i - 1], points[i]) <= tol { return true }
            return false
        }
    }

    static func dist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Full-screen frozen-screenshot overlay: drag to select, annotate in place.
final class OverlayView: NSView, NSTextFieldDelegate {
    let image: NSImage
    var sel: NSRect?
    var editing = false
    var dragStart: CGPoint?
    var annotations: [Annotation] = []
    var current: Annotation?
    var tool: Tool = .rect
    var color: NSColor = .systemRed
    var field: NSTextField?
    var toolbar: NSView?
    var selected: Int?
    var dragLast: CGPoint?
    var moveLast: CGPoint?   // set while the selection itself is being dragged (hand tool)
    var toolButtons: [NSButton] = []
    var onClose: () -> Void = {}

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func updateCursor(at p: CGPoint) {
        if let tb = toolbar, tb.frame.contains(p) { NSCursor.arrow.set() }
        else if moveLast != nil { NSCursor.closedHand.set() }
        else if editing, tool == .move, sel?.contains(p) == true { NSCursor.openHand.set() }
        else if dragLast != nil { NSCursor.closedHand.set() }
        else if editing, annotationIndex(at: p) != nil { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }

    override func mouseMoved(with e: NSEvent) { updateCursor(at: convert(e.locationInWindow, from: nil)) }
    override func cursorUpdate(with e: NSEvent) { updateCursor(at: convert(e.locationInWindow, from: nil)) }

    /// Horizontal mirror that stays a template image, so contentTintColor still applies.
    static func mirrored(_ img: NSImage) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { r in
            let t = NSAffineTransform()
            t.translateX(by: r.width, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
            img.draw(in: r)
            return true
        }
        out.isTemplate = true
        return out
    }

    // MARK: drawing

    override func draw(_ r: NSRect) {
        image.draw(in: bounds)
        let dim = NSBezierPath(rect: bounds)
        if let s = sel { dim.append(NSBezierPath(rect: s)); dim.windingRule = .evenOdd }   // dim everything but the selection
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        guard let s = sel else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: s).addClip()
        annotations.forEach { renderAnnotation($0) }
        if let c = current { renderAnnotation(c) }
        if let i = selected, annotations.indices.contains(i) {
            let box = NSBezierPath(rect: annotations[i].bounds.insetBy(dx: -5, dy: -5))
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            box.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.systemBlue.setStroke()
        let b = NSBezierPath(rect: s.insetBy(dx: -0.75, dy: -0.75))
        b.lineWidth = 1.5
        b.stroke()

        let scale = pixelScale
        let label = "\(Int(s.width * scale)) x \(Int(s.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        var box = NSRect(x: s.minX, y: s.maxY + 6, width: sz.width + 16, height: sz.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = s.maxY - box.height - 4; box.origin.x += 4 }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attrs)
    }

    func renderAnnotation(_ a: Annotation) {
        Canvas.render(a, src: image, base: bounds)
    }

    var pixelScale: CGFloat {
        guard let rep = image.representations.first else { return 1 }
        return CGFloat(rep.pixelsWide) / bounds.width
    }

    // MARK: mouse

    func clamp(_ p: CGPoint) -> CGPoint {
        guard let s = sel else { return p }
        return CGPoint(x: min(max(p.x, s.minX), s.maxX), y: min(max(p.y, s.minY), s.maxY))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !editing {
            dragStart = p
            sel = nil
            return
        }
        commitText()
        window?.makeFirstResponder(self)
        guard let s = sel, s.contains(p) else { selected = nil; needsDisplay = true; return }
        if tool == .move {
            selected = nil
            moveLast = p
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        if let i = annotationIndex(at: p) {
            selected = i
            dragLast = p
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        selected = nil
        needsDisplay = true
        if tool == .text { beginText(at: p); return }
        current = Annotation(tool: tool, points: [p], color: color)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !editing, let a = dragStart {
            sel = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
            needsDisplay = true
            return
        }
        if let last = moveLast, let s = sel {
            var r = s.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)     // keep the selection on screen
            r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
            moveLast = CGPoint(x: last.x + (r.minX - s.minX), y: last.y + (r.minY - s.minY))
            sel = r
            placeToolbar()
            needsDisplay = true
            return
        }
        if let last = dragLast, let i = selected, annotations.indices.contains(i) {
            let dx = p.x - last.x, dy = p.y - last.y
            annotations[i].points = annotations[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            dragLast = p
            needsDisplay = true
            return
        }
        guard current != nil else { return }
        let q = clamp(p)
        if tool == .pen { current!.points.append(q) } else { current!.points = [current!.points[0], q] }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if !editing {
            dragStart = nil
            if let s = sel, s.width > 4, s.height > 4 { beginEditing() } else { sel = nil; needsDisplay = true }
            return
        }
        if moveLast != nil {
            moveLast = nil
            updateCursor(at: convert(e.locationInWindow, from: nil))
            return
        }
        if dragLast != nil {
            dragLast = nil
            updateCursor(at: convert(e.locationInWindow, from: nil))
            return
        }
        if let c = current, c.points.count > 1 { annotations.append(c) }
        current = nil
        needsDisplay = true
    }

    /// Topmost annotation under the point.
    func annotationIndex(at p: CGPoint) -> Int? {
        annotations.indices.reversed().first { annotations[$0].hit(p) }
    }

    override func rightMouseDown(with e: NSEvent) { onClose() }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onClose()
        case 36 where editing: copyAndClose()
        case 51, 117:
            if let i = selected, annotations.indices.contains(i) { annotations.remove(at: i); selected = nil; needsDisplay = true }
        default:
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "z" { undo() } else { super.keyDown(with: e) }
        }
    }

    // MARK: text

    func beginText(at p: CGPoint) {
        let f = NSTextField(frame: NSRect(x: p.x, y: p.y - 12, width: 260, height: 28))
        f.font = .boldSystemFont(ofSize: 20)
        f.textColor = color
        f.drawsBackground = false
        f.isBordered = false
        f.focusRingType = .none
        f.delegate = self
        f.target = self
        f.action = #selector(commitText)
        addSubview(f)
        window?.makeFirstResponder(f)
        field = f
    }

    @objc func commitText() {
        guard let f = field else { return }
        field = nil
        if !f.stringValue.isEmpty {
            annotations.append(Annotation(tool: .text, points: [CGPoint(x: f.frame.minX + 2, y: f.frame.minY + 3)],
                                          color: f.textColor ?? color, text: f.stringValue))
        }
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    // MARK: toolbar

    func beginEditing() {
        editing = true
        tool = .move   // after framing, the first thing you usually want is to nudge the selection
        let tb = NSView()
        tb.wantsLayer = true
        tb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        tb.layer?.cornerRadius = 10

        func btn(_ symbol: String, _ fallback: String, _ sel: Selector, tag: Int = 0) -> NSButton {
            let b = NSButton()
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
                b.image = symbol == "hand.raised" ? OverlayView.mirrored(img) : img   // palm faces the other way
            } else { b.title = fallback }
            b.isBordered = false
            b.target = self
            b.action = sel
            b.tag = tag
            b.contentTintColor = .labelColor
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        let tools: [(String, String, Tool)] = [
            ("hand.raised", "Move", .move), ("rectangle", "Rect", .rect), ("circle", "Oval", .ellipse), ("line.diagonal", "Line", .line),
            ("arrow.up.right", "Arrow", .arrow), ("pencil", "Pen", .pen),
            ("checkerboard.rectangle", "Mosaic", .mosaic), ("textformat", "Text", .text)]
        toolButtons = tools.map { btn($0.0, $0.1, #selector(pickTool(_:)), tag: $0.2.rawValue) }

        let well = NSColorWell(style: .minimal)
        well.color = color
        well.target = self
        well.action = #selector(pickColor(_:))
        well.widthAnchor.constraint(equalToConstant: 28).isActive = true
        well.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let views: [NSView] = toolButtons + [well,
            btn("arrow.uturn.backward", "Undo", #selector(undoAction)),
            btn("xmark", "Close", #selector(closeAction)),
            btn("arrow.down.to.line", "Save", #selector(saveAction)),
            btn("checkmark", "Copy", #selector(copyAction))]
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        tb.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: tb.leadingAnchor), stack.trailingAnchor.constraint(equalTo: tb.trailingAnchor),
            stack.topAnchor.constraint(equalTo: tb.topAnchor), stack.bottomAnchor.constraint(equalTo: tb.bottomAnchor)])
        let size = stack.fittingSize
        tb.frame.size = size
        addSubview(tb)
        toolbar = tb
        placeToolbar()
        refreshTools()
        needsDisplay = true
    }

    func placeToolbar() {
        guard let tb = toolbar, let s = sel else { return }
        let w = tb.frame.width, h = tb.frame.height
        let x = max(8, min(s.maxX - w, bounds.width - w - 8))
        var y = s.minY - h - 8
        if y < 8 { y = s.maxY + 8 }
        if y + h > bounds.height - 8 { y = s.minY + 8 }
        tb.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func refreshTools() {
        for b in toolButtons { b.contentTintColor = b.tag == tool.rawValue ? .systemBlue : .labelColor }
    }

    @objc func pickTool(_ b: NSButton) { commitText(); tool = Tool(rawValue: b.tag) ?? .rect; refreshTools() }
    @objc func pickColor(_ w: NSColorWell) { color = w.color }
    @objc func undoAction() { undo() }
    @objc func closeAction() { onClose() }
    @objc func saveAction() { saveToFile(); onClose() }
    @objc func copyAction() { copyAndClose() }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast(); selected = nil; needsDisplay = true }
    }

    // MARK: output

    func rendered() -> NSBitmapImageRep? {
        commitText()
        guard let s = sel,
              let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s.width * pixelScale), pixelsHigh: Int(s.height * pixelScale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        bmp.size = s.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        let t = NSAffineTransform()
        t.translateX(by: -s.minX, yBy: -s.minY)
        t.concat()
        image.draw(in: bounds)
        annotations.forEach { renderAnnotation($0) }
        NSGraphicsContext.restoreGraphicsState()
        return bmp
    }

    func copyAndClose() {
        if let bmp = rendered() {
            copyToClipboard(bmp)
            NSSound(named: "Pop")?.play()
        }
        onClose()
    }

    func saveToFile() {
        guard let png = rendered()?.representation(using: .png, properties: [:]) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        try? png.write(to: saveDir.appendingPathComponent("Shot \(fmt.string(from: Date())).png"))
    }
}

enum Overlay {
    static var window: EditorWindow?
    static let escapeID: UInt32 = 99
    static var escRef: EventHotKeyRef?

    static func dismiss() { (window?.contentView as? OverlayView)?.onClose() }

    static func show(image: NSImage, screen: NSScreen, fullSelection: Bool) {
        guard window == nil else { return }
        let win = EditorWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.hasShadow = false
        win.isOpaque = true
        win.isReleasedWhenClosed = false
        win.setFrame(screen.frame, display: true)
        win.acceptsMouseMovedEvents = true
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        view.onClose = {
            if let r = escRef { UnregisterEventHotKey(r); escRef = nil }
            win.orderOut(nil)
            win.contentView = nil   // breaks win -> view -> onClose -> win, so the screenshot is freed
            window = nil
            NSCursor.arrow.set()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSCursor.arrow.set() }
            // hand freed screenshot pages back to the OS instead of letting the allocator sit on them
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
        win.contentView = view
        if fullSelection {
            view.sel = view.bounds
            view.beginEditing()
        }
        window = win
        // Safety nets so a full-screen overlay can never trap the user, even if it never gets key focus:
        // a global Esc hotkey (active only while the overlay is up), right-click, and a timeout before any selection.
        RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x53484F54, id: escapeID),
                            GetApplicationEventTarget(), 0, &escRef)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            if window === win, !view.editing { view.onClose() }
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSCursor.crosshair.set()
    }
}
