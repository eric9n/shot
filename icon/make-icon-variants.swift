// Renders light/dark Shot icon previews and Icon Composer layers (1024px PNGs).
// Usage: swift icon/make-icon-variants.swift <output-dir>
import AppKit

let coral = NSColor(red: 1.0, green: 0.353, blue: 0.306, alpha: 1)   // #FF5A4E
let dark = NSColor(red: 0.071, green: 0.082, blue: 0.122, alpha: 1)  // #12151F

func png(_ name: String, _ draw: (CGFloat) -> Void) {
    let px = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name))
}

func glyph(_ color: NSColor) {
    let body: CGFloat = 824, origin: CGFloat = 100, u = body / 112
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin + x * u, y: origin + (112 - y) * u) }
    color.setStroke(); color.setFill()
    let c = pt(56, 56)
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 26 * u, y: c.y - 26 * u, width: 52 * u, height: 52 * u))
    ring.lineWidth = 7 * u
    ring.stroke()
    NSBezierPath(ovalIn: NSRect(x: c.x - 10 * u, y: c.y - 10 * u, width: 20 * u, height: 20 * u)).fill()
    let t = NSBezierPath()
    t.lineWidth = 5 * u; t.lineCapStyle = .round
    for (a, b) in [((56, 14), (56, 22)), ((56, 90), (56, 98)), ((14, 56), (22, 56)), ((90, 56), (98, 56))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        t.move(to: pt(a.0, a.1)); t.line(to: pt(b.0, b.1))
    }
    t.stroke()
}

func squircle(_ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
}

png("Shot-light.png") { _ in squircle(coral); glyph(.white) }
png("Shot-dark.png") { _ in squircle(dark); glyph(coral) }
png("layer-glyph-white.png") { _ in glyph(.white) }
png("layer-glyph-coral.png") { _ in glyph(coral) }
png("layer-bg-coral.png") { s in coral.setFill(); NSRect(x: 0, y: 0, width: s, height: s).fill() }
png("layer-bg-dark.png") { s in dark.setFill(); NSRect(x: 0, y: 0, width: s, height: s).fill() }
