import AppKit
import XCTest
@testable import Lineform

/// Whole-document robustness for the pure Markdown layer.
///
/// Two things live here, both added after a review found defects the per-feature suites could not
/// see because they only ever feed well-formed `\n` input:
///
/// 1. **CRLF.** Every detector in `MarkdownBlockGrouping` compares against `\n`-shaped text —
///    `trimmingCharacters(in: .whitespaces)` does not strip `\r`, and neither do the table,
///    list, and checkbox regexes. A Windows-authored file therefore had no closing code fence,
///    and the whole document after the first fence collapsed into one code block.
/// 2. **A seeded fuzz sweep.** The pure transforms all do UTF-16 range arithmetic against text
///    they did not produce. The sweep is deterministic (fixed seed, no `Math.random`) so a
///    failure is reproducible, and it asserts nothing about output — it exists to prove none of
///    them trap on adversarial input.
final class MarkdownRobustnessTests: XCTestCase {

    // MARK: - CRLF

    private static let crlfDocument = """
    # Title\r
    \r
    ```swift\r
    let a = 1\r
    ```\r
    \r
    | A | B |\r
    |---|---|\r
    | 1 | 2 |\r
    \r
    ---\r
    \r
    > [!NOTE]\r
    > hi\r

    """

    /// The document above, with `\r\n` normalised to `\n`. A CRLF file must group into exactly
    /// the same blocks as its LF twin.
    private static var lfDocument: String {
        crlfDocument.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func blockNames(in text: String) -> [String] {
        let source = markdownSourceLines(in: text)
        return markdownBlocks(in: source.lines, lineRanges: source.ranges).map { block in
            switch block {
            case .lines: return "lines"
            case .singleLineMath: return "singleLineMath"
            case .fencedMath: return "fencedMath"
            case .mermaid: return "mermaid"
            case .horizontalRule: return "horizontalRule"
            case .blockquote: return "blockquote"
            case .callout: return "callout"
            case .list: return "list"
            case .table: return "table"
            case .fencedCode: return "fencedCode"
            case .image: return "image"
            }
        }
    }

    func testCRLFGroupsIntoTheSameBlocksAsLF() {
        XCTAssertEqual(blockNames(in: Self.crlfDocument), blockNames(in: Self.lfDocument))
        XCTAssertTrue(blockNames(in: Self.crlfDocument).contains("table"))
        XCTAssertTrue(blockNames(in: Self.crlfDocument).contains("callout"))
        XCTAssertTrue(blockNames(in: Self.crlfDocument).contains("horizontalRule"))
    }

    /// The regression itself: an unclosed fence swallowed everything after it.
    func testCRLFCodeFenceCloses() {
        let source = markdownSourceLines(in: Self.crlfDocument)
        let blocks = markdownBlocks(in: source.lines, lineRanges: source.ranges)
        guard let fence = blocks.compactMap({ block -> (String, String, Int?)? in
            guard case let .fencedCode(language, body, _, closingIndex) = block else { return nil }
            return (language, body, closingIndex)
        }).first else {
            return XCTFail("the CRLF document should contain a fenced code block")
        }
        XCTAssertEqual(fence.0, "swift")
        XCTAssertEqual(fence.1, "let a = 1")
        XCTAssertNotNil(fence.2, "the fence must find its closing delimiter")
    }

    /// Line text is CR-stripped but the ranges still measure the original bytes — checkbox
    /// toggling, image reconnect, code copy, and the cross-mode scroll restore all index the
    /// real document with them.
    func testCRLFLineRangesMeasureTheOriginalText() {
        let text = "alpha\r\nbeta\r\ngamma"
        let source = markdownSourceLines(in: text)
        XCTAssertEqual(source.lines, ["alpha", "beta", "gamma"])
        let ns = text as NSString
        XCTAssertEqual(source.ranges.map { ns.substring(with: $0) }, ["alpha\r", "beta\r", "gamma"])
    }

    func testLFSplittingIsUnchanged() {
        let text = "alpha\nbeta\n"
        let source = markdownSourceLines(in: text)
        XCTAssertEqual(source.lines, ["alpha", "beta", ""])
        XCTAssertEqual(source.ranges, [
            NSRange(location: 0, length: 5),
            NSRange(location: 6, length: 4),
            NSRange(location: 11, length: 0),
        ])
    }

    func testCRLFTaskCheckboxRangePointsAtItsMarker() {
        let text = "- [ ] one\r\n- [x] two\r\n"
        let source = markdownSourceLines(in: text)
        let blocks = markdownBlocks(in: source.lines, lineRanges: source.ranges)
        guard case let .list(items, _)? = blocks.first(where: { if case .list = $0 { return true }; return false }) else {
            return XCTFail("expected a list block")
        }
        let ns = text as NSString
        for item in items {
            guard let checkbox = item.checkbox else { return XCTFail("expected a checkbox") }
            XCTAssertTrue(["[ ]", "[x]"].contains(ns.substring(with: checkbox.sourceRange)))
        }
    }

    func testCRLFHTMLExportEmitsRealBlocks() {
        let html = MarkdownHTMLRenderer.body(for: Self.crlfDocument, generatedImage: { _ in nil })
        XCTAssertEqual(html, MarkdownHTMLRenderer.body(for: Self.lfDocument, generatedImage: { _ in nil }))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertFalse(html.contains("\r"), "a carriage return must never reach the exported HTML")
    }

    func testCRLFSpeechSkipsCodeAndReadsTheRest() {
        let spoken = SpeechTextExtractor.spokenText(from: Self.crlfDocument)
        XCTAssertEqual(spoken, SpeechTextExtractor.spokenText(from: Self.lfDocument))
        XCTAssertFalse(spoken.contains("let a = 1"), "fenced code is never spoken")
        XCTAssertTrue(spoken.contains("Title"))
    }

    /// Convert to Plain Text REWRITES the user's document, so it must not change the shape of a
    /// file it was only asked to strip markup from. `components(separatedBy: .newlines)` splits
    /// `\r` and `\n` separately, so every `\r\n` yielded an empty component and the conversion
    /// inserted a blank line after every line.
    func testPlainTextConversionDoesNotDoubleCRLFLineBreaks() {
        let crlf = "# Title\r\n\r\n- one\r\n- two\r\n"
        let converted = MarkdownPlainTextConverter.plainText(from: crlf)
        XCTAssertEqual(converted.components(separatedBy: "\n").count,
                       crlf.components(separatedBy: "\n").count,
                       "conversion changed the line count: \(converted.debugDescription)")
        // Line endings survive the conversion, and the markup is still stripped.
        XCTAssertTrue(converted.contains("\r\n"), "CRLF endings must be preserved")
        XCTAssertFalse(converted.contains("# "), "heading markers are still stripped")
        XCTAssertTrue(converted.contains("Title"))
    }

    func testPlainTextConversionIsUnchangedForLF() {
        XCTAssertEqual(
            MarkdownPlainTextConverter.plainText(from: "# Title\n\n- one\n"),
            MarkdownPlainTextConverter.plainText(from: "# Title\r\n\r\n- one\r\n")
                .replacingOccurrences(of: "\r", with: "")
        )
    }

    /// Write-mode block spacing keys off blank lines; a CRLF blank line is `"\r"`, which
    /// `.whitespaces` does not trim, so every blank line read as content.
    func testBlockSpacingSeesCRLFBlankLines() {
        let lf = MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes(
            inLines: "# Title\n\nbody\n".components(separatedBy: "\n")
        )
        let crlf = MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes(
            inLines: "# Title\r\n\r\nbody\r\n".components(separatedBy: "\n")
        )
        XCTAssertEqual(crlf, lf)
    }

    /// The sweep. CRLF caused three separate defects in three different layers, each found only
    /// after the previous "fix" was called done — so the class is closed by asserting the general
    /// property rather than by patching the next instance: for a document differing ONLY in line
    /// endings, every pure transform must agree with its LF twin once endings are normalised out
    /// of the comparison. A new transform that forgets `\r` fails here instead of shipping.
    func testEveryPureTransformAgreesAcrossLineEndings() {
        let lf = """
        ---
        title: Notes
        ---

        # Heading

        Body with `code` and a [link](x.md).

        - [ ] task one
        - [x] task two

        > [!NOTE]
        > callout body

        | A | B |
        |---|---|
        | 1 | 2 |

        ```swift
        let a = 1
        ```

        $$
        x = 1
        $$

        ---

        Tail.
        """
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        func stripped(_ text: String) -> String { text.replacingOccurrences(of: "\r", with: "") }

        XCTAssertEqual(markdownSourceLines(in: crlf).lines, markdownSourceLines(in: lf).lines,
                       "line splitting differs")

        // Block grouping: same partition, same payloads. Source RANGES must legitimately differ
        // (the CRLF document is longer), so range-carrying fields are compared by the text they
        // cover — which is the property that actually matters to checkbox toggling and Reconnect.
        func blockDescriptions(in text: String) -> [String] {
            let ns = text as NSString
            let source = markdownSourceLines(in: text)
            func covered(_ range: NSRange) -> String { stripped(ns.substring(with: range)) }
            return markdownBlocks(in: source.lines, lineRanges: source.ranges).map { block in
                switch block {
                case let .list(items, lastLineIndex):
                    let described = items.map { item in
                        let box = item.checkbox.map { "\($0.isChecked):\(covered($0.sourceRange))" } ?? "-"
                        return "\(item.text)/\(item.indentLevel)/\(item.ordinal.map(String.init) ?? "-")/\(box)"
                    }
                    return "list(\(described))/\(lastLineIndex)"
                case let .image(alt, path, sourceRange, lineIndex):
                    return "image(\(alt)/\(path)/\(covered(sourceRange))/\(lineIndex))"
                default:
                    return String(describing: block)
                }
            }
        }
        XCTAssertEqual(blockDescriptions(in: crlf), blockDescriptions(in: lf),
                       "block grouping differs across line endings")

        XCTAssertEqual(
            MarkdownHTMLRenderer.body(for: crlf, generatedImage: { _ in nil }),
            MarkdownHTMLRenderer.body(for: lf, generatedImage: { _ in nil }),
            "HTML export differs"
        )
        XCTAssertEqual(
            SpeechTextExtractor.spokenText(from: crlf),
            SpeechTextExtractor.spokenText(from: lf),
            "read-aloud differs"
        )
        XCTAssertEqual(
            stripped(MarkdownPlainTextConverter.plainText(from: crlf)),
            MarkdownPlainTextConverter.plainText(from: lf),
            "Convert to Plain Text differs"
        )
        XCTAssertEqual(
            MarkdownOutlineParser().items(in: crlf).map(\.title),
            MarkdownOutlineParser().items(in: lf).map(\.title),
            "outline differs"
        )
        XCTAssertEqual(
            MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes(inLines: crlf.components(separatedBy: "\n")),
            MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes(inLines: lf.components(separatedBy: "\n")),
            "write-mode block spacing differs"
        )

        // Protected regions are position-dependent, so compare the TEXT they cover.
        func protectedText(in text: String) -> [String] {
            let ns = text as NSString
            return MarkdownWritingToolsProtection
                .ignoredRanges(in: text, enclosingRange: NSRange(location: 0, length: ns.length))
                .sorted { $0.location < $1.location }
                .map { stripped(ns.substring(with: $0)) }
        }
        XCTAssertEqual(protectedText(in: crlf), protectedText(in: lf), "protected regions differ")

        func checkableText(in text: String) -> [String] {
            let ns = text as NSString
            return MarkdownSpellCheckRegions
                .checkableRanges(in: ns, enclosing: NSRange(location: 0, length: ns.length))
                .map { stripped(ns.substring(with: $0)) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        XCTAssertEqual(checkableText(in: crlf), checkableText(in: lf), "spell-checked regions differ")
    }

    // MARK: - Heading detection agreement

    /// `MarkdownHeadingEditing.classify` and `MarkdownHeadingParser` must agree about what a
    /// heading is, or a heading command rewrites a line the reader never saw as one — or leaves
    /// one the outline sidebar cannot see. Both accept up to three columns of indent and a
    /// space, tab, or end of line after the hashes.
    func testHeadingDetectionAgreesWithTheOutlineParser() {
        let headings = ["# Title", "###### Six", " ## Indented", "   # Three spaces", "#\tTab", "##\tTab section"]
        for line in headings {
            guard case let .editable(_, level, _) = MarkdownHeadingEditing.classify(line: line) else {
                return XCTFail("\(line.debugDescription) should be editable")
            }
            XCTAssertEqual(level, MarkdownHeadingParser.heading(in: line)?.level,
                           "disagreement on \(line.debugDescription)")
        }

        let notHeadings = ["####### Seven", "#NoSpace", "    # Indented code", "plain"]
        for line in notHeadings {
            XCTAssertNil(MarkdownHeadingParser.heading(in: line), "\(line.debugDescription) is not a heading")
        }
    }

    /// The stacking bug, reached through a tab: `##\tSection` is a real CommonMark heading, so
    /// ⌘4 must change its level rather than prepend a second marker. The separator is rewritten
    /// as a space, which is what the command emits for every heading it writes.
    func testHeadingLevelChangeOnATabSeparatedHeadingDoesNotStack() {
        let edit = MarkdownHeadingEditing.setLevel(4, in: "##\tSection", selectedRange: NSRange(location: 8, length: 0))
        XCTAssertEqual(edit?.text, "#### Section")
        XCTAssertEqual(MarkdownHeadingParser.heading(in: edit?.text ?? "")?.level, 4)
    }

    // MARK: - Executable link schemes

    /// HTML export writes a file that gets shared. A `javascript:` destination is code, not a
    /// path, so it is dropped while the link text still renders — the one-to-one rule protects
    /// paths from being resolved or rewritten, which is a different thing.
    func testExportDropsExecutableLinkDestinations() {
        let cases = [
            "[click](javascript:location='http://evil.example')",
            "[click](JavaScript:alert)",
            "[click](  javascript:alert)",
            "[click](java\tscript:alert)",
            "[click](vbscript:msgbox)",
            "[click](data:text/html;base64,PHNjcmlwdD4=)",
            // An SVG is a document and can carry script; naming only `text/html` missed it.
            "[click](data:image/svg+xml,<svg onload=alert(1)>)",
            "[click](data:application/xhtml+xml,x)",
        ]
        for markdown in cases {
            let html = MarkdownHTMLRenderer.inlineHTML(markdown)
            XCTAssertFalse(html.contains("<a "), "\(markdown.debugDescription) still exported a link: \(html)")
            XCTAssertTrue(html.contains("click"), "the link text must survive: \(html)")
        }
    }

    /// The rule is a closed set of executable schemes, NOT a URL policy — every ordinary
    /// destination, including relative paths and inline image data, still passes through verbatim.
    func testExportKeepsOrdinaryLinkDestinationsVerbatim() {
        let cases = [
            ("[a](images/photo.png)", "images/photo.png"),
            ("[a](https://example.com/x?y=1&z=2)", "https://example.com/x?y=1&amp;z=2"),
            ("[a](../notes/other.md)", "../notes/other.md"),
            ("[a](mailto:me@example.com)", "mailto:me@example.com"),
            ("[a](#anchor)", "#anchor"),
            ("[a](my javascript notes.md)", "my javascript notes.md"),
            // App deep links are why export blocklists rather than allowlisting the way the
            // Quick Look appex does — people really do write these in notes.
            ("[a](obsidian://open?vault=x)", "obsidian://open?vault=x"),
            ("[a](message://%3Cabc@example.com%3E)", "message://%3Cabc@example.com%3E"),
            ("[a](file:///Users/me/notes.md)", "file:///Users/me/notes.md"),
        ]
        for (markdown, expected) in cases {
            let html = MarkdownHTMLRenderer.inlineHTML(markdown)
            XCTAssertEqual(html, "<a href=\"\(expected)\">a</a>", "changed \(markdown.debugDescription)")
        }
    }

    /// Images are deliberately untouched: `javascript:` in an `img src` does not execute, and a
    /// `data:image` payload is legitimate — generated math and mermaid images depend on it.
    func testExportKeepsImageSourcesVerbatim() {
        XCTAssertTrue(MarkdownHTMLRenderer.inlineHTML("![x](data:image/png;base64,AAA)")
            .contains("src=\"data:image/png;base64,AAA\""))
    }

    // MARK: - Seeded fuzz

    /// Deterministic xorshift — `Math.random` would make a failure unreproducible.
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

    /// Every character class the transforms special-case, plus a non-BMP scalar and a `\r`, so
    /// UTF-16 index arithmetic is exercised against surrogate pairs.
    private static let fuzzAlphabet = Array("#*_-`~|[]()!>0123456789. \n\t\\$aZé😀\r:^{}\"'&<>/")

    func testPureTransformsSurviveAdversarialInput() {
        var random = Seeded(state: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<600 {
            var text = ""
            for _ in 0..<random.int(90) {
                text.append(Self.fuzzAlphabet[random.int(Self.fuzzAlphabet.count)])
            }
            let ns = text as NSString
            let location = random.int(ns.length + 1)
            let range = NSRange(location: location, length: random.int(ns.length - location + 1))
            let caret = NSRange(location: location, length: 0)

            _ = MarkdownListContinuation.outcome(for: text, selectedRange: caret)
            _ = MarkdownHeadingEditing.setLevel(random.int(7) == 0 ? nil : random.int(6) + 1, in: text, selectedRange: range)
            _ = MarkdownTableEditing.tabTarget(in: text, selectedRange: range, forward: random.int(2) == 0)
            _ = MarkdownTableEditing.reformat(in: text, selectedRange: caret)
            _ = MarkdownTableEditing.insertion(in: text, selectedRange: caret)
            let source = markdownSourceLines(in: text)
            _ = markdownBlocks(in: source.lines, lineRanges: source.ranges)
            _ = MarkdownHTMLRenderer.body(for: text, generatedImage: { _ in nil })
            _ = MarkdownPlainTextConverter.plainText(from: text)
            _ = SpeechTextExtractor.spokenText(from: text)
            _ = MarkdownSpellCheckRegions.checkableRanges(in: ns, enclosing: range)
            _ = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: range)
            _ = MarkdownOutlineParser().items(in: text)
        }
    }

    /// Reformat writes its result to the user's file, so the table it writes back must parse to
    /// exactly the table that was there. Comparing the PARSED tables (rather than the raw text)
    /// is what makes this checkable: padding short rows and dropping cells past the column count
    /// is GFM's own normalisation, while losing characters inside a cell is the bug. This is the
    /// shape that caught `String.padding(toLength:)` truncating emoji and decomposed accents.
    func testReformatPreservesEveryCell() {
        var random = Seeded(state: 0x0123_4567_89AB_CDEF)
        let cellAlphabet = Array("ab 😀é#*-|\\`0")
        for _ in 0..<400 {
            func cell() -> String {
                var out = ""
                for _ in 0..<random.int(5) { out.append(cellAlphabet[random.int(cellAlphabet.count)]) }
                return out
            }
            let text = "| \(cell()) | \(cell()) |\n| - | - |\n| \(cell()) | \(cell()) |"
            let caret = NSRange(location: 2, length: 0)
            guard let before = MarkdownTableEditing.locate(in: text, at: caret.location)?.table,
                  let edit = MarkdownTableEditing.reformat(in: text, selectedRange: caret),
                  let after = MarkdownTableEditing.locate(in: edit.text, at: caret.location)?.table else {
                continue
            }
            XCTAssertEqual(after.headers, before.headers, "headers changed reformatting \(text.debugDescription)")
            XCTAssertEqual(after.rows, before.rows, "rows changed reformatting \(text.debugDescription)")
        }
    }
}
