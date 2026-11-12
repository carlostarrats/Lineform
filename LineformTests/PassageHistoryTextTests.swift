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
        let text = "x y x"
        XCTAssertNil(PassageHistoryText.locate("x", before: "", after: "", in: text, within: NSRange(location: 0, length: 5)))
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
}
