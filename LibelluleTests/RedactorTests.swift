import CoreGraphics
import Testing
@testable import Libellule

struct RedactorTests {
    @Test func findsEmailAddressesAndPhoneNumbers() {
        let kinds = Redactor.matches(in: "Mail jane.doe@example.com or call +32 470 12 34 56").map(\.kind)
        #expect(kinds == [.email, .phone])
    }

    @Test func findsKeysByTheirPrefix() {
        let matches = Redactor.matches(in: "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(matches.map(\.kind) == [.secret])
    }

    @Test func findsTheValueAfterALabel() {
        let text = "password: hunter2!"
        let matches = Redactor.matches(in: text)
        #expect(matches.map(\.kind) == [.secret])
        #expect(matches.first.map { String(text[$0.range]) } == "hunter2!")
    }

    @Test func cardNumbersMustPassTheChecksum() {
        #expect(Redactor.passesLuhn("4242 4242 4242 4242"))
        #expect(!Redactor.passesLuhn("4242 4242 4242 4241"))
        #expect(!Redactor.passesLuhn("4242 4242"))
        #expect(!Redactor.matches(in: "Order 1234 5678 9012 3456").contains { $0.kind == .account })
    }

    @Test func ibansAreMostlyDigitsAfterTheCountry() {
        #expect(Redactor.looksLikeIBAN("BE71 0961 2345 6769"))
        #expect(!Redactor.looksLikeIBAN("AB12 CDEF GHIJ KLMN"))
    }

    @Test func randomLookingRunsAreKeysButWordsAndPathsAreNot() {
        #expect(Redactor.isRandomLooking("aZ3kP9qL2mX7vB4nR8tY1wC6"))
        #expect(!Redactor.isRandomLooking("thisIsALongVariableName"))
        #expect(!Redactor.isRandomLooking("Users/jane/Documents/Report2026"))
    }

    @Test func eachStyleCoversWithItsOwnShape() {
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(RedactionStyle.blackout.shape(covering: rect) == .blackout(rect))
        #expect(RedactionStyle.pixelate.shape(covering: rect) == .pixelate(rect))
        #expect(RedactionStyle.blur.shape(covering: rect) == .blur(rect))
    }
}
