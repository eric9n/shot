// Stress test for the capture overlay: runs frame -> resize -> annotate -> export -> close (or pin and unpin) many times and reports
// whether memory keeps growing. It compiles the real overlay sources, so it catches regressions such as a window or
// view (and the full-screen image it holds) staying alive after every capture.
//
// Run through tools/leak-check.sh. Env: CYCLES (default 40).
import AppKit
import Darwin

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return Double(info.phys_footprint) / 1_048_576
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let scale = screen.backingScaleFactor
let cycles = Int(ProcessInfo.processInfo.environment["CYCLES"] ?? "40") ?? 40

// A real PNG on disk, decoded the way Shot decodes a capture, so every cycle gets a fresh full-size CGImage.
let pngURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shot-leak-check.png")
do {
    let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for i in 0..<60 {
        ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: i * h / 60, width: w, height: h / 60))
    }
    let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func decode() -> CGImage {
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: max(screen.frame.width, screen.frame.height) * scale]
    return CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithURL(pngURL as CFURL, nil)!, 0, opts as CFDictionary)!
}

func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: Overlay.window!.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

func oneCapture() {
    Overlay.show(cg: decode(), screen: screen, fullSelection: false)
    let view = Overlay.window!.contentView as! OverlayView
    func drag(_ a: CGPoint, _ b: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, a))
        view.mouseDragged(with: event(.leftMouseDragged, b))
        view.mouseUp(with: event(.leftMouseUp, b))
    }
    drag(CGPoint(x: 200, y: 200), CGPoint(x: 800, y: 600))      // frame a region
    drag(CGPoint(x: 800, y: 200), CGPoint(x: 900, y: 150))      // resize by a corner handle
    for tool in [Tool.rect, .mosaic, .arrow, .pen] {            // one annotation of each kind
        view.tool = tool
        drag(CGPoint(x: 300, y: 300), CGPoint(x: 500, y: 450))
    }
    view.tool = .rect
    drag(CGPoint(x: 400, y: 300), CGPoint(x: 450, y: 320))      // grab and move an annotation
    _ = view.rendered()                                         // export, as ✓ and ↓ do
    if done % 2 == 1 {                                          // every other capture ends as a pin, then the pin is closed
        view.pinAction()
        Pins.closeAll()
    } else {
        view.copyAndClose()
    }
}

var done = 0
var readings: [Double] = []
print(String(format: "start: %.0f MB, %d cycles", footprintMB(), cycles))

func next() {
    if done == cycles {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let head = readings.prefix(3), tail = readings.suffix(3)
            let drift = tail.reduce(0, +) / Double(max(tail.count, 1)) - head.reduce(0, +) / Double(max(head.count, 1))
            print(String(format: "final: %.0f MB", footprintMB()))
            print(String(format: "drift: %+.1f MB", drift))
            exit(0)
        }
        return
    }
    autoreleasepool { oneCapture() }
    done += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {     // let the close and the page-return timer fire, as in real use
        if done % 4 == 0 {
            readings.append(footprintMB())
            print(String(format: "after %2d: %.0f MB", done, readings.last!))
        }
        next()
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
app.run()
