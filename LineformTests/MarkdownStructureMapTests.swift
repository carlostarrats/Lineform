import XCTest
@testable import Lineform

/// The AI-edit safety layer: what is prose (may be sent and revised) and what is Markdown
/// structure (never sent, never changed). Wrong offsets here write into the user's file, so the
/// fixtures are adversarial on purpose — CRLF, BOM, emoji, escapes, tables with `\|`, fences
/// inside fences.
final class MarkdownStructureMapTests: XCTestCase {
    // MARK: - Helpers

    private func segments(_ text: String) -> [ProseSegment] {
        MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: (text as NSString).length))
    }

    private func texts(_ text: String) -> [String] {
        segments(text).map(\.text)
    }

    /// Every segment's range must hold exactly its text, and never overlap structure.
    private func assertSegmentsAreExact(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = text as NSString
        let structure = MarkdownStructureMap.structureRanges(in: ns, scope: NSRange(location: 0, length: ns.length))
        for segment in segments(text) {
            XCTAssertEqual(ns.substring(with: segment.range), segment.text, file: file, line: line)
            for range in structure {
                XCTAssertEqual(NSIntersectionRange(range, segment.range).length, 0, "segment \(segment) overlaps structure \(range)", file: file, line: line)
            }
        }
    }

    /// The one admitted-or-not decision for a single revision of the segment whose text is `target`.
    private func admit(_ revision: String, replacing target: String, in text: String, file: StaticString = #filePath, line: UInt = #line) -> String?? {
        let all = segments(text)
        guard let segment = all.first(where: { $0.text == target }) else {
            XCTFail("no segment \(target) in \(all.map(\.text))", file: file, line: line)
            return nil
        }
        let result = MarkdownStructureGuard.admissibleRevisions([revision], for: [segment], in: text)
        XCTAssertEqual(result.count, 1, file: file, line: line)
        return result.first
    }

    private func applying(_ revisions: [String?], to segments: [ProseSegment], in text: String) -> String {
        let mutable = NSMutableString(string: text)
        for (segment, revision) in zip(segments, revisions).sorted(by: { $0.0.range.location > $1.0.range.location }) {
            if let revision {
                mutable.replaceCharacters(in: segment.range, with: revision)
            }
        }
        return mutable as String
    }

    // MARK: - Brief tests

    func testHeadingMarkerIsStructure() {
        XCTAssertEqual(texts("## Section title\n"), ["Section title"])
        // Indented (≤3) and closed ATX headings, per `MarkdownHeadingParser`.
        XCTAssertEqual(texts("  ### Indented ###\n"), ["Indented"])
        assertSegmentsAreExact("## Section title\n")
    }

    func testListTaskAndNestedIndentation() {
        XCTAssertEqual(texts("- [ ] Buy milk\n  1. Nested item\n"), ["Buy milk", "Nested item"])
        XCTAssertEqual(texts("* [x] Done\n    + Deep\n9) Nine\n"), ["Done", "Deep", "Nine"])
        assertSegmentsAreExact("- [ ] Buy milk\n  1. Nested item\n")
    }

    func testBlockquoteAndCallout() {
        XCTAssertEqual(texts("> [!NOTE] Heads up\n> Body text\n"), ["Heads up", "Body text"])
        // Nested quotes: every `>` is a marker, not only the first.
        XCTAssertEqual(texts("> > Deep quote\n>> Deeper\n"), ["Deep quote", "Deeper"])
        // A list inside a quote keeps its marker.
        XCTAssertEqual(texts("> - quoted item\n"), ["quoted item"])
        assertSegmentsAreExact("> [!WARNING]\n> Body text\n")
        XCTAssertEqual(texts("> [!WARNING]\n> Body text\n"), ["Body text"])
    }

    func testEmphasisDelimitersAreStructure() {
        XCTAssertEqual(texts("This is **very** good"), ["This is", "very", "good"])
        XCTAssertEqual(texts("an *em* and _it_ and ~~gone~~"), ["an", "em", "and", "it", "and", "gone"])
        // snake_case and arithmetic are prose, not emphasis.
        XCTAssertEqual(texts("make_test_file 2 * 3 * 4"), ["make_test_file 2 * 3 * 4"])
    }

    func testLinkTextIsProseDestinationIsNot() {
        XCTAssertEqual(texts("See [the docs](https://x.y \"T\") now"), ["See", "the docs", "now"])
        // Balanced parentheses in the URL stay inside the destination.
        XCTAssertEqual(texts("A [wiki](https://e.org/Foo_(bar)) link"), ["A", "wiki", "link"])
        assertSegmentsAreExact("A [wiki](https://e.org/Foo_(bar)) link")
    }

    func testImageIsWhollyStructure() {
        XCTAssertEqual(texts("![Alt text](img.png) after"), ["after"])
        XCTAssertEqual(texts("![Alt text](img.png)\n"), [])
        // Spaces and parens in a local path (what other editors write) stay structure.
        XCTAssertEqual(texts("Before ![a pic](my photo (1).png) after"), ["Before", "after"])
        XCTAssertEqual(texts("![](photo%20%281%29.png) tail"), ["tail"])
    }

    func testInlineCodeAndAllMathAreStructure() {
        XCTAssertEqual(texts("Use `x` and $a^2$ or \\(b^2\\) here"), ["Use", "and", "or", "here"])
        // Prose dollar amounts stay prose.
        XCTAssertEqual(texts("It costs $5 to $10."), ["It costs $5 to $10."])
    }

    func testBlocksAreNeverSent() {
        let text = """
        ---
        title: Doc
        ---

        ```swift
        let x = 1

        ```

        ````markdown
        ```
        inner fence
        ```
        Still code
        ````

        ```mermaid
        ---
        title: Flow
        ---
        graph TD
        A-->B
        ```

        $$
        a^2 + b^2
        $$

        $$x = 1$$

        \\[
        c^2
        \\]

        \\[d^2\\]

        Prose.
        """
        XCTAssertEqual(texts(text), ["Prose."])
    }

    func testTableCellsAreProsePipesAreNot() {
        XCTAssertEqual(texts("| A | B |\n|---|:-:|\n| one | two |\n"), ["A", "B", "one", "two"])
        // Escaped pipes and code in cells are structure.
        XCTAssertEqual(texts("| A | B |\n|---|---|\n| a \\| b | `c|d` x |\n"), ["A", "B", "a", "b", "x"])
        assertSegmentsAreExact("| A | B |\n|---|---|\n| a \\| b | `c|d` x |\n")
    }

    func testEscapesHardBreaksHTMLFootnotes() {
        XCTAssertEqual(texts("Keep \\* this  \nNext<br>line[^1]\n"), ["Keep", "this", "Next", "line"])
        XCTAssertEqual(texts("Ends with backslash\\\nNext"), ["Ends with backslash", "Next"])
        XCTAssertEqual(texts("<div class=\"x\">Inside</div> <!-- hidden note -->\n[^1]: The note."), ["Inside", "The note."])
        // An autolink is a link: its URL is never sent.
        XCTAssertEqual(texts("Visit <https://example.com/a?b=c> today"), ["Visit", "today"])
    }

    func testRuleAndSetextUnderline() {
        XCTAssertEqual(texts("Title\n===\n\n---\n\nText"), ["Title", "Text"])
        XCTAssertEqual(texts("Sub\n---\n\n***\n\n___\n\nEnd"), ["Sub", "End"])
    }

    func testCRLFAndBOM() {
        let text = "\u{FEFF}# Title\r\nBody line\r\n"
        let found = segments(text)
        XCTAssertEqual(found.map(\.text), ["Title", "Body line"])
        XCTAssertEqual(found.map(\.range), [NSRange(location: 3, length: 5), NSRange(location: 10, length: 9)])
        let signature = MarkdownStructureMap.signature(of: text as NSString, scope: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertTrue(signature.joined().contains("\u{FEFF}"))
        XCTAssertTrue(signature.joined().contains("\r\n"))
        // CRLF tables and fences survive the `\r`.
        XCTAssertEqual(texts("| A |\r\n|---|\r\n| b |\r\n\r\n```\r\ncode\r\n```\r\nAfter\r\n"), ["A", "b", "After"])
    }

    func testScopedStructureMatchesWholeDocument() {
        let text = """
        \u{FEFF}---
        title: x
        ---
        # Heading **bold**
        Para with `code` and [link](u) and $m$.\r
        - [ ] task
          1. nested
        > [!TIP] Title
        > body

        | a | b \\| c |
        |---|---|
        | 1 | 2 |

        ```
        fenced
        ```
        Setext
        ===
        End  \u{1F44B}\u{1F3FD} trailing\\
        """
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let whole = MarkdownStructureMap.structureRanges(in: ns, scope: full)
        let lines = markdownSourceLines(in: text)
        XCTAssertGreaterThan(lines.ranges.count, 10)
        for index in lines.ranges.indices {
            let start = index == 0 ? 0 : lines.ranges[index].location
            let end = index + 1 < lines.ranges.count ? lines.ranges[index + 1].location : ns.length
            let lineRange = NSRange(location: start, length: end - start)
            let scoped = MarkdownStructureMap.structureRanges(in: ns, scope: lineRange)
            let expected = whole.map { NSIntersectionRange($0, lineRange) }.filter { $0.length > 0 }
            XCTAssertEqual(scoped, expected, "line \(index)")
            // A caret (empty scope) inside the line sees the same line.
            let caret = MarkdownStructureMap.structureRanges(in: ns, scope: NSRange(location: start, length: 0))
            XCTAssertEqual(caret, expected, "caret on line \(index)")
        }
    }

    func testGuardAdmitsProseOnlyRevision() {
        XCTAssertEqual(admit("This was", replacing: "This is", in: "This is **very** good"), "This was")
        XCTAssertEqual(admit("très", replacing: "very", in: "This is **very** good"), "très")
        XCTAssertEqual(admit("Uno", replacing: "one", in: "| A | B |\n|---|:-:|\n| one | two |\n"), "Uno")
        XCTAssertEqual(admit("the manual", replacing: "the docs", in: "See [the docs](https://x.y) now"), "the manual")
        // Edge whitespace the AI adds is not spliced in.
        XCTAssertEqual(admit("  Body copy ", replacing: "Body line", in: "# T\r\nBody line\r\n"), "Body copy")
    }

    func testGuardDropsRevisionThatAddsStructure() {
        let para = "Hello world\n\nNext para"
        for revision in ["**x**", "# x", "`x`", "\\*x", "[a](b)", "$x$", "![a](b)", "<b>x</b>", "x[^1]", "- x", "> x", "1. x", "```x", "x  \\"] {
            XCTAssertEqual(admit(revision, replacing: "Hello world", in: para), .some(nil), revision)
        }
        let table = "| A | B |\n|---|:-:|\n| one | two |\n"
        XCTAssertEqual(admit("x | y", replacing: "one", in: table), .some(nil))
        XCTAssertEqual(admit("x \\| y", replacing: "one", in: table), .some(nil))
        // Becoming a setext underline or a rule.
        XCTAssertEqual(admit("===", replacing: "Second", in: "First\nSecond\n"), .some(nil))
        XCTAssertEqual(admit("***", replacing: "Alone", in: "Above\n\nAlone\n\nBelow"), .some(nil))
        // Turning a paragraph line into a table header above an existing row.
        XCTAssertEqual(admit("a | b", replacing: "Top", in: "Top\n|---|---|\n"), .some(nil))
    }

    func testGuardDropsLineBreaksControlCharactersAndRunaways() {
        let text = "Short prose here.\n"
        for revision in ["a\nb", "a\rb", "a\u{2028}b", "a\u{2029}b", "a\u{85}b", "a\u{7}b", "a\tb", "   ", ""] {
            XCTAssertEqual(admit(revision, replacing: "Short prose here.", in: text), .some(nil), revision.debugDescription)
        }
        let original = "Short prose here."
        let runaway = String(repeating: original, count: 20)
        XCTAssertEqual(admit(runaway, replacing: original, in: text), .some(nil))
        // Exactly at the ceiling is admitted.
        let ceiling = String(repeating: "a", count: 2 * (original as NSString).length + 200)
        XCTAssertEqual(admit(ceiling, replacing: original, in: text), ceiling)
    }

    func testVerifyDetectsChangedStructure() {
        XCTAssertFalse(MarkdownStructureGuard.verify(original: "# A", revised: "## A"))
        XCTAssertTrue(MarkdownStructureGuard.verify(original: "# A", revised: "# B"))
        XCTAssertFalse(MarkdownStructureGuard.verify(original: "a\nb", revised: "a\r\nb"))
        XCTAssertFalse(MarkdownStructureGuard.verify(original: "\u{FEFF}a", revised: "a"))
        XCTAssertFalse(MarkdownStructureGuard.verify(original: "x **y** z", revised: "x y z"))
    }

    // MARK: - Adversarial

    func testEmojiAndCombiningMarksStayOnComposedBoundaries() {
        let text = "Hi 👋🏽 **bo\u{301}ld**\u{301} e\u{301}nd 👨‍👩‍👧"
        let ns = text as NSString
        assertSegmentsAreExact(text)
        for segment in segments(text) {
            let composed = ns.rangeOfComposedCharacterSequences(for: segment.range)
            XCTAssertEqual(composed, segment.range, segment.text)
        }
        // A selection that splits an emoji is widened, never cut.
        let emoji = ns.range(of: "👋🏽")
        let split = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: emoji.location + 1, length: 1))
        XCTAssertEqual(split.map(\.text), ["👋🏽"])
    }

    func testPartialSelectionIsClippedToTheSelection() {
        let text = "Alpha beta gamma\n## Delta epsilon"
        let ns = text as NSString
        let selection = NSRange(location: ns.range(of: "beta").location, length: ns.range(of: "Delta").location + 5 - ns.range(of: "beta").location)
        XCTAssertEqual(MarkdownStructureMap.proseSegments(in: text, selection: selection).map(\.text), ["beta gamma", "Delta"])
    }

    func testFakeAIThatRewritesEverythingLeavesStructureByteForByte() {
        let text = """
        \u{FEFF}---\r
        title: Keep\r
        ---\r
        # Heading with *em*\r
        Para [link text](https://e.org/a_(b) "Title") and `code` and $x^2$.\r
        \r
        - [ ] Task one\r
          - Nested two\r
        > [!NOTE] Callout title\r
        > Callout body\r
        \r
        | Col A | Col \\| B |\r
        |:--|--:|\r
        | cell 1 | cell 2 |\r
        \r
        ```python\r
        print("\\\\d")\r
        ```\r
        Setext\r
        ---\r
        Hard break  \r
        Footnote[^n] and <span>html</span>\r
        [^n]: Note text\r
        """
        let all = segments(text)
        XCTAssertFalse(all.isEmpty)
        // A hostile fake: every other revision tries to inject structure, the rest are prose.
        let hostile = ["**bold**", "~~gone~~", "`code`", "x[^1]", "\\*", "[x](y)", "$m$", "line\nbreak", "<i>x</i>"]
        let revisions = all.enumerated().map { index, segment in
            index.isMultiple(of: 2) ? hostile[(index / 2) % hostile.count] : segment.text.uppercased() + " ok"
        }
        let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: all, in: text)
        XCTAssertEqual(admitted.count, all.count)
        for (index, value) in admitted.enumerated() where index.isMultiple(of: 2) {
            XCTAssertNil(value, "hostile revision \(revisions[index]) admitted for \(all[index].text)")
        }
        let revised = applying(admitted, to: all, in: text)
        XCTAssertNotEqual(revised, text)
        XCTAssertTrue(MarkdownStructureGuard.verify(original: text, revised: revised))
        let ns = text as NSString
        XCTAssertEqual(
            MarkdownStructureMap.signature(of: ns, scope: NSRange(location: 0, length: ns.length)),
            MarkdownStructureMap.signature(of: revised as NSString, scope: NSRange(location: 0, length: (revised as NSString).length))
        )
        XCTAssertTrue(revised.hasPrefix("\u{FEFF}---\r\ntitle: Keep\r\n---\r\n"))
        XCTAssertTrue(revised.contains("print(\"\\\\d\")"))
    }

    func testSeveralRevisionsInOneBlockAreJudgedTogether() {
        let text = "Alpha *beta* gamma"
        let all = segments(text)
        XCTAssertEqual(all.map(\.text), ["Alpha", "beta", "gamma"])
        // Each alone is prose; together they would still be prose.
        let admitted = MarkdownStructureGuard.admissibleRevisions(["One", "two", "three"], for: all, in: text)
        XCTAssertEqual(admitted, ["One", "two", "three"])
        XCTAssertEqual(applying(admitted, to: all, in: text), "One *two* three")
        // "a _x" + "y_ b" would form an italic span only when both land.
        let pair = "First **bold** second"
        let pairSegments = segments(pair)
        // Each half carries an `_` the original did not, so each is refused on its own.
        let joint = MarkdownStructureGuard.admissibleRevisions(["a _x", "mid", "y_ b"], for: pairSegments, in: pair)
        XCTAssertEqual(joint, [nil, "mid", nil])
    }

    func testProseAfterACodeBlockWithBlankLinesIsStillEditable() {
        let text = "```\ncode\n\nmore code\n```\nProse right after"
        XCTAssertEqual(admit("Prose edited after", replacing: "Prose right after", in: text), "Prose edited after")
        // Even a fence-opening revision on that line is refused.
        XCTAssertEqual(admit("```", replacing: "Prose right after", in: text), .some(nil))
    }

    func testStaleSegmentsAreRefused() {
        let text = "Hello world"
        let stale = ProseSegment(range: NSRange(location: 0, length: 5), text: "Jello")
        XCTAssertEqual(MarkdownStructureGuard.admissibleRevisions(["Yellow"], for: [stale], in: text), [nil])
        let outOfBounds = ProseSegment(range: NSRange(location: 8, length: 10), text: "rld")
        XCTAssertEqual(MarkdownStructureGuard.admissibleRevisions(["x"], for: [outOfBounds], in: text), [nil])
        // Missing revisions are nil; extras are ignored.
        let all = segments(text)
        XCTAssertEqual(MarkdownStructureGuard.admissibleRevisions([], for: all, in: text), [nil])
    }

    /// The guard analyses each block in its own window, so 400 revisions on a large document do
    /// not re-derive the whole document 400 times. Correctness, not a wall-clock ceiling.
    func testGuardOnALargeDocumentAdmitsEveryProseRevision() {
        var parts: [String] = []
        for index in 0..<2_000 {
            parts.append(index.isMultiple(of: 7) ? "```\ncode \(index)\n\nmore\n```\nAfter code \(index)" : "Paragraph **\(index)** with [link](u\(index)) text.")
        }
        let text = parts.joined(separator: "\n\n")
        let all = Array(segments(text).prefix(400))
        XCTAssertEqual(all.count, 400)
        let revisions = all.map { $0.text + " edited" }
        let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: all, in: text)
        XCTAssertEqual(admitted, revisions.map { Optional($0) })
        XCTAssertTrue(MarkdownStructureGuard.verify(original: text, revised: applying(admitted, to: all, in: text)))
    }

    // MARK: - Review round 1

    func testEmphasisCannotBeRePairedOrRemoved() {
        XCTAssertEqual(admit("*very*", replacing: "very", in: "This is **very** good"), .some(nil))
        XCTAssertEqual(admit("a*", replacing: "a", in: "a *b* c"), .some(nil))
        XCTAssertEqual(admit("b_", replacing: "b", in: "a _b_ c"), .some(nil))
        // A triple run is never split into a lone prose `*`.
        XCTAssertEqual(texts("***bold italic*** end"), ["bold italic", "end"])
        XCTAssertEqual(texts("x ~~~y~~~ z *a*** b"), ["x", "y", "z", "a", "b"])
        // `___x___` is not emphasis to Lineform (no `__bold__`, no intraword `_`): it renders
        // literally, so it is prose — and the punctuation rule still keeps every `_` in place.
        XCTAssertEqual(texts("___x___ and"), ["___x___ and"])
        XCTAssertEqual(admit("x and", replacing: "___x___ and", in: "___x___ and"), .some(nil))
        // Prose punctuation must survive in order, but prose around it may change.
        XCTAssertEqual(admit("It is #1 and $5", replacing: "It was #1 and $5", in: "It was #1 and $5\n"), "It is #1 and $5")
        XCTAssertEqual(admit("It was 1 and $5", replacing: "It was #1 and $5", in: "It was #1 and $5\n"), .some(nil))
    }

    func testSingleTildeDoubleBacktickAndAllEscapesAreStructure() {
        XCTAssertEqual(texts("a ~gone~ b"), ["a", "gone", "b"])
        XCTAssertEqual(texts("``x`` y"), ["y"])
        XCTAssertEqual(texts("a \\- b \\# c"), ["a", "b", "c"])
    }

    func testMultiLineHTMLIsStructure() {
        XCTAssertEqual(texts("Intro\n<!--\nhidden note\n-->\nAfter"), ["Intro", "After"])
        XCTAssertEqual(texts("Intro\n\n<!-- never closed\nstill hidden\n\nhidden too"), ["Intro"])
        XCTAssertEqual(texts("<img src=\"a.png\"\n width=\"3\"> tail\n\nNext"), ["tail", "Next"])
        // An opener inside code opens nothing.
        XCTAssertEqual(texts("Use `<!--` here\n\nLater"), ["Use", "here", "Later"])
        let comment = "Intro\n<!--\nhidden note\n-->\nAfter"
        XCTAssertNil(segments(comment).first { $0.text.contains("<!--") || $0.text.contains("-->") })
    }

    func testReferenceLinksAreStructure() {
        let text = "[docs][ref] and [ref] here\n\n[ref]: https://e.org \"Title\""
        XCTAssertEqual(texts(text), ["docs", "and", "here"])
        XCTAssertEqual(texts("[Docs][] ok\n\n[docs]: u"), ["ok"])
        XCTAssertEqual(texts("![alt][img] x\n\n[img]: a.png"), ["x"])
        // An undefined `[maybe]` is just bracketed prose — but its brackets cannot be changed.
        XCTAssertEqual(texts("[maybe] x"), ["[maybe] x"])
        XCTAssertEqual(admit("(maybe) x", replacing: "[maybe] x", in: "[maybe] x"), .some(nil))
        // Footnote definitions keep their text as prose.
        XCTAssertEqual(texts("[^1]: The note."), ["The note."])
    }

    func testEmailsAndBareURLsAreStructure() {
        XCTAssertEqual(texts("Mail <me@mail.com> or me@mail.com now"), ["Mail", "or", "now"])
        XCTAssertEqual(texts("See https://e.org/a?b=c. And www.x.org, ok"), ["See", ". And", ", ok"])
        XCTAssertEqual(texts("(see https://e.org/a)"), ["(see", ")"])
    }

    func testFormatCharactersAreNeverIntroduced() {
        let text = "Hello world\n"
        XCTAssertEqual(admit("Hello\u{200B} world", replacing: "Hello world", in: text), .some(nil))
        XCTAssertEqual(admit("Hello \u{202E}world", replacing: "Hello world", in: text), .some(nil))
        // One the original already carried may stay.
        XCTAssertEqual(admit("Hi\u{200B}there", replacing: "Hello\u{200B}world", in: "Hello\u{200B}world"), "Hi\u{200B}there")
    }

    func testControlAndSeparatorCharactersInsideALineAreNeverSent() {
        // A U+2028 pasted from InDesign, and a tab: both would make any revision inadmissible,
        // so they are structure and stay in the document.
        XCTAssertEqual(texts("one\u{2028}two\tthree"), ["one", "two", "three"])
    }
}
