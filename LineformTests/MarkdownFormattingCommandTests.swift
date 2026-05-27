import XCTest
@testable import Lineform

final class MarkdownFormattingCommandTests: XCTestCase {
    func testTitlePrefixesSelectedLineWithHeadingMarker() {
        let edit = MarkdownFormattingCommand.title.apply(
            to: "Lineform",
            selectedRange: NSRange(location: 0, length: 8)
        )

        XCTAssertEqual(edit.text, "# Lineform")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 2, length: 8))
    }

    func testSectionPrefixesSelectedLineWithSecondLevelHeadingMarker() {
        let edit = MarkdownFormattingCommand.section.apply(
            to: "Features",
            selectedRange: NSRange(location: 0, length: 8)
        )

        XCTAssertEqual(edit.text, "## Features")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 3, length: 8))
    }

    func testBoldWrapsSelectedTextAndKeepsSelectionInsideMarkers() {
        let edit = MarkdownFormattingCommand.bold.apply(
            to: "Make this clear",
            selectedRange: NSRange(location: 5, length: 4)
        )

        XCTAssertEqual(edit.text, "Make **this** clear")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 7, length: 4))
    }

    func testBoldRemovesExistingMarkersAroundSelection() {
        let edit = MarkdownFormattingCommand.bold.apply(
            to: "Make **this** clear",
            selectedRange: NSRange(location: 7, length: 4)
        )

        XCTAssertEqual(edit.text, "Make this clear")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 5, length: 4))
    }

    func testInlineCodeWrapsEmptySelectionWithEditableCaretBetweenMarkers() {
        let edit = MarkdownFormattingCommand.inlineCode.apply(
            to: "Use code",
            selectedRange: NSRange(location: 4, length: 0)
        )

        XCTAssertEqual(edit.text, "Use ``code")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 5, length: 0))
    }

    func testUnorderedListPrefixesEachSelectedLine() {
        let edit = MarkdownFormattingCommand.unorderedList.apply(
            to: "one\ntwo\nthree",
            selectedRange: NSRange(location: 0, length: 7)
        )

        XCTAssertEqual(edit.text, "- one\n- two\nthree")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 0, length: 11))
    }

    func testLinkWrapsSelectedTextAndSelectsURLPlaceholder() {
        let edit = MarkdownFormattingCommand.link.apply(
            to: "Open docs",
            selectedRange: NSRange(location: 5, length: 4)
        )

        XCTAssertEqual(edit.text, "Open [docs](https://example.com)")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 12, length: 19))
    }

    func testPlainTextConversionRemovesCommonMarkdownSyntax() {
        let markdown = """
        # Title

        > **Important** [link](https://example.com)
        - `local` files
        """

        XCTAssertEqual(
            MarkdownPlainTextConverter.plainText(from: markdown),
            """
            Title

            Important link
            local files
            """
        )
    }

    func testPlainTextConversionCanRestoreUnchangedConvertedRange() {
        let conversion = MarkdownPlainTextConversion(
            originalMarkdown: "# Title",
            plainText: "Title",
            range: NSRange(location: 0, length: 5)
        )

        let restored = conversion.restoredMarkdown(in: "Title\n\nBody")

        XCTAssertEqual(restored?.text, "# Title\n\nBody")
        XCTAssertEqual(restored?.selectedRange, NSRange(location: 0, length: 7))
    }

    func testPlainTextConversionDoesNotRestoreAfterPlainTextChanges() {
        let conversion = MarkdownPlainTextConversion(
            originalMarkdown: "# Title",
            plainText: "Title",
            range: NSRange(location: 0, length: 5)
        )

        XCTAssertNil(conversion.restoredMarkdown(in: "Edited title"))
    }
}
