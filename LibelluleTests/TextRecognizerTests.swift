import CoreGraphics
import Testing
@testable import Libellule

struct TextRecognizerTests {
    /// A line as Vision reports it: normalized, origin at the bottom-left.
    private func line(_ text: String, y: CGFloat, maxX: CGFloat = 0.9) -> TextRecognizer.RecognizedLine {
        TextRecognizer.RecognizedLine(text: text, box: CGRect(x: 0.1, y: y, width: maxX - 0.1, height: 0.04))
    }

    @Test func keepsOneLinePerLineAndCollapsesSpaces() {
        let text = TextRecognizer.assemble([line("Hello  world ", y: 0.9), line("Second line", y: 0.85)], joining: false)
        #expect(text == "Hello world\nSecond line")
    }

    @Test func joinsParagraphsAndMendsHyphenatedWords() {
        let lines = [
            line("The quick brown fox jumps over the lazy", y: 0.90),
            line("dog and keeps run-", y: 0.85),
            line("ning until it stops.", y: 0.80, maxX: 0.5),
            line("A new paragraph.", y: 0.75),
        ]
        let text = TextRecognizer.assemble(lines, joining: true)
        #expect(text == "The quick brown fox jumps over the lazy dog and keeps running until it stops.\n\nA new paragraph.")
    }

    @Test func aTallGapStartsAParagraph() {
        let text = TextRecognizer.assemble([line("First", y: 0.9), line("Second", y: 0.7)], joining: true)
        #expect(text == "First\n\nSecond")
    }

    @Test func theNoticeCountsWhatWasCopied() {
        #expect(TextRecognizer.Copied.text(count: 1, paragraphs: false).message == "Copied 1 line of text")
        #expect(TextRecognizer.Copied.text(count: 3, paragraphs: false).message == "Copied 3 lines of text")
        #expect(TextRecognizer.Copied.text(count: 2, paragraphs: true).message == "Copied 2 paragraphs of text")
        #expect(TextRecognizer.Copied.codes(count: 1, qr: true).message == "Copied the QR code's contents")
    }
}
