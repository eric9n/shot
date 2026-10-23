import AppKit

enum Tool: Int { case pen, rect, arrow, text, ellipse, line, mosaic, move }

struct Annotation {
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var text = ""
}

enum AnnotationRenderer {
    static let mosaicBlock: CGFloat = 8   // points per mosaic block

    static func render(_ a: Annotation, mosaic: NSBitmapImageRep? = nil) {
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
}

extension Annotation {
    var textRect: NSRect {
        let sz = (text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        return NSRect(origin: points[0], size: sz)
    }

    var bounds: NSRect {
        if tool == .text { return textRect }
        let xs = points.map(\.x), ys = points.map(\.y)
        return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    func hit(_ p: CGPoint) -> Bool {
        let tol: CGFloat = 8
        let b = bounds
        switch tool {
        case .text:
            return b.insetBy(dx: -4, dy: -4).contains(p)
        case .move:
            return false
        case .mosaic:
            return b.contains(p)
        case .rect:
            return b.insetBy(dx: -tol, dy: -tol).contains(p)
                && !(b.width > 2 * tol && b.height > 2 * tol && b.insetBy(dx: tol, dy: tol).contains(p))
        case .ellipse:
            let a = b.width / 2, c = b.height / 2
            guard a > 0, c > 0 else { return false }
            let d = sqrt(pow((p.x - b.midX) / a, 2) + pow((p.y - b.midY) / c, 2))
            return abs(d - 1) * min(a, c) <= tol
        case .pen, .line, .arrow:
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Annotation.dist(p, points[i - 1], points[i]) <= tol { return true }
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
