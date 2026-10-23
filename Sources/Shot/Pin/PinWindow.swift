import AppKit

/// The picture inside a pinned window. Drag to move, scroll to zoom, double-click or Esc to close, right-click for more.
final class PinView: NSView {
    private(set) var bitmap: NSBitmapImageRep?
    private var cg: CGImage?
    private var baseSize = NSSize.zero          // size when pinned; zoom is measured against it
    var onClose: () -> Void = {}

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
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor   // keeps the edge visible over white pages
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows a screenshot, or nothing (nil) to release it.
    func set(_ bmp: NSBitmapImageRep?) {
        bitmap = bmp
        cg = bmp?.cgImage
        baseSize = bmp?.size ?? .zero
        layer?.contents = cg
        layer?.contentsGravity = .resize
    }

    /// Zooms around the window's center. 1 point of scroll is 1% (clamped to 20%…500% of the pinned size).
    func zoom(by delta: CGFloat) {
        guard let w = window, baseSize.width > 0 else { return }
        let width = min(max(w.frame.width * (1 + delta * 0.01), baseSize.width * 0.2), baseSize.width * 5)
        let height = width * baseSize.height / baseSize.width
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(NSRect(x: c.x - width / 2, y: c.y - height / 2, width: width, height: height), display: true)
    }

    override func scrollWheel(with e: NSEvent) { zoom(by: e.scrollingDeltaY) }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onClose() } else { window?.performDrag(with: e) }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onClose() }                                                     // Esc
        else if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "c" { copyPin() }
        else if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "s" { savePin() }
        else { super.keyDown(with: e) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyPin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Save", action: #selector(savePin), keyEquivalent: "").target = self
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

    @objc func copyPin() { if let b = bitmap { copyToClipboard(b) } }
    @objc func savePin() { if let b = bitmap { Output.write(b) } }
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

/// All pinned screenshots. A closed pin gives up its image right away and its window is parked for the next pin
/// to reuse, so pinning over and over doesn't keep creating windows.
enum Pins {
    static var active: [PinWindow] = []
    private static var idle: [PinWindow] = []

    /// Pins `bmp` as a floating window with the given frame (in screen coordinates).
    @discardableResult
    static func pin(_ bmp: NSBitmapImageRep, frame: NSRect) -> PinWindow {
        let w = idle.popLast() ?? PinWindow()
        w.alphaValue = 1
        w.setFrame(frame, display: false)
        w.pinView.set(bmp)
        active.append(w)
        w.orderFrontRegardless()
        w.makeKey()
        return w
    }

    static func release(_ w: PinWindow) {
        guard active.contains(where: { $0 === w }) else { return }
        w.pinView.set(nil)
        w.orderOut(nil)
        active.removeAll { $0 === w }
        idle.append(w)
    }

    static func closeAll() { active.forEach { release($0) } }
}
