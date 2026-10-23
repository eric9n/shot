import AppKit

/// Puts PNG bytes on the clipboard (the pasteboard keeps its own copy). Runs in the capture child, which may exit right
/// after, so the auto-clear timer is run by the menu-bar process: the child just reports the copy.
func copyToClipboard(_ bmp: NSBitmapImageRep) {
    guard let png = bmp.representation(using: .png, properties: [:]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(png, forType: .png)
    Session.report("copied \(pb.changeCount)")
}

private var clipboardTimer: Timer?

/// Menu-bar process: clears the clipboard after the chosen delay, unless something else has been copied since.
func scheduleClipboardClear(changeCount mine: Int) {
    clipboardTimer?.invalidate()
    let seconds = clipboardClearSeconds
    guard seconds > 0 else { return }
    clipboardTimer = Timer.scheduledTimer(withTimeInterval: Double(seconds), repeats: false) { _ in
        if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() }
    }
}
