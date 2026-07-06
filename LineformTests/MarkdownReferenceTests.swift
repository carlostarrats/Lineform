import XCTest
@testable import Lineform

final class MarkdownReferenceTests: XCTestCase {
    func testSectionsCoverEveryGroupAndAreNonEmpty() {
        let titles = MarkdownReference.sections.map(\.title)
        XCTAssertEqual(titles, ["Markdown Basics", "Diagrams", "Math", "Search"])
        for section in MarkdownReference.sections {
            XCTAssertFalse(section.rows.isEmpty, section.title)
        }
    }

    func testBasicsIncludesCoreSyntax() {
        let basics = MarkdownReference.sections.first { $0.title == "Markdown Basics" }
        let syntaxes = basics?.rows.map(\.syntax) ?? []
        for expected in ["# Title", "**bold**", "- [x] done", "| a | b |"] {
            XCTAssertTrue(syntaxes.contains(expected), "missing \(expected)")
        }
    }

    // Guards the narrow-column rewrite: a future edit can't silently re-bloat copy.
    func testExplanationsStayConcise() {
        for section in MarkdownReference.sections {
            for row in section.rows {
                XCTAssertLessThanOrEqual(
                    row.explanation.count, 90,
                    "too wordy for the sidebar: \(row.syntax) — \(row.explanation)"
                )
            }
        }
    }

    func testBlockSpacingIsNotRenderedAsCode() {
        let row = MarkdownReference.sections
            .flatMap(\.rows)
            .first { $0.syntax == "Block Spacing" }
        XCTAssertEqual(row?.rendersSyntaxAsCode, false)
    }

    func testAccessibilityLabelReadsExplanationThenSyntax() {
        let row = MarkdownReference.Row(syntax: "**bold**", explanation: "Bold.")
        XCTAssertEqual(row.accessibilityLabel, "Bold. Syntax: **bold**")
    }
}
