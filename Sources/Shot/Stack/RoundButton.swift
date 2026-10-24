import AppKit

/// A small round button with a cream symbol on translucent dark-brown glass. Used on pins (store) and in the stack
/// (pin back, remove, hide).
final class RoundButton: NSButton {
    init(symbol: String, tip: String, diameter: CGFloat = 22) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: diameter * 0.46, weight: .bold))
        contentTintColor = Warm.color(0xFFF4E3)
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        layer?.backgroundColor = Self.rest
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let rest = Warm.ink.withAlphaComponent(0.62).cgColor
    private static let pressed = Warm.ink.withAlphaComponent(0.88).cgColor

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // works in windows that are not key
    override var isHighlighted: Bool {
        didSet { layer?.backgroundColor = isHighlighted ? Self.pressed : Self.rest }
    }
}
