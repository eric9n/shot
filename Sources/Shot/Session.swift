import AppKit

/// Shot runs the heavy things in short-lived copies of itself, so the menu-bar process never holds a screenshot and
/// everything a copy used goes back to the system when it exits:
///   `Shot --capture <mode>`   freezes the screen and shows the overlay; exits when the overlay and its pins are closed
///   `Shot --pin-clipboard`    pins the clipboard's picture or text
///   `Shot --pin-item <id>`    puts a stored item back on the screen as a pin
///   `Shot --stack [--peek]`   the stack window (`--peek`: only for two seconds, after something was stored)
///
/// A child talks back with one line per event on its standard output:
///   "copied <changeCount>"  something was put on the clipboard (the parent runs the auto-clear timer)
///   "overlay-closed"        the overlay is gone but pins are still open
///   "stored"                a pin was stored in the stack
///   "pin-item <id>"         the stack asks for a stored item to be pinned
enum Session {
    static let flag = "--capture"
    static let pinClipboardFlag = "--pin-clipboard"
    static let pinItemFlag = "--pin-item"
    static let stackFlag = "--stack"
    static let peekFlag = "--peek"

    // MARK: parent (menu-bar process)

    private enum Role { case capture, pin, stack }

    private static var children: [Process] = []
    private static var capturing: Process?          // the child whose overlay is still up
    private static var stack: Process?              // the stack window, while it is showing

    /// Starts a capture in a new child, unless one is already freezing the screen.
    static func start(_ mode: Mode) {
        guard capturing == nil else { return }
        launch([flag, String(mode.rawValue)], role: .capture)
    }

    /// True when the clipboard holds a picture or text that can be pinned.
    static var clipboardCanPin: Bool {
        NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue,
                                                                    NSPasteboard.PasteboardType.string.rawValue])
    }

    /// Pins the clipboard's picture or text in a new child.
    static func pinClipboard() {
        guard clipboardCanPin else { NSSound.beep(); return }
        launch([pinClipboardFlag], role: .pin)
    }

    /// Shows the stack, or hides it if it is showing.
    static func toggleStack() {
        if let s = stack {
            stack = nil
            s.terminate()
        } else {
            launch([stackFlag], role: .stack)
        }
    }

    private static func launch(_ arguments: [String], role: Role) {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments
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
                if stack === p { stack = nil }
            }
        }
        do {
            try p.run()
            children.append(p)
            switch role {
            case .capture: capturing = p
            case .stack: stack = p
            case .pin: break
            }
        } catch {
            NSLog("Shot: could not start child: \(error)")
        }
    }

    static func handle(_ line: String, from p: Process) {
        let parts = line.split(separator: " ")
        switch parts.first {
        case "copied": if parts.count > 1, let n = Int(parts[1]) { scheduleClipboardClear(changeCount: n) }
        case "overlay-closed": if capturing === p { capturing = nil }
        case "stored": if stack == nil { launch([stackFlag, peekFlag], role: .stack) }   // show it for two seconds
        case "pin-item": if parts.count > 1 { launch([pinItemFlag, String(parts[1])], role: .pin) }
        default: break
        }
    }

    /// True while a capture child is still freezing the screen or showing its overlay.
    static var isCapturing: Bool { capturing != nil }
    /// Children that only show pins now.
    private static var pinChildren: [Process] { children.filter { $0 !== capturing && $0 !== stack } }
    static var hasPins: Bool { !pinChildren.isEmpty }
    static func closeAllPins() { pinChildren.forEach { $0.terminate() } }

    /// Shot is quitting: close everything it started and forget what was stored in the stack.
    static func shutdown() {
        children.forEach { $0.terminate() }
        StackStore.clear()
    }

    // MARK: child

    /// If launched as a child, does its job and never returns.
    static func runChildIfRequested() {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        func value(after name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

        if args.contains(stackFlag) {
            StackSession.run(peek: args.contains(peekFlag))
        }
        if args.contains(pinClipboardFlag) {
            app.setActivationPolicy(.accessory)
            if !Pins.pinClipboard() { exit(1) }
            app.run()
            exit(0)
        }
        if let id = value(after: pinItemFlag) {
            app.setActivationPolicy(.accessory)
            if !Pins.pinItem(id: id) { exit(1) }
            app.run()
            exit(0)
        }
        guard let raw = value(after: flag).flatMap({ UInt32($0) }), let mode = Mode(rawValue: raw) else { return }
        app.setActivationPolicy(.accessory)
        Shortcuts.installHandler()          // for the overlay's Esc hotkey
        freeze(mode)
        app.run()
        exit(0)
    }

    /// Tells the menu-bar process something. If it has already gone away the write just fails; it must not kill this process.
    static func report(_ line: String) {
        signal(SIGPIPE, SIG_IGN)
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
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
