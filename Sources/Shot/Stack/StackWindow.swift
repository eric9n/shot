import AppKit
import ImageIO

private let cardWidth: CGFloat = 232
private let cardHeight: CGFloat = 132
private let stripHeight: CGFloat = 38          // how much of a card shows while it is stacked under the next one
private let shadowRoom: CGFloat = 26           // space around the cards for their shadows: enough for the shadow to fade out
                                                // completely, or the window's edge cuts it off in a straight line
private let cardRadius: CGFloat = 14

// MARK: one card

/// One stored item, drawn as a card. Click copies it, dragging takes it into another app, and the two buttons that
/// show on hover put it back on the screen as a pin or remove it.
final class StackCell: NSView, NSDraggingSource {
    let item: StackItem
    private let onChange: () -> Void
    private let onAction: (TimeInterval) -> Void   // after a click or a button: the stack closes after this many seconds
    private let clip = NSView()                  // clips the content to the rounded corners; the shadow is on the card itself
    private let pinButton = RoundButton(symbol: "pin.fill", tip: "Pin it back on the screen", diameter: 22)
    private let removeButton = RoundButton(symbol: "xmark", tip: "Remove from the stack", diameter: 22)
    private var downPoint: NSPoint?
    private var dragging = false
    private var hideToast: DispatchWorkItem?
    private var toast: NSView?

    init(item: StackItem, onChange: @escaping () -> Void, onAction: @escaping (TimeInterval) -> Void) {
        self.item = item
        self.onChange = onChange
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
        wantsLayer = true
        layer?.shadowColor = Warm.ink.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: 3)      // falls upward onto the card above it
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

        clip.frame = bounds
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cardRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 0.5
        clip.layer?.borderColor = Warm.hairline.cgColor
        addSubview(clip)
        buildContent()

        pinButton.target = self
        pinButton.action = #selector(pinBack)
        removeButton.target = self
        removeButton.action = #selector(remove)
        pinButton.setFrameOrigin(NSPoint(x: cardWidth - 2 * 22 - 14, y: cardHeight - 22 - 8))
        removeButton.setFrameOrigin(NSPoint(x: cardWidth - 22 - 8, y: cardHeight - 22 - 8))
        for b in [pinButton, removeButton] { b.alphaValue = 0; addSubview(b) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What shows on the card, anchored to its top so the visible strip of a stacked card shows the start of the content.
    private func buildContent() {
        switch item.kind {
        case .image:
            clip.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.2).cgColor
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 640]   // a thumbnail only; the full picture stays on disk
            if let src = CGImageSourceCreateWithURL(StackStore.contentURL(item) as CFURL, nil),
               let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), thumb.width > 0, thumb.height > 0 {
                let scale = max(cardWidth / CGFloat(thumb.width), cardHeight / CGFloat(thumb.height))     // fill the card
                let w = CGFloat(thumb.width) * scale, h = CGFloat(thumb.height) * scale
                let picture = CALayer()
                picture.frame = CGRect(x: (cardWidth - w) / 2, y: cardHeight - h, width: w, height: h)   // top aligned
                picture.contents = thumb
                picture.contentsGravity = .resize
                clip.layer?.addSublayer(picture)
            }
        case .text, .link:
            let paper = Warm.layer(Warm.cream)               // a cream card, a little warmer toward the bottom
            paper.frame = bounds
            clip.layer?.addSublayer(paper)
            let text = StackStore.text(of: item) ?? ""
            let isLink = item.kind == .link
            let label = NSTextField(wrappingLabelWithString: String(text.prefix(300)))
            label.font = .systemFont(ofSize: 13, weight: isLink ? .medium : .regular)
            label.textColor = isLink ? Warm.link : Warm.text
            label.maximumNumberOfLines = 0
            label.cell?.truncatesLastVisibleLine = true
            label.isSelectable = false
            let left: CGFloat = isLink ? 36 : 14
            label.frame = NSRect(x: left, y: 12, width: cardWidth - left - 14, height: cardHeight - 12 - 11)
            clip.addSubview(label)
            if isLink {
                let icon = NSImageView(frame: NSRect(x: 14, y: cardHeight - 11 - 17, width: 18, height: 18))
                icon.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Link")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
                icon.contentTintColor = Warm.link
                clip.addSubview(icon)
            }
        }
    }

    // Everything on the card is one surface for the mouse, except the two buttons while they are showing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        for b in [pinButton, removeButton] where b.alphaValue > 0.5 && b.frame.contains(p) { return b }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The card the pointer is on (as decided by the stack) shows its two buttons; the others hide them.
    func setFocused(_ focused: Bool) { setButtons(visible: focused) }

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
        onAction(0.55)                 // long enough to see "Copied"
    }

    @objc private func pinBack() {
        Session.report("pin-item \(item.id)")        // the new pin process takes it out of the stack
        onAction(0.1)
    }

    @objc private func remove() {
        StackStore.remove(item.id)
        Session.report("stack-changed")
        onChange()
        onAction(0.1)
    }

    /// "Copied" in a capsule on the visible top of the card, for a moment.
    private func showCopied() {
        let box: NSView
        if let t = toast { box = t } else {
            let label = NSTextField(labelWithString: "Copied")
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            label.sizeToFit()
            box = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 20, height: label.frame.height + 10))
            box.wantsLayer = true
            box.layer?.backgroundColor = Warm.ink.withAlphaComponent(0.8).cgColor
            box.layer?.cornerRadius = box.frame.height / 2
            label.setFrameOrigin(NSPoint(x: 10, y: 5))
            box.addSubview(label)
            addSubview(box)
            toast = box
        }
        box.setFrameOrigin(NSPoint(x: (cardWidth - box.frame.width) / 2, y: cardHeight - stripHeight / 2 - box.frame.height / 2))
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

