import XCTest
@testable import Lineform

final class MarkdownBlockGroupingTests: XCTestCase {
    func testPlainLinesAreOneLinesBlock() {
        XCTAssertEqual(markdownBlocks(in: ["a", "b", "c"]), [.lines(0..<3)])
    }

    func testFencedCodeStaysInsideALinesRun() {
        // A regular ``` fence toggles fence state but is rendered per line, so it stays in `.lines`.
        XCTAssertEqual(markdownBlocks(in: ["before", "```", "code", "```", "after"]), [.lines(0..<5)])
    }

    func testMermaidFenceBecomesMermaidBlockWithoutDelimiters() {
        XCTAssertEqual(
            markdownBlocks(in: ["```mermaid", "graph TD;A-->B;", "```"]),
            [.mermaid(source: "graph TD;A-->B;", closingIndex: 2)]
        )
    }

    func testMermaidBlockIsBracketedByLinesRuns() {
        XCTAssertEqual(
            markdownBlocks(in: ["intro", "```mermaid", "graph TD;A-->B;", "```", "outro"]),
            [.lines(0..<1), .mermaid(source: "graph TD;A-->B;", closingIndex: 3), .lines(4..<5)]
        )
    }

    func testUnclosedMermaidHasNilClosingIndex() {
        XCTAssertEqual(
            markdownBlocks(in: ["```mermaid", "graph TD;A-->B;"]),
            [.mermaid(source: "graph TD;A-->B;", closingIndex: nil)]
        )
    }

    func testDisplayMathFenceBecomesMathBlock() {
        XCTAssertEqual(
            markdownBlocks(in: ["$$", "x^2", "$$"]),
            [.fencedMath(latex: "x^2", closingIndex: 2)]
        )
    }

    func testUnclosedDisplayMathHasNilClosingIndex() {
        XCTAssertEqual(
            markdownBlocks(in: ["$$", "x^2"]),
            [.fencedMath(latex: "x^2", closingIndex: nil)]
        )
    }

    func testSingleLineDisplayMathIsItsOwnBlock() {
        XCTAssertEqual(
            markdownBlocks(in: ["before", "$$E=mc^2$$", "after"]),
            [.lines(0..<1), .singleLineMath(latex: "E=mc^2", lineIndex: 1), .lines(2..<3)]
        )
    }

    func testDollarInsideRegularCodeFenceIsNotMath() {
        // `$$` inside a regular ``` fence must not open a math block — it stays in `.lines`.
        XCTAssertEqual(
            markdownBlocks(in: ["```", "$$", "```"]),
            [.lines(0..<3)]
        )
    }

    func testSingleEmptyLineIsOneLinesBlock() {
        XCTAssertEqual(markdownBlocks(in: [""]), [.lines(0..<1)])
    }

    // MARK: - Horizontal rule

    func testStandaloneDashesAfterBlankAreHorizontalRule() {
        XCTAssertEqual(
            markdownBlocks(in: ["a", "", "---", "", "b"]),
            [.lines(0..<2), .horizontalRule(lineIndex: 2), .lines(3..<5)]
        )
    }

    func testStarsAndUnderscoresAreHorizontalRules() {
        XCTAssertEqual(markdownBlocks(in: ["***"]), [.horizontalRule(lineIndex: 0)])
        XCTAssertEqual(markdownBlocks(in: ["___"]), [.horizontalRule(lineIndex: 0)])
    }

    func testLeadingDashesAreFrontMatterNotRule() {
        // A leading `---` opens YAML front matter — not a divider.
        let blocks = markdownBlocks(in: ["---", "title: x", "---", "body"])
        XCTAssertFalse(blocks.contains(.horizontalRule(lineIndex: 0)))
        XCTAssertFalse(blocks.contains(.horizontalRule(lineIndex: 2)))
    }

    func testDashesUnderTextAreSetextUnderlineNotRule() {
        // `---` directly under a paragraph line is a setext heading underline, not a divider.
        let blocks = markdownBlocks(in: ["Heading", "---", "body"])
        XCTAssertFalse(blocks.contains(.horizontalRule(lineIndex: 1)))
    }

    func testDashesInsideCodeFenceAreNotRule() {
        let blocks = markdownBlocks(in: ["```", "---", "```"])
        XCTAssertEqual(blocks, [.lines(0..<3)])
    }

    func testDashesAfterListOrQuoteAreRuleNotSetext() {
        // A list item or blockquote line is its own block, so `---` right after it is a real
        // thematic break — not a setext heading underline (which only applies under paragraph text).
        XCTAssertTrue(markdownBlocks(in: ["- item", "---"]).contains(.horizontalRule(lineIndex: 1)))
        XCTAssertTrue(markdownBlocks(in: ["> quote", "---"]).contains(.horizontalRule(lineIndex: 1)))
        // But `---` under ordinary paragraph text stays a setext underline (not a rule).
        XCTAssertFalse(markdownBlocks(in: ["paragraph", "---"]).contains(.horizontalRule(lineIndex: 1)))
    }

