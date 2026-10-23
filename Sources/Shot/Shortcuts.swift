import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var code: UInt32
    var mods: UInt32      // Carbon modifier mask
    var label: String     // key as typed, uppercased

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }
}

enum Shortcuts {
    static let defaults: [Mode: Shortcut] = [
        .region: Shortcut(code: UInt32(kVK_ANSI_A), mods: UInt32(controlKey | optionKey), label: "A"),
        .window: Shortcut(code: UInt32(kVK_ANSI_W), mods: UInt32(controlKey | optionKey), label: "W"),
        .fullscreen: Shortcut(code: UInt32(kVK_ANSI_S), mods: UInt32(controlKey | optionKey), label: "S"),
    ]
    static var current: [Mode: Shortcut] = load()
    static var refs: [EventHotKeyRef] = []
    static var installed = false

    static func load() -> [Mode: Shortcut] {
        var out = defaults
        for m in [Mode.region, .window, .fullscreen] {
            if let d = UserDefaults.standard.data(forKey: "shortcut.\(m.rawValue)"),
               let s = try? JSONDecoder().decode(Shortcut.self, from: d) { out[m] = s }
        }
        return out
    }

    static func set(_ s: Shortcut, for m: Mode) {
        current[m] = s
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "shortcut.\(m.rawValue)")
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    /// (Re)registers all global hotkeys. Returns the modes the system refused (already taken elsewhere).
    @discardableResult
    static func register() -> [Mode] {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                if id.id == Overlay.escapeID { DispatchQueue.main.async { Overlay.dismiss() } }
                else if let m = Mode(rawValue: id.id) { DispatchQueue.main.async { capture(m) } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        var failed: [Mode] = []
        for (mode, s) in current {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(s.code, s.mods, EventHotKeyID(signature: 0x53484F54, id: mode.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref = ref { refs.append(ref) } else { failed.append(mode) }
        }
        return failed
    }
}

extension Mode: Hashable {}

/// Small window with one click-to-record button per action.
final class ShortcutWindow: NSObject, NSWindowDelegate {
    static var shared: ShortcutWindow?

    let window: NSWindow
    var buttons: [Mode: NSButton] = [:]
    let folderButton = NSButton()
    var recording: Mode?
    var monitor: Any?
    let note = NSTextField(labelWithString: "Click a shortcut, then press the new keys (needs a modifier). Esc cancels. Save Folder is used by the ↓ button.")
    var onChange: () -> Void

    static func show(onChange: @escaping () -> Void) {
        if shared == nil { shared = ShortcutWindow(onChange: onChange) }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window.makeKeyAndOrderFront(nil)
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Shot Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        var rows: [NSView] = []
        for (mode, title) in [(Mode.region, "Capture Region"), (.window, "Capture Window"), (.fullscreen, "Capture Full Screen")] {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let b = NSButton(title: Shortcuts.current[mode]?.display ?? "", target: self, action: #selector(startRecording(_:)))
            b.tag = Int(mode.rawValue)
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(equalToConstant: 140).isActive = true
            buttons[mode] = b
            rows.append(NSStackView(views: [label, b]))
        }
        let folderLabel = NSTextField(labelWithString: "Save Folder")
        folderLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        folderButton.bezelStyle = .rounded
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.widthAnchor.constraint(equalToConstant: 140).isActive = true
        folderButton.title = ShortcutWindow.folderTitle()
        rows.append(NSStackView(views: [folderLabel, folderButton]))

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = 340
        note.lineBreakMode = .byWordWrapping
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        let showIcon = NSButton(checkboxWithTitle: "Show menu bar icon", target: self, action: #selector(toggleIcon(_:)))
        showIcon.state = UserDefaults.standard.bool(forKey: "hideMenuIcon") ? .off : .on
        let quit = NSButton(title: "Quit Shot", target: nil, action: #selector(NSApplication.terminate(_:)))
        let bottom = NSStackView(views: [reset, quit])
        let stack = NSStackView(views: rows + [showIcon, note, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    static func folderTitle() -> String { (saveDir.path as NSString).abbreviatingWithTildeInPath }

    @objc func chooseFolder() {
        stopRecording()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDir
        panel.prompt = "Choose"
        panel.message = "Where should saved screenshots go?"
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url
            folderButton.title = ShortcutWindow.folderTitle()
            note.stringValue = "Save folder updated."
        }
    }

    @objc func startRecording(_ b: NSButton) {
        stopRecording()
        guard let mode = Mode(rawValue: UInt32(b.tag)) else { return }
        recording = mode
        b.title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] e in
            handle(e)
            return nil
        }
    }

    func handle(_ e: NSEvent) {
        guard let mode = recording else { return }
        if e.keyCode == 53 { stopRecording(); return }
        let mods = Shortcuts.carbonMods(e.modifierFlags)
        guard mods != 0, let ch = e.charactersIgnoringModifiers?.uppercased(), !ch.isEmpty else {
            NSSound.beep(); note.stringValue = "Include at least one of ⌃ ⌥ ⇧ ⌘."; return
        }
        let new = Shortcut(code: UInt32(e.keyCode), mods: mods, label: ch)
        if let clash = Shortcuts.current.first(where: { $0.key != mode && $0.value.code == new.code && $0.value.mods == new.mods }) {
            NSSound.beep(); note.stringValue = "\(new.display) is already used by another Shot action (\(clash.key))."; return
        }
        let old = Shortcuts.current[mode]
        Shortcuts.set(new, for: mode)
        if Shortcuts.register().contains(mode) {
            if let old = old { Shortcuts.set(old, for: mode) }
            Shortcuts.register()
            NSSound.beep(); note.stringValue = "\(new.display) is taken by the system or another app."
        } else {
            note.stringValue = "Saved."
        }
        stopRecording()
        onChange()
    }

    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
        refresh()
    }

    @objc func toggleIcon(_ b: NSButton) {
        let show = b.state == .on
        UserDefaults.standard.set(!show, forKey: "hideMenuIcon")
        (NSApp.delegate as? AppDelegate)?.item.isVisible = show
        note.stringValue = show ? "Menu bar icon shown." : "Icon hidden; shortcuts still work. Open Shot again from Applications to bring this window back."
    }

    @objc func resetDefaults() {
        stopRecording()
        for (m, s) in Shortcuts.defaults { Shortcuts.set(s, for: m) }
        Shortcuts.register()
        refresh()
        onChange()
        note.stringValue = "Defaults restored."
    }

    func refresh() {
        for (m, b) in buttons { b.title = Shortcuts.current[m]?.display ?? "" }
    }

    func windowWillClose(_ n: Notification) { stopRecording(); ShortcutWindow.shared = nil }
}
