import AppKit

/// A toolbar icon you drag out of the overlay and drop into another app (chat, Finder, Mail, a document).
/// The screenshot is written to a temporary file when the drag starts, in the chosen format and name.
final class DragHandle: NSButton, NSDraggingSource {
    var makeFile: (() -> URL?)?
    var onBegan: (() -> Void)?
    var onEnded: ((_ dropped: Bool) -> Void)?
    private var started = false

    override func mouseDown(with event: NSEvent) { started = false }   // no click action: this only drags

    override func mouseDragged(with event: NSEvent) {
        guard !started, let url = makeFile?() else { return }
        started = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let thumb = DragHandle.thumbnail(of: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        let h: CGFloat = 72, w = thumb.size.height > 0 ? max(24, min(160, h * thumb.size.width / thumb.size.height)) : h
        item.setDraggingFrame(NSRect(x: -w / 2, y: -h / 2, width: w, height: h), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// A small preview for the drag image. Loading the file itself would decode the full screenshot just to show 72 points.
    static func thumbnail(of url: URL) -> NSImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 320]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onBegan?() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded?(!operation.isEmpty)
    }
}
