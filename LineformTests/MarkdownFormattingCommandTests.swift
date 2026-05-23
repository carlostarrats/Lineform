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
}
