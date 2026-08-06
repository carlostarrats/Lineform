import XCTest
@testable import Lineform

final class MarkdownReferenceTests: XCTestCase {
    private static let languages = ["en", "es", "fr", "de", "ja", "zh-Hans"]

    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
            "\(language).lproj missing from the test host"
        )
    }

    /// Explicitly the ENGLISH rendering. `.main` is NOT the fix — `MarkdownReference.sections`
    /// is *defined* as `sections(in: .main)`, so on a Mac or CI runner configured for German
    /// `.main` resolves German and every English-asserting test below fails. The built app's
    /// `en.lproj` carries no `Localizable.strings`, so a lookup there returns the key — which
    /// is the English text.
    private func englishBundle() throws -> Bundle { try bundle("en") }

    func testSectionsCoverEveryGroupAndAreNonEmpty() throws {
        // The group SET is the invariant; naming the titles is how we catch a dropped section.
        // Per-language shape is covered by testSectionTitlesLocalize.
        let sections = MarkdownReference.sections(in: try englishBundle())
        XCTAssertEqual(sections.map(\.title), ["Markdown Basics", "Diagrams", "Math", "Spelling", "Search"])
        for section in sections {
            XCTAssertFalse(section.rows.isEmpty, section.title)
        }
    }

    func testBasicsIncludesCoreSyntax() throws {
        let basics = MarkdownReference.sections(in: try englishBundle()).first { $0.title == "Markdown Basics" }
        let syntaxes = basics?.rows.map(\.syntax) ?? []
        for expected in ["# Title", "**bold**", "- [x] done", "| a | b |", "> [!NOTE]", "```swift"] {
            XCTAssertTrue(syntaxes.contains(expected), "missing \(expected)")
        }
    }

    func testBasicsIncludesCalloutSyntax() throws {
        let basics = MarkdownReference.sections(in: try englishBundle()).first { $0.title == "Markdown Basics" }
        let syntaxes = basics?.rows.map(\.syntax) ?? []
        XCTAssertTrue(syntaxes.contains("> [!NOTE]"), "missing callout row")
    }

    // The tab is where users look for shortcuts, so the keyboard aids have to stay named here
    // when the editor gains them — heading levels, list continuation, and table authoring all
    // shipped without the reference mentioning them once.
    func testReferenceNamesTheEditingShortcuts() throws {
        // The glyphs are UI, not prose: they must survive translation in EVERY language.
        for language in Self.languages {
            let explanations = MarkdownReference.sections(in: try bundle(language))
                .flatMap(\.rows).map(\.explanation).joined(separator: " ")
            // The GLYPHS are protected, not the connective between them: "⌘2 to ⌘6" as one
            // token forced an English "to" into all five translations. "bis"/"à"/"a"/"〜"/"至"
            // are prose and belong to the translator.
            for expected in ["⌘1", "⌘0", "⌘2", "⌘6", "⌃⌘T", "⌃⌘R", "Shift-Tab"] {
                XCTAssertTrue(explanations.contains(expected), "\(language) lost the shortcut glyph \(expected)")
            }
        }

        // English prose, so it is pinned to the English bundle rather than the host's language.
        let english = MarkdownReference.sections(in: try englishBundle())
            .flatMap(\.rows).map(\.explanation).joined(separator: " ")
        XCTAssertTrue(english.contains("Return starts the next"), "reference no longer describes list continuation")
    }

    /// Guards the narrow-column rewrite in EVERY language, not just English. The column does not
    /// get wider in German. Pinning only `en` let a 120-character translation ship silently.
    func testExplanationsStayConciseInEveryLanguage() throws {
        for language in Self.languages {
            for section in MarkdownReference.sections(in: try bundle(language)) {
                for row in section.rows {
                    XCTAssertLessThanOrEqual(
                        row.explanation.count, 90,
                        "too wordy for the sidebar in \(language): \(row.syntax) — \(row.explanation)"
                    )
                }
            }
        }
    }

    func testBlockSpacingIsNotRenderedAsCode() throws {
        let row = MarkdownReference.sections(in: try englishBundle())
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

    private func germanBundle() throws -> Bundle { try bundle("de") }

    func testSectionTitlesLocalize() throws {
        let english = MarkdownReference.sections(in: try englishBundle()).map(\.title)
        let german = MarkdownReference.sections(in: try germanBundle()).map(\.title)

        XCTAssertEqual(english, ["Markdown Basics", "Diagrams", "Math", "Spelling", "Search"])
        XCTAssertEqual(german.count, english.count)
        // "Diagrams"→"Diagramme" and "Math"→"Formeln" are near-cognates; asserting the whole
        // array would just re-encode the translation. Assert that translation HAPPENED instead.
        XCTAssertNotEqual(german[0], english[0], "Markdown Basics should be translated in German")
        XCTAssertNotEqual(german[3], english[3], "Spelling should be translated in German")
    }

    func testLabelRowsLocalizeAndSyntaxRowsDoNot() throws {
        let german = try germanBundle()
        let englishRows = MarkdownReference.sections(in: try englishBundle()).flatMap(\.rows)
        let germanRows = MarkdownReference.sections(in: german).flatMap(\.rows)

        XCTAssertEqual(germanRows.count, englishRows.count)

        for (en, de) in zip(englishRows, germanRows) {
            if en.rendersSyntaxAsCode {
                XCTAssertEqual(de.syntax, en.syntax, "Markdown syntax must never translate: \(en.syntax)")
            } else if en.syntax == "Tab" {
                // A keycap legend. Apple ships "Tab" untranslated in de/ja; the key exists in the
                // catalog so other languages CAN differ, but equality here is correct, not a miss.
                continue
            } else {
                XCTAssertNotEqual(de.syntax, en.syntax, "Label row should translate: \(en.syntax)")
            }
        }
    }

    func testExactlyFourRowsAreLabelsNotSyntax() throws {
        let labels = MarkdownReference.sections(in: try englishBundle())
            .flatMap(\.rows).filter { !$0.rendersSyntaxAsCode }
        XCTAssertEqual(labels.count, 4, "A new label row must be localized — see testLabelRowsLocalize…")
    }
}
