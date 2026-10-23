import AppKit
import Carbon

// Shot: menu-bar screenshot tool. No network code, no dependencies.
// Capture is done by Apple's own /usr/sbin/screencapture.

enum Mode: UInt32 {
    case region = 1, window, fullscreen

    var args: [String] {
        switch self {
        case .region: return ["-i", "-s"]
        case .window: return ["-i", "-w"]
        case .fullscreen: return []
        }
    }
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

/// Puts PNG bytes on the clipboard. The pasteboard keeps its own copy, so Shot holds no image afterwards
/// (handing it an NSImage makes the pasteboard retain the whole image until the next copy).
func copyToClipboard(_ bmp: NSBitmapImageRep) {
    guard let png = bmp.representation(using: .png, properties: [:]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)
}

func dbg(_ m: String) {
    let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shot.log")
    let line = "\(Date()) \(m)\n"
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: f, atomically: true, encoding: .utf8) }
}

func capture(_ mode: Mode) {
    dbg("capture \(mode)")
    if mode != .window { freeze(fullSelection: mode == .fullscreen); return }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let file = saveDir.appendingPathComponent("Shot \(fmt.string(from: Date())).png")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = mode.args + [file.path]
    task.terminationHandler = { t in
        dbg("exit \(t.terminationStatus)")
        DispatchQueue.main.async {
            // User pressed Esc -> no file written.
            guard let img = NSImage(contentsOf: file) else { return }
            if let data = try? Data(contentsOf: file) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            }
            NSSound(named: "Pop")?.play()
            _ = Editor(file: file, image: img)
        }
    }
    
    do { try task.run() } catch { dbg("run failed \(error)") }
}

/// Grabs the display under the cursor, then shows it frozen in the selection overlay.
func freeze(fullSelection: Bool) {
    guard Overlay.window == nil else { return }
    let mouse = NSEvent.mouseLocation
    let screens = NSScreen.screens
    let idx = screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shot-\(UUID().uuidString).png")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {   // let the menu finish closing
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-D", "\(idx + 1)", tmp.path]
        task.terminationHandler = { t in
            dbg("freeze exit \(t.terminationStatus)")
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let data = try? Data(contentsOf: tmp), let img = NSImage(data: data) else { return }
                Overlay.show(image: img, screen: screens[idx], fullSelection: fullSelection)
            }
        }
        do { try task.run() } catch { dbg("run failed \(error)") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shot")

        item.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuIcon")
        buildMenu()
        let failed = Shortcuts.register()
        if !failed.isEmpty { dbg("hotkeys refused: \(failed)") }
        dbg("preflight=\(CGPreflightScreenCaptureAccess())")
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
