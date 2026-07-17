import XCTest
@testable import Lineform

final class OutlineSidebarTabTests: XCTestCase {
    func testTabsIncludeMarkdownBasicsInOrder() {
        XCTAssertEqual(OutlineSidebarTab.allCases, [.outline, .files, .markdownBasics])
        XCTAssertEqual(OutlineSidebarTab.markdownBasics.rawValue, "Markdown Basics")
        XCTAssertEqual(OutlineSidebarView.tabTitles, ["Outline", "Files", "Markdown Basics"])
    }
}
