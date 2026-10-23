import AppKit

enum Tool: Int { case pen, rect, arrow, text, ellipse, line, mosaic, move, number, highlighter }

struct Annotation {
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var text = ""
    var level = 1   // size: 0 thin, 1 medium, 2 thick (line width, font size, marker size, highlighter width)
    var style = 0   // 0 solid, 1 dashed, 2 filled (filled only means something for rectangles and ellipses)
}

enum AnnotationRenderer {
    static let mosaicBlock: CGFloat = 8   // points per mosaic block

    // MARK: sizes per level

    private static func pick<T>(_ values: [T], _ level: Int) -> T { values[min(max(level, 0), values.count - 1)] }
    static func lineWidth(_ level: Int) -> CGFloat { pick([2, 3, 6], level) }
    static func highlighterWidth(_ level: Int) -> CGFloat { pick([10, 16, 26], level) }
    static func arrowHead(_ level: Int) -> CGFloat { pick([12, 16, 24], level) }
    static func numberRadius(_ level: Int) -> CGFloat { pick([11, 14, 20], level) }
    static func textFont(_ level: Int) -> NSFont { .boldSystemFont(ofSize: pick([16, 20, 28], level)) }

    // MARK: text

    /// One TextKit stack shared by the editor, the measuring and the drawing, so text looks identical while you type,
    /// after you finish, and in the exported image. (NSString drawing spaces lines slightly differently.)
    final class TextLayout {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 100_000, height: 100_000))

        init(_ text: String, color: NSColor = .black, level: Int = 1) {
            storage = NSTextStorage(string: text, attributes: [.font: AnnotationRenderer.textFont(level), .foregroundColor: color])
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        /// Used size; a trailing newline counts as an empty line, so the box grows as soon as you press Return.
        var size: NSSize {
            manager.ensureLayout(for: container)
            var r = manager.usedRect(for: container)
            if manager.extraLineFragmentRect.height > 0 { r = r.union(manager.extraLineFragmentRect) }
            return NSSize(width: ceil(r.width), height: ceil(r.height))
        }
    }

    static func textSize(_ text: String, level: Int) -> NSSize { TextLayout(text, level: level).size }

    /// Text annotations are anchored at their top-left corner, which stays put as lines are added.
    static func textBox(_ a: Annotation) -> NSRect {
        let size = textSize(a.text, level: a.level)
        return NSRect(x: a.points[0].x, y: a.points[0].y - size.height, width: size.width, height: size.height)
    }

    // MARK: drawing

    /// Dashes scale with the line width so thick lines don't turn into dots.
    private static func dashed(_ p: NSBezierPath, _ a: Annotation) {
        if a.style == 1 { p.setLineDash([p.lineWidth * 3, p.lineWidth * 2.2], count: 2, phase: 0) }
    }

    /// Outline, plus a translucent fill for the "filled" style.
    private static func strokeShape(_ p: NSBezierPath, _ a: Annotation) {
        p.lineWidth = lineWidth(a.level)
        if a.style == 2 {
            a.color.withAlphaComponent(0.25).setFill()
            p.fill()
        }
        dashed(p, a)
        p.stroke()
    }

    static func render(_ a: Annotation, mosaic: NSBitmapImageRep? = nil) {
        a.color.setStroke()
        switch a.tool {
        case .pen:
            guard let f = a.points.first else { return }
            let p = NSBezierPath()
            p.lineWidth = lineWidth(a.level); p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: f)
            a.points.dropFirst().forEach { p.line(to: $0) }
            p.stroke()
        case .highlighter:
            guard let f = a.points.first else { return }
            // One translucent stroke: overlapping parts of the same stroke don't get darker.
            a.color.withAlphaComponent(0.35).setStroke()
            let p = NSBezierPath()
            p.lineWidth = highlighterWidth(a.level); p.lineCapStyle = .butt; p.lineJoinStyle = .bevel   // flat ends, like a real highlighter
            p.move(to: f)
            a.points.dropFirst().forEach { p.line(to: $0) }
            p.stroke()
        case .rect:
            guard let s = a.points.first, let e = a.points.last else { return }
            strokeShape(NSBezierPath(rect: NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(s.x - e.x), height: abs(s.y - e.y))), a)
        case .move:
            return
        case .ellipse:
            guard let s = a.points.first, let e = a.points.last else { return }
            strokeShape(NSBezierPath(ovalIn: NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(s.x - e.x), height: abs(s.y - e.y))), a)
        case .line:
            guard let s = a.points.first, let e = a.points.last else { return }
            let p = NSBezierPath()
            p.lineWidth = lineWidth(a.level); p.lineCapStyle = .round
            p.move(to: s); p.line(to: e)
            dashed(p, a)
            p.stroke()
        case .mosaic:
            guard let s = a.points.first, let e = a.points.last, let map = mosaic else { return }
            let r = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(s.x - e.x), height: abs(s.y - e.y))
            // `map` is the whole screen shrunk to one pixel per block; stretching it without smoothing gives hard blocks.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            map.draw(in: NSRect(x: 0, y: 0, width: CGFloat(map.pixelsWide) * mosaicBlock, height: CGFloat(map.pixelsHigh) * mosaicBlock))
            NSColor.black.withAlphaComponent(0.72).setFill()   // dark tint, blocks stay visible
            r.fill()
            NSGraphicsContext.restoreGraphicsState()
        case .arrow:
            guard let s = a.points.first, let e = a.points.last, s != e else { return }
            let w = lineWidth(a.level)
            let shaft = NSBezierPath()
            shaft.lineWidth = w; shaft.lineCapStyle = .round
            shaft.move(to: s); shaft.line(to: e)
            dashed(shaft, a)
            shaft.stroke()
            let head = NSBezierPath()           // the head stays solid even when the shaft is dashed
            head.lineWidth = w; head.lineCapStyle = .round
            let ang = atan2(e.y - s.y, e.x - s.x), len = arrowHead(a.level)
            for d in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                head.move(to: e)
                head.line(to: CGPoint(x: e.x + len * cos(ang + d), y: e.y + len * sin(ang + d)))
            }
            head.stroke()
        case .number:
            guard let c = a.points.first else { return }
            let r = numberRadius(a.level)
            let disc = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            a.color.setFill()
            disc.fill()
            NSColor.white.setStroke()       // thin white ring keeps the marker readable on any background
            disc.lineWidth = 2
            disc.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: a.text.count > 1 ? r * 0.93 : r * 1.15),
                                                        .foregroundColor: NSColor.white]
            let size = (a.text as NSString).size(withAttributes: attrs)
            (a.text as NSString).draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        case .text:
            let layout = TextLayout(a.text, color: a.color, level: a.level)
            let box = textBox(a)
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.translateBy(x: box.minX, y: box.maxY)    // TextKit lays out top-down: put the origin at the top-left, y pointing down
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            layout.manager.drawGlyphs(forGlyphRange: layout.manager.glyphRange(for: layout.container), at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
    }
}

