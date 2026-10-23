import AppKit

/// Every capture runs in its own short-lived copy of Shot (`Shot --capture <mode>`). The child freezes the screen, shows
/// the overlay, and exits when the overlay and any pins it made are closed, so all of its memory goes back to the system.
/// The menu-bar process never holds a screenshot.
///
/// The child talks back with one line per event on its standard output:
///   "copied <changeCount>"  something was put on the clipboard (the parent runs the auto-clear timer)
///   "overlay-closed"        the overlay is gone but pins are still open
enum Session {
    static let flag = "--capture"

    // MARK: parent (menu-bar process)

    private static var children: [Process] = []
    private static var capturing: Process?          // the child whose overlay is still up

    /// Starts a capture in a new child, unless one is already freezing the screen.
    static func start(_ mode: Mode) {
        guard capturing == nil, let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = [flag, String(mode.rawValue)]
        let out = Pipe()
        p.standardOutput = out
        var pending = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                pending += String(decoding: data, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    handle(String(pending[..<nl]), from: p)
                    pending = String(pending[pending.index(after: nl)...])
                }
            }
        }
        p.terminationHandler = { p in
            DispatchQueue.main.async {
                children.removeAll { $0 === p }
                if capturing === p { capturing = nil }
            }
        }
        do {
            try p.run()
            children.append(p)
            capturing = p
        } catch {
            NSLog("Shot: could not start capture: \(error)")
        }
    }

    private static func handle(_ line: String, from p: Process) {
        let parts = line.split(separator: " ")
        switch parts.first {
        case "copied": if parts.count > 1, let n = Int(parts[1]) { scheduleClipboardClear(changeCount: n) }
        case "overlay-closed": if capturing === p { capturing = nil }
        default: break
        }
    }

    /// True while a capture child is still freezing the screen or showing its overlay.
    static var isCapturing: Bool { capturing != nil }
    /// Children that only show pins now.
    static var hasPins: Bool { children.contains { $0 !== capturing } }
    static func closeAllPins() { children.filter { $0 !== capturing }.forEach { $0.terminate() } }

    // MARK: child (one capture)

    /// If launched as a capture child, runs the capture and never returns.
    static func runChildIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let raw = UInt32(args[i + 1]), let mode = Mode(rawValue: raw) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Shortcuts.installHandler()          // for the overlay's Esc hotkey
        freeze(mode)
        app.run()
        exit(0)
    }

    static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// The overlay closed: done, unless pins are still on screen.
    static func overlayClosed() {
        if Pins.active.isEmpty { exit(0) }
        report("overlay-closed")
    }

    /// The last pin closed: done, unless the overlay is (somehow) still up.
    static func pinsClosed() {
        if Overlay.window == nil { exit(0) }
    }
}
