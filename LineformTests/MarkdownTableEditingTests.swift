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

    // MARK: - Tab

    private let grid = "| A | B |\n| - | - |\n| 1 | 2 |"

    private func tab(_ text: String, _ location: Int, forward: Bool = true, length: Int = 0)
        -> MarkdownTableEditing.TabOutcome? {
        MarkdownTableEditing.tabTarget(
            in: text,
            selectedRange: NSRange(location: location, length: length),
            forward: forward
        )
    }

    func testTabMovesToTheNextCellInTheRow() {
        XCTAssertEqual(tab(grid, 2), .select(NSRange(location: 6, length: 1)))
    }

    func testTabSkipsTheDelimiterRowOnItsWayToTheBody() {
        XCTAssertEqual(tab(grid, 6), .select(NSRange(location: 22, length: 1)))
    }

    func testShiftTabMovesBackwards() {
        XCTAssertEqual(tab(grid, 6, forward: false), .select(NSRange(location: 2, length: 1)))
    }

    func testShiftTabSkipsTheDelimiterRowGoingBack() {
        XCTAssertEqual(tab(grid, 22, forward: false), .select(NSRange(location: 6, length: 1)))
    }

    /// ⌘← puts the caret at offset 0, ahead of the opening pipe. Tab from there selects the
    /// first cell rather than skipping over it into the second.
    func testTabFromTheStartOfTheLineSelectsTheFirstCell() {
        XCTAssertEqual(tab(grid, 0), .select(NSRange(location: 2, length: 1)))
    }

    func testShiftTabFromTheStartOfTheLineIsAConsumedNoOp() {
        XCTAssertEqual(tab(grid, 0, forward: false), .stay)
    }

    func testShiftTabInTheFirstHeaderCellIsAConsumedNoOp() {
        XCTAssertEqual(tab(grid, 2, forward: false), .stay)
    }

    func testTabInTheLastCellAppendsARow() {
        XCTAssertEqual(
            tab(grid, 26),
            .appendRow(
                insertion: "\n|     |     |",
                at: (grid as NSString).length,
                selecting: NSRange(location: (grid as NSString).length + 3, length: 0)
            )
        )
    }

    func testAppendedRowMatchesCurrentColumnWidths() {
        let wide = "| Fruit | B |\n| ----- | - |\n| Plum  | 2 |"
        guard case let .appendRow(insertion, _, _)? = tab(wide, (wide as NSString).length - 2) else {
            return XCTFail("expected an appended row")
        }
        // Column 0 is 5 wide ("Fruit"); column 1 falls back to the floor of 3.
        XCTAssertEqual(insertion, "\n|       |     |")
    }

    func testTabOutsideATableIsNotIntercepted() {
        XCTAssertNil(tab("just prose", 4))
    }

    func testTabInsideFencedCodeIsNotIntercepted() {
        XCTAssertNil(tab("```\n\(grid)\n```", 8))
    }

    func testTabWithAMultiLineSelectionIsNotIntercepted() {
        XCTAssertNil(tab(grid, 2, length: 20))
    }

    // MARK: - End to end

    /// Reformat is presentational only: the renderer must group the rewritten source into exactly
    /// the same `MarkdownTable` it grouped before. This is the automated half of "Read mode looks
    /// identical after ⌃⌘R".
    func testReformatDoesNotChangeWhatTheRendererSees() {
        let text = "| Fruit | Colour |\n|:-|-:|\n| Plum | purple |\n| Fig |"
        let before = markdownBlocks(in: text.components(separatedBy: "\n"))
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        let after = markdownBlocks(in: edit!.text.components(separatedBy: "\n"))

        guard case let .table(originalTable, _)? = before.first,
              case let .table(reformattedTable, _)? = after.first else {
            return XCTFail("both sides should group as a single table")
        }
        XCTAssertEqual(originalTable, reformattedTable)
    }

    /// Insert, then Tab across every cell and off the end, applying each outcome the way
    /// `LineformTextView` does. Catches offsets that are individually plausible but do not
    /// compose into a usable document.
    func testInsertThenTabAcrossTheWholeTableProducesAValidDocument() {
        var text = MarkdownTableEditing.insertion(in: "", selectedRange: NSRange(location: 0, length: 0)).text
        var caret = 2

        // Three header cells, then six body cells: eight forward moves stay inside the table.
        for step in 0..<8 {
            guard case let .select(range)? = MarkdownTableEditing.tabTarget(
                in: text,
                selectedRange: NSRange(location: caret, length: 0),
                forward: true
            ) else {
                return XCTFail("step \(step) should have selected a cell")
            }
            caret = range.location
        }

        // The ninth lands on the last cell's far edge and appends a row.
        guard case let .appendRow(insertion, at, selecting)? = MarkdownTableEditing.tabTarget(
            in: text,
            selectedRange: NSRange(location: caret, length: 0),
            forward: true
        ) else {
            return XCTFail("the last cell should append a row")
        }
        text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: insertion)

        XCTAssertEqual(text.components(separatedBy: "\n").count, 5)
        XCTAssertNotNil(MarkdownTableEditing.locate(in: text, at: selecting.location))
        guard case let .table(table, _)? = markdownBlocks(in: text.components(separatedBy: "\n")).first else {
            return XCTFail("the result should still group as a table")
        }
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rows.count, 3)
    }
}
