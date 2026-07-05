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
}
