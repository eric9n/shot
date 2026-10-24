import AppKit

/// Full-screen frozen-screenshot overlay: drag to select, annotate in place.
final class OverlayView: NSView, NSTextViewDelegate {
    var sel: NSRect?
    var editing = false
    var dragStart: CGPoint?
    var annotations: [Annotation] = []
    var current: Annotation?
    var tool: Tool = .rect
    var color: NSColor = .systemRed
    var sizeLevel = 1                  // 0 thin, 1 medium, 2 thick: applies to what you draw next (and to the selected one when changed)
    var style = 0                      // 0 solid, 1 dashed, 2 filled
    var textLevel = 1                  // size level the text being typed started with
    var redoStack: [Annotation] = []   // annotations removed by undo, restored by redo until something new is drawn
    var sizeControl: NSSegmentedControl?
    var styleControl: NSPopUpButton?
    var field: NSTextView?
    var textStack: AnnotationRenderer.TextLayout?   // keeps the editor's storage alive while typing
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
    var mosaicMap: NSBitmapImageRep?       // whole screen at one pixel per mosaic block
    var annoView: AnnotationView!

    init(frame: NSRect, scale: CGFloat) {
        backdrop = Backdrop(frame: NSRect(origin: .zero, size: frame.size), scale: scale)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(backdrop)
        annoView = AnnotationView(owner: self)
        annoView.isHidden = true
        addSubview(annoView)
    }

