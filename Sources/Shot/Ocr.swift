import Vision

/// Reads the text in an image with the system's Vision framework. Everything runs on this Mac.
enum Ocr {
    /// Recognized text, one line per detected line, top to bottom. Empty if nothing was found.
    /// Runs on a background queue; `done` is called on the main queue.
    static func recognize(_ image: CGImage, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]   // hints; detection still picks among supported ones
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { done(lines.joined(separator: "\n")) }
        }
    }
}
