import XCTest
@testable import Lineform

final class PassageHistoryTextTests: XCTestCase {
    func testClassifyWordSentenceParagraph() {
        let text = "One two three. Four five six seven.\n\nNext paragraph here."
        XCTAssertEqual(PassageHistoryText.classify(NSRange(location: 4, length: 3), in: text), .word)
        XCTAssertEqual(PassageHistoryText.classify(NSRange(location: 15, length: 20), in: text), .sentence)
        XCTAssertEqual(PassageHistoryText.classify(NSRange(location: 0, length: 35), in: text), .paragraph)
    }

    func testClassifySpanningParagraphsIsParagraph() {
        let text = "One two three.\n\nNext paragraph here."
        XCTAssertEqual(PassageHistoryText.classify(NSRange(location: 4, length: 20), in: text), .paragraph)
    }

    func testClassifyParagraphBoundariesUseBlankLinesInCRLF() {
        let text = "Alpha beta gamma delta.\r\n\r\nSecond one here."
        XCTAssertEqual(PassageHistoryText.classify(NSRange(location: 0, length: 23), in: text), .paragraph)
    }

    func testClassifyRejectsWhitespaceOnly() {
        XCTAssertNil(PassageHistoryText.classify(NSRange(location: 0, length: 3), in: " \n "))
        XCTAssertNil(PassageHistoryText.classify(NSRange(location: 1, length: 0), in: "abc"))
    }

    func testClassifyAlignsToComposedCharacters() {
        let text = "Hi 👍🏽 there friend again."
        let emoji = (text as NSString).range(of: "👍🏽")
        let split = NSRange(location: emoji.location + 1, length: 1)
        let aligned = PassageHistoryText.aligned(split, in: text)
        XCTAssertEqual(aligned, emoji)
        XCTAssertNotNil(PassageHistoryText.classify(split, in: text))
    }

    func testAlignedTrimsWhitespaceAndClamps() {
        let text = "  hello \r\n"
        XCTAssertEqual(PassageHistoryText.aligned(NSRange(location: 0, length: 99), in: text), NSRange(location: 2, length: 5))
    }

    func testLocatePicksOccurrenceMatchingContext() {
        let text = "Alpha is here. It works. Beta is there. It works. Gamma."
        let second = (text as NSString).range(of: "It works.", options: .backwards)
        let ctx = PassageHistoryText.context(around: second, in: text)
        let found = PassageHistoryText.locate("It works.", before: ctx.before, after: ctx.after,
                                              in: text, within: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(found, second)
    }

    func testLocateReturnsNilWhenTextIsGone() {
        XCTAssertNil(PassageHistoryText.locate("missing", before: "a", after: "b", in: "nothing here",
                                               within: NSRange(location: 0, length: 12)))
    }

    func testLocateNilOnZeroScoreTie() {
        // Neither occurrence touches a scope edge, so the empty contexts earn no boundary credit.
        let text = "a x y x b"
        XCTAssertNil(PassageHistoryText.locate("x", before: "", after: "", in: text, within: NSRange(location: 0, length: 9)))
    }

    func testLocateMatchesPassageAtDocumentStart() {
        // Empty `before` = the passage opened the document; the following text has since changed.
        let text = "Hello there, friend."
        XCTAssertEqual(PassageHistoryText.locate("Hello", before: "", after: "! Old tail.", in: text,
                                                 within: NSRange(location: 0, length: (text as NSString).length)),
                       NSRange(location: 0, length: 5))
    }

    func testLocateMatchesWholeDocumentPassage() {
        let text = "Only this."
        XCTAssertEqual(PassageHistoryText.locate(text, before: "", after: "", in: text,
                                                 within: NSRange(location: 0, length: 10)),
                       NSRange(location: 0, length: 10))
    }

    func testLocateInCRLFAndBOMText() {
        let text = "\u{FEFF}A\r\nB target C\r\n"
        let expected = (text as NSString).range(of: "target")
        let ctx = PassageHistoryText.context(around: expected, in: text)
        XCTAssertEqual(PassageHistoryText.locate("target", before: ctx.before, after: ctx.after, in: text,
                                                 within: NSRange(location: 0, length: (text as NSString).length)), expected)
    }

    func testLocateRespectsScope() {
        let text = "needle one. needle two."
        let found = PassageHistoryText.locate("needle", before: "", after: " one.", in: text,
                                              within: NSRange(location: 5, length: 18))
        XCTAssertEqual(found, NSRange(location: 12, length: 6))
    }

    func testContextIsBoundedAndComposedSafe() {
        let text = String(repeating: "👍🏽", count: 40) + "TARGET" + String(repeating: "👍🏽", count: 40)
        let r = (text as NSString).range(of: "TARGET")
        let ctx = PassageHistoryText.context(around: r, in: text)
        XCTAssertLessThanOrEqual((ctx.before as NSString).length, PassageHistoryText.contextLength)
        XCTAssertLessThanOrEqual((ctx.after as NSString).length, PassageHistoryText.contextLength)
        XCTAssertTrue(ctx.before.hasSuffix("👍🏽"))
    }

    func testLocateReturnsNilForContextlessSingleOccurrence() {
        XCTAssertNil(PassageHistoryText.locate("works", before: "zzz", after: "qqq", in: "It works fine.",
                                               within: NSRange(location: 0, length: 14)))
    }

    func testLocateRejectsMidWordMatch() {
        let text = "the other"
        XCTAssertNil(PassageHistoryText.locate("he", before: "t", after: " other", in: text,
                                               within: NSRange(location: 0, length: 9)))
    }

    func testLocateRejectsComposedCharacterSplit() {
        let decomposed = "a cafe\u{301} b"
        XCTAssertNil(PassageHistoryText.locate("cafe", before: "a ", after: "\u{301} b", in: decomposed,
                                               within: NSRange(location: 0, length: (decomposed as NSString).length)))
        let skin = "ok 👍🏽 ok"
        XCTAssertNil(PassageHistoryText.locate("👍", before: "ok ", after: "🏽 ok", in: skin,
                                               within: NSRange(location: 0, length: (skin as NSString).length)))
        let whole = PassageHistoryText.locate("👍🏽", before: "ok ", after: " ok", in: skin,
                                              within: NSRange(location: 0, length: (skin as NSString).length))
        XCTAssertEqual(whole, (skin as NSString).range(of: "👍🏽"))
    }

    func testAlignedClampsInvalidRanges() {
        let text = "hello"
        XCTAssertEqual(PassageHistoryText.aligned(NSRange(location: NSNotFound, length: 3), in: text).length, 0)
        XCTAssertEqual(PassageHistoryText.aligned(NSRange(location: 2, length: Int.max), in: text), NSRange(location: 2, length: 3))
        XCTAssertEqual(PassageHistoryText.aligned(NSRange(location: 99, length: 1), in: text), NSRange(location: 5, length: 0))
        XCTAssertEqual(PassageHistoryText.aligned(NSRange(location: Int.max - 1, length: 5), in: text), NSRange(location: 5, length: 0))
    }
}
