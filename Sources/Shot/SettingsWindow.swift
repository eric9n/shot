import AppKit
import Carbon
import ServiceManagement

/// The Settings window: shortcuts (click a button, press the new keys), save folder, and the other options.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static var shared: SettingsWindow?

    let window: NSWindow
    var buttons: [Mode: NSButton] = [:]
    let folderButton = NSButton()
    let clipPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    static let clipOptions: [(String, Int)] = [("Never", 0), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300)]
    var recording: Mode?
    var monitor: Any?
    let note = NSTextField(labelWithString: "Click a shortcut, then press the new keys (needs a modifier). Esc cancels. Save Folder is used by the ↓ button.")
    var onChange: () -> Void

    static func show(onChange: @escaping () -> Void) {
        if shared == nil { shared = SettingsWindow(onChange: onChange) }
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
        folderButton.title = SettingsWindow.folderTitle()
        rows.append(NSStackView(views: [folderLabel, folderButton]))

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = 340
        note.lineBreakMode = .byWordWrapping
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        let showIcon = NSButton(checkboxWithTitle: "Show menu bar icon", target: self, action: #selector(toggleIcon(_:)))
        showIcon.state = UserDefaults.standard.bool(forKey: "hideMenuIcon") ? .off : .on
        let retina = NSButton(checkboxWithTitle: "Keep Retina resolution (uncheck to use less memory)", target: self, action: #selector(toggleRetina(_:)))
        retina.state = keepRetina ? .on : .off
        let login = NSButton(checkboxWithTitle: "Launch Shot at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let clipLabel = NSTextField(labelWithString: "Clear clipboard after")
        clipLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        clipPopup.addItems(withTitles: SettingsWindow.clipOptions.map(\.0))
        clipPopup.selectItem(at: SettingsWindow.clipOptions.firstIndex { $0.1 == clipboardClearSeconds } ?? 0)
        clipPopup.target = self
        clipPopup.action = #selector(clipChanged(_:))
        clipPopup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let clipRow = NSStackView(views: [clipLabel, clipPopup])

        let quit = NSButton(title: "Quit Shot", target: nil, action: #selector(NSApplication.terminate(_:)))
        let bottom = NSStackView(views: [reset, quit])
        let stack = NSStackView(views: rows + [clipRow, showIcon, retina, login, note, bottom])
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
            folderButton.title = SettingsWindow.folderTitle()
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

    @objc func clipChanged(_ p: NSPopUpButton) {
        clipboardClearSeconds = SettingsWindow.clipOptions[p.indexOfSelectedItem].1
        note.stringValue = clipboardClearSeconds == 0 ? "Copied screenshots stay on the clipboard."
            : "A copied screenshot is removed after \(p.titleOfSelectedItem ?? "")  (only if you haven't copied something else)."
    }

    @objc func toggleLogin(_ b: NSButton) {
        do {
            if b.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note.stringValue = b.state == .on ? "Shot will start when you log in." : "Shot will not start at login."
        } catch {
            b.state = b.state == .on ? .off : .on   // revert the checkbox
            note.stringValue = "Couldn't change the login item: \(error.localizedDescription)"
        }
    }

    @objc func toggleRetina(_ b: NSButton) {
        keepRetina = b.state == .on
        note.stringValue = keepRetina ? "New screenshots keep full Retina resolution." : "New screenshots use 1x resolution (softer, less memory)."
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

    func windowWillClose(_ n: Notification) { stopRecording(); SettingsWindow.shared = nil }
}
