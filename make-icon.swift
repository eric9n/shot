// Renders the Shot app icon (dark rounded square, coral shutter ring) into an .iconset folder.
// Usage: swift make-icon.swift <output.iconset>
import AppKit

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body, centered.
    let canvas = CGFloat(px)
    let body = canvas * 824 / 1024
    let origin = (canvas - body) / 2
    let rect = NSRect(x: origin, y: origin, width: body, height: body)
    let u = body / 112   // design units (112-unit artboard)

    NSColor(red: 0.071, green: 0.082, blue: 0.122, alpha: 1).setFill()   // #12151F
    NSBezierPath(roundedRect: rect, xRadius: 25 * u, yRadius: 25 * u).fill()

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + (112 - y) * u) }
    let coral = NSColor(red: 1.0, green: 0.353, blue: 0.306, alpha: 1)   // #FF5A4E
    coral.setStroke()
    coral.setFill()

    let c = pt(56, 56)
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 26 * u, y: c.y - 26 * u, width: 52 * u, height: 52 * u))
    ring.lineWidth = 7 * u
    ring.stroke()
    NSBezierPath(ovalIn: NSRect(x: c.x - 10 * u, y: c.y - 10 * u, width: 20 * u, height: 20 * u)).fill()

    let ticks = NSBezierPath()
    ticks.lineWidth = 5 * u
    ticks.lineCapStyle = .round
    for (a, b) in [((56, 14), (56, 22)), ((56, 90), (56, 98)), ((14, 56), (22, 56)), ((90, 56), (98, 56))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        ticks.move(to: pt(a.0, a.1))
        ticks.line(to: pt(b.0, b.1))
    }
    ticks.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