/// The stack's content view. It watches the pointer for the whole stack, so which card is under it is decided in one place
/// and not by the cards themselves: cards sliding under a still pointer must not count as the pointer moving onto them.
final class StackContentView: NSView {
    var onPointer: ((NSPoint) -> Void)?
    var onLeave: (() -> Void)?
    var onEmptyClick: (() -> Void)?       // a click that landed on no card (the margin around them)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseMoved(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onLeave?() }
    override func mouseDown(with event: NSEvent) { onEmptyClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The stack process: a column of cards hanging from the floating icon at the top right, stacked like cards in a wallet:
/// the oldest at the top, each card covering all but the top strip of the one above it, the newest in front and whole.
/// Pointing at a card slides the ones below it down so that card shows in full. The process lives only while the stack is
/// visible; hiding it quits it, so its memory (a few small thumbnails) goes back to the system.
final class StackController {
    private let panel: NSPanel
    private let emptyPill = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing stored. Hover a pin and click the tray button.")
    private var cells: [StackCell] = []          // oldest first: top to bottom
    private var shown: [StackItem] = []
    private(set) var hovered: Int?                // the card that is unfolded (the one the pointer is on)
    private var releaseHover: DispatchWorkItem?
    private var targetFrames: [NSRect] = []       // where the cards are going to be (not where they are in the middle of a move)
    private var clickMonitor: Any?
    private var closing = false
    /// What happens when the stack closes. The stack runs in its own process, so that is to quit it.
    var onClose: () -> Void = { exit(0) }
    private var screen: NSScreen
    private var lastIcon = NSRect.zero            // where the icon was when the column was last placed
    private var peekUntil = Date.distantFuture

    /// `peek`: show for two seconds (when something has just been stored), then hide again.
    init(peek: Bool) {
        screen = StackIcon.homeScreen
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                  // the cards have their own shadows
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let content = StackContentView()
        content.onPointer = { [weak self] p in self?.pointerMoved(p) }
        content.onLeave = { [weak self] in self?.scheduleRelease() }
        content.onEmptyClick = { [weak self] in self?.close(after: 0) }
        panel.contentView = content
        panel.acceptsMouseMovedEvents = true

        emptyPill.wantsLayer = true
        emptyPill.layer?.cornerRadius = 20
        emptyPill.layer?.cornerCurve = .continuous
        emptyPill.layer?.masksToBounds = true
        emptyPill.layer?.borderWidth = 0.5
        emptyPill.layer?.borderColor = Warm.hairline.cgColor
        let pillPaper = Warm.layer(Warm.cream)
        pillPaper.frame = CGRect(x: 0, y: 0, width: cardWidth, height: 52)
        emptyPill.layer?.addSublayer(pillPaper)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Warm.text.withAlphaComponent(0.75)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyPill.addSubview(emptyLabel)
        if peek { peekUntil = Date().addingTimeInterval(2) }
    }

    func show() {
        reload(force: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        // Things stored by pins in other processes show up within half a second.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        // A click anywhere else on the screen closes the stack (a click on the icon is the icon's own business).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.clickedElsewhere(at: NSEvent.mouseLocation)
        }
        // The column hangs from the icon, so it follows when the icon is dragged.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.followIcon() }
    }

    private func followIcon() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)       // see what the menu-bar process just saved
        let home = StackIcon.homeScreen
        let icon = StackIcon.circle(on: home)
        guard icon != lastIcon || home != screen else { return }
        screen = home
        layout(animated: false)
    }

    private func tick() {
        reload(force: false)
        if peekUntil != .distantFuture, Date() >= peekUntil, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { hide() }
    }

    private func hide() { close(after: 0) }

