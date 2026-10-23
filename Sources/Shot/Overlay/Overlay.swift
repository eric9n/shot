import AppKit
import Carbon

/// Borderless windows can't become key on their own; the overlay needs the keyboard (Esc, Return, ⌘Z).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The capture child's one overlay. When it closes the child exits (or waits for its pins), so nothing here needs to
/// release memory by hand.
enum Overlay {
    static var window: OverlayWindow?       // the overlay on screen, nil once closed
    static let escapeID: UInt32 = 99
    static var escRef: EventHotKeyRef?

    static func dismiss() { (window?.contentView as? OverlayView)?.escape() }

    static func show(cg: CGImage, screen: NSScreen, fullSelection: Bool, windows: [NSRect] = [], preselect: NSRect? = nil) {
        guard window == nil else { return }
        let win = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.hasShadow = false
        win.isOpaque = true
        win.isReleasedWhenClosed = false
        win.acceptsMouseMovedEvents = true
        win.setFrame(screen.frame, display: false)
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
        win.contentView = view
        view.begin(cg: cg, size: screen.frame.size, windows: windows)
        view.onClose = {
            if let r = escRef { UnregisterEventHotKey(r); escRef = nil }   // pins may keep the process running
            win.orderOut(nil)
            window = nil
            NSCursor.arrow.set()
            Session.overlayClosed()
        }
        if fullSelection {
            view.sel = view.bounds
            view.beginEditing()
        } else if let r = preselect?.intersection(view.bounds), r.width >= 20, r.height >= 20 {
            view.sel = r                    // "Repeat Last Region": start with the previous region already selected
            view.beginEditing()
        }
        window = win
        // Safety nets so a full-screen overlay can never trap the user, even if it never gets key focus:
        // a global Esc hotkey (active only while the overlay is up), right-click, and a timeout before any selection.
        RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x53484F54, id: escapeID),
                            GetApplicationEventTarget(), 0, &escRef)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            if window != nil, !view.editing { view.onClose() }
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSCursor.crosshair.set()
        if !windows.isEmpty {   // highlight the window already under the cursor
            let m = NSEvent.mouseLocation
            view.updateHover(at: CGPoint(x: m.x - screen.frame.minX, y: m.y - screen.frame.minY))
        }
    }
}
