import XCTest
@testable import Lineform

final class SelectionContextTests: XCTestCase {
    func testSelectedTextReflectsSelectedRange() {
        let context = SelectionContext(
            text: "Before selected after",
            selectedRange: NSRange(location: 7, length: 8)
        )

        XCTAssertEqual(context.selectedText, "selected")
    }

    func testCurrentLineRangeIncludesLineContainingSelection() {
        let text = "first\nsecond line\nthird"
        let context = SelectionContext(text: text, selectedRange: NSRange(location: 8, length: 0))

        XCTAssertEqual(context.currentLineText, "second line")
    }
}