extension Annotation {
    var textRect: NSRect { AnnotationRenderer.textBox(self) }

    var bounds: NSRect {
        if tool == .text { return textRect }
        if tool == .number, let c = points.first {
            let r = AnnotationRenderer.numberRadius(level)
            return NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    func hit(_ p: CGPoint) -> Bool {
        let tol = max(8, AnnotationRenderer.lineWidth(level) + 2)   // thicker lines are easier to grab
        let b = bounds
        switch tool {
        case .text:
            return b.insetBy(dx: -4, dy: -4).contains(p)
        case .number:
            return b.insetBy(dx: -4, dy: -4).contains(p)
        case .move:
            return false
        case .mosaic:
            return b.contains(p)
        case .rect:
            let outer = b.insetBy(dx: -tol, dy: -tol)
            if style == 2 { return outer.contains(p) }   // filled: the whole shape is grabbable
            return outer.contains(p) && !(b.width > 2 * tol && b.height > 2 * tol && b.insetBy(dx: tol, dy: tol).contains(p))
        case .ellipse:
            let a = b.width / 2, c = b.height / 2
            guard a > 0, c > 0 else { return false }
            let d = sqrt(pow((p.x - b.midX) / a, 2) + pow((p.y - b.midY) / c, 2))
            if style == 2 { return d <= 1 + tol / min(a, c) }
            return abs(d - 1) * min(a, c) <= tol
        case .pen, .line, .arrow, .highlighter:
            guard points.count > 1 else { return false }
            let reach = tool == .highlighter ? AnnotationRenderer.highlighterWidth(level) / 2 + 2 : tol
            for i in 1..<points.count where Annotation.dist(p, points[i - 1], points[i]) <= reach { return true }
            return false
        }
    }

    static func dist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
