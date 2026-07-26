import AppKit
import XCTest
@testable import Lineform

final class MarkdownTableEditingTests: XCTestCase {
    private let simple = """
    | A | B |
    | - | - |
    | 1 | 2 |
    """

    private func locate(_ text: String, _ location: Int) -> MarkdownTableRegion? {
        MarkdownTableEditing.locate(in: text, at: location)
    }

    // MARK: - Detection

    func testLocatesTableFromHeaderRow() {
        let region = locate(simple, 2)
        XCTAssertEqual(region?.range, NSRange(location: 0, length: (simple as NSString).length))
        XCTAssertEqual(region?.table.headers, ["A", "B"])
        XCTAssertEqual(region?.lineRanges.count, 3)
    }

    func testLocatesTableFromDelimiterRow() {
        XCTAssertEqual(locate(simple, 11)?.table.headers, ["A", "B"])
    }

    func testLocatesTableFromBodyRow() {
        XCTAssertEqual(locate(simple, 22)?.table.rows, [["1", "2"]])
    }

    func testStopsAtSurroundingProse() {
        let text = "intro\n\n\(simple)\n\noutro"
        let region = locate(text, 9)
        XCTAssertEqual(region?.range, NSRange(location: 7, length: (simple as NSString).length))
    }

    func testParagraphLineWithPipeAboveTableIsNotPartOfIt() {
        let text = "see a|b below\n\(simple)"
        XCTAssertEqual(locate(text, 20)?.table.headers, ["A", "B"])
        XCTAssertNil(locate(text, 2))
    }

    func testBarePipeLineWithoutDelimiterIsNotATable() {
        XCTAssertNil(locate("| A | B |", 3))
    }

    func testMismatchedColumnCountsAreNotATable() {
        XCTAssertNil(locate("| A | B |\n| - |", 3))
    }

    func testSetextRuleUnderPipeLineIsNotATable() {
        XCTAssertNil(locate("a|b\n---", 1))
    }

    func testTableInsideFencedCodeIsNotATable() {
        XCTAssertNil(locate("```\n\(simple)\n```", 8))
    }

    func testPreservesLeadingIndentation() {
        XCTAssertEqual(locate("  | A | B |\n  | - | - |", 4)?.indent, "  ")
    }

    // MARK: - Cell geometry

    func testContentRangesCoverTrimmedCells() {
        let text = "| Fruit | Colour |\n| - | - |"
        let region = locate(text, 2)!
        let ranges = MarkdownTableEditing.contentRanges(ofLine: 0, in: region, text: text)
        XCTAssertEqual(ranges, [NSRange(location: 2, length: 5), NSRange(location: 10, length: 6)])
    }

    /// An empty cell has no content to point at, so the caret goes where content WOULD start in
    /// a reformatted row: past the pipe and its following space. In `|     |  |` that is offset
    /// 2 for the first cell (pipe at 0, space at 1) and offset 8 for the second (pipe at 6).
    func testContentRangeOfEmptyCellSitsWhereContentWouldStart() {
        let text = "|     |  |\n| - | - |"
        let region = locate(text, 2)!
        let ranges = MarkdownTableEditing.contentRanges(ofLine: 0, in: region, text: text)
        XCTAssertEqual(ranges, [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0)])
    }

    func testContentRangesHandleMissingOuterPipes() {
        let text = "A | B\n- | -"
        let region = locate(text, 1)!
        let ranges = MarkdownTableEditing.contentRanges(ofLine: 0, in: region, text: text)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
    }

    func testColumnWidthsTakeTheWidestCell() {
        let text = "| A | Colour |\n| - | - |\n| Plum | x |"
        XCTAssertEqual(MarkdownTableEditing.columnWidths(for: locate(text, 2)!), [4, 6])
    }

    func testColumnWidthsHaveAFloorOfThree() {
        let text = "| A | B |\n| - | - |"
        XCTAssertEqual(MarkdownTableEditing.columnWidths(for: locate(text, 2)!), [3, 3])
    }

    // MARK: - Insert

    private static let skeleton = """
    |     |     |     |
    | --- | --- | --- |
    |     |     |     |
    |     |     |     |
    """

    func testInsertsSkeletonIntoAnEmptyDocument() {
        let edit = MarkdownTableEditing.insertion(in: "", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.text, Self.skeleton)
        XCTAssertEqual(edit.selectedRange, NSRange(location: 2, length: 0))
    }

    func testInsertsAfterAParagraphWithABlankLineBetween() {
        let edit = MarkdownTableEditing.insertion(in: "intro", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.text, "intro\n\n\(Self.skeleton)")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 9, length: 0))
    }

    func testInsertsOnABlankLineWithoutAddingAnother() {
        let edit = MarkdownTableEditing.insertion(in: "intro\n\n", selectedRange: NSRange(location: 7, length: 0))
        XCTAssertEqual(edit.text, "intro\n\n\(Self.skeleton)")
    }

    func testSeparatesFromFollowingProse() {
        let edit = MarkdownTableEditing.insertion(in: "intro\noutro", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.text, "intro\n\n\(Self.skeleton)\n\noutro")
    }

    // MARK: - Reformat

    func testReformatAlignsRaggedColumns() {
        let text = "| Fruit | Colour |\n|-|-|\n| Plum | purple |"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, """
        | Fruit | Colour |
        | ----- | ------ |
        | Plum  | purple |
        """)
    }

    func testReformatReturnsNilWhenAlreadyAligned() {
        let text = "| Fruit | Colour |\n| ----- | ------ |\n| Plum  | purple |"
        XCTAssertNil(MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0)))
    }

    func testReformatPreservesAlignmentColons() {
        let text = "| A | B | C |\n|:-|-:|:-:|"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, "| A   | B   | C   |\n| :-- | --: | :-: |")
    }

    func testReformatPadsAndTruncatesRowsToTheDelimiterWidth() {
        let text = "| A | B |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, "| A   | B   |\n| --- | --- |\n| 1   |     |\n| 1   | 2   |")
    }

    func testReformatPreservesIndentation() {
        let text = "  | A | B |\n  |-|-|"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.text, "  | A   | B   |\n  | --- | --- |")
    }

    func testReformatKeepsTheCaretInItsCell() {
        let text = "| Fruit | Colour |\n|-|-|\n| Plum | purple |"
        // Caret inside "purple", two characters in.
        let caret = (text as NSString).range(of: "purple").location + 2
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: caret, length: 0))
        let reformatted = edit!.text as NSString
        XCTAssertEqual(edit?.selectedRange.location, reformatted.range(of: "purple").location + 2)
    }

    func testReformatRefusesOnEscapedPipe() {
        let text = "| A | B |\n| - | - |\n| a \\| b | c |"
        XCTAssertNil(MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0)))
    }

    func testReformatRefusesOnBacktick() {
        let text = "| A | B |\n| - | - |\n| `a|b` | c |"
        XCTAssertNil(MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0)))
    }

    func testReformatReturnsNilOutsideATable() {
        XCTAssertNil(MarkdownTableEditing.reformat(in: "just prose", selectedRange: NSRange(location: 2, length: 0)))
    }
}
