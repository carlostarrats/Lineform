import XCTest
@testable import Lineform

/// Probes for the classes of defect that static reading keeps missing in this codebase: a
/// construct the editor and the renderer define twice and disagree about, a transform whose
/// arithmetic is unbounded, and a file authored on another platform (CRLF, a BOM, encoded
/// paths) that every ASCII/LF fixture in the suite steps around.
final class InteropProbeTests: XCTestCase {

    // MARK: - Ordered-list markers

    /// `MarkdownBlockGrouping`'s list regex accepts `[0-9]{1,9}` — CommonMark's limit. Return had
    /// no limit at all, so a 10-digit marker rendered as a PARAGRAPH while Return continued it as
    /// a list, and a marker at `Int.max` overflowed `number + 1` and trapped.
    func testOrderedContinuationAgreesWithTheRendererOnMarkerLength() {
        for digits in ["1", "123456789"] {
            let line = "\(digits). item"
            XCTAssertNotNil(
                MarkdownListContinuation.outcome(
                    for: line,
                    selectedRange: NSRange(location: (line as NSString).length, length: 0)
                ),
                "\(digits) digits is a list to the renderer, so Return must continue it"
            )
        }
        for digits in ["1234567890", "9223372036854775807", "99999999999999999999"] {
            let line = "\(digits). item"
            XCTAssertNil(
                MarkdownListContinuation.outcome(
                    for: line,
                    selectedRange: NSRange(location: (line as NSString).length, length: 0)
                ),
                "\(digits.count) digits is a paragraph to the renderer, so Return must not continue it"
            )
        }
    }

    /// The renderer accepts a tab after a list marker (`[ \t]+`); the editor's `LinePrefix`
    /// accepted only a space, so `-\titem` drew as a bullet but Return dropped out of the list.
    func testBulletContinuationAcceptsATabAfterTheMarker() {
        let line = "-\titem"
        guard case .continue(let insertion)? = MarkdownListContinuation.outcome(
            for: line,
            selectedRange: NSRange(location: (line as NSString).length, length: 0)
        ) else {
            return XCTFail("a tab-separated bullet renders as a list, so Return must continue it")
        }
        XCTAssertEqual(insertion, "\n- ")
    }

    // MARK: - Table reformat in a CRLF document

    /// `caretAfterReformat` rebuilds the table's line ranges from the replacement text. It split
    /// on `\n` and kept each line's trailing `\r`, which `contentRanges` then read as cell
    /// content — a phantom trailing cell, and the caret landing a column off after ⌃⌘R.
    func testReformatKeepsTheCaretInItsCellInACRLFDocument() {
        let table = [
            "| Name | Value |",
            "| --- | --- |",
            "| a | 1 |",
        ]
        for ending in ["\n", "\r\n"] {
            let text = table.joined(separator: ending)
            // Caret on the `1` in the body row's second cell.
            let caret = (text as NSString).range(of: "1", options: .backwards).location
            guard let edit = MarkdownTableEditing.reformat(
                in: text,
                selectedRange: NSRange(location: caret, length: 0)
            ) else {
                return XCTFail("the table is unaligned, so Reformat must rewrite it (\(ending.debugDescription))")
            }
            let edited = edit.text as NSString
            let landed = edited.substring(
                with: NSRange(location: edit.selectedRange.location, length: 1)
            )
            XCTAssertEqual(
                landed, "1",
                "caret must stay on its own cell's content for \(ending.debugDescription)"
            )
        }
    }

    // MARK: - Image destinations

    /// Percent-encoded destinations are ordinary Markdown — every other editor writes `%20` for a
    /// space. The resolver compared the raw string against the filesystem, so a document authored
    /// elsewhere showed a broken-image placeholder for a file that is right there on disk.
    func testResolverFindsAPercentEncodedDestination() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("my image (1).png")
        try Data([0x89]).write(to: file)

