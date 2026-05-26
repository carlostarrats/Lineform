import XCTest
@testable import Lineform

final class OutlineSidebarViewTests: XCTestCase {
    @MainActor
    func testEmptyOutlineMessageExplainsHowToPopulateSidebar() {
        XCTAssertEqual(OutlineSidebarView.emptyStateTitle, "No headings yet")
        XCTAssertEqual(OutlineSidebarView.emptyStateMessage, "Add # Title or ## Section to build an outline.")
    }

    @MainActor
    func testOutlineTitleDoesNotUseIcon() {
        XCTAssertFalse(OutlineSidebarView.titleShowsIcon)
    }

    @MainActor
    func testOutlineTitleOnlyShowsForEmptyDrawer() {
        let items = MarkdownOutlineParser().items(in: "# Title")

        XCTAssertTrue(OutlineSidebarView.showsTitle(for: []))
        XCTAssertFalse(OutlineSidebarView.showsTitle(for: items))
    }

    @MainActor
    func testOutlineDrawerUsesFlatSidebarBackground() {
        XCTAssertFalse(OutlineSidebarView.usesSubtleGradientBackground)
        XCTAssertLessThan(OutlineSidebarView.backgroundOpacity, 1)
        XCTAssertGreaterThan(OutlineSidebarView.backgroundOpacity, 0.9)
    }

    @MainActor
    func testOutlineDrawerKeepsLightChromeIndependentOfEditorTheme() {
        XCTAssertTrue(OutlineSidebarView.usesThemeIndependentLightChrome)
        XCTAssertLessThan(OutlineSidebarView.primaryTextWhiteComponent, 0.25)
        XCTAssertGreaterThan(OutlineSidebarView.secondaryTextWhiteComponent, OutlineSidebarView.primaryTextWhiteComponent)
        XCTAssertLessThan(OutlineSidebarView.secondaryTextWhiteComponent, 0.55)
    }

    @MainActor
    func testOutlineRowsExposeVisibleHoverFeedback() {
        XCTAssertTrue(OutlineSidebarView.rowsShowHoverFeedback)
        XCTAssertGreaterThan(OutlineSidebarView.rowHoverFillOpacity, 0)
        XCTAssertLessThan(OutlineSidebarView.rowHoverFillOpacity, 0.2)
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
