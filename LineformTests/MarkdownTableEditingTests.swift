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
}
