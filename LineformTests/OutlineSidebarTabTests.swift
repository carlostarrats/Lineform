import XCTest
@testable import Lineform

final class OutlineSidebarTabTests: XCTestCase {
    func testTabsIncludeInfoInOrder() {
        XCTAssertEqual(OutlineSidebarTab.allCases, [.outline, .files, .info])
        XCTAssertEqual(OutlineSidebarTab.info.rawValue, "Info")
        XCTAssertEqual(OutlineSidebarView.tabTitles, ["Outline", "Files", "Info"])
    }
}
