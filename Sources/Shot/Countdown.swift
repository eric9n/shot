import AppKit
import Carbon

/// Delayed capture: a small number counts down at the top of the screen, then the normal capture starts.
/// The panel is hidden before the screen is grabbed, so it never ends up in the screenshot.
enum Countdown {
    static let escapeID: UInt32 = 98
    static let digitBase: UInt32 = 200           // hotkey ids 200...209 are the digits 0...9
    static var active: Bool { timer != nil }

    // Main keyboard digits 0...9, then the keypad's.
    private static let digitKeyCodes: [Int] = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
    private static var digitRefs: [EventHotKeyRef] = []

    private static var panel: NSPanel?
    private static let digits = NSTextField(labelWithString: "")
    private static var timer: Timer?
    private static var remaining = 0
    private static var action: (() -> Void)?
    private static var escRef: EventHotKeyRef?

    static func start(seconds: Int, then action: @escaping () -> Void) {
        guard !Session.isCapturing, !active, seconds > 0 else { return }
        self.action = action
        remaining = seconds
        digits.stringValue = "\(remaining)"
        show()
        RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x53484F54, id: escapeID),
                            GetApplicationEventTarget(), 0, &escRef)
        // Digit keys restart the countdown. The panel never takes keyboard focus (that would close the menu you are about
        // to capture), so these are system-wide hotkeys that only exist while a countdown runs.
        for (i, code) in digitKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: 0x53484F54, id: digitBase + UInt32(i % 10)),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref = ref { digitRefs.append(ref) }
        }
        timer = makeTimer()
    }

    private static func makeTimer() -> Timer {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            remaining -= 1
            if remaining <= 0 { finish() } else { digits.stringValue = "\(remaining)" }
        }
    }

    /// A digit key was pressed: start counting again from that many seconds (0 means 10).
    static func restart(digit: Int) {
        guard active else { return }
        let seconds = digit == 0 ? 10 : digit
        remaining = seconds
        digits.stringValue = "\(seconds)"
        timer?.invalidate()
        timer = makeTimer()      // a full second passes before the first tick
    }

    static func cancel() {
        stop()
        action = nil
    }

    private static func finish() {
        let go = action
        stop()
        action = nil
        // Let the panel leave the screen before anything is grabbed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { go?() }
    }

    private static func stop() {
        timer?.invalidate()
        timer = nil
        if let r = escRef { UnregisterEventHotKey(r); escRef = nil }
        digitRefs.forEach { UnregisterEventHotKey($0) }
        digitRefs = []
        panel?.orderOut(nil)
    }

    private static func show() {
        let p: NSPanel
        if let existing = panel { p = existing } else {
            p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 130, height: 110), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let card = CountdownView(frame: p.contentRect(forFrameRect: p.frame))
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            card.layer?.cornerRadius = 22
            digits.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
            digits.textColor = .white
            digits.alignment = .center
            digits.frame = NSRect(x: 0, y: 14, width: 130, height: 80)   // just the number; the keys are explained in Settings
            card.addSubview(digits)
            p.contentView = card
            panel = p
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        p.setFrameOrigin(NSPoint(x: screen.frame.midX - 65, y: screen.frame.maxY - 110 - 50))   // top center, under the menu bar
        p.orderFrontRegardless()
    }
}

/// Clicking the countdown cancels it.
private final class CountdownView: NSView {
    override func mouseDown(with event: NSEvent) { Countdown.cancel() }
}
