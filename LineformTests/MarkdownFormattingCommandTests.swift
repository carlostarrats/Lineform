import XCTest
@testable import Lineform

final class MarkdownFormattingCommandTests: XCTestCase {
    func testBoldWrapsSelectedTextAndKeepsSelectionInsideMarkers() {
        let edit = MarkdownFormattingCommand.bold.apply(
            to: "Make this clear",
            selectedRange: NSRange(location: 5, length: 4)
        )

        XCTAssertEqual(edit.text, "Make **this** clear")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 7, length: 4))
    }

    // Italic picks its marker from the selection's surroundings. `_` cannot emphasise part of a
    // word (that rule is what stops `make_test_file` being mangled), so a mid-word selection has
    // to use `*` or ⌘I would insert markup that renders as literal underscores.
    func testItalicWrapsAWholeWordInUnderscores() {
        let edit = MarkdownFormattingCommand.italic.apply(
            to: "Make this clear",
            selectedRange: NSRange(location: 5, length: 4)
        )

        XCTAssertEqual(edit.text, "Make _this_ clear")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 6, length: 4))
    }

    func testItalicWrapsAPartialWordInAsterisks() {
        let edit = MarkdownFormattingCommand.italic.apply(
            to: "italics",
            selectedRange: NSRange(location: 0, length: 4)
        )

        XCTAssertEqual(edit.text, "*ital*ics")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 1, length: 4))
    }

    func testItalicRemovesExistingUnderscoresAroundSelection() {
        let edit = MarkdownFormattingCommand.italic.apply(
            to: "Make _this_ clear",
            selectedRange: NSRange(location: 6, length: 4)
        )

        XCTAssertEqual(edit.text, "Make this clear")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 5, length: 4))
    }

    func testItalicRemovesExistingAsterisksAroundSelection() {
        let edit = MarkdownFormattingCommand.italic.apply(
            to: "*ital*ics",
            selectedRange: NSRange(location: 1, length: 4)
        )

        XCTAssertEqual(edit.text, "italics")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 0, length: 4))
    }

    // Un-toggling must not peel one asterisk off a bold run and silently demote it to italics.
    // The surrounding `*` are not word characters, so this wraps in `_` exactly as it did before
    // asterisk italics existed.
    func testItalicInsideBoldMarkersDoesNotUnwrapTheBold() {
        let edit = MarkdownFormattingCommand.italic.apply(
            to: "a **word** b",
            selectedRange: NSRange(location: 4, length: 4)
        )

        XCTAssertEqual(edit.text, "a **_word_** b")
    }

    func testStrikethroughWrapsSelectedTextWithTildes() {
        let edit = MarkdownFormattingCommand.strikethrough.apply(
            to: "old",
            selectedRange: NSRange(location: 0, length: 3)
        )

        XCTAssertEqual(edit.text, "~~old~~")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 2, length: 3))
    }

    func testStrikethroughRemovesExistingTildesAroundSelection() {
        let edit = MarkdownFormattingCommand.strikethrough.apply(
            to: "~~old~~",
            selectedRange: NSRange(location: 2, length: 3)
        )

        XCTAssertEqual(edit.text, "old")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 0, length: 3))
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

    // Conversion rewrites the user's real document, so mangling a word here is worse than
    // mis-drawing it. It must strip exactly what the renderer treats as emphasis and nothing
    // else: intraword underscores, spaced asterisks, and `__dunder__` (which this app does not
    // render as bold) all have to survive intact.
    func testPlainTextConversionKeepsUnderscoresInsideWords() {
        XCTAssertEqual(
            MarkdownPlainTextConverter.plainText(from: "run make_test_file and __init__ now"),
            "run make_test_file and __init__ now"
        )
    }

    func testPlainTextConversionKeepsSpacedAsterisks() {
        XCTAssertEqual(MarkdownPlainTextConverter.plainText(from: "2 * 3 * 4"), "2 * 3 * 4")
    }

    func testPlainTextConversionStripsRealEmphasis() {
        XCTAssertEqual(
            MarkdownPlainTextConverter.plainText(from: "an *aster* and an _under_ and **strong**"),
            "an aster and an under and strong"
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