        XCTAssertEqual(
            ImageResolver.resolve(path: "my%20image%20%281%29.png", documentDirectory: directory),
            .localFile(file.standardizedFileURL)
        )
        // A literal path still wins, and a name that really does contain a percent escape is not
        // decoded out from under the writer when the literal file exists.
        XCTAssertEqual(
            ImageResolver.resolve(path: "my image (1).png", documentDirectory: directory),
            .localFile(file.standardizedFileURL)
        )
    }

    /// Reconnect writes the picked file's path straight into `![](…)`. A filename containing a
    /// parenthesis — `photo (1).png`, what every browser download is called — closed the
    /// destination early, so the app could no longer parse the link it had just written.
    func testReconnectWritesADestinationTheAppCanParseBack() {
        let directory = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        let picked = directory.appendingPathComponent("photo (1).png")
        let path = ImageLinkRewrite.linkPath(for: picked, documentDirectory: directory)

        let text = "![shot](old.png)"
        let rewritten = ImageLinkRewrite.rewritten(
            in: text,
            at: NSRange(location: 0, length: (text as NSString).length),
            newPath: path
        )
        let line = try? XCTUnwrap(rewritten)
        guard let line else { return }

        let ns = line as NSString
        guard let match = MarkdownInlineSyntax.image.firstMatch(
            in: line,
            range: NSRange(location: 0, length: ns.length)
        ), match.range.length == ns.length else {
            return XCTFail("the app's own image pattern must match the whole link it wrote: \(line)")
        }
        XCTAssertEqual(ns.substring(with: match.range(at: 1)), "shot", "alt text is preserved")
        XCTAssertEqual(
            ImageResolver.resolve(
                path: ns.substring(with: match.range(at: 2)),
                documentDirectory: directory
            ),
            .unresolved,
            "no such file, but the destination must still round-trip through the parser"
        )
        XCTAssertFalse(
            ns.substring(with: match.range(at: 2)).contains(")"),
            "a bare `)` closes the destination early"
        )
    }

    // MARK: - Byte-order mark

    /// A UTF-8 BOM is what Windows Notepad puts at the head of a `.md`. It is an invisible
    /// character on line 1, so the first heading, front-matter fence, or code fence in the file
    /// failed every `hasPrefix` test in the app and the whole document read as prose.
    func testABOMDoesNotHideTheFirstLinesStructure() {
        let bom = "\u{FEFF}"
        let text = bom + "# Title\n\nBody.\n"

        XCTAssertEqual(
            MarkdownOutlineParser().items(in: text).map(\.title),
            ["Title"],
            "the outline must see a heading on the first line of a BOM'd file"
        )
        XCTAssertEqual(markdownSourceLines(in: text).lines.first, "# Title")
        XCTAssertEqual(
            markdownSourceLines(in: text).ranges.first,
            NSRange(location: 1, length: 7),
            "the BOM occupies a UTF-16 unit, so the line's text starts one past it"
        )
    }

    /// The editor half of the same file. A disagreement between what the reader sees as a heading
    /// and what ⌘1–⌘6 sees is the marker-stacking bug this repo has now paid for three times.
    func testHeadingEditingAgreesWithTheParserOnABOMdLine() {
        let line = "\u{FEFF}## Section"
        guard case .editable(let indent, let level, _) = MarkdownHeadingEditing.classify(line: line) else {
            return XCTFail("a BOM'd heading is still a heading")
        }
        XCTAssertEqual(level, MarkdownHeadingParser.heading(in: line)?.level)
        XCTAssertEqual(indent, "\u{FEFF}", "the mark is carried in the indent, so it stays first in the file")

        guard let edit = MarkdownHeadingEditing.setLevel(
            1,
            in: line,
            selectedRange: NSRange(location: (line as NSString).length, length: 0)
        ) else {
            return XCTFail("⌘1 must retitle the line")
        }
        XCTAssertEqual(edit.text, "\u{FEFF}# Section", "no second marker, and the BOM stays at byte 0")
    }

    /// Front matter is protected from Writing Tools, the spell checker, and the heading commands.
    /// The prefix test ran against raw text, so a BOM'd file's YAML was protected by nothing.
    func testFrontMatterIsProtectedInABOMdFile() {
        let text = "\u{FEFF}---\ntitle: Notes\n---\n\n# Body\n"
        XCTAssertTrue(
            MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
                location: (text as NSString).range(of: "title").location,
                in: text
            ),
            "a YAML key inside front matter must be protected"
        )
        XCTAssertFalse(
            MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
                location: (text as NSString).range(of: "Body").location,
                in: text
            ),
            "and the protection must still end where the front matter does"
        )
    }

    func testABOMDoesNotStopTheFirstCodeFenceFromClosing() {
        let text = "\u{FEFF}```\ncode\n```\n\n# After\n"
        XCTAssertEqual(
            MarkdownOutlineParser().items(in: text).map(\.title),
            ["After"],
            "the fence must close, so the heading after it is real"
        )
    }

    // MARK: - Document statistics

    /// The status line says "characters". It counted UTF-16 code units, so a document of two
    /// emoji reported four characters.
    func testCharacterCountCountsWhatTheWriterSees() {
        XCTAssertEqual(DocumentStatistics(text: "😀😀").characterCount, 2)
        XCTAssertEqual(DocumentStatistics(text: "e\u{0301}").characterCount, 1, "a combining accent is one character")
        XCTAssertEqual(DocumentStatistics(text: "One calm line.").characterCount, 14)
    }

    // MARK: - The Quick Look mirror

    /// `QuickLookMarkdownRenderer` re-states the app's inline rules by hand — the appex cannot
    /// import `MarkdownInlineSyntax`. `RobustnessProbeTests` pins four emphasis hazards; this
    /// widens the same comparison to the rest of the inline surface, because every rule that is
    /// written twice here has eventually disagreed.
    @MainActor
    func testQuickLookMirrorsTheAppAcrossTheInlineSurface() {
        let lines = [
            "plain prose with no markers",
            "a **bold** word",
            "an *italic* word",
            "an _italic_ word",
            "a `code span` inline",
            "a ~~struck~~ word",
            "a [link](https://example.com) inline",
            "an ![alt text](photo.png) inline",
            "an empty ![](photo.png) inline",
            "an empty [](https://example.com) link",
            "escaped \\*not italic\\* here",
            "escaped \\`not code\\` here",
            "escaped \\[not a link\\](x) here",
            "a **bold with *italic* inside** word",
            "price is 2 * 3 * 4 dollars",
            "call make_test_file now",
            "the __init__ dunder",
            "a `` `nested` `` span",
            "unclosed **bold here",
            "unclosed `code here",
            "a | pipe and a $ dollar",
            "emoji 😀 **bold 😀** tail",
        ]
        for line in lines {
            let quickLook = QuickLookMarkdownRenderer.render(line + "\n").string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let app = MarkdownPreviewRenderer().render(line + "\n", profile: .original).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                quickLook, app,
                "Finder shows something the app never shows for \(line.debugDescription)"
            )
        }
    }

    /// The one place the two deliberately differ, pinned so it cannot silently widen.
    ///
    /// The app's inline pass is FLAT — one earliest-match scan per line, no recursion into a
    /// token's contents — so emphasis inside link text is drawn literally. The appex recurses.
    /// Making them agree means giving the app a recursive inline model, which is a redesign of
    /// the renderer, HTML export, and read-aloud together, not a fix; it is recorded in
    /// `docs/architecture/rendering.md` instead of being half-done here.
    @MainActor
    func testNestedEmphasisInLinkTextIsTheKnownDivergence() {
        let line = "a [**bold** link](https://example.com) inline\n"
        XCTAssertEqual(
            MarkdownPreviewRenderer().render(line, profile: .original).string
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "a **bold** link inline",
            "the app's flat scan draws the inner markers literally"
        )
        XCTAssertEqual(
            QuickLookMarkdownRenderer.render(line).string
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "a bold link inline",
            "the appex recurses into link text"
        )
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteropProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.standardizedFileURL
    }

    // MARK: - Gaps found by adversarially verifying the 2026-07-27 fixes

    /// Convert to Plain Text rewrites the user's file, so it must not touch code. The unescape
    /// added to it ran over fenced-code bodies and code-span contents, halving every doubled
    /// backslash in the user's code.
    func testConvertToPlainTextLeavesCodeVerbatim() {
        let markdown = """
        Prose with \\*escaped\\* markers.
        ```python
        re.compile(r"\\d+\\.\\d")
        printf("a\\tb\\n");
        ```
        A span `\\[a\\]` stays literal.
        """
        let plain = MarkdownPlainTextConverter.plainText(from: markdown)

        XCTAssertTrue(plain.contains(#"re.compile(r"\d+\.\d")"#), plain)
        XCTAssertTrue(plain.contains(#"printf("a\tb\n");"#), plain)
        XCTAssertTrue(plain.contains(#"\[a\]"#), "a code span's contents are literal: \(plain)")
        // The prose run outside code IS unescaped — that half of the behaviour must survive.
        XCTAssertTrue(plain.contains("Prose with *escaped* markers."), plain)
    }

    /// An unclosed `](` must not pair with a `)` on a later line and delete everything between.
    func testConvertToPlainTextNeverDeletesALineViaAnUnclosedLink() {
        let markdown = "See [the docs](https://example.com/a\nSmiley :-)\nNext paragraph survives?"
        let plain = MarkdownPlainTextConverter.plainText(from: markdown)

        XCTAssertTrue(plain.contains("Smiley :-)"), "the middle line must survive: \(plain)")
        XCTAssertTrue(plain.contains("Next paragraph survives?"), plain)
    }

    /// The BOM belongs to the file's encoding and only ever sits at index 0. Return must not copy
    /// it into the inserted text, where `markdownSourceLines` would not strip it and the new line
    /// would render as a paragraph while the editor still called it a list.
    func testReturnOnABOMdListLineDoesNotCopyTheByteOrderMark() {
        for line in ["\u{FEFF}- milk", "\u{FEFF}1. one", "\u{FEFF}> quoted", "\u{FEFF}  - deep"] {
            let prefix = LinePrefix(line: line)
            XCTAssertNotNil(prefix, line)
            XCTAssertFalse(
                prefix?.continuation.unicodeScalars.contains("\u{FEFF}") ?? true,
                "continuation must not carry the BOM: \(String(describing: prefix?.continuation))"
            )
        }
    }

    /// `MarkdownBlockGrouping` requires `[ \t]+` after a list marker, so a bare `-` is a
    /// paragraph. Accepting it made Return ERASE the character the writer had just typed.
    func testABareListMarkerIsNotAListLine() {
        for line in ["-", "*", "+", "1.", "1)"] {
            XCTAssertNil(LinePrefix(line: line), "\(line) renders as a paragraph, so Return must not treat it as a list")
        }
        for line in ["- x", "1. x", "-\tx"] {
            XCTAssertNotNil(LinePrefix(line: line), line)
        }
    }

    /// The app and the Quick Look appex must unescape the same marker set.
    func testAppAndQuickLookUnescapeTheSameMarkers() {
        for source in [#"a path C:\\Users\\me in prose"#, #"50\% off and \!bang"#, #"escaped \!\[not an image\] here"#] {
            let app = MarkdownInlineSyntax.unescape(source)
            let quickLook = QuickLookMarkdownRenderer.render(source).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(app, quickLook, "source: \(source)")
        }
    }

    /// A link or image DESTINATION must be non-empty on both surfaces.
    func testEmptyDestinationIsLiteralTextOnBothSurfaces() {
        for source in ["an empty [text]() link", "an empty ![alt]() image"] {
            let quickLook = QuickLookMarkdownRenderer.render(source).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(quickLook, source, "the appex must leave this literal, like the app does")
        }
    }

    /// A document that ends inside a fence still has a body to show.
    func testQuickLookRendersAnUnterminatedCodeBlock() {
        let rendered = QuickLookMarkdownRenderer.render("intro\n```swift\nlet a = 1\nlet b = 2\n").string
        XCTAssertTrue(rendered.contains("let a = 1"), rendered)
        XCTAssertTrue(rendered.contains("let b = 2"), rendered)
    }

    /// A closing fence must match the opener's run length and carry nothing after it.
    func testQuickLookHonoursTheRunLengthRule() {
        let rendered = QuickLookMarkdownRenderer.render("````\n```\ninner\n```\n````\nafter").string
        XCTAssertTrue(rendered.contains("inner"), rendered)
        XCTAssertTrue(rendered.contains("after"), rendered)
    }

    /// `removingPercentEncoding` is all-or-nothing, so an unescaped `%` broke the round trip for
    /// every filename that also contained a paren. A leading/trailing space is trimmed by the
    /// resolver, so it has to be escaped too.
    func testImageDestinationsRoundTripThroughAwkwardFilenames() {
        for name in ["Q3 100% final (2).png", "50%off (1).png", " leading (1).png", "trailing (1).png "] {
            let destination = ImageLinkRewrite.markdownDestination(for: name)
            XCTAssertEqual(
                destination.removingPercentEncoding, name,
                "destination \(destination) must decode back to the filename"
            )
        }
    }

    /// The outline, the renderer, and the editor must agree on what a line IS, not only on the
    /// fence rule. A mid-document BOM (what `cat a.md b.md` produces) is prose to the renderer.
    func testOutlineDoesNotOpenAFenceOnAMidDocumentByteOrderMark() {
        let text = "# One\n\n\u{FEFF}```swift\n\n# Two\n"
        let items = MarkdownOutlineParser().items(in: text)

        XCTAssertEqual(items.map(\.title), ["One", "Two"], "neither heading is inside a code block")
    }

    /// `markdownBlocks` consumes a `$$` block before it looks for a fence, so the outline needs
    /// math state or a fence-shaped line inside math swallows the rest of the document.
    func testOutlineIgnoresFenceShapedLinesInsideDisplayMath() {
        let text = "# One\n\n$$\n```\n$$\n\n# Two\n"
        let items = MarkdownOutlineParser().items(in: text)

        XCTAssertEqual(items.map(\.title), ["One", "Two"])
    }

    /// The editor's colouring is a fourth definition of these constructs and must agree with the
    /// renderer: an escaped opener is prose, and line 1 of a BOM'd file still has its heading.
    func testRangeAnalyzerAgreesWithTheRendererOnEscapesAndTheBOM() {
        let analyzer = MarkdownRangeAnalyzer()

        XCTAssertTrue(
            analyzer.ranges(in: #"escaped \`not code\` here"#).allSatisfy { $0.kind != .codeSpan },
            "an escaped backtick does not open a code span"
        )
        XCTAssertFalse(
            analyzer.ranges(in: "\u{FEFF}# Title").isEmpty,
            "line 1 of a BOM'd file still has a heading marker"
        )
    }

}
