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
}