    /// Rebuilds the cards when the stored items changed.
    func reload(force: Bool) {
        let items = StackStore.items()
        guard force || items != shown else { return }
        if peekUntil != .distantFuture, items != shown, !force { peekUntil = Date().addingTimeInterval(2) }   // a new item: keep showing
        shown = items
        hovered = nil
        cells.forEach { $0.removeFromSuperview() }
        emptyPill.removeFromSuperview()
        // `items` is newest first; the column runs oldest (top) to newest (front, bottom).
        cells = items.reversed().map { item in
            StackCell(item: item,
                      onChange: { [weak self] in self?.reload(force: false) },
                      onAction: { [weak self] delay in self?.close(after: delay) })
        }
        if cells.isEmpty { panel.contentView?.addSubview(emptyPill) }
        cells.forEach { panel.contentView?.addSubview($0) }       // later cards are in front
        layout(animated: false)
    }

    /// The card under `p`, by where the cards are going to be: the one in front where they overlap.
    private func cardAt(_ p: NSPoint) -> Int? {
        targetFrames.indices.reversed().first { targetFrames[$0].contains(p) }
    }

    /// The pointer moved over the stack. Pointing at a card unfolds it.
    func pointerMoved(_ p: NSPoint) {
        releaseHover?.cancel()
        guard let index = cardAt(p) else { scheduleRelease(); return }       // between cards or in the margin
        guard index != hovered else { return }
        hovered = index
        layout(animated: true)
    }

    /// The pointer left the cards: fold the unfolded card back after a moment (so crossing a gap does not flicker).
    private func scheduleRelease() {
        releaseHover?.cancel()
        guard hovered != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hovered = nil
            self?.layout(animated: true)
        }
        releaseHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// A click somewhere on the screen outside the stack. Clicks on the icon are left to the icon: it closes the stack itself,
    /// and closing here too would make that click open it again.
    func clickedElsewhere(at point: NSPoint) {
        if StackIcon.hitRect(on: screen).contains(point) { return }
        close(after: 0)
    }

    /// Closes the stack (after `delay` seconds): it fades out and goes away, leaving just the icon. This is what happens after
    /// you click a card or a button, and when you click anywhere else.
    func close(after delay: TimeInterval) {
        guard !closing else { return }
        closing = true
        releaseHover?.cancel()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                self.panel.animator().alphaValue = 0
            }, completionHandler: { self.onClose() })
        }
    }

    private func layout(animated: Bool) {
        let n = cells.count
        let visible = screen.visibleFrame
        let icon = StackIcon.circle(on: screen)          // the column hangs from where the icon is (shown or not)
        lastIcon = icon
        let gap: CGFloat = 12
        let width = cardWidth + 2 * shadowRoom

        // Under the icon if there is room for the column there, otherwise above it (the column then opens upwards).
        let naturalHeight: CGFloat = n == 0 ? 52 + 2 * shadowRoom
            : 2 * shadowRoom + cardHeight + CGFloat(n - 1) * stripHeight + (n > 1 ? cardHeight - stripHeight : 0)
        let spaceBelow = icon.minY - gap - visible.minY - 8
        let spaceAbove = visible.maxY - icon.maxY - gap - 8
        let below = spaceBelow >= naturalHeight || spaceBelow >= spaceAbove
        let room = below ? spaceBelow : spaceAbove

        var height: CGFloat
        var frames: [NSRect] = []
        if n == 0 {
            height = naturalHeight
            emptyPill.frame = NSRect(x: shadowRoom, y: shadowRoom, width: cardWidth, height: 52)
            emptyLabel.frame = NSRect(x: 12, y: 8, width: cardWidth - 24, height: 36)
        } else {
            // When there are many cards on a short screen the visible strips get thinner so the column still fits.
            let strip = n > 1 ? max(14, min(stripHeight, (room - 2 * shadowRoom - 2 * cardHeight) / CGFloat(n - 1))) : 0
            // The front card is already whole; pointing at any other card makes room for it by moving the ones below it down.
            let extra: CGFloat = (hovered != nil && hovered! < n - 1) ? cardHeight - strip : 0
            height = 2 * shadowRoom + cardHeight + CGFloat(n - 1) * strip + extra
            for i in 0..<n {
                let belowHovered = (hovered != nil && i > hovered!) ? extra : 0
                let offsetFromTop = shadowRoom + CGFloat(i) * strip + belowHovered
                frames.append(NSRect(x: shadowRoom, y: height - offsetFromTop - cardHeight, width: cardWidth, height: cardHeight))
            }
        }
        // Right edges lined up with the icon; if that would run off the left of the screen, left edges instead.
        var x = icon.maxX + shadowRoom - width
        if x + shadowRoom < visible.minX + 8 { x = icon.minX - shadowRoom }
        let y = below ? icon.minY - gap + shadowRoom - height : icon.maxY + gap - shadowRoom
        let panelFrame = NSRect(x: x, y: y, width: width, height: height)
        targetFrames = frames
        for (i, cell) in cells.enumerated() { cell.setFocused(i == hovered) }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().setFrame(panelFrame, display: true)
                for (cell, f) in zip(cells, frames) { cell.animator().frame = f }
            }
        } else {
            panel.setFrame(panelFrame, display: true)
            for (cell, f) in zip(cells, frames) { cell.frame = f }
        }
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
