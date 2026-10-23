import AppKit

enum Mode: UInt32 {
    case region = 1, window, fullscreen, repeatLast, delayed
}

func capture(_ mode: Mode) {
    if mode == .delayed {
        // The shortcut starts a countdown with the default delay; pressing it again cancels the countdown.
        // When it ends the screen freezes with the last region already selected (plain selection if there is none yet).
        if Countdown.active { Countdown.cancel() } else { Countdown.start(seconds: delaySeconds) { Session.start(.repeatLast) } }
        return
    }
    Session.start(mode)
}

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

/// Capture child: grabs the display under the cursor, then shows it frozen in the selection overlay.
/// If anything fails there is nothing to show, so the child just exits.
func freeze(_ mode: Mode) {
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
                // Decode once, at the size the overlay shows: Retina by default, or 1 pixel per point (smaller, softer)
                // when chosen in Settings.
                let screen = screens[idx]
                let scale: CGFloat = keepRetina ? screen.backingScaleFactor : 1
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceShouldCacheImmediately: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: max(screen.frame.width, screen.frame.height) * scale]
                let cg = CGImageSourceCreateWithURL(tmp as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts as CFDictionary) }
                try? FileManager.default.removeItem(at: tmp)
                guard let cg = cg else { exit(1) }
                Overlay.show(cg: cg, screen: screen, fullSelection: mode == .fullscreen, windows: windows,
                             preselect: mode == .repeatLast ? lastRegion : nil)
            }
        }
        do { try task.run() } catch { exit(1) }
    }
}
