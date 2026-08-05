import XCTest
@testable import Lineform

final class OutlineSidebarTabTests: XCTestCase {
    func testTabsIncludeMarkdownBasicsInOrder() {
        XCTAssertEqual(OutlineSidebarTab.allCases, [.outline, .files, .markdownBasics])
        XCTAssertEqual(OutlineSidebarTab.markdownBasics.rawValue, "Markdown Basics")
        XCTAssertEqual(OutlineSidebarView.tabTitles, ["Outline", "Files", "Markdown Basics"])
    }

    func testTabTitlesRemainStableInEnglish() {
        XCTAssertEqual(OutlineSidebarTab.allCases.map(\.title), ["Outline", "Files", "Markdown Basics"])
    }

    func testRawValuesAreIdentityNotDisplayAndNeverChange() {
        // rawValue is persisted identity; localizing it would corrupt saved state.
        XCTAssertEqual(OutlineSidebarTab.allCases.map(\.rawValue), ["Outline", "Files", "Markdown Basics"])
    }
}
