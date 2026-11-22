import XCTest
@testable import LineformCore

/// Moved from the Mac's `OutlineSidebarViewTests`; the Mac's `outlineTree(from:)` forwards here.
final class MarkdownOutlineTreeTests: XCTestCase {
    func testOutlineTitleOnlyShowsForEmptyDrawer() {
        let items = MarkdownOutlineParser().items(in: "# Title")

        XCTAssertFalse(MarkdownOutlineTree.showsTitle(for: []))
        XCTAssertFalse(MarkdownOutlineTree.showsTitle(for: items))
    }

    func testOutlineTreeGroupsSectionsUnderNearestHigherLevelHeading() {
        let items = MarkdownOutlineParser().items(in: """
        # First
        ## First Section
        ### First Detail
        # Second
        ## Second Section
        """)

        let tree = MarkdownOutlineTree.tree(from: items)

        XCTAssertEqual(tree.map(\.item.title), ["First", "Second"])
        XCTAssertEqual(tree.first?.children.map(\.item.title), ["First Section"])
        XCTAssertEqual(tree.first?.children.first?.children.map(\.item.title), ["First Detail"])
        XCTAssertEqual(tree.last?.children.map(\.item.title), ["Second Section"])
    }

    func testDeeperFirstHeadingStillRootsAndSkippedLevelsNest() {
        let items = MarkdownOutlineParser().items(in: """
        ### Lead
        # Top
        ### Skipped a level
        """)
        let tree = MarkdownOutlineTree.tree(from: items)
        XCTAssertEqual(tree.map(\.item.title), ["Lead", "Top"])
        XCTAssertEqual(tree.last?.children.map(\.item.title), ["Skipped a level"])
        XCTAssertEqual(tree.first?.id, items.first?.id)
    }
}
