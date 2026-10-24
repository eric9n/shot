import AppKit

/// The picture inside a pinned window. Drag to move (hold Option and drag to take it into another app instead), scroll to
/// zoom, double-click or Esc to close, right-click for more.
final class PinView: NSView, NSDraggingSource {
    private var cg: CGImage?                     // the only copy of the picture; a bitmap is made just for copy and save
    private(set) var text: String?               // set instead of `cg` when the pin shows text
    private var label: NSTextField?
    private let storeButton = RoundButton(symbol: "tray.and.arrow.down.fill", tip: "Store in the stack", diameter: 24)
    private static let textFontSize: CGFloat = 16, textPadding: CGFloat = 16
    private var baseSize = NSSize.zero          // size when pinned; zoom is measured against it
    var onClose: () -> Void = {}
    // A hairline (one device pixel) in a mid gray: visible on white pages and on dark ones without looking like a frame.
    private static let normalBorder = NSColor(white: 0.5, alpha: 0.4).cgColor
    private static let normalBorderWidth: CGFloat = 0.5
    private static let cornerRadius: CGFloat = 10
    private var toast: NSView?                   // "Copied", shown briefly after a copy
    private var hideToast: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.contents = cg
        layer?.contentsGravity = .resize
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PinView.cornerRadius
        layer?.cornerCurve = .continuous        // the smooth corner macOS uses for its own windows
        layer?.masksToBounds = true
        layer?.borderWidth = PinView.normalBorderWidth
        layer?.borderColor = PinView.normalBorder

        // The store button sits at the top right and only shows while the pointer is over the pin.
        storeButton.target = self
        storeButton.action = #selector(storePin)
        storeButton.autoresizingMask = [.minXMargin, .minYMargin]
        storeButton.alphaValue = 0
        addSubview(storeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setStoreButton(visible: true) }
    override func mouseExited(with event: NSEvent) { setStoreButton(visible: false) }

    private func setStoreButton(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            storeButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Puts this pin in the stack and closes it. The stack window shows briefly if it was hidden, to show where it went.
    @objc func storePin() {
        guard let w = window else { return }
        var item: StackItem?
        if let t = text { item = StackStore.add(text: t, frame: w.frame) }
        else if let b = bitmap { item = StackStore.add(image: b, frame: w.frame) }
        guard item != nil else { NSSound.beep(); return }
        Session.report("stored")
        onClose()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The whole pin is one surface: clicks drag the window, they never reach the text inside.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        return storeButton.alphaValue > 0.5 && storeButton.frame.contains(p) ? storeButton : self
    }

    /// Text pins scale like pictures: font and padding grow with the window.
    override func layout() {
        super.layout()
        storeButton.setFrameOrigin(NSPoint(x: bounds.width - storeButton.frame.width - 8, y: bounds.height - storeButton.frame.height - 8))
        guard let label = label, baseSize.width > 0 else { return }
        let k = bounds.width / baseSize.width
        let font = NSFont.systemFont(ofSize: PinView.textFontSize * k)
        if label.font?.pointSize != font.pointSize { label.font = font }
        label.frame = bounds.insetBy(dx: PinView.textPadding * k, dy: PinView.textPadding * k)
    }

    /// Size the label needs for `text` wrapped to `width`, at `fontSize`. Measured with the same kind of cell the label
    /// draws with, so the line height matches what is drawn.
    static func measure(_ text: String, fontSize: CGFloat, width: CGFloat) -> NSSize {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = .systemFont(ofSize: fontSize)
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000))
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The window size for pinning `text`: black on white, wrapped at 560 points, cut off at `maxHeight`.
    static func textPinSize(_ text: String, maxHeight: CGFloat) -> NSSize {
        let pad = textPadding
        let width = min(560, measure(text, fontSize: textFontSize, width: 560 - 2 * pad).width + 2 * pad)
        let height = measure(text, fontSize: textFontSize, width: width - 2 * pad).height + 2 * pad
        return NSSize(width: width, height: min(height, maxHeight))
    }