    /// Loads the screenshot.
    func begin(cg: CGImage, size: NSSize, windows: [NSRect]) {
        mosaicMap = OverlayView.makeMosaicMap(cg: cg, size: size)
        pixelsWide = cg.width
        backdrop.setImage(cg)
        windowRects = windows
        syncChrome()
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

    /// Shrinks the screenshot to one pixel per block, once per capture, so drawing a mosaic is just stretching this map.
    static func makeMosaicMap(cg: CGImage, size: NSSize) -> NSBitmapImageRep {
        let cols = Int(ceil(size.width / AnnotationRenderer.mosaicBlock)), rows = Int(ceil(size.height / AnnotationRenderer.mosaicBlock))
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
        AnnotationRenderer.render(a, mosaic: mosaicMap)
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
        if tool == .number {
            // Next number = highest one on the canvas + 1, so undo and delete behave naturally.
            let n = (annotations.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
            add(Annotation(tool: .number, points: [p], color: color, text: "\(n)", level: sizeLevel, style: style))
            selected = annotations.count - 1
            dragLast = p                      // dragging right after the click nudges the marker into place
            NSCursor.closedHand.set()
            syncChrome()
            return
        }
        current = Annotation(tool: tool, points: [p], color: color, level: sizeLevel, style: style)
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
        if tool == .pen || tool == .highlighter {
            if e.modifierFlags.contains(.shift) {
                // Holding ⇧ gives a straight line, locked to horizontal or vertical (whichever way you moved more).
                let start = current!.points[0]
                let end = abs(q.x - start.x) >= abs(q.y - start.y) ? CGPoint(x: q.x, y: start.y) : CGPoint(x: start.x, y: q.y)
                current!.points = [start, end]
            } else {
                current!.points.append(q)
            }
        } else {
            current!.points = [current!.points[0], q]
        }
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
        if let c = current, c.points.count > 1 { add(c) }
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
        case 53: escape()
        case 36 where editing: copyAndClose()
        case 35 where editing && e.modifierFlags.intersection([.command, .control, .option]).isEmpty:   // P: pin
            pinAction()
        case 17 where editing && e.modifierFlags.intersection([.command, .control, .option]).isEmpty:   // T: copy text
            ocrAction()
        case 51, 117:
            if let i = selected, annotations.indices.contains(i) { annotations.remove(at: i); selected = nil; syncChrome() }
        case 123...126 where editing:   // ← → ↓ ↑ ; ⇧ moves 10 points instead of 1
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            nudge(dx: e.keyCode == 123 ? -step : e.keyCode == 124 ? step : 0, dy: e.keyCode == 125 ? -step : e.keyCode == 126 ? step : 0)
        default:
            let key = e.charactersIgnoringModifiers?.lowercased()
            if e.modifierFlags.contains(.command), key == "z" {
                if e.modifierFlags.contains(.shift) { redo() } else { undo() }
            } else {
                super.keyDown(with: e)
            }
        }
    }

    // MARK: text

    func beginText(at p: CGPoint) {
        textLevel = sizeLevel
        let font = AnnotationRenderer.textFont(textLevel)
        let top = p.y + font.boundingRectForFont.height / 2   // the click lands mid-first-line
        // Built on an explicit TextKit 1 stack (the same one AnnotationRenderer draws with), not the default one.
        let stack = AnnotationRenderer.TextLayout("", color: color, level: textLevel)
        let t = NSTextView(frame: NSRect(x: p.x, y: top - 24, width: 24, height: 24), textContainer: stack.container)
        textStack = stack
        t.font = font
        t.textColor = color
        t.insertionPointColor = color
        t.drawsBackground = false
        t.isRichText = false
        t.textContainerInset = .zero
        t.textContainer?.widthTracksTextView = false
        t.isHorizontallyResizable = true
        t.isVerticallyResizable = true
        t.delegate = self
        addSubview(t)
        window?.makeFirstResponder(t)
        field = t
        fitEditor()
    }

    /// Grows the editor to fit its text, keeping the top-left corner fixed.
    func fitEditor() {
        guard let t = field else { return }
        let size = AnnotationRenderer.textSize(t.string.isEmpty ? " " : t.string, level: textLevel)
        t.frame = NSRect(x: t.frame.minX, y: t.frame.maxY - size.height, width: max(size.width, 12) + 4, height: size.height)
    }

    func textDidChange(_ notification: Notification) { fitEditor() }

    /// Return starts a new line; ⌘Return (or Esc, a click elsewhere, picking another tool) finishes the text.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            commitText()
            return true
        }
        return false
    }

    @objc func commitText() {
        guard let t = field else { return }
        field = nil
        let text = t.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            add(Annotation(tool: .text, points: [CGPoint(x: t.frame.minX, y: t.frame.maxY)],
                           color: t.textColor ?? color, text: text, level: textLevel))
        }
        t.delegate = nil
        t.removeFromSuperview()
        textStack = nil
        window?.makeFirstResponder(self)
        syncChrome()
    }

    /// Esc: finish the text being typed, otherwise close the overlay.
    func escape() {
        if field != nil { commitText() } else { onClose() }
    }

    // MARK: toolbar

    func beginEditing() {
        editing = true
        tool = .move   // after framing, the first thing you usually want is to nudge the selection
        let tb = NSView()
        tb.wantsLayer = true
        tb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        tb.layer?.cornerRadius = 10

        func btn(_ symbol: String, _ fallback: String, _ sel: Selector, tag: Int = 0, tip: String? = nil) -> NSButton {
            let b = NSButton()
            b.toolTip = tip
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
            ("arrow.up.right", "Arrow", .arrow), ("pencil", "Pen", .pen), ("highlighter", "Highlight", .highlighter),
            ("checkerboard.rectangle", "Mosaic", .mosaic), ("textformat", "Text", .text),
            ("1.circle", "Number", .number)]
        toolButtons = tools.map { btn($0.0, $0.1, #selector(pickTool(_:)), tag: $0.2.rawValue) }

        let well = NSColorWell(style: .minimal)
        well.color = color
        well.target = self
        well.action = #selector(pickColor(_:))
        well.widthAnchor.constraint(equalToConstant: 28).isActive = true
        well.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let sizePicker = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: self, action: #selector(pickSize(_:)))
        sizePicker.selectedSegment = sizeLevel
        sizePicker.controlSize = .small
        sizeControl = sizePicker

        let styleMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        styleMenu.addItems(withTitles: ["Solid", "Dashed", "Filled"])
        styleMenu.selectItem(at: style)
        styleMenu.controlSize = .small
        styleMenu.target = self
        styleMenu.action = #selector(pickStyle(_:))
        styleControl = styleMenu

        // Drag this into another app to drop the screenshot there as a file. The overlay covers the whole screen, so it
        // turns see-through and click-through while the drag is in flight; if nothing takes the drop it comes back.
        let dragHandle = DragHandle()
        dragHandle.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Drag out")
        dragHandle.isBordered = false
        dragHandle.contentTintColor = .labelColor
        dragHandle.toolTip = "Drag into another app"
        dragHandle.widthAnchor.constraint(equalToConstant: 30).isActive = true
        dragHandle.heightAnchor.constraint(equalToConstant: 30).isActive = true
        dragHandle.makeFile = { [weak self] in self?.makeDragFile() }
        dragHandle.onBegan = { [weak self] in
            self?.window?.alphaValue = 0
            self?.window?.ignoresMouseEvents = true
        }
        dragHandle.onEnded = { [weak self] dropped in
            guard let self = self else { return }
            if dropped { self.onClose() } else {
                self.window?.alphaValue = 1
                self.window?.ignoresMouseEvents = false
            }
        }

        let views: [NSView] = toolButtons + [well, sizePicker, styleMenu,
            btn("arrow.uturn.backward", "Undo", #selector(undoAction)),
            btn("arrow.uturn.forward", "Redo", #selector(redoAction)),
            btn("pin", "Pin", #selector(pinAction)),
            btn("text.viewfinder", "Text", #selector(ocrAction), tip: "Copy the text in the selection (T)"),
            dragHandle,
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
    @objc func redoAction() { redo() }

    /// Sets the size for what you draw next, and changes the selected annotation too if there is one.
    @objc func pickSize(_ c: NSSegmentedControl) {
        sizeLevel = c.selectedSegment
        if let i = selected, annotations.indices.contains(i) { annotations[i].level = sizeLevel; syncChrome() }
    }

    @objc func pickStyle(_ p: NSPopUpButton) {
        style = p.indexOfSelectedItem
        if let i = selected, annotations.indices.contains(i) { annotations[i].style = style; syncChrome() }
    }
    @objc func closeAction() { onClose() }
    @objc func saveAction() { saveToFile(); onClose() }

    /// Turns the selection (with its annotations) into a floating window right where it is on screen.
    @objc func pinAction() {
        guard let s = sel, let w = window, let bmp = rendered() else { return }
        Pins.pin(bmp, frame: s.offsetBy(dx: w.frame.minX, dy: w.frame.minY))
        onClose()
    }
    @objc func copyAction() { copyAndClose() }

    /// Adds a finished annotation. Drawing something new ends the redo history.
    func add(_ a: Annotation) {
        annotations.append(a)
        redoStack = []
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        selected = nil
        syncChrome()
    }

    func redo() {
        guard let a = redoStack.popLast() else { return }
        annotations.append(a)
        syncChrome()
    }

    /// Arrow keys: nudge the selected annotation, or the selection itself when no annotation is selected.
    func nudge(dx: CGFloat, dy: CGFloat) {
        if let i = selected, annotations.indices.contains(i) {
            annotations[i].points = annotations[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        } else if editing, var r = sel {
            r.origin.x = min(max(r.origin.x + dx, 0), bounds.width - r.width)
            r.origin.y = min(max(r.origin.y + dy, 0), bounds.height - r.height)
            sel = r
            placeToolbar()
        } else {
            return
        }
        syncChrome()
    }

    // MARK: output

    /// The selected part of the screenshot, without annotations.
    func selectionCrop() -> CGImage? {
        guard let s = sel, let cg = backdrop.cg else { return nil }
        let sx = CGFloat(cg.width) / bounds.width, sy = CGFloat(cg.height) / bounds.height
        return cg.cropping(to: CGRect(x: s.minX * sx, y: (bounds.height - s.maxY) * sy, width: s.width * sx, height: s.height * sy).integral)
    }

    private var recognizing = false
    private var statusBox: NSView?
    private var statusLabel: NSTextField?
    private var statusHide: DispatchWorkItem?

    /// A small message in the middle of the selection ("Recognizing text…"). Stays until replaced, or hides itself after
    /// `hideAfter` seconds.
    func showStatus(_ text: String, hideAfter: TimeInterval? = nil) {
        guard let s = sel else { return }
        if statusBox == nil {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = .white
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            box.layer?.cornerRadius = 8
            box.addSubview(label)
            addSubview(box)
            statusBox = box
            statusLabel = label
        }
        guard let box = statusBox, let label = statusLabel else { return }
        label.stringValue = text
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 14, y: 8))
        box.frame = NSRect(x: 0, y: 0, width: label.frame.width + 28, height: label.frame.height + 16)
        box.setFrameOrigin(NSPoint(x: s.midX - box.frame.width / 2, y: s.midY - box.frame.height / 2))
        box.isHidden = false
        statusHide?.cancel()
        if let t = hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.statusBox?.isHidden = true }
            statusHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
        }
    }

    /// Reads the text in the selection (the screenshot itself, not the annotations), copies it, and closes.
    /// The first use after a restart can take several seconds while the system prepares its text model, so a message
    /// shows meanwhile. With no text found, the overlay stays so you can pick another area.
    @objc func ocrAction() {
        commitText()
        guard !recognizing, let crop = selectionCrop() else { return }
        recognizing = true
        lastRegion = sel
        showStatus("Recognizing text…")
        Ocr.recognize(crop) { [weak self] text in
            guard let self = self else { return }
            self.recognizing = false
            if text.isEmpty { self.showStatus("No text found", hideAfter: 1.5); return }
            copyTextToClipboard(text)
            self.onClose()
        }
    }

    func rendered() -> NSBitmapImageRep? {
        commitText()
        guard let s = sel,
              let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s.width * pixelScale), pixelsHigh: Int(s.height * pixelScale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        lastRegion = s   // remembered for "Repeat Last Region"
        bmp.size = s.size
        // Draw only the selected pixels (cropping shares the screenshot's memory) instead of the whole screen clipped
        // to the selection; this keeps the short peak during export a few MB lower.
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: bmp)
        NSGraphicsContext.current = ctx
        if let part = selectionCrop() { ctx?.cgContext.draw(part, in: CGRect(origin: .zero, size: s.size)) }
        let t = NSAffineTransform()
        t.translateX(by: -s.minX, yBy: -s.minY)
        t.concat()
        annotations.forEach { renderAnnotation($0) }
        NSGraphicsContext.restoreGraphicsState()
        return bmp
    }

    func copyAndClose() {
        if let bmp = rendered() {
            copyToClipboard(bmp)
        }
        onClose()
    }

    func saveToFile() {
        if let bmp = rendered() { Output.write(bmp) }
    }

    /// For the drag handle: writes the screenshot to a temporary file (chosen format and name) and returns it.
    func makeDragFile() -> URL? {
        guard let bmp = rendered() else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Shot-drag", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)   // earlier drag files are no longer needed
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Output.write(bmp, to: dir)
    }
}
