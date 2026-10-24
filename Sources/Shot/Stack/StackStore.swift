import AppKit
import CryptoKit

/// One thing in the stack: a picture, some text, or a link. `id` is a fingerprint of the content, so the same content is
/// never stored twice: storing it again only moves the existing item to the front.
struct StackItem: Codable, Equatable {
    enum Kind: String, Codable { case image, text, link }
    let id: String
    let kind: Kind
    var created: Date
    var frame: CGRect       // where the pin was on screen (points), so it can be put back there
}

/// The stack's contents on disk, shared by every Shot process (pins write, the stack window reads). One folder per item
/// holding `meta.json` and the content, newest first, at most `limit` items. The menu-bar process clears it when Shot
/// starts and quits, so it only ever holds what was stored in this run.
enum StackStore {
    static let limit = 10
    static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shot/Stack", isDirectory: true)

    // MARK: adding

    /// A text is a link when the whole of it is one http(s) address.
    static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }

    private static func fingerprint(_ prefix: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores a picture. The fingerprint covers the pixels only, so the same picture pinned at another size is still the same.
    @discardableResult
    static func add(image bmp: NSBitmapImageRep, frame: CGRect) -> StackItem? {
        guard let pixels = bmp.bitmapData, let png = bmp.representation(using: .png, properties: [:]) else { return nil }
        let id = fingerprint("image \(bmp.pixelsWide)x\(bmp.pixelsHigh) ", Data(bytes: pixels, count: bmp.bytesPerRow * bmp.pixelsHigh))
        return add(id: id, kind: .image, file: "content.png", content: png, frame: frame)
    }

    /// Stores text, or a link when the text is just an address.
    @discardableResult
    static func add(text: String, frame: CGRect) -> StackItem? {
        let data = Data(text.utf8)
        return add(id: fingerprint("text ", data), kind: isLink(text) ? .link : .text, file: "content.txt", content: data, frame: frame)
    }

    private static func add(id: String, kind: StackItem.Kind, file: String, content: Data, frame: CGRect) -> StackItem? {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent(id, isDirectory: true)
        let item = StackItem(id: id, kind: kind, created: Date(), frame: frame)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let contentURL = folder.appendingPathComponent(file)
            if !fm.fileExists(atPath: contentURL.path) { try content.write(to: contentURL, options: .atomic) }
            // Same content again: only the date (and where it was) changes, which moves it to the front.
            try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            return nil
        }
        items().dropFirst(limit).forEach { remove($0.id) }
        return item
    }

    // MARK: reading

    /// All items, newest first.
    static func items() -> [StackItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { f in
            (try? Data(contentsOf: f.appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(StackItem.self, from: $0) }
        }.sorted { $0.created > $1.created }
    }

    static func contentURL(_ item: StackItem) -> URL {
        dir.appendingPathComponent(item.id).appendingPathComponent(item.kind == .image ? "content.png" : "content.txt")
    }

    static func text(of item: StackItem) -> String? {
        item.kind == .image ? nil : try? String(contentsOf: contentURL(item), encoding: .utf8)
    }

    static func item(id: String) -> StackItem? { items().first { $0.id == id } }

    // MARK: removing

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}