    /// Shows text instead of a picture; `size` is the pinned size.
    func setText(_ string: String, size: NSSize) {
        text = string
        cg = nil
        baseSize = size
        layer?.contents = nil
        layer?.backgroundColor = NSColor.white.cgColor
        let l = NSTextField(wrappingLabelWithString: string)
        l.textColor = .black
        l.maximumNumberOfLines = 0
        l.cell?.truncatesLastVisibleLine = true
        l.isSelectable = false
        label?.removeFromSuperview()
        addSubview(l)
        label = l
        needsLayout = true
    }

    /// Shows a screenshot.
    func set(_ bmp: NSBitmapImageRep) {
        cg = bmp.cgImage
        baseSize = bmp.size
        layer?.contents = cg
        layer?.contentsGravity = .resize
    }

    /// A bitmap of the picture at its pinned size, for copy and save.
    var bitmap: NSBitmapImageRep? {
        guard let cg = cg else { return nil }
        let b = NSBitmapImageRep(cgImage: cg)
        b.size = baseSize
        return b
    }

    /// Scales the window around its center, clamped to 20%…500% of the pinned size and never larger than the screen
    /// (the window's surface grows with its area, so a 5x zoom of a big pin could take hundreds of MB).
    func zoom(factor: CGFloat) {
        guard let w = window, baseSize.width > 0, baseSize.height > 0 else { return }
        let screen = (w.screen ?? NSScreen.main)?.frame.size ?? NSSize(width: 100_000, height: 100_000)
        let maxWidth = max(min(baseSize.width * 5, screen.width, screen.height * baseSize.width / baseSize.height), baseSize.width * 0.2)
        let width = min(max(w.frame.width * factor, baseSize.width * 0.2), maxWidth)
        var height = width * baseSize.height / baseSize.width
        if let t = text {   // the text re-wraps at the new font size, so its height is measured, not scaled
            let k = width / baseSize.width, pad = PinView.textPadding * k
            height = min(PinView.measure(t, fontSize: PinView.textFontSize * k, width: width - 2 * pad).height + 2 * pad, screen.height)
        }
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(NSRect(x: c.x - width / 2, y: c.y - height / 2, width: width, height: height), display: true)
        w.invalidateShadow()
    }

    /// Back to the size it was pinned at.
    func resetZoom() {
        guard let w = window, baseSize.width > 0 else { return }
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(NSRect(x: c.x - baseSize.width / 2, y: c.y - baseSize.height / 2, width: baseSize.width, height: baseSize.height), display: true)
        w.invalidateShadow()
    }

    /// Scroll: a trackpad reports pixels, a mouse wheel reports lines, so a wheel notch counts for more. One event never
    /// changes the size by more than 10%.
    func zoom(byScroll delta: CGFloat, precise: Bool) {
        zoom(factor: max(0.9, min(1.1, 1 + delta * (precise ? 0.01 : 0.06))))
    }

    override func scrollWheel(with e: NSEvent) { zoom(byScroll: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas) }

    // Trackpad: pinch to zoom, two-finger double-tap (smart zoom) back to the pinned size.
    override func magnify(with e: NSEvent) { zoom(factor: 1 + e.magnification) }
    override func smartMagnify(with e: NSEvent) { resetZoom() }

