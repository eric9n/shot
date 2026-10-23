import AppKit

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

/// Full Retina resolution unless the user opted into 1x to save memory.
var keepRetina: Bool {
    get { UserDefaults.standard.object(forKey: "retina") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "retina") }
}
