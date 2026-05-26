import XCTest
@testable import Lineform

final class OutlineSidebarViewTests: XCTestCase {
    @MainActor
    func testEmptyOutlineMessageExplainsHowToPopulateSidebar() {
        XCTAssertEqual(OutlineSidebarView.emptyStateTitle, "No headings yet")
        XCTAssertEqual(OutlineSidebarView.emptyStateMessage, "Add # Title or ## Section to build an outline.")
    }

    @MainActor
    func testHeadingLevelsUseDistinctSidebarIcons() {
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 1), "textformat.size")
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 2), "list.bullet.indent")
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 3), "text.alignleft")
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 6), "text.alignleft")
    }

    @MainActor
    func testOutlineTreeGroupsSectionsUnderNearestHigherLevelHeading() {
        let items = MarkdownOutlineParser().items(in: """
        # First
        ## First Section
        ### First Detail
        # Second
        ## Second Section
        """)

        let tree = OutlineSidebarView.outlineTree(from: items)

        XCTAssertEqual(tree.map(\.item.title), ["First", "Second"])
        XCTAssertEqual(tree.first?.children.map(\.item.title), ["First Section"])
        XCTAssertEqual(tree.first?.children.first?.children.map(\.item.title), ["First Detail"])
        XCTAssertEqual(tree.last?.children.map(\.item.title), ["Second Section"])
    }
}
