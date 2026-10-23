import AppKit

enum Mode: UInt32 {
    case region = 1, window, fullscreen
}

func capture(_ mode: Mode) { freeze(mode) }

/// On-screen app windows on `screen`, front to back, in the overlay's coordinates (origin bottom-left of the screen).
func windowRects(on screen: NSScreen) -> [NSRect] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    var out: [NSRect] = []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,                 // normal app windows only (no menu bar, Dock)
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              (w[kCGWindowOwnerPID as String] as? Int) != me,
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
        // CG: origin top-left of the main display, y down. AppKit: origin bottom-left, y up.
        let r = NSRect(x: cg.minX, y: mainHeight - cg.maxY, width: cg.width, height: cg.height).intersection(screen.frame)
        if r.width >= 30, r.height >= 30 { out.append(r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)) }
    }
    return out
}

/// Grabs the display under the cursor, then shows it frozen in the selection overlay.
func freeze(_ mode: Mode) {
    guard Overlay.window == nil else { return }
    let mouse = NSEvent.mouseLocation
    let screens = NSScreen.screens
    let idx = screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shot-\(UUID().uuidString).png")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {   // let the menu finish closing
        // Window rectangles are read at the moment of capture, so they match the frozen image.
        let windows = mode == .window ? windowRects(on: screens[idx]) : []
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-D", "\(idx + 1)", tmp.path]
        task.terminationHandler = { t in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: tmp) }
                // Decode straight to the target size so a full-resolution bitmap is never held in memory.
                // Retina by default; 1 pixel per point (smaller, softer) is opt-in in Settings.
                let screen = screens[idx]
                let scale: CGFloat = keepRetina ? screen.backingScaleFactor : 1
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceShouldCacheImmediately: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: max(screen.frame.width, screen.frame.height) * scale]
                guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
                Overlay.show(cg: cg, screen: screen, fullSelection: mode == .fullscreen, windows: windows)
            }
        }
        try? task.run()
    }
}
