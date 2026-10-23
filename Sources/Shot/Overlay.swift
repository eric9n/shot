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

/// The eight grab points around the selection (AppKit coordinates: y grows upward, so "top" is maxY).
enum Handle: CaseIterable {
    case tl, t, tr, r, br, b, bl, l

    func point(in r: NSRect) -> CGPoint {
        switch self {
        case .tl: return CGPoint(x: r.minX, y: r.maxY)
        case .t: return CGPoint(x: r.midX, y: r.maxY)
        case .tr: return CGPoint(x: r.maxX, y: r.maxY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.minY)
        case .b: return CGPoint(x: r.midX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.minY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }
    var movesLeft: Bool { self == .tl || self == .l || self == .bl }
    var movesRight: Bool { self == .tr || self == .r || self == .br }
    var movesTop: Bool { self == .tl || self == .t || self == .tr }
    var movesBottom: Bool { self == .bl || self == .b || self == .br }

    var cursor: NSCursor {
        switch self {
        case .l, .r: return .resizeLeftRight
        case .t, .b: return .resizeUpDown
        default:
            if #available(macOS 15, *) {
                let pos: NSCursor.FrameResizePosition = self == .tl ? .topLeft : self == .tr ? .topRight : self == .bl ? .bottomLeft : .bottomRight
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        }
    }
}

/// Shows the screenshot by pointing a layer at the CGImage (no copy, no backing store of its own),
/// plus the dim/border/size-label chrome as lightweight shape layers.
final class Backdrop: NSView {
    private(set) var cg: CGImage?
    // Solid-color layers need no backing store (a full-screen shape layer would rasterize ~20 MB).
    let dimBands = (0..<4).map { _ in CALayer() }   // bottom, top, left, right of the selection
    let border = CALayer()
    let labelBox = CALayer()
    let labelText = CATextLayer()
    let handleLayers = Handle.allCases.map { _ in CALayer() }

    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        dimBands.forEach { $0.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor }
        border.borderColor = NSColor.systemBlue.cgColor
        border.borderWidth = 1.5
        labelBox.backgroundColor = NSColor.systemBlue.cgColor
        labelBox.cornerRadius = 4
        labelText.fontSize = 12
        labelText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.contentsScale = scale
        labelBox.addSublayer(labelText)
        for h in handleLayers {
            h.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            h.backgroundColor = NSColor.white.cgColor
            h.borderColor = NSColor.systemBlue.cgColor
            h.borderWidth = 1.5
        }
        (dimBands + [border, labelBox] + handleLayers).forEach { layer?.addSublayer($0) }
        update(sel: nil, label: "", handles: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.contents = cg
        layer?.contentsGravity = .resize
    }

    /// Points the layer at a screenshot, or at nothing (nil) to release it.
    func setImage(_ image: CGImage?) {
        cg = image
        layer?.contents = image
        layer?.contentsGravity = .resize
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(sel: NSRect?, label: String, handles: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let s = sel {                                // dim everything except the selection
            dimBands[0].frame = CGRect(x: 0, y: 0, width: bounds.width, height: s.minY)
            dimBands[1].frame = CGRect(x: 0, y: s.maxY, width: bounds.width, height: bounds.height - s.maxY)
            dimBands[2].frame = CGRect(x: 0, y: s.minY, width: s.minX, height: s.height)
            dimBands[3].frame = CGRect(x: s.maxX, y: s.minY, width: bounds.width - s.maxX, height: s.height)
            border.frame = s.insetBy(dx: -1.5, dy: -1.5)
        } else {
            dimBands[0].frame = bounds
            for b in dimBands.dropFirst() { b.frame = .zero }
        }
        border.isHidden = sel == nil
        for (h, l) in zip(Handle.allCases, handleLayers) {
            l.isHidden = !(handles && sel != nil)
            if let s = sel { l.position = h.point(in: s) }
        }
        labelBox.isHidden = sel == nil
        if let s = sel {
            let sz = (label as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            var box = NSRect(x: s.minX, y: s.maxY + 6, width: sz.width + 16, height: sz.height + 6)
            if box.maxY > bounds.maxY { box.origin.y = s.maxY - box.height - 4; box.origin.x += 4 }
            labelBox.frame = box
            labelText.frame = CGRect(x: 8, y: 3, width: sz.width + 4, height: sz.height)
            labelText.string = label
        }
        CATransaction.commit()
    }
}

/// Draws the annotations; sized to the selection only, so its backing store stays small.
final class AnnotationView: NSView {
    unowned let owner: OverlayView
    init(owner: OverlayView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ r: NSRect) {
        let t = NSAffineTransform()
        t.translateX(by: -frame.minX, yBy: -frame.minY)   // annotations live in overlay coordinates
        t.concat()
        owner.annotations.forEach { owner.renderAnnotation($0) }
        if let c = owner.current { owner.renderAnnotation(c) }
        if let i = owner.selected, owner.annotations.indices.contains(i) {
            let box = NSBezierPath(rect: owner.annotations[i].bounds.insetBy(dx: -5, dy: -5))
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            box.stroke()
        }
    }
}

/// Full-screen frozen-screenshot overlay: drag to select, annotate in place.
final class OverlayView: NSView, NSTextFieldDelegate {
    var image = NSImage(size: .zero)
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
    var windowRects: [NSRect] = []   // Capture Window: clickable window frames, front to back
    var hover: NSRect?               // window under the cursor, highlighted until you click or drag
    var resizing: Handle?            // set while a selection handle is being dragged
    var resizeBase = NSRect.zero
    var resizeFrom = CGPoint.zero

    var pixelsWide = 1   // real pixel width of the screenshot (NSImage reports it unreliably)

    let backdrop: Backdrop
    var mosaicMap = OverlayView.blankMap   // whole screen at one pixel per mosaic block, built per capture
    var annoView: AnnotationView!

    /// AppKit in this OS keeps every NSView it ever created alive (a notification observer retains it), and a view
    /// holds its screenshot. So there is exactly one OverlayView; each capture loads into it and `end()` empties it.
    init(frame: NSRect, scale: CGFloat) {
        backdrop = Backdrop(frame: NSRect(origin: .zero, size: frame.size), scale: scale)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(backdrop)
        annoView = AnnotationView(owner: self)
        annoView.isHidden = true
        addSubview(annoView)
    }

    static let blankMap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    /// Starts a capture session in this (reused) view.
    func begin(cg: CGImage, size: NSSize, windows: [NSRect]) {
        setFrameSize(size)
        backdrop.frame = NSRect(origin: .zero, size: size)
        mosaicMap = OverlayView.makeMosaicMap(cg: cg, size: size)
        image = NSImage(cgImage: cg, size: size)   // wraps the same CGImage, no copy
        pixelsWide = cg.width
        backdrop.setImage(cg)
        reset()
        windowRects = windows
        syncChrome()
    }

    /// Ends the session and lets go of the screenshot.
    func end() {
        commitText()
        backdrop.setImage(nil)
        image = NSImage(size: .zero)
        mosaicMap = OverlayView.blankMap
        pixelsWide = 1
        reset()
        toolbar?.isHidden = true
        annoView.isHidden = true
    }

    private func reset() {
        sel = nil
        editing = false
        dragStart = nil
        annotations = []
        current = nil
        tool = .rect
        selected = nil
        dragLast = nil
        moveLast = nil
        resizing = nil
        hover = nil
        windowRects = []
        field?.removeFromSuperview()
        field = nil
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}   // nothing to draw: the layers do the work, so no full-screen backing store

    /// Refreshes the layers after any state change (the view draws nothing itself, so needsDisplay can't be relied on).
    func syncChrome() {
        guard annoView != nil, backdrop.superview != nil else { return }
        let shown = sel ?? (editing ? nil : hover)
        let label = shown.map { "\(Int($0.width * pixelScale)) x \(Int($0.height * pixelScale))" } ?? ""
        backdrop.update(sel: shown, label: label, handles: editing && sel != nil)
        annoView.isHidden = sel == nil || !editing
        if let s = sel { annoView.frame = s }
        annoView.needsDisplay = true
    }

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
        else if let h = resizing ?? handle(at: p) { h.cursor.set() }
        else if moveLast != nil { NSCursor.closedHand.set() }
        else if editing, tool == .move, sel?.contains(p) == true { NSCursor.openHand.set() }
        else if dragLast != nil { NSCursor.closedHand.set() }
        else if editing, annotationIndex(at: p) != nil { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }

    /// The selection handle under the point, once the selection is fixed.
    func handle(at p: CGPoint) -> Handle? {
        guard editing, let s = sel else { return nil }
        return Handle.allCases.first { hypot($0.point(in: s).x - p.x, $0.point(in: s).y - p.y) <= 9 }
    }

    func updateHover(at p: CGPoint) {
        guard !editing, dragStart == nil, !windowRects.isEmpty else { return }
        let h = windowRects.first { $0.contains(p) }
        if h != hover { hover = h; syncChrome() }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        updateHover(at: p)
        updateCursor(at: p)
    }
    override func cursorUpdate(with e: NSEvent) { updateCursor(at: convert(e.locationInWindow, from: nil)) }

    /// Shrinks the screenshot to one pixel per block. Done before the layer takes the image: reading the pixels
    /// again later makes the system rebuild a full-size copy.
    static func makeMosaicMap(cg: CGImage, size: NSSize) -> NSBitmapImageRep {
        let cols = Int(ceil(size.width / Canvas.mosaicBlock)), rows = Int(ceil(size.height / Canvas.mosaicBlock))
        let map = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols, pixelsHigh: rows, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        if let ctx = NSGraphicsContext(bitmapImageRep: map) {
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        }
        return map
    }

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

    func renderAnnotation(_ a: Annotation) {
        Canvas.render(a, mosaic: mosaicMap)
    }

    var pixelScale: CGFloat { CGFloat(pixelsWide) / bounds.width }

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
        if let h = handle(at: p), let s = sel {
            resizing = h
            resizeBase = s
            resizeFrom = p
            selected = nil
            h.cursor.set()
            syncChrome()
            return
        }
        guard let s = sel, s.contains(p) else { selected = nil; syncChrome(); return }
        if tool == .move {
            selected = nil
            moveLast = p
            NSCursor.closedHand.set()
            syncChrome()
            return
        }
        if let i = annotationIndex(at: p) {
            selected = i
            dragLast = p
            NSCursor.closedHand.set()
            syncChrome()
            return
        }
        selected = nil
        syncChrome()
        if tool == .text { beginText(at: p); return }
        current = Annotation(tool: tool, points: [p], color: color)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !editing, let a = dragStart {
            hover = nil
            sel = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
            syncChrome()
            return
        }
        if let h = resizing {
            let dx = p.x - resizeFrom.x, dy = p.y - resizeFrom.y
            let b = resizeBase, minSize: CGFloat = 20
            var r = b
            if h.movesLeft { let x = min(max(b.minX + dx, 0), b.maxX - minSize); r.origin.x = x; r.size.width = b.maxX - x }
            if h.movesRight { r.size.width = min(max(b.width + dx, minSize), bounds.width - b.minX) }
            if h.movesBottom { let y = min(max(b.minY + dy, 0), b.maxY - minSize); r.origin.y = y; r.size.height = b.maxY - y }
            if h.movesTop { r.size.height = min(max(b.height + dy, minSize), bounds.height - b.minY) }
            sel = r
            placeToolbar()
            syncChrome()
            return
        }
        if let last = moveLast, let s = sel {
            var r = s.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)     // keep the selection on screen
            r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
            moveLast = CGPoint(x: last.x + (r.minX - s.minX), y: last.y + (r.minY - s.minY))
            sel = r
            placeToolbar()
            syncChrome()
            return
        }
        if let last = dragLast, let i = selected, annotations.indices.contains(i) {
            let dx = p.x - last.x, dy = p.y - last.y
            annotations[i].points = annotations[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            dragLast = p
            syncChrome()
            return
        }
        guard current != nil else { return }
        let q = clamp(p)
        if tool == .pen { current!.points.append(q) } else { current!.points = [current!.points[0], q] }
        syncChrome()
    }

    override func mouseUp(with e: NSEvent) {
        if !editing {
            dragStart = nil
            if let s = sel, s.width > 4, s.height > 4 { beginEditing() }
            else if sel == nil, let h = hover { sel = h; hover = nil; beginEditing() }   // plain click on a window
            else { sel = nil; syncChrome() }
            return
        }
        if resizing != nil {
            resizing = nil
            updateCursor(at: convert(e.locationInWindow, from: nil))
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
        syncChrome()
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
            if let i = selected, annotations.indices.contains(i) { annotations.remove(at: i); selected = nil; syncChrome() }
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
        syncChrome()
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    // MARK: toolbar

    func beginEditing() {
        editing = true
        tool = .move   // after framing, the first thing you usually want is to nudge the selection
        if let tb = toolbar {   // built once, reused by later captures
            tb.isHidden = false
            placeToolbar()
            refreshTools()
            syncChrome()
            return
        }
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
        syncChrome()
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
        if !annotations.isEmpty { annotations.removeLast(); selected = nil; syncChrome() }
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
    static var window: EditorWindow?       // the overlay currently on screen, nil when idle
    /// The one overlay window, reused for every capture. AppKit never fully releases windows that were created and
    /// closed repeatedly (each kept its screenshot alive, ~22 MB per capture), so we never create a second one.
    static var spare: EditorWindow?
    static var view: OverlayView?           // the one overlay view, see OverlayView.init
    static var generation = 0               // lets a stale timeout tell it belongs to an earlier capture
    static let escapeID: UInt32 = 99
    static var escRef: EventHotKeyRef?

    static func dismiss() { (window?.contentView as? OverlayView)?.onClose() }

    static func show(cg: CGImage, screen: NSScreen, fullSelection: Bool, windows: [NSRect] = []) {
        guard window == nil else { return }
        let win: EditorWindow
        if let w = spare {
            win = w
        } else {
            win = EditorWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.level = .screenSaver
            win.hasShadow = false
            win.isOpaque = true
            win.isReleasedWhenClosed = false
            win.acceptsMouseMovedEvents = true
            spare = win
        }
        win.setFrame(screen.frame, display: false)
        generation += 1
        let gen = generation
        let view: OverlayView
        if let v = Overlay.view {
            view = v
        } else {
            view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
            Overlay.view = view
            win.contentView = view
        }
        view.begin(cg: cg, size: screen.frame.size, windows: windows)
        view.onClose = {
            if let r = escRef { UnregisterEventHotKey(r); escRef = nil }
            view.end()              // releases the screenshot
            win.orderOut(nil)
            window = nil
            NSCursor.arrow.set()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSCursor.arrow.set() }
            // hand freed screenshot pages back to the OS instead of letting the allocator sit on them
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
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
            if gen == generation, window != nil, !view.editing { view.onClose() }
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSCursor.crosshair.set()
        if !windows.isEmpty {   // highlight the window already under the cursor
            let m = NSEvent.mouseLocation
            view.updateHover(at: CGPoint(x: m.x - screen.frame.minX, y: m.y - screen.frame.minY))
        }
    }
}
