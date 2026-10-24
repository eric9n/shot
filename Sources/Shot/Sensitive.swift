import Vision

/// Finds private-looking things in a picture, to cover them: phone numbers, e-mail addresses, Chinese ID numbers, bank card
/// numbers, API keys and tokens, IP addresses. It reads the text with the system's Vision framework (offline) and looks for
/// patterns, so names and addresses, which have no fixed shape, are not found.
enum Sensitive {
    private struct Rule {
        let regex: NSRegularExpression
        let valid: ((String) -> Bool)?
        init(_ pattern: String, options: NSRegularExpression.Options = [], valid: ((String) -> Bool)? = nil) {
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.valid = valid
        }
    }

    private static func digits(_ s: String) -> [Int] { s.compactMap { $0.wholeNumberValue } }

    /// The Luhn check that real card numbers pass.
    static func luhn(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count >= 13, d.count <= 19 else { return false }
        var sum = 0
        for (i, n) in d.reversed().enumerated() { sum += i % 2 == 1 ? (n * 2 > 9 ? n * 2 - 9 : n * 2) : n }
        return sum % 10 == 0
    }

    /// The check character at the end of a Chinese ID number (ISO 7064 mod 11-2).
    static func idChecksum(_ s: String) -> Bool {
        let c = Array(s.uppercased())
        guard c.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let sum = zip(c.prefix(17), weights).reduce(0) { $0 + ($1.0.wholeNumberValue ?? 0) * $1.1 }
        return c[17] == Array("10X98765432")[sum % 11]
    }

    private static let rules: [Rule] = [
        Rule(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive),                                  // e-mail
        Rule(#"(?<![0-9])(?:\+?86[ \-]?)?1[3-9][0-9][ \-]?[0-9]{4}[ \-]?[0-9]{4}(?![0-9])"#),                           // mobile, China
        Rule(#"(?<![0-9])0[0-9]{2,3}[ \-][0-9]{7,8}(?![0-9])"#),                                                         // landline, China
        Rule(#"\+[0-9]{1,3}[ \-]?[0-9]{2,4}[ \-]?[0-9]{3,4}[ \-]?[0-9]{3,4}(?![0-9])"#),                                // international, with a +
        Rule(#"(?<![0-9])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9A-Za-z])"#, valid: idChecksum),   // ID number
        Rule(#"(?<![0-9])(?:[0-9][ \-]?){12,18}[0-9](?![0-9])"#, valid: luhn),                                          // card number
        Rule(#"(?<![A-Za-z0-9_\-])(?:sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9\-]{10,})"#),   // well-known key shapes
        Rule(#"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9_\-])"#, valid: { s in s.contains { $0.isLetter } && s.contains { $0.isNumber } }),   // long random-looking token
        Rule(#"(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?![0-9.])"#),   // IPv4 address
    ]

    /// The parts of `text` that look private, overlapping ones merged.
    static func ranges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Range<String.Index>] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: whole) {
                guard let r = Range(m.range, in: text) else { continue }
                if let valid = rule.valid, !valid(String(text[r])) { continue }
                found.append(r)
            }
        }
        var merged: [Range<String.Index>] = []
        for r in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Where the private things are in `image`, as boxes in 0...1 with the origin at the bottom left. Runs on a background
    /// queue; `done` is called on the main queue.
    static func find(in image: CGImage, done: @escaping ([CGRect]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false          // "corrections" would change digits and codes
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            var boxes: [CGRect] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for range in ranges(in: candidate.string) {
                    if let box = try? candidate.boundingBox(for: range) { boxes.append(box.boundingBox) }
                }
            }
            DispatchQueue.main.async { done(boxes) }
        }
    }
}
