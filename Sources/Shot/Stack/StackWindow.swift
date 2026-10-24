import AppKit
import ImageIO

private let cellHeight: CGFloat = 80
private let maxCellWidth: CGFloat = 120, minCellWidth: CGFloat = 72
private let cellGap: CGFloat = 10
private let panelInset: CGFloat = 12

// MARK: one item

/// One thumbnail in the stack. Click copies it, dragging takes it into another app, and the two buttons that show on
/// hover put it back on the screen as a pin or remove it.
final class StackCell: NSView, NSDraggingSource {
    let item: StackItem
    private let cellW: CGFloat
    private let onChange: () -> Void
    private let pinButton = RoundButton(symbol: "pin.fill", tip: "Pin it back on the screen", diameter: 22)
    private let removeButton = RoundButton(symbol: "xmark", tip: "Remove from the stack", diameter: 22)
    private var downPoint: NSPoint?
    private var dragging = false
    private var hideToast: DispatchWorkItem?
    private var toast: NSView?

    init(item: StackItem, width: CGFloat, onChange: @escaping () -> Void) {
        self.item = item
        self.cellW = width
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: cellHeight))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        buildContent()

        pinButton.target = self
        pinButton.action = #selector(pinBack)
        removeButton.target = self
        removeButton.action = #selector(remove)
        pinButton.setFrameOrigin(NSPoint(x: cellW - 2 * 22 - 10, y: cellHeight - 22 - 5))
        removeButton.setFrameOrigin(NSPoint(x: cellW - 22 - 5, y: cellHeight - 22 - 5))
        for b in [pinButton, removeButton] { b.alphaValue = 0; addSubview(b) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        switch item.kind {
        case .image:
            layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.18).cgColor
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 360]   // a thumbnail only; the full picture stays on disk
            if let src = CGImageSourceCreateWithURL(StackStore.contentURL(item) as CFURL, nil),
               let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                layer?.contents = thumb
                layer?.contentsGravity = .resizeAspectFill
            }
        case .text, .link:
            layer?.backgroundColor = NSColor.white.cgColor
            let text = StackStore.text(of: item) ?? ""
            let isLink = item.kind == .link
            let label = NSTextField(wrappingLabelWithString: String(text.prefix(160)))
            label.font = .systemFont(ofSize: isLink ? 10.5 : 11)
            label.textColor = isLink ? .systemBlue : .black
            label.maximumNumberOfLines = isLink ? 3 : 5
            label.cell?.truncatesLastVisibleLine = true
            label.isSelectable = false
            let top: CGFloat = isLink ? 26 : 9
            label.frame = NSRect(x: 8, y: 8, width: cellW - 16, height: cellHeight - 8 - top)
            addSubview(label)
            if isLink {
                let icon = NSImageView(frame: NSRect(x: 9, y: cellHeight - 22, width: 14, height: 14))
                icon.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Link")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
                icon.contentTintColor = .systemBlue
                addSubview(icon)
            }
        }
    }

    // Everything inside is one surface for the mouse, except the two buttons while they are showing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        for b in [pinButton, removeButton] where b.alphaValue > 0.5 && b.frame.contains(p) { return b }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { setButtons(visible: true) }
    override func mouseExited(with event: NSEvent) { setButtons(visible: false) }

    private func setButtons(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for b in [pinButton, removeButton] { b.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { copyItem() }
        downPoint = nil
    }

    // MARK: actions

    private func copyItem() {
        if item.kind == .image {
            guard let data = try? Data(contentsOf: StackStore.contentURL(item)), let bmp = NSBitmapImageRep(data: data) else { return }
            copyToClipboard(bmp)
        } else if let text = StackStore.text(of: item) {
            copyTextToClipboard(text)
        } else {
            return
        }
        showCopied()
    }

    @objc private func pinBack() { Session.report("pin-item \(item.id)") }   // the new pin process takes it out of the stack

    @objc private func remove() {
        StackStore.remove(item.id)
        onChange()
    }

    /// "Copied" in a capsule in the middle of the thumbnail, for a moment.
    private func showCopied() {
        let box: NSView
        if let t = toast { box = t } else {
            let label = NSTextField(labelWithString: "Copied")
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            label.sizeToFit()
            box = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 20, height: label.frame.height + 10))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            box.layer?.cornerRadius = box.frame.height / 2
            label.setFrameOrigin(NSPoint(x: 10, y: 5))
            box.addSubview(label)
            addSubview(box)
            toast = box
        }
        box.setFrameOrigin(NSPoint(x: (bounds.width - box.frame.width) / 2, y: (bounds.height - box.frame.height) / 2))
        box.alphaValue = 1
        hideToast?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                box.animator().alphaValue = 0
            }
        }
        hideToast = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: drag out

    private func beginDrag(with event: NSEvent) {
        let writer: NSPasteboardWriting
        switch item.kind {
        case .image:
            guard let url = dragFile() else { return }
            writer = url as NSURL
        case .text:
            guard let text = StackStore.text(of: item) else { return }
            writer = text as NSString
        case .link:
            guard let text = StackStore.text(of: item), let url = URL(string: text) else { return }
            writer = url as NSURL
        }
        setButtons(visible: false)
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        var preview = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            preview = NSImage(size: bounds.size)
            preview.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// A picture dragged into another app arrives as a file, in the chosen format and name (like the overlay's drag icon).
    private func dragFile() -> URL? {
        guard let data = try? Data(contentsOf: StackStore.contentURL(item)), let bmp = NSBitmapImageRep(data: data) else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Shot-drag", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Output.write(bmp, to: dir)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: the window

/// The stack process: a floating strip at the top of the screen showing what is stored. It lives only while it is
/// visible; hiding it quits the process, so its memory (a few small thumbnails) goes back to the system.
final class StackController {
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let closeButton = RoundButton(symbol: "xmark", tip: "Hide the stack", diameter: 20)
    private let emptyLabel = NSTextField(labelWithString: "Nothing stored. Hover a pin and click the tray button.")
    private var cells: [StackCell] = []
    private var shown: [StackItem] = []
    private let screen: NSScreen
    private var peekUntil = Date.distantFuture

    /// `peek`: show for two seconds (when something has just been stored), then hide again.
    init(peek: Bool) {
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        panel.contentView = background

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        closeButton.target = self
        closeButton.action = #selector(hide)
        if peek { peekUntil = Date().addingTimeInterval(2) }
    }

    func show() {
        reload(force: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        // Things stored by pins in other processes show up within half a second.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        reload(force: false)
        if peekUntil != .distantFuture, Date() >= peekUntil, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { hide() }
    }

    @objc private func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { exit(0) })
    }

    /// Rebuilds the thumbnails when the stored items changed.
    func reload(force: Bool) {
        let items = StackStore.items()
        guard force || items != shown else { return }
        if peekUntil != .distantFuture, items != shown, !force { peekUntil = Date().addingTimeInterval(2) }   // a new item: keep showing
        shown = items
        cells.forEach { $0.removeFromSuperview() }
        // Thumbnails shrink when there are many on a narrow screen, so the strip never reaches the screen's edges.
        let n = items.count
        let room = screen.visibleFrame.width - 48 - panelInset * 2 - 26 - CGFloat(max(n - 1, 0)) * cellGap
        let cellW = n == 0 ? maxCellWidth : max(minCellWidth, min(maxCellWidth, room / CGFloat(n)))
        cells = items.map { StackCell(item: $0, width: cellW, onChange: { [weak self] in self?.reload(force: false) }) }

        let size = n == 0
            ? NSSize(width: 380, height: 56)
            : NSSize(width: panelInset * 2 + CGFloat(n) * cellW + CGFloat(n - 1) * cellGap + 26, height: panelInset * 2 + cellHeight)
        background.subviews.forEach { $0.removeFromSuperview() }
        if n == 0 {
            emptyLabel.frame = NSRect(x: 12, y: (size.height - 16) / 2, width: size.width - 24 - 32, height: 16)   // clear of the close button
            background.addSubview(emptyLabel)
        }
        for (i, cell) in cells.enumerated() {
            cell.setFrameOrigin(NSPoint(x: panelInset + CGFloat(i) * (cellW + cellGap), y: panelInset))
            background.addSubview(cell)
        }
        closeButton.setFrameOrigin(NSPoint(x: size.width - 20 - 8, y: size.height - 20 - 8))
        background.addSubview(closeButton)

        // Top right, just under the menu bar; it grows to the left as items are added.
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

private var controller: StackController?

enum StackSession {
    /// Runs the stack window; never returns.
    static func run(peek: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        controller = StackController(peek: peek)
        controller?.show()
        app.run()
        exit(0)
    }
}
