import AppKit

/// The picture inside a pinned window. Drag to move, scroll to zoom, double-click or Esc to close, right-click for more.
final class PinView: NSView {
    private var cg: CGImage?                     // the only copy of the picture; a bitmap is made just for copy and save
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
        let height = width * baseSize.height / baseSize.width
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
        guard let b = bitmap else { return }
        copyToClipboard(b)
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
    @objc func savePin() { if let b = bitmap { Output.write(b) } }
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
        active.append(w)
        w.orderFrontRegardless()
        w.makeKey()
        return w
    }

    static func release(_ w: PinWindow) {
        guard active.contains(where: { $0 === w }) else { return }
        w.close()
        active.removeAll { $0 === w }
        if active.isEmpty { Session.pinsClosed() }
    }

    static func closeAll() { active.forEach { release($0) } }
}
