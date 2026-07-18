import XCTest
@testable import Lineform

final class MarkdownCalloutTests: XCTestCase {
    func testEachKnownTypeParses() {
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!NOTE]")?.kind, .note)
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!TIP]")?.kind, .tip)
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!IMPORTANT]")?.kind, .important)
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!WARNING]")?.kind, .warning)
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!CAUTION]")?.kind, .caution)
    }

    func testTypeMatchIsCaseInsensitive() {
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!note]")?.kind, .note)
        XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!Warning]")?.kind, .warning)
    }

    func testNoCustomTitleYieldsNilTitle() {
        let parsed = MarkdownCallout.parse(firstQuoteText: "[!NOTE]")
        XCTAssertEqual(parsed?.kind, .note)
        XCTAssertNil(parsed?.title)
    }

    func testCustomTitleIsCapturedAndTrimmed() {
        let parsed = MarkdownCallout.parse(firstQuoteText: "[!NOTE]   Remember this  ")
        XCTAssertEqual(parsed?.kind, .note)
        XCTAssertEqual(parsed?.title, "Remember this")
    }

    func testTrailingWhitespaceOnlyIsNotATitle() {
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!TIP]   ")?.title)
    }

    func testUnknownTypeReturnsNil() {
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!FOO]"))
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!FOO] title"))
    }

    func testMalformedMarkersReturnNil() {
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!]"))          // empty type
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[NOTE]"))       // missing !
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "!NOTE"))        // no brackets
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "text [!NOTE]")) // marker not at start
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: ""))            // empty
        XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!NOTE"))       // unclosed
    }
}
