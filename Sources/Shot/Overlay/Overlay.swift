import AppKit
import Carbon
import Darwin

/// Borderless windows can't become key on their own; the overlay needs the keyboard (Esc, Return, ⌘Z).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

enum Overlay {
    static var window: OverlayWindow?       // the overlay currently on screen, nil when idle
    /// The one overlay window, reused for every capture. AppKit never fully releases windows that were created and
    /// closed repeatedly (each kept its screenshot alive, ~22 MB per capture), so we never create a second one.
    static var spare: OverlayWindow?
    static var view: OverlayView?           // the one overlay view, see OverlayView.init
    static var generation = 0               // lets a stale timeout tell it belongs to an earlier capture
    static let escapeID: UInt32 = 99
    static var escRef: EventHotKeyRef?

    static func dismiss() { (window?.contentView as? OverlayView)?.escape() }

    static func show(cg: CGImage, screen: NSScreen, fullSelection: Bool, windows: [NSRect] = []) {
        guard window == nil else { return }
        let win: OverlayWindow
        if let w = spare {
            win = w
        } else {
            win = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.level = .screenSaver
            win.hasShadow = false
            win.isOpaque = true
            win.isReleasedWhenClosed = false
            win.acceptsMouseMovedEvents = true
            spare = win
        }
        win.setFrame(screen.frame, display: false)
        generation += 1
        let gen = generation
        let view: OverlayView
        if let v = Overlay.view {
            view = v
        } else {
            view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
            Overlay.view = view
            win.contentView = view
        }
        view.begin(cg: cg, size: screen.frame.size, windows: windows)
        view.onClose = {
            if let r = escRef { UnregisterEventHotKey(r); escRef = nil }
            view.end()              // releases the screenshot
            win.orderOut(nil)
            window = nil
            NSCursor.arrow.set()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSCursor.arrow.set() }
            // hand freed screenshot pages back to the OS instead of letting the allocator sit on them
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
        if fullSelection {
            view.sel = view.bounds
            view.beginEditing()
        }
        window = win
        // Safety nets so a full-screen overlay can never trap the user, even if it never gets key focus:
        // a global Esc hotkey (active only while the overlay is up), right-click, and a timeout before any selection.
        RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x53484F54, id: escapeID),
                            GetApplicationEventTarget(), 0, &escRef)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            if gen == generation, window != nil, !view.editing { view.onClose() }
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
