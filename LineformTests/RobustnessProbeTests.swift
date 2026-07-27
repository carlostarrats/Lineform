import AppKit
import XCTest
@testable import Lineform

/// The companion sweep to `MarkdownRobustnessTests`.
///
/// That file closed the line-endings class over the Markdown *block* layer. This one covers the
/// surfaces it does not reach, chosen by the same rule: a transform belongs here if a wrong answer
/// either **writes to the user's file** (the formatting commands, Find & Replace, Convert to Plain
/// Text), **leaves the app** (HTML export, the Quick Look appex), or **feeds an AppKit call that
/// raises rather than degrades** (`setSelectedRange`).
///
/// Two kinds of property live here, both of which found shipped defects that reading the code did
/// not:
///
/// 1. **Hostile input.** The commands do UTF-16 range arithmetic on text they did not produce, so
///    they are fuzzed with emoji, non-BMP scalars, combining marks, and `\r`. Deterministic
///    xorshift with a fixed seed — a failure has to be reproducible.
/// 2. **Agreement between two definitions of one concept.** This codebase has several pairs that
///    must agree, and every disagreement so far has been a real defect. Asserting the agreement
///    directly is cheaper than keeping both sides correct by inspection.
final class RobustnessProbeTests: XCTestCase {

    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
    }

    /// Every character class the transforms special-case, plus a non-BMP scalar and a `\r`.
    private static let alphabet = Array("#*_-`~|[]()!>0123456789. \n\t\\$aZé😀\r:^{}\"'&<>/")

    private static let allCommands: [MarkdownFormattingCommand] = [
        .bold, .italic, .inlineCode, .strikethrough, .blockquote, .unorderedList, .orderedList, .link,
    ]

    private func fuzzText(_ random: inout Seeded, maxLength: Int = 70) -> String {
        var text = ""
        for _ in 0..<random.int(maxLength) {
            text.append(Self.alphabet[random.int(Self.alphabet.count)])
        }
        return text
    }

    // MARK: - Formatting commands

    /// Each command's result goes straight to `setSelectedRange`, where an out-of-bounds value is
    /// an exception, not a misplaced caret.
    ///
    /// The regression: `replace(range:in:with:)` converts through `Range(_:in:)`, which returns
    /// `nil` for a selection that splits a surrogate pair or separates a base character from its
    /// combining mark. The edit was then silently skipped while the command still returned the
    /// selection the edit *would* have produced — a range past the end of the unchanged document.
    /// Selecting a run of text that clipped half an emoji and pressing ⌘B raised.
    func testFormattingCommandsSurviveAdversarialInput() {
        var random = Seeded(state: 0xDEAD_BEEF_CAFE_1234)
        for _ in 0..<600 {
            let text = fuzzText(&random)
            let ns = text as NSString
            let location = random.int(ns.length + 1)
            let range = NSRange(location: location, length: random.int(ns.length - location + 1))

            for command in Self.allCommands {
                let edit = command.apply(to: text, selectedRange: range)
                let length = (edit.text as NSString).length
                XCTAssertGreaterThanOrEqual(edit.selectedRange.location, 0,
                    "\(command) location < 0 for \(text.debugDescription) range \(range)")
                XCTAssertGreaterThanOrEqual(edit.selectedRange.length, 0,
                    "\(command) length < 0 for \(text.debugDescription) range \(range)")
                XCTAssertLessThanOrEqual(NSMaxRange(edit.selectedRange), length,
                    "\(command) selection overruns its own result for \(text.debugDescription) range \(range)")
            }
        }
    }

    /// The other half of the same defect: a command that moves the caret while silently failing to
    /// edit leaves the user looking at a selection that describes text it never wrote.
    func testFormattingCommandsActuallyEditWhenTheyClaimTo() {
        var random = Seeded(state: 0x5151_5151_A0A0_A0A0)
        for _ in 0..<400 {
            let text = fuzzText(&random, maxLength: 50)
            let ns = text as NSString
            let location = random.int(ns.length + 1)
            let range = NSRange(location: location, length: random.int(ns.length - location + 1))

            for command in Self.allCommands {
                let edit = command.apply(to: text, selectedRange: range)
                if edit.text == text {
                    XCTAssertEqual(
                        edit.selectedRange,
                        MarkdownFormattingCommand.composedCharacterAligned(range, in: text),
                        "\(command) moved the caret without editing \(text.debugDescription) range \(range)"
                    )
                }
            }
        }
    }

    /// A selection covering whole wide characters must round-trip their content intact.
    func testFormattingCommandsHandleWideCharacters() {
        let samples = ["😀😀😀", "cafe\u{301} au lait", "a😀b", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢"]
        for text in samples {
            let ns = text as NSString
            for command in Self.allCommands {
                let whole = NSRange(location: 0, length: ns.length)
                let edit = command.apply(to: text, selectedRange: whole)
                XCTAssertNotEqual(edit.text, text,
                    "\(command) silently no-opped on \(text.debugDescription)")
                XCTAssertTrue(edit.text.contains(text) || command == .blockquote
                              || command == .unorderedList || command == .orderedList,
                    "\(command) lost content from \(text.debugDescription): \(edit.text.debugDescription)")
            }
        }
    }

    /// A selection that clips half a character grows to cover the whole one; a caret is only moved
    /// off the middle of a sequence, never widened into a selection the user did not make.
    func testComposedCharacterAlignmentGrowsSelectionsButNotCarets() {
        let text = "a😀b"                       // a | 😀 (2 units) | b
        XCTAssertEqual(
            MarkdownFormattingCommand.composedCharacterAligned(NSRange(location: 1, length: 1), in: text),
            NSRange(location: 1, length: 2), "a clipped emoji must be covered whole"
        )
        XCTAssertEqual(
            MarkdownFormattingCommand.composedCharacterAligned(NSRange(location: 2, length: 0), in: text),
            NSRange(location: 1, length: 0), "a caret inside a sequence moves to its start"
        )
        XCTAssertEqual(
            MarkdownFormattingCommand.composedCharacterAligned(NSRange(location: 0, length: 1), in: text),
            NSRange(location: 0, length: 1), "an already-aligned range is untouched"
        )
        // Out of bounds collapses to a caret rather than trapping inside NSString.
        XCTAssertEqual(
            MarkdownFormattingCommand.composedCharacterAligned(NSRange(location: 99, length: 5), in: text),
            NSRange(location: 4, length: 0)
        )
    }

    // MARK: - Find & Replace

    /// Matching is case- AND diacritic-insensitive, so a match is not the length of the query:
    /// `é` matches `e`, and a decomposed `e` + combining acute is two UTF-16 units matching one.
    /// Replace All rewrites every one of those ranges back-to-front, in the user's document.
    func testSearchMatchesAreWellFormedUnderWideInput() {
        var random = Seeded(state: 0x9999_8888_7777_6666)
        let searchAlphabet = Array("aeé😀 \r\ncafé\u{301}xAE")
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<random.int(50) {
                text.append(searchAlphabet[random.int(searchAlphabet.count)])
            }
            var query = ""
            for _ in 0..<random.int(4) + 1 {
                query.append(searchAlphabet[random.int(searchAlphabet.count)])
            }
            let ns = text as NSString
            let matches = EditorSearchResolver.matches(in: text, query: query)

            var previousEnd = 0
            for match in matches {
                XCTAssertGreaterThanOrEqual(match.location, previousEnd,
                    "matches overlap or go backwards for \(query.debugDescription) in \(text.debugDescription)")
                XCTAssertLessThanOrEqual(NSMaxRange(match), ns.length,
                    "match overruns the document for \(query.debugDescription) in \(text.debugDescription)")
                previousEnd = NSMaxRange(match)
            }

            if let result = EditorSearchResolver.replaceAll(in: text, query: query, replacement: "Z") {
                let length = (result.text as NSString).length
                XCTAssertLessThanOrEqual(NSMaxRange(result.selectedRange), length,
                    "Replace All selection overruns its own result for \(query.debugDescription)")
                XCTAssertEqual(result.replacedCount, matches.count,
                    "Replace All disagreed with search for \(query.debugDescription) in \(text.debugDescription)")
            }
        }
    }

    /// Replace must not cascade on its own output.
    func testReplaceAllDoesNotCascadeOnItsOwnOutput() {
        let result = EditorSearchResolver.replaceAll(in: "cat cat cat", query: "cat", replacement: "cats")
        XCTAssertEqual(result?.text, "cats cats cats")
        XCTAssertEqual(result?.replacedCount, 3)
    }

    // MARK: - Write-mode highlighting stays line-local

    /// Visible-window-scoped highlighting is only correct because `MarkdownRangeAnalyzer` is
    /// strictly line-local — a token that straddles a newline would be scoped away and the
    /// highlight would depend on where the window happens to be scrolled.
    func testRangeAnalyzerIsStrictlyLineLocal() {
        var random = Seeded(state: 0x7777_1234_ABCD_0001)
        let analyzer = MarkdownRangeAnalyzer()
        for _ in 0..<300 {
            let text = fuzzText(&random, maxLength: 80)
            let ns = text as NSString
            for token in analyzer.ranges(in: text) {
                XCTAssertFalse(ns.substring(with: token.range).contains("\n"),
                    "token \(token.kind) straddles a newline in \(text.debugDescription)")
            }
        }
    }

    // MARK: - Agreement: the editor and the renderer on what a table is

    /// `MarkdownTableEditing.locate` decides whether Tab moves between cells and whether ⌃⌘R
    /// rewrites the line; `markdownBlocks` decides whether Read mode draws a table. Where they
    /// disagree, ⌃⌘R reflows something the reader never saw as a table.
    func testEditorAndRendererAgreeOnWhatATableIs() {
        var random = Seeded(state: 0xFACE_0FF1_CE00_1234)
        let rowAlphabet = Array("| -:abc\t")
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<random.int(4) + 1 {
                for _ in 0..<random.int(14) {
                    text.append(rowAlphabet[random.int(rowAlphabet.count)])
                }
                text.append("\n")
            }
            let ns = text as NSString
            let source = markdownSourceLines(in: text)

            var rendererTableLines = Set<Int>()
            for block in markdownBlocks(in: source.lines, lineRanges: source.ranges) {
                guard case let .table(_, lastLineIndex) = block else { continue }
                var index = lastLineIndex
                while index >= 0, source.lines[index].contains("|") {
                    rendererTableLines.insert(index)
                    index -= 1
                }
            }

            for (index, lineRange) in source.ranges.enumerated() {
                let editorSeesTable = MarkdownTableEditing.locate(in: text, at: lineRange.location)?
                    .lineRanges.contains { NSIntersectionRange($0, lineRange).length > 0
                        || $0.location == lineRange.location } ?? false
                guard editorSeesTable else { continue }
                XCTAssertTrue(
                    rendererTableLines.contains(index),
                    """
                    the editor treats line \(index) as part of a table but the renderer does not, \
                    in \(text.debugDescription) — line \(ns.substring(with: lineRange).debugDescription)
                    """
                )
            }
        }
    }

    // MARK: - Agreement: heading editing and the outline parser

    /// The fixed list in `MarkdownRobustnessTests` checks the shapes someone thought of; the
    /// stacking bug lived in a shape nobody thought of.
    ///
    /// The two are deliberately NOT identical: `MarkdownHeadingParser` requires a non-empty title,
    /// because a nameless heading has nothing to show in the outline, while
    /// `MarkdownHeadingEditing` must still recognise `"## "` or ⌘2 prepends a second marker and
    /// produces the `# ## Section` line the outline can no longer see. So the invariant is
    /// directional, asserted both ways with that one exemption named explicitly.
    func testHeadingClassificationAgreesWithTheParserUnderFuzz() {
        var random = Seeded(state: 0x0FF1_CE12_3456_7890)
        let headingAlphabet = Array("# \tabc\r0.->")
        for _ in 0..<600 {
            var line = ""
            for _ in 0..<random.int(12) {
                line.append(headingAlphabet[random.int(headingAlphabet.count)])
            }
            let parsed = MarkdownHeadingParser.heading(in: line)?.level
            var classified: Int?
            if case let .editable(_, level, _) = MarkdownHeadingEditing.classify(line: line) {
                classified = level
            }

            if let parsed {
                XCTAssertEqual(classified, parsed,
                    "the outline sees a level-\(parsed) heading the editor does not, in \(line.debugDescription)")
            }
            if let classified, parsed == nil {
                let title = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertTrue(title.isEmpty,
                    "the editor will re-level a level-\(classified) heading the outline cannot see, in \(line.debugDescription)")
            }
        }
    }

    // MARK: - Spell checking stays inside the window it was asked about

    /// This runs per keystroke against the visible window; a range outside `enclosing` hands
    /// `NSSpellChecker` a slice of a different part of the document.
    func testSpellCheckRegionsStayWithinTheRequestedRange() {
        var random = Seeded(state: 0xABCD_0123_4567_89EF)
        for _ in 0..<300 {
            let text = fuzzText(&random, maxLength: 90)
            let ns = text as NSString
            let location = random.int(ns.length + 1)
            let enclosing = NSRange(location: location, length: random.int(ns.length - location + 1))
            for range in MarkdownSpellCheckRegions.checkableRanges(in: ns, enclosing: enclosing) {
                XCTAssertGreaterThanOrEqual(range.location, enclosing.location,
                    "region starts before the requested range in \(text.debugDescription)")
                XCTAssertLessThanOrEqual(NSMaxRange(range), NSMaxRange(enclosing),
                    "region ends after the requested range in \(text.debugDescription)")
            }
        }
    }

    // MARK: - Convert to Plain Text round-trips

    /// `restoredMarkdown` is the undo path for a command that rewrote the user's document.
    func testPlainTextConversionRestores() {
        var random = Seeded(state: 0x1111_2222_3333_4444)
        for _ in 0..<300 {
            let text = fuzzText(&random, maxLength: 60)
            let plain = MarkdownPlainTextConverter.plainText(from: text)
            let conversion = MarkdownPlainTextConversion(
                originalMarkdown: text,
                plainText: plain,
                range: NSRange(location: 0, length: (plain as NSString).length)
            )
            guard let restored = conversion.restoredMarkdown(in: plain) else { continue }
            XCTAssertEqual(restored.text, text, "round-trip lost content for \(text.debugDescription)")
        }
    }

    // MARK: - Exported HTML is a file the user shares

    /// Raw HTML in the source is escaped, not passed through. One-to-one governs *destinations* —
    /// paths and URLs are emitted exactly as written — it does not mean the body is raw markup.
    func testExportEscapesRawHTMLInBodyText() {
        let html = MarkdownHTMLRenderer.body(
            for: "A <script>alert(1)</script> line & an <img onerror=alert(2)> tag.\n",
            generatedImage: { _ in nil }
        )
        XCTAssertFalse(html.contains("<script>"), "raw script tag survived export: \(html)")
        XCTAssertFalse(html.contains("<img onerror"), "raw tag survived export: \(html)")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "the text should still be readable: \(html)")
    }

    /// A destination is emitted verbatim into a double-quoted attribute, so it must not be able to
    /// close that attribute and open an event handler.
    func testExportDestinationsCannotEscapeTheirAttribute() {
        let cases = [
            "[a](x\" onmouseover=\"alert(1))",
            "![a](x\" onerror=\"alert(1))",
            "[a](x><script>alert(1)</script>)",
        ]
        for markdown in cases {
            let html = MarkdownHTMLRenderer.inlineHTML(markdown)
            XCTAssertFalse(html.contains("onmouseover=\"alert"), "attribute injection via \(markdown): \(html)")
            XCTAssertFalse(html.contains("onerror=\"alert"), "attribute injection via \(markdown): \(html)")
            XCTAssertFalse(html.contains("<script>"), "tag injection via \(markdown): \(html)")
        }
    }

    /// Fenced code is exactly where people paste markup.
    func testExportEscapesFencedCode() {
        let html = MarkdownHTMLRenderer.body(
            for: "```html\n<script>alert(1)</script>\n```\n",
            generatedImage: { _ in nil }
        )
        XCTAssertFalse(html.contains("<script>alert"), "code fence emitted live HTML: \(html)")
    }

    // MARK: - Agreement: the Quick Look appex mirrors the app

    /// The appex cannot import `MarkdownInlineSyntax`, so it re-states the emphasis rules by hand.
    /// Where the two drift, Finder shows something the app never shows — and Finder is where
    /// people look at files they have not opened.
    @MainActor
    func testQuickLookMirrorsTheAppsEmphasisRules() {
        let hazards = [
            "run make_test_file now",
            "a __init__ dunder",
            "2 * 3 * 4",
            "snake_case_name here",
        ]
        for source in hazards {
            let quickLook = QuickLookMarkdownRenderer.render(source).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let app = MarkdownPreviewRenderer().render(source, profile: .original).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(quickLook, app, "Quick Look disagrees with the app on \(source.debugDescription)")
        }
    }

    /// An image is not a link. The appex had no image pattern, so its link rule claimed the
    /// `[alt](path)` and left the `!` behind: Finder showed "!a picture", underlined and
    /// accent-coloured as a link, for a line the app draws as a picture.
    func testQuickLookDoesNotStrandTheImageBang() {
        let rendered = QuickLookMarkdownRenderer.render("![a picture](photo.png)\n").string
        XCTAssertFalse(rendered.contains("!"), "the image marker leaked into the preview: \(rendered.debugDescription)")
        XCTAssertTrue(rendered.contains("a picture"), "the alt text should still read: \(rendered.debugDescription)")
    }

    /// The appex renders untrusted document content in an unattended Finder/Spotlight context.
    func testQuickLookSurvivesAdversarialInput() {
        var random = Seeded(state: 0x0BAD_F00D_0BAD_F00D)
        for _ in 0..<300 {
            _ = QuickLookMarkdownRenderer.render(fuzzText(&random, maxLength: 90))
        }
    }
}