    // MARK: - Blockquote

    func testBlockquoteGroupsContiguousQuotedLinesStrippingMarkers() {
        XCTAssertEqual(
            markdownBlocks(in: ["> a", "> b", "after"]),
            [
                .blockquote(lines: [
                    MarkdownQuoteLine(depth: 1, text: "a"),
                    MarkdownQuoteLine(depth: 1, text: "b")
                ], lastLineIndex: 1),
                .lines(2..<3)
            ]
        )
    }

    func testNestedBlockquoteRaisesDepth() {
        XCTAssertEqual(
            markdownBlocks(in: [">> deep"]),
            [.blockquote(lines: [MarkdownQuoteLine(depth: 2, text: "deep")], lastLineIndex: 0)]
        )
    }

    func testBlockquoteInsideCodeFenceIsNotAQuote() {
        XCTAssertEqual(markdownBlocks(in: ["```", "> a", "```"]), [.lines(0..<3)])
    }

    func testBlockquoteLineParsingHandlesSpacedNesting() {
        XCTAssertEqual(MarkdownBlockquote.quoteLine("> > x"), MarkdownQuoteLine(depth: 2, text: "x"))
        XCTAssertEqual(MarkdownBlockquote.quoteLine("  > y"), MarkdownQuoteLine(depth: 1, text: "y"))
        XCTAssertNil(MarkdownBlockquote.quoteLine("no quote"))
    }

    // MARK: - Lists

    func testUnorderedListGroupsItems() {
        XCTAssertEqual(
            markdownBlocks(in: ["- one", "- two"]),
            [.list(items: [
                MarkdownListItem(text: "one", indentLevel: 0, ordinal: nil),
                MarkdownListItem(text: "two", indentLevel: 0, ordinal: nil)
            ], lastLineIndex: 1)]
        )
    }

    func testOrderedListNumbersSequentiallyEvenWhenAllOnes() {
        XCTAssertEqual(
            markdownBlocks(in: ["1. a", "1. b", "1. c"]),
            [.list(items: [
                MarkdownListItem(text: "a", indentLevel: 0, ordinal: 1),
                MarkdownListItem(text: "b", indentLevel: 0, ordinal: 2),
                MarkdownListItem(text: "c", indentLevel: 0, ordinal: 3)
            ], lastLineIndex: 2)]
        )
    }

    func testNestedListRaisesIndentLevelAndCountsIndependently() {
        XCTAssertEqual(
            markdownBlocks(in: ["1. top", "  1. nested", "  1. nested2", "2. top2"]),
            [.list(items: [
                MarkdownListItem(text: "top", indentLevel: 0, ordinal: 1),
                MarkdownListItem(text: "nested", indentLevel: 1, ordinal: 1),
                MarkdownListItem(text: "nested2", indentLevel: 1, ordinal: 2),
                MarkdownListItem(text: "top2", indentLevel: 0, ordinal: 2)
            ], lastLineIndex: 3)]
        )
    }

    func testListParsingIgnoresNonListLines() {
        XCTAssertNil(MarkdownList.parse("just text"))
        XCTAssertNil(MarkdownList.parse("-no space after marker"))
        XCTAssertEqual(MarkdownList.parse("* star")?.ordered, false)
        XCTAssertEqual(MarkdownList.parse("3) paren")?.ordered, true)
    }

    // MARK: - Task checkboxes