    // Hold Option and drag: the pin's content goes into another app (a picture as a file, text as text, a link as a link),
    // and the pin stays where it is. Without Option, a drag moves the pin.
    private var optionDownAt: NSPoint?
    private(set) var dragOutStarted = false

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onClose(); return }
        if e.modifierFlags.contains(.option) {
            optionDownAt = e.locationInWindow
            dragOutStarted = false
            return
        }
        window?.performDrag(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let start = optionDownAt, !dragOutStarted, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 4 else { return }
        dragOutStarted = true
        beginDragOut(with: e)
    }

    override func mouseUp(with e: NSEvent) { optionDownAt = nil }

    /// What the pin gives to the app it is dropped on: a link as a link, other text as text, a picture as a file.
    func dragWriter() -> NSPasteboardWriting? {
        if let t = text {
            if StackStore.isLink(t), let url = URL(string: t) { return url as NSURL }
            return t as NSString
        }
        guard let bmp = bitmap, let url = Output.dragFile(bmp) else { return nil }
        return url as NSURL
    }

    private func beginDragOut(with e: NSEvent) {
        guard let writer = dragWriter() else { return }
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        if let rep = rep { cacheDisplay(in: bounds, to: rep) }
        let shrink = min(1, 180 / max(bounds.width, bounds.height))                     // a small preview follows the pointer
        let size = NSSize(width: bounds.width * shrink, height: bounds.height * shrink)
        let preview = NSImage(size: size)
        if let rep = rep { preview.addRepresentation(rep) }
        let here = convert(e.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(x: here.x - size.width / 2, y: here.y - size.height / 2, width: size.width, height: size.height), contents: preview)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onClose() }                                                     // Esc
        else if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "c" { copyPin() }
        else if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "s" { savePin() }
        else if e.charactersIgnoringModifiers == "+" || e.charactersIgnoringModifiers == "=" { zoom(factor: 1.1) }
        else if e.charactersIgnoringModifiers == "-" { zoom(factor: 1 / 1.1) }
        else if e.charactersIgnoringModifiers == "0" { resetZoom() }
        else { super.keyDown(with: e) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyPin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Save", action: #selector(savePin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Store in Stack", action: #selector(storePin), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "").target = self
        m.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "").target = self
        m.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self
        let opacity = NSMenu()
        for (title, value) in [("100%", 1.0), ("75%", 0.75), ("50%", 0.5), ("25%", 0.25)] {
            let item = NSMenuItem(title: title, action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs((window?.alphaValue ?? 1) - value) < 0.01 ? .on : .off
            opacity.addItem(item)
        }
        let parent = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        parent.submenu = opacity
        m.addItem(parent)
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close All Pins", action: #selector(closeAll), keyEquivalent: "").target = self
        return m
    }

    @objc func copyPin() {
        if let t = text { copyTextToClipboard(t) }
        else if let b = bitmap { copyToClipboard(b) }
        else { return }
        showCopied()
    }

    /// Confirms a copy: the border turns blue and "Copied" appears in the middle, then both fade back after a second.
    private func showCopied() {
        let box: NSView
        if let t = toast { box = t } else {
            let label = NSTextField(labelWithString: "Copied")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.sizeToFit()
            box = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 24, height: label.frame.height + 12))
            box.wantsLayer = true
            box.layer?.backgroundColor = Warm.ink.withAlphaComponent(0.78).cgColor
            box.layer?.cornerRadius = box.frame.height / 2      // a capsule
            label.setFrameOrigin(NSPoint(x: 12, y: 6))
            box.addSubview(label)
            addSubview(box)
            toast = box
        }
        box.setFrameOrigin(NSPoint(x: (bounds.width - box.frame.width) / 2, y: (bounds.height - box.frame.height) / 2))
        box.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]   // stays centered while zooming
        box.alphaValue = 1
        box.isHidden = false
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2

        hideToast?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.layer?.borderColor = PinView.normalBorder
            self.layer?.borderWidth = PinView.normalBorderWidth
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                box.animator().alphaValue = 0
            }, completionHandler: {
                if box.alphaValue == 0 { box.isHidden = true }   // a newer copy may have shown it again
            })
        }
        hideToast = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    @objc func savePin() {
        if let t = text { Output.writeText(t) } else if let b = bitmap { Output.write(b) }
    }
    @objc func zoomIn() { zoom(factor: 1.25) }
    @objc func zoomOut() { zoom(factor: 0.8) }
    @objc func actualSize() { resetZoom() }
    @objc func setOpacity(_ item: NSMenuItem) { window?.alphaValue = CGFloat(item.representedObject as? Double ?? 1) }
    @objc func closePin() { onClose() }
    @objc func closeAll() { Pins.closeAll() }
}

final class PinWindow: NSWindow {
    let pinView = PinView()
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // stays put when you switch Spaces
        contentView = pinView
        pinView.onClose = { [unowned self] in Pins.release(self) }
    }
}

/// All pinned screenshots in this capture process. When the last one closes, the process exits.
enum Pins {
    static var active: [PinWindow] = []

