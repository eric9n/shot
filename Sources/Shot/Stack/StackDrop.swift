import AppKit
import UniformTypeIdentifiers

/// What can be dropped on the icon: selected text, a link, a picture (from a web page, or an image file). Other files are
/// not stored.
enum StackDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL, .string]

    private static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func webURL(_ pb: NSPasteboard) -> URL? {
        (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first { !$0.isFileURL }
    }

    private static func text(_ pb: NSPasteboard) -> String? {
        let t = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : String(t.prefix(5000))
    }

    /// Whether the pasteboard has something the stack can take (cheap: nothing is read or decoded).
    static func accepts(_ pb: NSPasteboard) -> Bool {
        let files = fileURLs(pb)
        if !files.isEmpty { return files.contains(where: isImageFile) }      // files: only pictures
        if pb.availableType(from: [.png, .tiff]) != nil { return true }
        return webURL(pb) != nil || text(pb) != nil
    }

    /// Stores what is on the pasteboard and returns how many items it added. Pictures are stored as pictures, a web link
    /// or a text that is one address as a link, other text as text. If it holds both a picture and a link (a picture from
    /// a web page), the picture wins. `center` is where "pin it back" will put it, since a drop has no pin to remember.
    @discardableResult
    static func store(_ pb: NSPasteboard, around center: CGPoint) -> Int {
        func frame(_ size: NSSize) -> CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        let files = fileURLs(pb)
        if !files.isEmpty {
            var stored = 0
            for url in files where isImageFile(url) {
                if let data = try? Data(contentsOf: url), let bmp = NSBitmapImageRep(data: data),
                   StackStore.add(image: bmp, frame: frame(bmp.size)) != nil { stored += 1 }
            }
            return stored
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let bmp = NSBitmapImageRep(data: data) {
            return StackStore.add(image: bmp, frame: frame(bmp.size)) == nil ? 0 : 1
        }
        if let url = webURL(pb) {
            return StackStore.add(text: url.absoluteString, frame: frame(NSSize(width: 300, height: 100))) == nil ? 0 : 1
        }
        if let t = text(pb) {
            return StackStore.add(text: t, frame: frame(NSSize(width: 300, height: 100))) == nil ? 0 : 1
        }
        return 0
    }
}
