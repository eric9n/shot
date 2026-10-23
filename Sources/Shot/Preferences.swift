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

/// Seconds the "Delayed Capture" shortcut waits (3, 5 or 10; default 5). The menu can still pick another one for a single capture.
let delayChoices = [3, 5, 10]
var delaySeconds: Int {
    get {
        let v = UserDefaults.standard.integer(forKey: "delaySeconds")
        return delayChoices.contains(v) ? v : 5
    }
    set { UserDefaults.standard.set(newValue, forKey: "delaySeconds") }
}

enum SaveFormat: String, CaseIterable {
    case png, jpg, heic
    var title: String { rawValue.uppercased() }
}

var saveFormat: SaveFormat {
    get { SaveFormat(rawValue: UserDefaults.standard.string(forKey: "saveFormat") ?? "") ?? .png }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "saveFormat") }
}

let defaultNamePattern = "Shot {date} at {time}"

/// File name template: {date} = 2026-10-23, {time} = 14.05.09, {n} = a counter that goes up by one per saved file.
var namePattern: String {
    get { UserDefaults.standard.string(forKey: "namePattern") ?? defaultNamePattern }
    set { UserDefaults.standard.set(newValue, forKey: "namePattern") }
}

var fileCounter: Int {
    get { max(UserDefaults.standard.integer(forKey: "fileCounter"), 1) }
    set { UserDefaults.standard.set(newValue, forKey: "fileCounter") }
}

/// The last region you confirmed (copied, saved or dragged out), in the overlay's coordinates, for "Repeat Last Region".
var lastRegion: NSRect? {
    get {
        guard let v = UserDefaults.standard.array(forKey: "lastRegion") as? [Double], v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    set {
        if let r = newValue { UserDefaults.standard.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: "lastRegion") }
        else { UserDefaults.standard.removeObject(forKey: "lastRegion") }
    }
}
