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

    /// Guards the mechanism the whole per-language reference rests on. `String(localized:…locale:)`
    /// formats interpolated VALUES for a locale; it does not choose which .lproj answers. Only a
    /// bundle does. If this ever inverts, `sections(in:)` is silently English everywhere.
    func testLanguageResolutionComesFromTheBundleNotTheLocale() throws {
        let german = try XCTUnwrap(
            Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)),
            "de.lproj missing from the test host — the app's own catalog should ship it"
        )

        // The positive: a German bundle resolves German.
        XCTAssertEqual(german.localizedString(forKey: "Don't Save", value: nil, table: nil), "Nicht sichern")

        // The negative: locale: does NOT.
        XCTAssertEqual(String(localized: "Don't Save", locale: Locale(identifier: "de_DE")), "Don't Save")

        // The form sections(in:) will use.
        XCTAssertEqual(String(localized: "Don't Save", bundle: german), "Nicht sichern")
    }

    func testSectionsInMainBundleMatchTheDefaultProperty() {
        XCTAssertEqual(MarkdownReference.sections(in: .main), MarkdownReference.sections)
    }
}
