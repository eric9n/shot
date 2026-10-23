import AppKit
import Carbon

// Shot: menu-bar screenshot tool. No network code, no dependencies.
// Capture is done by Apple's own /usr/sbin/screencapture.

enum Mode: UInt32 {
    case region = 1, window, fullscreen
}

let defaultSaveDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Shot", isDirectory: true)

/// User-chosen folder (Settings), falling back to ~/Pictures/Shot.
var saveDir: URL {
    get {
        let dir = UserDefaults.standard.string(forKey: "saveDir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultSaveDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    set { UserDefaults.standard.set(newValue.path, forKey: "saveDir") }
}

/// Seconds after which a copied screenshot is removed from the clipboard (0 = never).
var clipboardClearSeconds: Int {
    get { UserDefaults.standard.integer(forKey: "clipboardClear") }
    set { UserDefaults.standard.set(newValue, forKey: "clipboardClear") }
}

var clipboardTimer: Timer?

/// Puts PNG bytes on the clipboard. The pasteboard keeps its own copy, so Shot holds no image afterwards
/// (handing it an NSImage makes the pasteboard retain the whole image until the next copy).
func copyToClipboard(_ bmp: NSBitmapImageRep) {
    guard let png = bmp.representation(using: .png, properties: [:]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)

    clipboardTimer?.invalidate()
    let seconds = clipboardClearSeconds
    guard seconds > 0 else { return }
    let mine = pb.changeCount
    clipboardTimer = Timer.scheduledTimer(withTimeInterval: Double(seconds), repeats: false) { _ in
        // Only clear if nothing else has been copied since.
        if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() }
    }
}

/// Full Retina resolution unless the user opted into 1x to save memory.
var keepRetina: Bool {
    get { UserDefaults.standard.object(forKey: "retina") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "retina") }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        menu.addItem(.separator())
        add("Settings…", #selector(editShortcuts))
        add("Open Screenshots Folder", #selector(openFolder))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    /// Launching Shot again (Finder, Spotlight, Dock) reopens Settings, the way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ShortcutWindow.show { [self] in buildMenu() }
        return true
    }

    @objc func region() { capture(.region) }
    @objc func window() { capture(.window) }
    @objc func full() { capture(.fullscreen) }
    @objc func openFolder() { NSWorkspace.shared.open(saveDir) }
    @objc func editShortcuts() { ShortcutWindow.show { [self] in buildMenu() } }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
