import AppKit

/// Turns a finished screenshot into a file: format, name, and a unique path.
enum Output {
    /// Expands the name template. Characters that can't appear in a file name are replaced.
    static func fileName(pattern: String, date: Date = Date(), counter: Int = 1) -> String {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH.mm.ss"
        var name = pattern
            .replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: time.string(from: date))
            .replacingOccurrences(of: "{n}", with: String(counter))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Shot" : name
    }

    /// Encodes in the chosen format. HEIC falls back to PNG if this Mac can't write it; `ext` is the extension actually used.
    static func encode(_ bmp: NSBitmapImageRep, as format: SaveFormat) -> (data: Data, ext: String)? {
        switch format {
        case .png:
            return bmp.representation(using: .png, properties: [:]).map { ($0, "png") }
        case .jpg:
            return bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.9]).map { ($0, "jpg") }
        case .heic:
            if let cg = bmp.cgImage {
                let data = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                    if CGImageDestinationFinalize(dest) { return (data as Data, "heic") }
                }
            }
            return encode(bmp, as: .png)
        }
    }

    /// A path in `dir` that doesn't exist yet ("name.png", then "name 2.png", "name 3.png", …).
    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(i).\(ext)")
            i += 1
        }
        return url
    }

    /// Saves into `dir` (default: the save folder) using the chosen format and name template. Returns the file written.
    @discardableResult
    static func write(_ bmp: NSBitmapImageRep, to dir: URL = saveDir) -> URL? {
        guard let (data, ext) = encode(bmp, as: saveFormat) else { return nil }
        let pattern = namePattern
        let counter = fileCounter
        let url = uniqueURL(in: dir, name: fileName(pattern: pattern, counter: counter), ext: ext)
        guard (try? data.write(to: url)) != nil else { return nil }
        if pattern.contains("{n}") { fileCounter = counter + 1 }
        return url
    }

    /// Example of what the current settings produce, for the Settings window.
    static func example() -> String {
        "\(fileName(pattern: namePattern, counter: fileCounter)).\(saveFormat.rawValue)"
    }
}
