import Vision

/// Reads QR codes (and other bar codes) in an image with the system's Vision framework. Everything runs on this Mac.
enum Qr {
    /// What each code in the image says, top to bottom and left to right, without repeats. Empty if there is none.
    /// Runs on a background queue; `done` is called on the main queue.
    static func read(_ image: CGImage, done: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNDetectBarcodesRequest()      // all the kinds of codes the system knows, QR included
            try? VNImageRequestHandler(cgImage: image).perform([request])
            // Boxes are in 0...1 with the origin at the bottom left, so "higher" means a bigger y. Codes whose middles are
            // within a twentieth of the picture's height of each other count as one row.
            let found = (request.results ?? []).filter { $0.payloadStringValue?.isEmpty == false }
            let ordered = found.sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.05 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
            }
            var seen = Set<String>()
            let payloads = ordered.compactMap { $0.payloadStringValue }.filter { seen.insert($0).inserted }
            DispatchQueue.main.async { done(payloads) }
        }
    }
}