    /// Pins `bmp` as a floating window with the given frame (in screen coordinates).
    @discardableResult
    static func pin(_ bmp: NSBitmapImageRep, frame: NSRect) -> PinWindow {
        let w = PinWindow()
        w.setFrame(frame, display: false)
        w.pinView.set(bmp)
        return show(w)
    }

    /// Pins text as a floating window with the given frame.
    @discardableResult
    static func pin(text: String, frame: NSRect) -> PinWindow {
        let w = PinWindow()
        w.setFrame(frame, display: false)
        w.pinView.setText(text, size: frame.size)
        return show(w)
    }

    /// Pins text centered on `center` (screen coordinates), moved if need be so that it is wholly on that screen.
    @discardableResult
    static func pin(text: String, around center: CGPoint) -> PinWindow {
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let text = String(text.prefix(5000))
        let size = PinView.textPinSize(text, maxHeight: v.height - 80)
        let w = min(size.width, v.width), h = min(size.height, v.height)
        let frame = NSRect(x: min(max(center.x - w / 2, v.minX), v.maxX - w), y: min(max(center.y - h / 2, v.minY), v.maxY - h), width: w, height: h)
        return pin(text: text, frame: frame)
    }

    private static func show(_ w: PinWindow) -> PinWindow {
        active.append(w)
        w.orderFrontRegardless()
        w.makeKey()
        w.invalidateShadow()
        return w
    }

    /// Pins what is on the clipboard, centered on the screen under the cursor: a picture at its own size, or text in a
    /// small white card. Anything bigger than the screen is shrunk (pictures) or cut off (text) to fit.
    /// Returns false if the clipboard holds neither.
    @discardableResult
    static func pinClipboard() -> Bool {
        let pb = NSPasteboard.general
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let room = screen.visibleFrame.insetBy(dx: 40, dy: 40).size
        func centered(_ size: NSSize) -> NSRect {
            NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        }
        let w: PinWindow
        if let bmp = (pb.data(forType: .png) ?? pb.data(forType: .tiff)).flatMap({ NSBitmapImageRep(data: $0) }),
           bmp.size.width > 0, bmp.size.height > 0 {
            let fit = min(1, room.width / bmp.size.width, room.height / bmp.size.height)
            let size = NSSize(width: (bmp.size.width * fit).rounded(), height: (bmp.size.height * fit).rounded())
            bmp.size = size                 // the pinned size is also the "actual size" zoom returns to
            w = pin(bmp, frame: centered(size))
        } else if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let text = String(text.prefix(5000))
            w = pin(text: text, frame: centered(PinView.textPinSize(text, maxHeight: room.height)))
        } else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// Puts a stored item back on the screen where it was (moved onto the screen if that place is gone), then takes it out
    /// of the stack. Returns false if the item is gone.
    @discardableResult
    static func pinItem(id: String) -> Bool {
        guard let item = StackStore.item(id: id) else { return false }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(item.frame) }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        func placed(_ size: NSSize, around center: CGPoint) -> NSRect {
            let w = min(size.width, visible.width), h = min(size.height, visible.height)
            return NSRect(x: min(max(center.x - w / 2, visible.minX), visible.maxX - w),
                          y: min(max(center.y - h / 2, visible.minY), visible.maxY - h), width: w, height: h)
        }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let w: PinWindow
        if item.kind == .image {
            guard let bmp = (try? Data(contentsOf: StackStore.contentURL(item))).flatMap({ NSBitmapImageRep(data: $0) }) else { return false }
            let frame = placed(item.frame.size, around: center)
            bmp.size = frame.size
            w = pin(bmp, frame: frame)
        } else {
            guard let text = StackStore.text(of: item) else { return false }
            w = pin(text: text, frame: placed(PinView.textPinSize(text, maxHeight: visible.height - 80), around: center))
        }
        StackStore.remove(id)
        Session.report("stack-changed")
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return true
    }

    static func release(_ w: PinWindow) {
        guard active.contains(where: { $0 === w }) else { return }
        w.close()
        active.removeAll { $0 === w }
        if active.isEmpty { Session.pinsClosed() }
    }

    static func closeAll() { active.forEach { release($0) } }
}
