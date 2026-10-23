import AppKit

// Shot: menu-bar screenshot tool. No network code, no dependencies.
// The screen is grabbed with Apple's own /usr/sbin/screencapture; everything else is drawn by Shot.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shot")

        item.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuIcon")
        buildMenu()
        Shortcuts.register()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    func buildMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        func sc(_ m: Mode) -> String { "   " + (Shortcuts.current[m]?.display ?? "") }
        add("Capture Region" + sc(.region), #selector(region))
        add("Capture Window" + sc(.window), #selector(window))
        add("Capture Full Screen" + sc(.fullscreen), #selector(full))
        add("Repeat Last Region" + sc(.repeatLast), #selector(repeatLast))
        add("Delayed Capture (\(delaySeconds) s)" + sc(.delayed), #selector(delayedDefault))
        let delays = NSMenu()
        for seconds in delayChoices {
            let mi = NSMenuItem(title: "Last region in \(seconds) seconds", action: #selector(delayed(_:)), keyEquivalent: "")
            mi.tag = seconds
            mi.target = self
            delays.addItem(mi)
        }
        let delayItem = NSMenuItem(title: "Other Delays", action: nil, keyEquivalent: "")
        delayItem.submenu = delays
        menu.addItem(delayItem)
        add("Close All Pins", #selector(closePins))
        menu.addItem(.separator())
        add("Settings…", #selector(editShortcuts))
        add("Open Screenshots Folder", #selector(openFolder))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    /// "Close All Pins" is only available while something is pinned.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(closePins) ? !Pins.active.isEmpty : true
    }

    /// Launching Shot again (Finder, Spotlight, Dock) reopens Settings, the way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show { [self] in buildMenu() }
        return true
    }

    @objc func region() { capture(.region) }
    @objc func window() { capture(.window) }
    @objc func full() { capture(.fullscreen) }
    @objc func repeatLast() { capture(.repeatLast) }
    @objc func delayedDefault() { capture(.delayed) }
    @objc func delayed(_ item: NSMenuItem) { Countdown.start(seconds: item.tag) { freeze(.repeatLast) } }
    @objc func closePins() { Pins.closeAll() }
    @objc func openFolder() { NSWorkspace.shared.open(saveDir) }
    @objc func editShortcuts() { SettingsWindow.show { [self] in buildMenu() } }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
