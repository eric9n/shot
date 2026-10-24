import AppKit

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

    /// Points the layer at the screenshot.
    func setImage(_ image: CGImage) {
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
        if let area = owner.sel { owner.renderAll(in: area, includingCurrent: true) }
        if let i = owner.selected, owner.annotations.indices.contains(i) {
            let box = NSBezierPath(rect: owner.annotations[i].bounds.insetBy(dx: -5, dy: -5))
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            box.stroke()
        }
    }
}
