import XCTest
@testable import Lineform

final class ReadingAssistRangeResolverTests: XCTestCase {
    func testCurrentLineFocusReturnsLineContainingSelection() {
        let text = "First line\nSecond line\nThird line"
        let selectedRange = NSRange(location: 13, length: 0)

        let range = ReadingAssistRangeResolver.focusRange(in: text, selectedRange: selectedRange, mode: .currentLine)

        XCTAssertEqual((text as NSString).substring(with: range!), "Second line\n")
    }

    func testCurrentParagraphFocusReturnsParagraphContainingSelection() {
        let text = "Alpha paragraph\n\nBeta paragraph\ncontinues\n\nGamma"
        let selectedRange = NSRange(location: 25, length: 0)

        let range = ReadingAssistRangeResolver.focusRange(in: text, selectedRange: selectedRange, mode: .currentParagraph)

        XCTAssertEqual((text as NSString).substring(with: range!), "Beta paragraph\ncontinues\n")
    }

    func testCurrentSentenceFocusReturnsSentenceContainingSelection() {
        let text = "First sentence. Second sentence is here. Third sentence."
        let selectedRange = NSRange(location: 23, length: 0)

        let range = ReadingAssistRangeResolver.focusRange(in: text, selectedRange: selectedRange, mode: .currentSentence)

        XCTAssertEqual((text as NSString).substring(with: range!), "Second sentence is here. ")
    }

    func testOffFocusModeDoesNotReturnRange() {
        let range = ReadingAssistRangeResolver.focusRange(
            in: "One line",
            selectedRange: NSRange(location: 0, length: 0),
            mode: .off
        )

        XCTAssertNil(range)
    }
}
