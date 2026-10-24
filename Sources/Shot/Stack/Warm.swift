import AppKit

/// The warm palette of the stack and its icon: cream, peach, sand, and clay, with a brown "ink" in place of black.
enum Warm {
    static func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    /// (top, bottom) of a vertical gradient.
    typealias Gradient = (top: NSColor, bottom: NSColor)
    static let cream: Gradient = (color(0xFFFBF3), color(0xFFE8CC))
    static let peach: Gradient = (color(0xFFCDAE), color(0xF4A07A))
    static let sand: Gradient = (color(0xF8E7CF), color(0xE9C99B))
    static let clay: Gradient = (color(0xEE8F6D), color(0xCB5F3E))
    static let badge: Gradient = (color(0xE8604B), color(0xC03F2D))      // deeper and redder than the clay, to stand out on it

    static let ink = color(0x3A1F10)            // dark brown: shadows and dark overlays instead of black
    static let text = color(0x4A2E20)           // text on cream
    static let link = color(0xB5502B)
    static let hairline = color(0xD9B98F, 0.55) // card edges

    /// A gradient layer for a view's layer: `top` at the top edge.
    static func layer(_ g: Gradient) -> CAGradientLayer {
        let l = CAGradientLayer()
        l.colors = [g.top.cgColor, g.bottom.cgColor]
        l.startPoint = CGPoint(x: 0.5, y: 1)
        l.endPoint = CGPoint(x: 0.5, y: 0)
        return l
    }
}
