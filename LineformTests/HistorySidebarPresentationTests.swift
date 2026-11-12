import XCTest
@testable import Lineform

final class HistorySidebarPresentationTests: XCTestCase {
    func testLevelSwitcherHiddenForSingleLevel() {
        XCTAssertFalse(HistorySidebarPresentation.showsLevelSwitcher([.sentence]))
        XCTAssertFalse(HistorySidebarPresentation.showsLevelSwitcher([]))
    }

    func testLevelSwitcherShownForNestedGroup() {
        XCTAssertTrue(HistorySidebarPresentation.showsLevelSwitcher([.sentence, .word]))
    }

    func testRowTextIsFirstLineCollapsed() {
        XCTAssertEqual(HistorySidebarRow.displayText(for: "A  b\nc"), "A b")
        XCTAssertEqual(HistorySidebarRow.displayText(for: "\n  lead \t space\nx"), "lead space")
    }

    func testLevelTitlesAreLocalizedNotRawValues() {
        XCTAssertEqual(HistoryLevel.paragraph.title, String(localized: "Paragraph"))
        XCTAssertEqual(HistoryLevel.allCases.map(\.title), ["Paragraph", "Sentence", "Word"])
        XCTAssertEqual(HistoryLevel.word.rawValue, "word")
    }

    func testHistoryTabTitleAndIcon() {
        XCTAssertEqual(OutlineSidebarTab.history.title, "History")
        XCTAssertEqual(OutlineSidebarTab.history.systemImage, "clock.arrow.circlepath")
    }

    func testRowAccessibilityLabel() {
        let row = HistorySidebarRow(id: 1, text: "Hello", author: .ai, isCurrent: true)
        XCTAssertEqual(row.accessibilityLabel(position: 2, of: 3), "Hello, by AI, version 2 of 3")
        let you = HistorySidebarRow(id: 0, text: "Hi", author: .you, isCurrent: false)
        XCTAssertEqual(you.accessibilityLabel(position: 1, of: 3), "Hi, by you, version 1 of 3")
    }
}
