import XCTest
@testable import Lineform

final class MarkdownReferenceTests: XCTestCase {
    func testSectionsCoverEveryGroupAndAreNonEmpty() {
        let titles = MarkdownReference.sections.map(\.title)
        XCTAssertEqual(titles, ["Markdown Basics", "Diagrams", "Math", "Spelling", "Search"])
        for section in MarkdownReference.sections {
            XCTAssertFalse(section.rows.isEmpty, section.title)
        }
    }

    func testBasicsIncludesCoreSyntax() {
        let basics = MarkdownReference.sections.first { $0.title == "Markdown Basics" }
        let syntaxes = basics?.rows.map(\.syntax) ?? []
        for expected in ["# Title", "**bold**", "- [x] done", "| a | b |", "> [!NOTE]", "```swift"] {
            XCTAssertTrue(syntaxes.contains(expected), "missing \(expected)")
        }
    }

    func testBasicsIncludesCalloutSyntax() {
        let basics = MarkdownReference.sections.first { $0.title == "Markdown Basics" }
        let syntaxes = basics?.rows.map(\.syntax) ?? []
        XCTAssertTrue(syntaxes.contains("> [!NOTE]"), "missing callout row")
    }

    // The tab is where users look for shortcuts, so the keyboard aids have to stay named here
    // when the editor gains them — heading levels, list continuation, and table authoring all
    // shipped without the reference mentioning them once.
    func testReferenceNamesTheEditingShortcuts() {
        let explanations = MarkdownReference.sections.flatMap(\.rows).map(\.explanation).joined(separator: " ")
        for expected in ["⌘1", "⌘0", "⌘2 to ⌘6", "⌃⌘T", "⌃⌘R", "Shift-Tab", "Return starts the next"] {
            XCTAssertTrue(explanations.contains(expected), "reference no longer mentions \(expected)")
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
