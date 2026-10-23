import AppKit

enum Tool: Int { case pen, rect, arrow, text, ellipse, line, mosaic, move }

struct Annotation {
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var text = ""
}

final class Canvas: NSView, NSTextFieldDelegate {
    let image: NSImage
    var annotations: [Annotation] = []
    var current: Annotation?
    var tool: Tool = .rect
    var color: NSColor = .systemRed
    var field: NSTextField?

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { window?.close() }

    override func draw(_ r: NSRect) {
        image.draw(in: bounds)
        annotations.forEach { Canvas.render($0) }
        if let c = current { Canvas.render(c) }
    }

    static func render(_ a: Annotation, src: NSImage? = nil, base: NSRect = .zero) {
        a.color.setStroke()
        switch a.tool {
        case .pen:
            guard let f = a.points.first else { return }
            let p = NSBezierPath()
            p.lineWidth = 3; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: f)
            a.points.dropFirst().forEach { p.line(to: $0) }
            p.stroke()
        case .rect:
            guard let s = a.points.first, let e = a.points.last else { return }
            let p = NSBezierPath(rect: NSRect(x: min(s.x, e.x), y: min(s.y, e.y),
                                              width: abs(s.x - e.x), height: abs(s.y - e.y)))
            p.lineWidth = 3
            p.stroke()
        case .move:
            return
        case .ellipse:
            guard let s = a.points.first, let e = a.points.last else { return }
            let p = NSBezierPath(ovalIn: NSRect(x: min(s.x, e.x), y: min(s.y, e.y),
                                                width: abs(s.x - e.x), height: abs(s.y - e.y)))
            p.lineWidth = 3
            p.stroke()
        case .line:
            guard let s = a.points.first, let e = a.points.last else { return }
            let p = NSBezierPath()
            p.lineWidth = 3; p.lineCapStyle = .round
            p.move(to: s); p.line(to: e)
            p.stroke()
        case .mosaic:
            guard let s = a.points.first, let e = a.points.last, let src = src else { return }
            let r = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(s.x - e.x), height: abs(s.y - e.y))
            let block: CGFloat = 8   // points per mosaic block
            let cols = Int(ceil(r.width / block)), rows = Int(ceil(r.height / block))
            guard cols > 0, rows > 0,
                  let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols, pixelsHigh: rows, bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: small) else { return }
            // Average the area under the rect into one pixel per block...
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            ctx.cgContext.scaleBy(x: 1 / block, y: 1 / block)
            ctx.cgContext.translateBy(x: -r.minX, y: -r.minY)
            src.draw(in: base)
            NSGraphicsContext.restoreGraphicsState()
            // ...then blow it back up without smoothing, so the blocks stay hard-edged, and tint it dark.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            small.draw(in: NSRect(x: r.minX, y: r.minY, width: CGFloat(cols) * block, height: CGFloat(rows) * block))
            NSColor.black.withAlphaComponent(0.72).setFill()
            r.fill()
            NSGraphicsContext.restoreGraphicsState()
        case .arrow:
            guard let s = a.points.first, let e = a.points.last, s != e else { return }
            let p = NSBezierPath()
            p.lineWidth = 3; p.lineCapStyle = .round
            p.move(to: s); p.line(to: e)
            let ang = atan2(e.y - s.y, e.x - s.x), len: CGFloat = 16
            for d in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                p.move(to: e)
                p.line(to: CGPoint(x: e.x + len * cos(ang + d), y: e.y + len * sin(ang + d)))
            }
            p.stroke()
        case .text:
            (a.text as NSString).draw(at: a.points[0], withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: a.color])
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        commitText()
        window?.makeFirstResponder(self)
        if tool == .text { beginText(at: p); return }
        current = Annotation(tool: tool, points: [p], color: color)
    }

    override func mouseDragged(with e: NSEvent) {
        guard current != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        if tool == .pen { current!.points.append(p) } else { current!.points = [current!.points[0], p] }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let c = current, c.points.count > 1 { annotations.append(c) }
        current = nil
        needsDisplay = true
    }

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
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
    }

    /// Full-resolution render of the image plus annotations.
    func rendered() -> NSBitmapImageRep? {
        commitText()
        guard let rep = image.representations.first,
              let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        bmp.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        annotations.forEach { Canvas.render($0) }
        NSGraphicsContext.restoreGraphicsState()
        return bmp
    }
}

final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class Editor: NSObject, NSWindowDelegate {
    static var open: [Editor] = []

    let window: EditorWindow
    let status = NSTextField(labelWithString: "")
    let canvas: Canvas
    let file: URL

    init(file: URL, image: NSImage) {
        self.file = file
        canvas = Canvas(image: image)

        let vis = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let w = max(560, min(image.size.width, vis.width * 0.9))
        let h = min(image.size.height, vis.height * 0.85) + 44
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        let tools = NSSegmentedControl(labels: ["Pen", "Rect", "Arrow", "Text"], trackingMode: .selectOne,
                                       target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = Tool.rect.rawValue
        let well = NSColorWell(style: .minimal)
        well.color = .systemRed
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 32).isActive = true

        func button(_ title: String, _ sel: Selector, _ key: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = .command
            return b
        }
        status.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [tools, well, status, spacer,
                                      button("Undo", #selector(undo), "z"),
                                      button("Copy", #selector(copyImage), "c"),
                                      button("Save", #selector(save), "s"),
                                      button("✕", #selector(close), "\u{1b}")])
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas

        let root = NSStackView(views: [bar, scroll])
        root.orientation = NSUserInterfaceLayoutOrientation.vertical
        root.spacing = 0
        root.distribution = NSStackView.Distribution.fill
        bar.setContentHuggingPriority(.required, for: .vertical)
        window.contentView = root

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        Editor.open.append(self)
    }

    func windowWillClose(_ n: Notification) { Editor.open.removeAll { $0 === self } }

    @objc func toolChanged(_ s: NSSegmentedControl) { canvas.tool = Tool(rawValue: s.selectedSegment) ?? .rect }
    @objc func colorChanged(_ w: NSColorWell) { canvas.color = w.color }
    @objc func undo() { canvas.undo() }
    @objc func close() { window.close() }

    @objc func copyImage() {
        guard let bmp = canvas.rendered() else { return }
        copyToClipboard(bmp)
        flash("Copied")
    }

    @objc func save() {
        guard let png = canvas.rendered()?.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: file); flash("Saved") } catch { flash("Save failed") }
    }

    func flash(_ msg: String) {
        status.stringValue = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in status.stringValue = "" }
    }
}
