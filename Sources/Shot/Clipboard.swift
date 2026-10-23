import AppKit

var clipboardTimer: Timer?

/// Puts PNG bytes on the clipboard. The pasteboard keeps its own copy, so Shot holds no image afterwards
/// (handing it an NSImage makes the pasteboard retain the whole image until the next copy).
func copyToClipboard(_ bmp: NSBitmapImageRep) {
    guard let png = bmp.representation(using: .png, properties: [:]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)

    clipboardTimer?.invalidate()
    let seconds = clipboardClearSeconds
    guard seconds > 0 else { return }
    let mine = pb.changeCount
    clipboardTimer = Timer.scheduledTimer(withTimeInterval: Double(seconds), repeats: false) { _ in
        // Only clear if nothing else has been copied since.
        if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() }
    }
}
