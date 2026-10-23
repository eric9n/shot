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

