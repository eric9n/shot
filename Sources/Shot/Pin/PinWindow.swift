import AppKit

/// The picture inside a pinned window. Drag to move, scroll to zoom, double-click or Esc to close, right-click for more.
final class PinView: NSView {
    private var cg: CGImage?                     // the only copy of the picture; a bitmap is made just for copy and save
    private(set) var text: String?               // set instead of `cg` when the pin shows text
    private var label: NSTextField?
    private static let textFontSize: CGFloat = 16, textPadding: CGFloat = 16
    private var baseSize = NSSize.zero          // size when pinned; zoom is measured against it
    var onClose: () -> Void = {}
    private static let normalBorder = NSColor.black.withAlphaComponent(0.25).cgColor   // keeps the edge visible over white pages
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
        layer?.borderWidth = 1
        layer?.borderColor = PinView.normalBorder
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The whole pin is one surface: clicks drag the window, they never reach the text inside.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    /// Text pins scale like pictures: font and padding grow with the window.
    override func layout() {
        super.layout()
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
    }

    /// Back to the size it was pinned at.
    func resetZoom() {
        guard let w = window, baseSize.width > 0 else { return }
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(NSRect(x: c.x - baseSize.width / 2, y: c.y - baseSize.height / 2, width: baseSize.width, height: baseSize.height), display: true)
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

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onClose() } else { window?.performDrag(with: e) }
    }

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
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            box.layer?.cornerRadius = 8
            label.setFrameOrigin(NSPoint(x: 12, y: 6))
            box.addSubview(label)
            addSubview(box)
            toast = box
        }
        box.setFrameOrigin(NSPoint(x: (bounds.width - box.frame.width) / 2, y: (bounds.height - box.frame.height) / 2))
        box.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]   // stays centered while zooming
        box.alphaValue = 1
        box.isHidden = false
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.borderWidth = 3

        hideToast?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.layer?.borderColor = PinView.normalBorder
            self.layer?.borderWidth = 1
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

    private static func show(_ w: PinWindow) -> PinWindow {
        active.append(w)
        w.orderFrontRegardless()
        w.makeKey()
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

    static func release(_ w: PinWindow) {
        guard active.contains(where: { $0 === w }) else { return }
        w.close()
        active.removeAll { $0 === w }
        if active.isEmpty { Session.pinsClosed() }
    }

    static func closeAll() { active.forEach { release($0) } }
}
