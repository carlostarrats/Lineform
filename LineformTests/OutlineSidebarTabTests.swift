import XCTest
@testable import Lineform

final class OutlineSidebarTabTests: XCTestCase {
    func testTabsIncludeMarkdownBasicsInOrder() {
        XCTAssertEqual(OutlineSidebarTab.allCases, [.outline, .files, .markdownBasics, .history])
        XCTAssertEqual(OutlineSidebarTab.visibleTabs(hasHistory: false), [.outline, .files, .markdownBasics])
        XCTAssertEqual(OutlineSidebarTab.visibleTabs(hasHistory: true), [.outline, .files, .markdownBasics, .history])
        XCTAssertEqual(OutlineSidebarTab.history.rawValue, "History")
        XCTAssertEqual(OutlineSidebarTab.markdownBasics.rawValue, "Markdown Basics")
        // pinned-en: tabTitles maps OutlineSidebarTab.title, itself String(localized:) — no
        // further constant to defer to; see testTabTitlesRemainStableInEnglish below.
        XCTAssertEqual(OutlineSidebarView.tabTitles, ["Outline", "Files", "Markdown Basics", "History"])
    }

    func testTabTitlesRemainStableInEnglish() {
        XCTAssertEqual(OutlineSidebarTab.allCases.map(\.title), ["Outline", "Files", "Markdown Basics", "History"])
    }

    func testRawValuesAreIdentityNotDisplayAndNeverChange() {
        // rawValue is persisted identity; localizing it would corrupt saved state.
        XCTAssertEqual(OutlineSidebarTab.allCases.map(\.rawValue), ["Outline", "Files", "Markdown Basics", "History"])
    }
}
