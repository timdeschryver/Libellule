import CoreGraphics
import Foundation
import Vision

/// How auto-redact hides what it finds. Only black out is final: pixelated digits and text in a known font
/// can sometimes be read back by matching blocks, and a blur can be partly undone.
enum RedactionStyle: String, CaseIterable, Identifiable {
    case blackout, pixelate, blur

    static let defaultsKey = "redactionStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blackout: String(localized: "Black Out")
        case .pixelate: String(localized: "Pixelate")
        case .blur: String(localized: "Blur")
        }
    }

    func shape(covering rect: CGRect) -> Annotation.Shape {
        switch self {
        case .blackout: .blackout(rect)
        case .pixelate: .pixelate(rect)
        case .blur: .blur(rect)
        }
    }

    /// Shared by the editor, the live palette, Settings and redaction on capture.
    static var preferred: RedactionStyle {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(RedactionStyle.init(rawValue:)) ?? .blackout }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// What one redaction pass did.
struct RedactionResult {
    var foundAnything: Bool
    /// What was newly covered; things already under a hidden area aren't counted again.
    var hidden: [Redactor.Kind]

    var message: String {
        if !hidden.isEmpty { return "Hid \(Redactor.summary(of: hidden))" }
        return foundAnything ? String(localized: "Already hidden") : String(localized: "Nothing sensitive found")
    }
}

extension AnnotationLayer {
    /// Looks for anything sensitive on `picture` (what this layer is drawn over) and covers what isn't covered
    /// yet, as one undo step. `stillShowing` is asked once the search is done: when the picture has changed
    /// meanwhile (a crop in the editor), the boxes no longer line up and nothing is added.
    func redact(_ picture: CGImage, style: RedactionStyle, stillShowing: () -> Bool = { true }) async -> RedactionResult? {
        let findings = await Redactor.findings(in: picture)
        guard stillShowing() else { return nil }
        let fresh = findings.filter { !isRedacted($0.rect(in: size)) }
        addRedactions(fresh.map { $0.rect(in: size) }, style: style)
        return RedactionResult(foundAnything: !findings.isEmpty, hidden: fresh.map(\.kind))
    }
}

/// Finds what shouldn't leave the machine in a capture (email addresses, phone numbers, IBANs and card numbers,
/// keys and tokens, faces) so the editor can cover it. Everything runs on device.
enum Redactor {
    /// In order of precedence when matches overlap: a token full of digits isn't also a phone number.
    enum Kind: Int, CaseIterable, Comparable {
        case secret, account, email, phone, face

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        func describe(count: Int) -> String {
            switch self {
            case .secret: count == 1 ? String(localized: "1 key or token") : String(localized: "\(count) keys or tokens")
            case .account: count == 1 ? String(localized: "1 account or card number") : String(localized: "\(count) account or card numbers")
            case .email: count == 1 ? String(localized: "1 email address") : String(localized: "\(count) email addresses")
            case .phone: count == 1 ? String(localized: "1 phone number") : String(localized: "\(count) phone numbers")
            case .face: count == 1 ? String(localized: "1 face") : String(localized: "\(count) faces")
            }
        }
    }

    struct Finding {
        let kind: Kind
        /// Normalized to the picture (0…1), top-left origin.
        let box: CGRect

        /// The area to cover on a picture of `size` points, with a margin so no edge of a glyph peeks out.
        func rect(in size: CGSize) -> CGRect {
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
            let padded: CGRect
            switch kind {
            case .face:
                // Face boxes run from the eyebrows to the chin; take in the forehead, hair and ears too.
                padded = CGRect(x: rect.minX - rect.width * 0.2, y: rect.minY - rect.height * 0.35, width: rect.width * 1.4, height: rect.height * 1.5)
            default:
                let margin = max(2, rect.height * 0.15)
                padded = rect.insetBy(dx: -margin, dy: -margin)
            }
            return padded.intersection(CGRect(origin: .zero, size: size))
        }
    }

    static func findings(in image: CGImage) async -> [Finding] {
        async let text = textFindings(in: image)
        async let faces = faceFindings(in: image)
        return await text + faces
    }

    /// "2 email addresses and 1 face"
    static func summary(of kinds: [Kind]) -> String {
        let parts = Kind.allCases.compactMap { kind -> String? in
            let count = kinds.filter { $0 == kind }.count
            return count > 0 ? kind.describe(count: count) : nil
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    // MARK: - Vision

    private static func textFindings(in image: CGImage) async -> [Finding] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Corrections would "fix" the very strings worth hiding: addresses, keys, account numbers.
        request.usesLanguageCorrection = false
        guard let observations = try? await request.perform(on: image) else { return [] }
        return observations.flatMap { observation -> [Finding] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            return matches(in: candidate.string).map { match in
                let box = candidate.boundingBox(for: match.range)?.boundingBox ?? observation.boundingBox
                return Finding(kind: match.kind, box: topLeft(box.cgRect))
            }
        }
    }

    private static func faceFindings(in image: CGImage) async -> [Finding] {
        guard let faces = try? await DetectFaceRectanglesRequest().perform(on: image) else { return [] }
        return faces.map { Finding(kind: .face, box: topLeft($0.boundingBox.cgRect)) }
    }

    /// Vision's normalized rectangles have their origin at the bottom-left.
    private static func topLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Text

    /// The sensitive parts of one line of recognized text, left to right. Where matches overlap, the kind
    /// listed first in `Kind` keeps the text.
    static func matches(in text: String) -> [(kind: Kind, range: Range<String.Index>)] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(kind: Kind, range: Range<String.Index>)] = []
        func add(_ kind: Kind, _ range: NSRange, where accept: (Substring) -> Bool = { _ in true }) {
            guard range.location != NSNotFound, let range = Range(range, in: text), accept(text[range]) else { return }
            found.append((kind, range))
        }

