import AppKit

/// The eight grab points around the selection (AppKit coordinates: y grows upward, so "top" is maxY).
enum Handle: CaseIterable {
    case tl, t, tr, r, br, b, bl, l

    func point(in r: NSRect) -> CGPoint {
        switch self {
        case .tl: return CGPoint(x: r.minX, y: r.maxY)
        case .t: return CGPoint(x: r.midX, y: r.maxY)
        case .tr: return CGPoint(x: r.maxX, y: r.maxY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.minY)
        case .b: return CGPoint(x: r.midX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.minY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }
    var movesLeft: Bool { self == .tl || self == .l || self == .bl }
    var movesRight: Bool { self == .tr || self == .r || self == .br }
    var movesTop: Bool { self == .tl || self == .t || self == .tr }
    var movesBottom: Bool { self == .bl || self == .b || self == .br }

    var cursor: NSCursor {
        switch self {
        case .l, .r: return .resizeLeftRight
        case .t, .b: return .resizeUpDown
        default:
            if #available(macOS 15, *) {
                let pos: NSCursor.FrameResizePosition = self == .tl ? .topLeft : self == .tr ? .topRight : self == .bl ? .bottomLeft : .bottomRight
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        }
    }
}
