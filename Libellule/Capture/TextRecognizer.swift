#if os(macOS)
import AppKit
import Vision

/// On-device text and code recognition for the "copy text" capture.
enum TextRecognizer {
    /// What ended up on the clipboard.
    enum Copied: Equatable {
        /// `count` lines, or paragraphs when the lines were joined.
        case text(count: Int, paragraphs: Bool)
        case codes(count: Int, qr: Bool)

        /// For the confirmation toast.
        var message: String {
            switch self {
            case .text(let count, true):
                return count == 1 ? String(localized: "Copied 1 paragraph of text") : String(localized: "Copied \(count) paragraphs of text")
            case .text(let count, false):
                return count == 1 ? String(localized: "Copied 1 line of text") : String(localized: "Copied \(count) lines of text")
            case .codes(let count, true):
                return count == 1 ? String(localized: "Copied the QR code's contents") : String(localized: "Copied \(count) QR codes")
            case .codes(let count, false):
                return count == 1 ? String(localized: "Copied the barcode's contents") : String(localized: "Copied \(count) barcodes")
            }
        }

        var systemImage: String {
            switch self {
            case .text: "text.viewfinder"
            case .codes(_, let qr): qr ? "qrcode.viewfinder" : "barcode.viewfinder"
            }
        }
    }

    /// A QR code or barcode found in the image.
    struct Code {
        let payload: String
        let isQR: Bool
        /// The share of the image it occupies (0…1).
        let coverage: CGFloat
    }

    /// Settings: run the lines of a paragraph together instead of keeping one line per line on screen.
    static let joinsLinesKey = "copyTextJoinsLines"
    static var joinsLines: Bool { UserDefaults.standard.bool(forKey: joinsLinesKey) }

    /// One recognized line and where it sits (normalized, origin at the bottom-left, as Vision reports it).
    struct RecognizedLine {
        var text: String
        var box: CGRect
    }

    /// The recognized text, top to bottom: one line per detected line, or paragraphs when `joining`.
    static func recognizeText(in image: CGImage, joining: Bool) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Left alone, Vision uses its English model, which reads nothing at all in Chinese, Japanese or Korean.
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        let ordered = observations.sorted { a, b in
            // Normalized coordinates have their origin at the bottom-left, so higher y is further up.
            let ay = a.boundingBox.origin.y
            let by = b.boundingBox.origin.y
            if abs(ay - by) > 0.012 { return ay > by }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }
        let lines = ordered.compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(text: text, box: CGRect(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height))
        }
        return assemble(lines, joining: joining)
    }

    /// One line per line, or the lines run together into paragraphs. Either way runs of spaces collapse to one.
    /// A paragraph ends at a gap taller than the line, or at a sentence that stops well short of the right edge;
    /// a word broken with a hyphen across two lines is mended.
    static func assemble(_ lines: [RecognizedLine], joining: Bool) -> String {
        let cleanedLines = lines.map { RecognizedLine(text: cleaned($0.text), box: $0.box) }.filter { !$0.text.isEmpty }
        guard joining else { return cleanedLines.map(\.text).joined(separator: "\n") }
        let rightEdge = cleanedLines.map(\.box.maxX).max() ?? 1
        var result = ""
        var last: RecognizedLine?
        for line in cleanedLines {
            defer { last = line }
            guard let previous = last else {
                result = line.text
                continue
            }
            let gap = previous.box.minY - line.box.maxY
            let endsSentence = previous.text.last.map { ".!?:".contains($0) } ?? false
            let stopsShort = previous.box.maxX < rightEdge - 0.2
            if gap > previous.box.height * 0.8 || (endsSentence && stopsShort) {
                result += "\n\n" + line.text
            } else if previous.text.hasSuffix("-"), let first = line.text.first, first.isLowercase {
                result.removeLast()
                result += line.text
            } else {
                result += " " + line.text
            }
        }
        return result
    }

    /// OCR sometimes doubles a space between words: keep single spaces, none at the ends.
    static func cleaned(_ text: String) -> String {
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The QR codes and barcodes with a readable payload, largest first.
    static func detectCodes(in image: CGImage) async throws -> [Code] {
        let request = DetectBarcodesRequest()
        let observations = try await request.perform(on: image)
        return observations.compactMap { observation -> Code? in
            guard let payload = observation.payloadString, !payload.isEmpty else { return nil }
            let box = observation.boundingBox
            return Code(payload: payload, isQR: observation.symbology == .qr, coverage: box.width * box.height)
        }
        .sorted { $0.coverage > $1.coverage }
    }

    /// Recognizes the text, and any QR code or barcode, and puts the result on the clipboard.
    /// A code wins when the selection is about it: there is no other text, or it fills a good part of the image.
    /// Returns nil when nothing was found.
    @discardableResult
    static func copyText(from image: CGImage) async -> Copied? {
        let joining = joinsLines
        async let recognizedText = try? recognizeText(in: image, joining: joining)
        async let detectedCodes = try? detectCodes(in: image)
        let text = await recognizedText ?? ""
        let codes = await detectedCodes ?? []

        let codeCoverage = codes.reduce(0) { $0 + $1.coverage }
        if !codes.isEmpty, text.isEmpty || codeCoverage >= 0.2 {
            copy(codes.map(\.payload).joined(separator: "\n"))
            return .codes(count: codes.count, qr: codes.allSatisfy(\.isQR))
        }
        guard !text.isEmpty else { return nil }
        copy(text)
        // Paragraphs are separated by a blank line, lines by a single newline; none of them is empty.
        let count = joining ? text.components(separatedBy: "\n\n").count : text.split(separator: "\n").count
        return .text(count: count, paragraphs: joining)
    }

    private static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
#endif
