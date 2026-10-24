import AppKit

/// Three little dots on a card's top pad: red, yellow, green, like a traffic light. Click one to tag the card with that
/// color; click the one that is already set to take the tag off.
final class TagPicker: NSView {
    static let dot: CGFloat = 12, gap: CGFloat = 8, ring: CGFloat = 2
    static var size: NSSize {
        let n = CGFloat(StackItem.Tag.allCases.count)
        return NSSize(width: n * dot + (n - 1) * gap + 2 * ring, height: dot + 2 * ring)
    }

    var selected: StackItem.Tag? { didSet { needsDisplay = true } }
    var onPick: ((StackItem.Tag) -> Void)?

    init() { super.init(frame: NSRect(origin: .zero, size: TagPicker.size)) }
    required init?(coder: NSCoder) { fatalError() }

    private func rect(of index: Int) -> NSRect {
        NSRect(x: TagPicker.ring + CGFloat(index) * (TagPicker.dot + TagPicker.gap), y: TagPicker.ring, width: TagPicker.dot, height: TagPicker.dot)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, tag) in StackItem.Tag.allCases.enumerated() {
            let r = rect(of: i)
            let dot = NSBezierPath(ovalIn: r)
            let g = Warm.tagGradient(tag)
            NSGradient(starting: g.top, ending: g.bottom)?.draw(in: dot, angle: -90)
            Warm.color(0xFFFBF3).setStroke()                       // a cream rim, so the dot shows on a pad of its own color
            dot.lineWidth = 1.5
            dot.stroke()
            if tag == selected {                                    // the one that is set has a dark ring around it
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2))
                Warm.ink.withAlphaComponent(0.6).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Each dot owns the space up to the middle of the gap next to it, so the dots are easy to hit.
        for (i, tag) in StackItem.Tag.allCases.enumerated() {
            let r = rect(of: i).insetBy(dx: -TagPicker.gap / 2, dy: -TagPicker.ring)
            if r.contains(p) { onPick?(tag); return }
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