        // A random-looking run inside a web address is a path or an ID, not a key; keys in a query string
        // still show up through their label ("?token=…") or their prefix.
        let links = (Patterns.link?.matches(in: text, range: whole) ?? []).compactMap { Range($0.range, in: text) }
        func outsideLinks(_ token: Substring) -> Bool {
            !links.contains { $0.overlaps(token.startIndex..<token.endIndex) }
        }

        for match in Patterns.knownToken.matches(in: text, range: whole) { add(.secret, match.range) }
        for match in Patterns.labelledSecret.matches(in: text, range: whole) { add(.secret, match.range(at: 1)) }
        for match in Patterns.bearer.matches(in: text, range: whole) { add(.secret, match.range(at: 1)) }
        for match in Patterns.longToken.matches(in: text, range: whole) {
            add(.secret, match.range) { isRandomLooking($0) && outsideLinks($0) }
        }
        for match in Patterns.iban.matches(in: text, range: whole) { add(.account, match.range, where: looksLikeIBAN) }
        for match in Patterns.cardNumber.matches(in: text, range: whole) { add(.account, match.range, where: passesLuhn) }
        for match in Patterns.email.matches(in: text, range: whole) { add(.email, match.range) }
        for match in Patterns.phone?.matches(in: text, range: whole) ?? [] {
            add(.phone, match.range) { $0.filter(\.isNumber).count >= 7 }
        }

        var accepted: [(kind: Kind, range: Range<String.Index>)] = []
        for item in found.sorted(by: { $0.kind < $1.kind }) where !accepted.contains(where: { $0.range.overlaps(item.range) }) {
            accepted.append(item)
        }
        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private enum Patterns {
        static let email = regex(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, caseInsensitive: true)
        /// Keys with a recognizable prefix: OpenAI and Anthropic, GitHub, Slack, AWS, Google, GitLab, npm, Stripe; JWTs.
        static let knownToken = regex(#"\b(?:sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9\-]{10,}|A[KS]IA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,}|glpat-[A-Za-z0-9_\-]{16,}|npm_[A-Za-z0-9]{30,}|[spr]k_(?:live|test)_[A-Za-z0-9]{16,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"#)
        /// The value after a label such as "password:" or "api_key =".
        static let labelledSecret = regex(#"\b(?:api[_\- ]?key|access[_\- ]?key|secret(?:[_\- ]?key)?|client[_\- ]?secret|token|password|passwd|pwd|passcode|pin)\b["']?\s*[:=]\s*["']?([^\s"',;]{4,})"#, caseInsensitive: true)
        static let bearer = regex(#"\bBearer\s+([A-Za-z0-9._~+/\-]{12,}=*)"#, caseInsensitive: true)
        /// Long unbroken runs that may be a key without a known prefix; `isRandomLooking` decides.
        static let longToken = regex(#"[A-Za-z0-9_+/=\-]{24,}"#)
        static let iban = regex(#"\b[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,30}\b"#)
        static let cardNumber = regex(#"\b[0-9](?:[ \-]?[0-9]){12,18}\b"#)
        static let phone = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        static let link = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
            // The patterns are fixed; a typo shows up the first time any text is checked.
            try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }
    }

    /// Mixed-case letters and digits with little repetition: a random key, not a word, a name in code or a hash.
    nonisolated static func isRandomLooking(_ token: Substring) -> Bool {
        guard token.contains(where: \.isUppercase), token.contains(where: \.isLowercase), token.contains(where: \.isNumber) else { return false }
        // A file path is short words between slashes; a base64 key has the odd slash in a long random run.
        if token.contains("/"), !token.split(separator: "/").contains(where: { $0.count >= 16 }) { return false }
        var counts: [Character: Int] = [:]
        for character in token { counts[character, default: 0] += 1 }
        let length = Double(token.count)
        let bitsPerCharacter = counts.values.reduce(0.0) { total, count in
            let share = Double(count) / length
            return total - share * log2(share)
        }
        return bitsPerCharacter >= 4
    }

    /// Two letters, two check digits and an account part that is mostly digits, 15 to 34 characters in all.
    nonisolated static func looksLikeIBAN(_ match: Substring) -> Bool {
        let compact = match.filter { $0 != " " }
        guard (15...34).contains(compact.count) else { return false }
        return compact.dropFirst(4).filter(\.isNumber).count >= 10
    }

    /// The card number checksum, which keeps order numbers and the like out.
    nonisolated static func passesLuhn(_ match: Substring) -> Bool {
        let digits = match.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            guard item.offset % 2 == 1 else { return total + item.element }
            let doubled = item.element * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }
}