    func testUncheckedTaskItemCarriesCheckboxAndStrippedText() {
        let blocks = markdownBlocks(in: ["- [ ] buy milk"])
        guard case .list(let items, _) = blocks.first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.first?.text, "buy milk")
        XCTAssertEqual(items.first?.checkbox, MarkdownCheckbox(isChecked: false, sourceRange: NSRange(location: 2, length: 3)))
        XCTAssertNil(items.first?.ordinal)
    }

    func testCheckedTaskItemIsChecked() {
        let blocks = markdownBlocks(in: ["- [x] done"])
        guard case .list(let items, _) = blocks.first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.first?.checkbox?.isChecked, true)
        XCTAssertEqual(items.first?.text, "done")
    }

    func testCheckboxSourceRangeIsAbsoluteAcrossLines() {
        // "intro\n- [ ] a": line 1 begins at offset 6; the "[" sits at column 2 -> range (8, 3).
        let blocks = markdownBlocks(in: ["intro", "- [ ] a"])
        guard case .list(let items, _) = blocks.last else { return XCTFail("expected a list") }
        XCTAssertEqual(items.first?.checkbox?.sourceRange, NSRange(location: 8, length: 3))
    }

    func testNonTaskListItemHasNoCheckbox() {
        let blocks = markdownBlocks(in: ["- regular"])
        guard case .list(let items, _) = blocks.first else { return XCTFail("expected a list") }
        XCTAssertNil(items.first?.checkbox)
    }

    func testCheckboxToggleSwapsMarker() {
        XCTAssertEqual(CheckboxToggle.toggledText(in: "- [ ] a", at: NSRange(location: 2, length: 3)), "- [x] a")
        XCTAssertEqual(CheckboxToggle.toggledText(in: "- [x] a", at: NSRange(location: 2, length: 3)), "- [ ] a")
    }

    func testCheckboxToggleIgnoresStaleRange() {
        // Range no longer points at a marker (text changed) -> nil, so the caller ignores it.
        XCTAssertNil(CheckboxToggle.toggledText(in: "- hello", at: NSRange(location: 2, length: 3)))
        XCTAssertNil(CheckboxToggle.toggledText(in: "- [ ] a", at: NSRange(location: 200, length: 3)))
    }

    func testBracketWithoutTrailingSpaceIsNotATask() {
        // GFM requires whitespace after the bracket: `- [x](link)` is a normal bullet, not a task.
        let blocks = markdownBlocks(in: ["- [x](link)"])
        guard case .list(let items, _) = blocks.first else { return XCTFail("expected a list") }
        XCTAssertNil(items.first?.checkbox)
        XCTAssertEqual(items.first?.text, "[x](link)")
    }

    func testBareCheckboxWithNoContentIsATask() {
        let blocks = markdownBlocks(in: ["- [ ]"])
        guard case .list(let items, _) = blocks.first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.first?.checkbox?.isChecked, false)
        XCTAssertEqual(items.first?.text, "")
    }

    // MARK: - Tables

    func testDelimiterRowDetection() {
        XCTAssertTrue(MarkdownTableParser.isDelimiterRow("|---|---|"))
        XCTAssertTrue(MarkdownTableParser.isDelimiterRow("| :--- | :---: | ---: |"))
        XCTAssertTrue(MarkdownTableParser.isDelimiterRow("--- | ---"))
        XCTAssertFalse(MarkdownTableParser.isDelimiterRow("| a | b |"))
        XCTAssertFalse(MarkdownTableParser.isDelimiterRow("plain text"))
    }

    func testCellSplittingDropsOuterPipes() {
        XCTAssertEqual(MarkdownTableParser.cells(in: "| a | b |"), ["a", "b"])
        XCTAssertEqual(MarkdownTableParser.cells(in: "a | b"), ["a", "b"])
    }

    func testAlignmentFromDelimiterColons() {
        XCTAssertEqual(MarkdownTableParser.alignment(of: ":---"), .left)
        XCTAssertEqual(MarkdownTableParser.alignment(of: ":---:"), .center)
        XCTAssertEqual(MarkdownTableParser.alignment(of: "---:"), .right)
        XCTAssertEqual(MarkdownTableParser.alignment(of: "---"), .left)
    }

    func testTableGroupsHeaderDelimiterAndRows() {
        let blocks = markdownBlocks(in: ["| a | b |", "|---|:--:|", "| 1 | 2 |", "| 3 | 4 |"])
        guard case .table(let table, let last) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(table.headers, ["a", "b"])
        XCTAssertEqual(table.alignments, [.left, .center])
        XCTAssertEqual(table.rows, [["1", "2"], ["3", "4"]])
        XCTAssertEqual(last, 3)
    }

    func testTableRowsPadAndTruncateToColumnCount() {
        let blocks = markdownBlocks(in: ["| a | b | c |", "|---|---|---|", "| 1 | 2 |", "| 1 | 2 | 3 | 4 |"])
        guard case .table(let table, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows, [["1", "2", ""], ["1", "2", "3"]])
    }

    func testHeaderWithoutDelimiterIsNotATable() {
        let blocks = markdownBlocks(in: ["| a | b |", "just text"])
        XCTAssertEqual(blocks, [.lines(0..<2)])
    }

    func testTableIsBracketedByLinesRuns() {
        let blocks = markdownBlocks(in: ["intro", "| a | b |", "|---|---|", "outro"])
        guard blocks.count == 3, case .lines = blocks[0], case .table = blocks[1], case .lines = blocks[2] else {
            return XCTFail("expected lines, table, lines; got \(blocks)")
        }
    }

    func testPipesInsideCodeFenceAreNotATable() {
        let blocks = markdownBlocks(in: ["```", "| a | b |", "|---|---|", "```"])
        XCTAssertEqual(blocks, [.lines(0..<4)])
    }

    func testPipeLineOverBareDashesIsNotATable() {
        // GFM column-count gate: "Pros | Cons" (2 cells) over "---" (1 cell) is NOT a table — it's a
        // setext heading (a `---` under paragraph text), so no table block is produced.
        let blocks = markdownBlocks(in: ["Pros | Cons", "---"])
        XCTAssertFalse(blocks.contains { if case .table = $0 { return true } else { return false } })
    }

    func testMismatchedColumnCountsAreNotATable() {
        let blocks = markdownBlocks(in: ["| a | b | c |", "|---|---|"])
        XCTAssertFalse(blocks.contains { if case .table = $0 { return true } else { return false } })
    }
}
