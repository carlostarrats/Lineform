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

    // MARK: - Identity

    /// `Section.id` and `Row.id` key SwiftUI `ForEach` and the copy button's transient "Copied"
    /// state. Every section title and five row syntax cells now localize, so an id derived from
    /// display text is an id that changes with the interface language. Asserted across all six
    /// bundles rather than reasoned about.
    func testEveryIdentityIsStableAcrossLanguages() throws {
        var sectionIDs: [String]?
        var rowIDs: [String]?

        for language in Self.languages {
            let sections = MarkdownReference.sections(in: try bundle(language))
            let sectionsHere = sections.map(\.id)
            let rowsHere = sections.flatMap(\.rows).map(\.id)

            if let sectionIDs {
                XCTAssertEqual(sectionsHere, sectionIDs, "section ids changed in \(language)")
                XCTAssertEqual(rowsHere, rowIDs, "row ids changed in \(language)")
            } else {
                sectionIDs = sectionsHere
                rowIDs = rowsHere
            }
        }

        // A duplicate id silently collapses two ForEach rows and makes one copy button light up
        // the other's checkmark.
        let sections = try XCTUnwrap(sectionIDs)
        let rows = try XCTUnwrap(rowIDs)
        XCTAssertEqual(Set(sections).count, sections.count, "duplicate section id in \(sections)")
        XCTAssertEqual(Set(rows).count, rows.count, "duplicate row id in \(rows)")
        XCTAssertFalse(sections.isEmpty)
        XCTAssertFalse(rows.isEmpty)
    }

    /// The rule in both directions: a LABEL row localizes its syntax and therefore MUST carry an
    /// explicit identifier; a literal-syntax row is document content and may fall through to it.
    func testLabelRowsCarryAnExplicitIdentifier() throws {
        for row in MarkdownReference.sections(in: try englishBundle()).flatMap(\.rows) {
            if row.rendersSyntaxAsCode {
                XCTAssertEqual(row.id, row.syntax, "\(row.syntax) no longer identifies by its syntax")
            } else {
                XCTAssertNotNil(row.identifier, "label row \"\(row.syntax)\" has a translated id")
            }
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

    /// East Asian Wide and Fullwidth ranges (UAX #11). A CJK character occupies TWO columns,
    /// so counting `Character`s measured the ja/zh rows at half their real width — the ceiling
    /// was tight for Latin (2 characters of headroom) and permitted ~2× overflow for CJK.
    private static let wideScalarRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF,
        0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    /// Column count, not character count. Measured on the grapheme's FIRST scalar: a
    /// combining mark never widens the cluster it attaches to.
    static func displayWidth(of text: String) -> Int {
        text.reduce(0) { total, character in
            let scalar = character.unicodeScalars.first?.value ?? 0
            return total + (wideScalarRanges.contains { $0.contains(scalar) } ? 2 : 1)
        }
    }

    func testDisplayWidthCountsEastAsianCharactersAsTwoColumns() {
        XCTAssertEqual(Self.displayWidth(of: "abc"), 3)
        XCTAssertEqual(Self.displayWidth(of: "見出し"), 6)
        XCTAssertEqual(Self.displayWidth(of: "⌘2〜⌘6"), 6, "⌘ is narrow, 〜 is wide")
        XCTAssertEqual(Self.displayWidth(of: "语法："), 6, "the fullwidth colon is two columns")
    }

    /// Guards the narrow-column rewrite in EVERY language, not just English. The column does not
    /// get wider in German. Pinning only `en` let a 120-character translation ship silently.
    func testExplanationsStayConciseInEveryLanguage() throws {
        for language in Self.languages {
            for section in MarkdownReference.sections(in: try bundle(language)) {
                for row in section.rows {
                    XCTAssertLessThanOrEqual(
                        Self.displayWidth(of: row.explanation), 90,
                        "too wide for the sidebar in \(language): \(row.syntax) — \(row.explanation)"
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

    func testAccessibilityLabelReadsExplanationThenSyntax() throws {
        let row = MarkdownReference.Row(syntax: "**bold**", explanation: "Bold.")
        XCTAssertEqual(row.accessibilityLabel(in: try englishBundle()), "Bold. Syntax: **bold**")
    }

    /// The connective is app chrome and localizes; the SYNTAX is document content and never does.
    /// Asserting the shape rather than the wording is deliberate: "Syntax" is an ordinary German
    /// word, so demanding a rendering that differs from English would force a contorted
    /// translation. What must hold in every language is the ORDER — explanation first, so
    /// VoiceOver leads with the meaning — and the syntax reaching the user byte-for-byte.
    func testAccessibilityLabelKeepsExplanationFirstAndSyntaxVerbatimInEveryLanguage() throws {
        let row = MarkdownReference.Row(syntax: "**bold**", explanation: "Fett.")

        for language in Self.languages {
            let label = row.accessibilityLabel(in: try bundle(language))
            XCTAssertTrue(label.hasPrefix("Fett."), "\(language): explanation must come first — \(label)")
            XCTAssertTrue(label.hasSuffix("**bold**"), "\(language): syntax must be last and verbatim — \(label)")
        }
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

    /// Every label row is asserted, including the two keycaps. An inequality check could not do
    /// that: `Tab` and `Return` are reproduced verbatim in German and Japanese, so the old test
    /// `continue`d past `Tab` and only three of the four label rows were really covered. What must
    /// hold is that the cell RESOLVED THROUGH THE CATALOG — assert it against the committed
    /// `Localizable.xcstrings`, which is true whether or not the translation differs.
    func testLabelRowsLocalizeAndSyntaxRowsDoNot() throws {
        let catalog = try Self.catalogTranslations()
        let english = try englishBundle()
        let englishRows = MarkdownReference.sections(in: english).flatMap(\.rows)

        for language in Self.languages {
            let rows = MarkdownReference.sections(in: try bundle(language)).flatMap(\.rows)
            XCTAssertEqual(rows.count, englishRows.count, "\(language): row count drifted")

            for (en, localized) in zip(englishRows, rows) {
                if en.rendersSyntaxAsCode {
                    XCTAssertEqual(localized.syntax, en.syntax,
                                   "\(language): Markdown syntax must never translate: \(en.syntax)")
                } else {
                    // English is the catalog KEY, not a localization: an `en.lproj` lookup
                    // returns the key itself.
                    let expected = language == "en"
                        ? en.syntax
                        : try XCTUnwrap(
                            catalog[en.syntax]?[language],
                            "label row \"\(en.syntax)\" has no \(language) catalog entry — it is "
                                + "not routing through String(localized:)")
                    XCTAssertEqual(localized.syntax, expected,
                                   "\(language): label row \"\(en.syntax)\" did not resolve from the catalog")
                }
            }
        }
    }

    func testExactlyFiveRowsAreLabelsNotSyntax() throws {
        let labels = MarkdownReference.sections(in: try englishBundle())
            .flatMap(\.rows).filter { !$0.rendersSyntaxAsCode }
        XCTAssertEqual(labels.map(\.id).sorted(), ["block-spacing", "return", "skipped", "spelling", "tab"],
                       "A new label row must be localized — see testLabelRowsLocalize…")
    }

    /// The copy affordance, from the other side: only a row whose cell is literal Markdown has
    /// anything to put on the pasteboard. The five label rows put a translated UI word in that
    /// cell, and `OutlineMarkdownBasicsTabView` used to offer "copy" on them too — so a Japanese
    /// user could put `スペル` on the pasteboard ready to paste into a Markdown file, where it
    /// means nothing.
    ///
    /// `copyableSyntax` is asserted against a NAMED list, not against `rendersSyntaxAsCode`: the
    /// property is derived from that flag, so comparing the two is `x == x` and can never fail.
    /// The view's side of this is structural, not tested here — `copyButton` takes a non-optional
    /// `String` that only the `if let copyableSyntax` unwrap can supply, so removing the check
    /// fails to compile.
    func testOnlyLiteralSyntaxRowsOfferCopy() throws {
        var copyableByID: [String: String?] = [:]
        for row in MarkdownReference.sections(in: try englishBundle()).flatMap(\.rows) {
            copyableByID[row.id] = row.copyableSyntax
        }

        // Every label row, by id — the same five `testExactlyFiveRowsAreLabelsNotSyntax` pins.
        for id in ["block-spacing", "return", "skipped", "spelling", "tab"] {
            let copyable = try XCTUnwrap(copyableByID[id], "the \(id) row disappeared")
            XCTAssertNil(copyable, "\(id) is a translated UI word and must offer no copy text")
        }

        // A code row from each section that has one, spot-checked against its literal Markdown.
        for syntax in ["# Title", "**bold**", "| a | b |", "```mermaid", "$x^2 + y^2$"] {
            XCTAssertEqual(copyableByID[syntax] ?? nil, syntax,
                           "\(syntax) is literal Markdown and must be copyable verbatim")
        }

        // And nothing outside the five labels is silently withheld.
        let withoutCopy = copyableByID.filter { $0.value == nil }.keys.sorted()
        XCTAssertEqual(withoutCopy, ["block-spacing", "return", "skipped", "spelling", "tab"])
    }

    /// The committed catalog, read as JSON. Reading is fine; never WRITE it through a serializer.
    // MARK: - The copy affordance and its accessibility mirror

    /// The row is collapsed with `.accessibilityElement(children: .ignore)`, which suppresses the
    /// copy `Button` outright — so the copy affordance also exists as a row-level accessibility
    /// action, and both halves read `Row.copyAffordance()`. The five label rows must have neither.
    ///
    /// This is what makes "no copy affordance at all" assertable without hosting a window: the view
    /// builds BOTH the button and the action from this one optional, so nil here is nil in both.
    func testOnlyLiteralSyntaxRowsOfferACopyAffordance() throws {
        let bundle = try englishBundle()
        var affordanceByID: [String: MarkdownReference.CopyAffordance?] = [:]
        for row in MarkdownReference.sections(in: bundle).flatMap(\.rows) {
            affordanceByID[row.id] = row.copyAffordance(in: bundle)
        }

        for id in ["block-spacing", "return", "skipped", "spelling", "tab"] {
            let affordance = try XCTUnwrap(affordanceByID[id], "the \(id) row disappeared")
            XCTAssertNil(affordance,
                         "\(id) is a translated UI word: no copy button and no copy action either")
        }

        let withoutAffordance = affordanceByID.filter { $0.value == nil }.keys.sorted()
        XCTAssertEqual(withoutAffordance, ["block-spacing", "return", "skipped", "spelling", "tab"],
                       "a code row lost its copy affordance, which removes its VoiceOver action too")
    }

    /// The action speaks the SYNTAX, never `Row.id` — which is an internal slug (`block-spacing`)
    /// on the rows that carry one — and it is localized at its definition site, through the
    /// existing `Copy %@` key rather than a duplicate.
    func testCopyAffordanceLabelSpeaksTheSyntaxAndLocalizes() throws {
        let english = try englishBundle()
        let row = try XCTUnwrap(MarkdownReference.sections(in: english).flatMap(\.rows)
            .first { $0.syntax == "**bold**" })
        let label = try XCTUnwrap(row.copyAffordance(in: english)).label
        XCTAssertEqual(label, "Copy **bold**")

        // Per language, against the committed catalog's `Copy %@` — a bare literal at the call
        // site would read "Copy **bold**" in all six.
        let template = try XCTUnwrap(Self.catalogTranslations()["Copy %@"],
                                     "the shared `Copy %@` key vanished from the catalog")
        for language in Self.languages where language != "en" {
            let translated = try XCTUnwrap(template[language], "`Copy %@` has no \(language) entry")
            let localized = try XCTUnwrap(row.copyAffordance(in: try bundle(language))).label
            XCTAssertEqual(localized, translated.replacingOccurrences(of: "%@", with: "**bold**"),
                           "\(language): the copy action label did not resolve from the catalog")
        }
    }

    /// What the action actually DOES. The pasteboard write is factored out of the button's closure
    /// precisely so the accessibility mirror and the button share it — and so it can be exercised
    /// here, against a scratch pasteboard, with no window and no `NSPasteboard.general` clobbering.
    /// `@MainActor` because the view type is — the pasteboard is created and read on the same
    /// actor that writes it. No window is constructed; this stays in the DEFAULT test plan.
    @MainActor
    func testCopyWritesTheRowsLiteralSyntaxToThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.lineform.tests.markdown-basics-copy"))
        defer { pasteboard.releaseGlobally() }

        for row in MarkdownReference.sections(in: try englishBundle()).flatMap(\.rows) {
            guard let affordance = row.copyAffordance(in: try englishBundle()) else { continue }
            OutlineMarkdownBasicsTabView.writeToPasteboard(affordance.text, to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), row.syntax,
                           "\(row.id) put something other than its literal syntax on the pasteboard")
        }

        // And it REPLACES rather than appends — the button can be pressed twice.
        OutlineMarkdownBasicsTabView.writeToPasteboard("# Title", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "# Title")
    }

    private static func catalogTranslations() throws -> [String: [String: String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lineform/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let strings = root?["strings"] as? [String: [String: Any]] ?? [:]
        var out: [String: [String: String]] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            var values: [String: String] = [:]
            for (language, localization) in localizations {
                if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
                    values[language] = value
                }
            }
            out[key] = values
        }
        return out
    }
}
