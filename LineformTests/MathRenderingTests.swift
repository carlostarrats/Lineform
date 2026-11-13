import XCTest
import AppKit
@testable import Lineform

final class MathRenderingTests: XCTestCase {
    // MARK: - Block fence

    func testBlockDelimiterOpening() {
        XCTAssertEqual(MathBlockFence.opening("$$"), .dollars)
        XCTAssertEqual(MathBlockFence.opening("  $$  "), .dollars)
        XCTAssertNil(MathBlockFence.opening("$"))
        XCTAssertNil(MathBlockFence.opening("$$x"))
        XCTAssertEqual(MathBlockFence.opening("\\["), .brackets)
        XCTAssertEqual(MathBlockFence.opening("  \\[ "), .brackets)
        XCTAssertNil(MathBlockFence.opening("\\]"), "only `\\[` opens a bracket block")
        XCTAssertNil(MathBlockFence.opening("\\[x"))
    }

    func testBlockClosingMatchesItsOwnOpenerOnly() {
        XCTAssertTrue(MathBlockFence.isClosing("$$", of: .dollars))
        XCTAssertTrue(MathBlockFence.isClosing(" \\] ", of: .brackets))
        XCTAssertFalse(MathBlockFence.isClosing("\\]", of: .dollars))
        XCTAssertFalse(MathBlockFence.isClosing("$$", of: .brackets))
        XCTAssertFalse(MathBlockFence.isClosing("\\[", of: .brackets))
    }

    func testSingleLineBlock() {
        XCTAssertEqual(MathBlockFence.singleLineBlock("$$x^2$$"), "x^2")
        XCTAssertEqual(MathBlockFence.singleLineBlock("$$ E=mc^2 $$"), " E=mc^2 ")
        XCTAssertNil(MathBlockFence.singleLineBlock("$$"))
        XCTAssertNil(MathBlockFence.singleLineBlock("$x$"))
        // Two display spans with prose between must NOT be treated as one block (would swallow "and").
        XCTAssertNil(MathBlockFence.singleLineBlock("$$a$$ and $$b$$"))
    }

    // MARK: - Inline delimiter rules

    private func mathValues(_ line: String) -> [String] {
        MathDelimiters.inlineSpans(in: line).map(\.latex)
    }
    private func styles(_ line: String) -> [MathStyle] {
        MathDelimiters.inlineSpans(in: line).map(\.style)
    }

    func testSimpleInlineMath() {
        XCTAssertEqual(mathValues("the value $x^2$ here"), ["x^2"])
    }
    func testDigitLeadingMathRenders() {
        // The opener may precede a digit; only the closing side guards against prose.
        XCTAssertEqual(mathValues("the value $2\\pi r$ here"), ["2\\pi r"])
        XCTAssertEqual(mathValues("so $1+1=2$ holds"), ["1+1=2"])
    }
    func testProseDigitDollarsAreLiteral() {
        XCTAssertEqual(mathValues("it costs $5 to $10 today"), [])
        XCTAssertEqual(mathValues("$5+$6 total"), [])            // closer followed by digit → literal
    }
    func testOpeningDollarFollowedBySpaceIsProse() {
        XCTAssertEqual(mathValues("give me $ 5 and $ 6"), [])
    }
    func testClosingDollarPrecededBySpaceIsProse() {
        // Whitespace immediately before the closing `$` disqualifies it (internal spaces are fine).
        XCTAssertEqual(mathValues("a $x^2 $ b"), [])
    }
    func testInternalSpacesAreAllowedInMath() {
        XCTAssertEqual(mathValues("a $x + y$ b"), ["x + y"])
    }
    func testEscapedDollarIsLiteral() {
        XCTAssertEqual(mathValues(#"a \$5 and \$6 b"#), [])
    }
    func testUnbalancedDollarStaysLiteral() {
        XCTAssertEqual(mathValues("a single $ here"), [])
    }
    func testTwoInlineExpressions() {
        XCTAssertEqual(mathValues("$a+b$ and $c-d$"), ["a+b", "c-d"])
    }
    func testMidLineDisplayMathIsOneSpan() {
        // `$$…$$` embedded in prose is a single display span — no stray `$` left over.
        XCTAssertEqual(mathValues("the famous $$E=mc^2$$ equation"), ["E=mc^2"])
        XCTAssertEqual(styles("the famous $$E=mc^2$$ equation"), [.display])
    }
    func testInlineSpanRangeCoversDelimiters() {
        let spans = MathDelimiters.inlineSpans(in: "ab $x$ cd")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.range, NSRange(location: 3, length: 3))   // "$x$"
    }

    // MARK: - Provider policy / cache

    func testMathSizeGuardBoundary() {
        XCTAssertTrue(MathBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_000)))
        XCTAssertFalse(MathBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_001)))
    }
    func testMathCacheKeyStableAndDistinct() {
        let a = MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2, pointSize: 18)
        XCTAssertEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2, pointSize: 18))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^3", style: .inline, foregroundHex: "#ffffff", scale: 2, pointSize: 18))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .display, foregroundHex: "#ffffff", scale: 2, pointSize: 18))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#000000", scale: 2, pointSize: 18))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 1, pointSize: 18))
        // Regression: a different reader font size must not collide (image is rendered at pointSize).
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2, pointSize: 24))
    }
    func testDisabledProviderSkips() {
        let outcome = DisabledMathImageProvider().outcome(latex: "x^2", style: .inline, foreground: .white, pointSize: 18, scale: 2)
        if case .skipped = outcome {} else { XCTFail("disabled provider must skip") }
    }

    // MARK: - Live SwiftMath smoke tests

    func testLiveProviderRendersNonEmptyImage() {
        let outcome = MathImageProvider().outcome(latex: "x^2+y^2", style: .display, foreground: .black, pointSize: 18, scale: 2)
        guard case .image(let image, _) = outcome else { return XCTFail("expected an image, got \(outcome)") }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
    func testLiveProviderReportsDescentForInlineMath() {
        // A fraction has real depth below the baseline, so descent must be positive.
        let outcome = MathImageProvider().outcome(latex: "\\frac{a}{b}", style: .inline, foreground: .black, pointSize: 18, scale: 2)
        guard case .image(_, let descent) = outcome else { return XCTFail("expected an image") }
        XCTAssertGreaterThan(descent, 0)
    }
    func testLiveProviderFailsOnGarbageLaTeX() {
        let outcome = MathImageProvider().outcome(latex: "\\frac{", style: .inline, foreground: .black, pointSize: 18, scale: 2)
        if case .failed = outcome {} else { XCTFail("malformed LaTeX must fail → fallback") }
    }
}

// MARK: - Backslash delimiters `\(…\)` / `\[…\]`

/// The backslash math delimiters, and — load-bearing — that every implementation of "what is
/// math" agrees on them. Each consumer below has its own copy of the inline walk (screen/PDF/print,
/// HTML export, read-aloud, Convert to Plain Text, Writing Tools / spell check, the Quick Look
/// appex), and in this repo every paired definition has eventually disagreed; this asserts it.
@MainActor
final class BackslashMathDelimiterTests: XCTestCase {
    // MARK: Detector + the explicit prose rule

    private func latex(_ line: String) -> [String] { MathDelimiters.inlineSpans(in: line).map(\.latex) }

    func testInlineParenSpans() {
        XCTAssertEqual(latex(#"where \( x \) is the radius"#), [" x "])
        XCTAssertEqual(latex(#"Area: \(\pi r^2\)."#), [#"\pi r^2"#])
        XCTAssertEqual(MathDelimiters.inlineSpans(in: #"\(x\)"#).first?.style, .inline)
        XCTAssertEqual(MathDelimiters.inlineSpans(in: #"\(x\)"#).first?.range, NSRange(location: 0, length: 5))
    }

    func testBracketSpansAreDisplayStyle() {
        let spans = MathDelimiters.inlineSpans(in: #"so \[ a^2 + b^2 = c^2 \] holds"#)
        XCTAssertEqual(spans.map(\.latex), [" a^2 + b^2 = c^2 "])
        XCTAssertEqual(spans.first?.style, .display)
    }

    func testProseRule() {
        // Math: a LaTeX signal, or no word of 3+ letters.
        for content in ["x", " x ", "f(x)", "2n + 1", #"\alpha"#, "a_1", "x^2", "{a}", "a = b", "ab", "i, j"] {
            XCTAssertTrue(MathDelimiters.backslashContentIsMath(Array(content)), content)
        }
        // Prose: a word of 3+ letters and no signal, or empty.
        for content in ["note", "see figure 2", "not a link", "max(a, b)", "", "   ", "café", "日本語"] {
            XCTAssertFalse(MathDelimiters.backslashContentIsMath(Array(content)), content)
        }
    }

    func testEscapedParenProseIsNotMath() {
        XCTAssertEqual(latex(#"see \(note\) for more"#), [])
        XCTAssertEqual(latex(#"\[not a link\](x)"#), [])
        XCTAssertEqual(latex(#"\(\)"#), [], "empty content is never math")
    }

    func testEscapedBackslashIsNotAnOpenerOrCloser() {
        XCTAssertEqual(latex(#"a path C:\\(x\) here"#), [], #"`\\` is an escaped backslash, then a bare `(`"#)
        XCTAssertEqual(latex(#"\(a\\)b\)"#), [#"a\\)b"#], #"`\\)` inside is an escaped backslash, not the closer"#)
    }

    func testUnclosedOpenersAreNotMath() {
        XCTAssertEqual(latex(#"open \(x and never closed"#), [])
        XCTAssertEqual(latex(#"\(x\] mismatched"#), [])
        // Memoized: a line of unclosed openers is linear, not quadratic (no timing — just completes).
        XCTAssertEqual(latex(String(repeating: #"\("#, count: 20_000)), [])
    }

    func testMixedWithDollarMath() {
        XCTAssertEqual(latex(#"mixed $a$ and \(b\) and $$c$$ and \[d\]"#), ["a", "b", "c", "d"])
        XCTAssertEqual(latex(#"$\(x\)$"#), [#"\(x\)"#], "inside `$…$` the backslash pair is escaped content")
    }

    // MARK: Blocks

    func testSingleLineBracketBlock() {
        XCTAssertEqual(MathBlockFence.singleLineBlock(#"\[ x^2 \]"#), " x^2 ")
        XCTAssertEqual(MathBlockFence.singleLineBlock(#"  \[x\]  "#), "x")
        XCTAssertNil(MathBlockFence.singleLineBlock(#"\[note\]"#), "prose rule applies to one-line blocks")
        XCTAssertNil(MathBlockFence.singleLineBlock(#"\[a\] and \[b\]"#), "two spans are not one block")
        XCTAssertNil(MathBlockFence.singleLineBlock(#"\[x\] tail"#))
    }

    func testFencedBracketBlockGroupsAsMathEvenWithProse() {
        let blocks = markdownBlocks(in: ["before", #"\["#, "area equals width", #"\]"#, "after"])
        let math = blocks.compactMap { block -> String? in
            if case let .fencedMath(latex, closing) = block, closing == 3 { return latex }
            return nil
        }
        XCTAssertEqual(math, ["area equals width"], "a delimiter alone on its line is unambiguous")
    }

    func testBlockDelimitersOnlyCloseTheirOwnKind() {
        let lines = ["$$", "x", #"\]"#, "# inside", "$$", "# after"]
        let blocks = markdownBlocks(in: lines)
        guard case let .fencedMath(latex, closing) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(closing, 4)
        XCTAssertEqual(latex, "x\n\\]\n# inside")
        let outline = MarkdownOutlineParser().items(in: lines.joined(separator: "\n")).map(\.title)
        XCTAssertEqual(outline, ["after"], "outline must agree with the renderer's block state")
    }

    func testOutlineSkipsHeadingsInsideBracketBlock() {
        let text = "\\[\n# not a heading\n```\n\\]\n# Real"
        XCTAssertEqual(MarkdownOutlineParser().items(in: text).map(\.title), ["Real"])
    }

    // MARK: Cross-implementation agreement

    /// (line, expected LaTeX of each math span). No code spans here — precedence against code is
    /// its own test below.
    private let corpus: [(line: String, latex: [String])] = [
        (#"where \( x \) is the radius"#, [" x "]),
        (#"Area: \(\pi r^2\)."#, [#"\pi r^2"#]),
        (#"\[ \int_0^1 f(x)\,dx \]"#, [#" \int_0^1 f(x)\,dx "#]),
        (#"so \[ a^2 + b^2 = c^2 \] holds"#, [" a^2 + b^2 = c^2 "]),
        (#"see \(note\) for more"#, []),
        (#"\[not a link\](x)"#, []),
        (#"a path C:\\(x\) here"#, []),
        (#"mixed $a$ and \(b\)"#, ["a", "b"]),
        (#"\(a*b*c\) and \(x_1 + y_1\)"#, ["a*b*c", "x_1 + y_1"]),
        (#"costs $5 and \(n\) items"#, ["n"]),
    ]

    private final class CountingMathProvider: MathImageProviding {
        private(set) var latex: [String] = []
        func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
            self.latex.append(latex)
            return .image(NSImage(size: NSSize(width: 10, height: 8)), descent: 2)
        }
    }

    private func renderPreview(_ text: String, provider: MathImageProviding) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text, profile: .original, columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(), mathProvider: provider,
            diagramLog: NullDiagramFailureLog(), appVersion: "1.0"
        )
    }

    func testDetectorMatchesCorpus() {
        for entry in corpus {
            XCTAssertEqual(latex(entry.line), entry.latex, entry.line)
        }
    }

    /// Read, Split, Styled PDF and Print all draw through `MarkdownPreviewRenderer`.
    func testPreviewRendererRendersExactlyTheDetectedSpans() {
        for entry in corpus {
            let provider = CountingMathProvider()
            let rendered = renderPreview(entry.line, provider: provider).string
            XCTAssertEqual(provider.latex, entry.latex, entry.line)
            if entry.latex.isEmpty, !entry.line.contains(#"\\"#) {
                XCTAssertFalse(rendered.contains(#"\("#) || rendered.contains(#"\["#),
                               "declined spans render as the escaped text: \(rendered)")
            }
        }
        XCTAssertTrue(renderPreview(#"see \(note\) for more"#, provider: CountingMathProvider()).string
            .contains("see (note) for more"))
    }

    func testHTMLExportEmbedsExactlyTheDetectedSpans() {
        for entry in corpus {
            var requested: [String] = []
            let html = MarkdownHTMLRenderer.body(for: entry.line) { image in
                if case let .math(latex) = image { requested.append(latex) }
                return Data([0x89])
            }
            XCTAssertEqual(requested, entry.latex, entry.line)
            XCTAssertEqual(html.components(separatedBy: "<img").count - 1, entry.latex.count, html)
        }
        let prose = MarkdownHTMLRenderer.body(for: #"see \(note\) for more"#) { _ in nil }
        XCTAssertTrue(prose.contains("see (note) for more"), prose)
    }

    func testWritingToolsAndSpellCheckProtectExactlyTheDetectedSpans() {
        for entry in corpus {
            let ns = entry.line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let spans = MathDelimiters.inlineSpans(in: entry.line).map(\.range)
            XCTAssertEqual(MarkdownWritingToolsProtection.ignoredRanges(in: entry.line, enclosingRange: full), spans, entry.line)
            XCTAssertEqual(MarkdownWritingToolsProtection.protectedRanges(in: ns, intersecting: full), spans, entry.line)
            let checkable = MarkdownSpellCheckRegions.checkableRanges(in: ns, enclosing: full)
            for span in spans {
                XCTAssertFalse(checkable.contains { NSIntersectionRange($0, span).length > 0 }, "spell-checked math in \(entry.line)")
            }
        }
        let prose = #"see \(nnote\) here"# as NSString
        let checkable = MarkdownSpellCheckRegions.checkableRanges(in: prose, enclosing: NSRange(location: 0, length: prose.length))
        XCTAssertEqual(checkable, [NSRange(location: 0, length: prose.length)], "escaped prose is still spell-checked")
    }

    func testScopedProtectionMatchesWholeDocumentWithBracketBlocks() {
        let text = "intro \\(x\\) here\n\\[\na = b\n$$\n\\]\nsee \\(note\\)\n$$\nc\n\\]\nd\n$$\ntail \\[y^2\\]\n\\[\nunclosed" as NSString
        let full = NSRange(location: 0, length: text.length)
        let whole = MarkdownWritingToolsProtection.ignoredRanges(in: text as String, enclosingRange: full)
        var scope = NSRange(location: 0, length: 0)
        while scope.location < text.length {
            scope = text.lineRange(for: NSRange(location: scope.location, length: 0))
            let scoped = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
            let expected = whole.map { NSIntersectionRange($0, scope) }.filter { $0.length > 0 }
            XCTAssertEqual(merged(scoped), merged(expected), "diverged at \(NSStringFromRange(scope))")
            scope.location = NSMaxRange(scope)
        }
        // The `\]` inside the `$$` block must not close it, and the `$$` inside `\[` must not either.
        let blockStart = (text as NSString).range(of: "\\[\na = b").location
        let blockEnd = NSMaxRange((text as NSString).range(of: "$$\n\\]\n")) // line 5 `\]` closes it
        XCTAssertTrue(whole.contains { $0.location == blockStart && NSMaxRange($0) == blockEnd }, "\(whole)")
    }

    func testReadAloudSkipsTheDetectedSpans() {
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: #"where \( x \) is the radius"#), "where  is the radius")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: #"mixed $a$ and \(b\)"#), "mixed  and")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: #"see \(note\) for more"#), "see (note) for more")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "Intro.\n\\[\nx^2\n\\]\nOutro."), "Intro.\nOutro.")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "Intro.\n\\[ x^2 \\]\nOutro."), "Intro.\nOutro.")
        for entry in corpus {
            let spoken = SpeechTextExtractor.spokenText(from: entry.line)
            for latex in entry.latex where latex.count > 1 {
                XCTAssertFalse(spoken.contains(latex), "spoke LaTeX \(latex): \(spoken)")
            }
        }
    }

    func testConvertToPlainTextLeavesMathVerbatim() {
        for entry in corpus {
            let converted = MarkdownPlainTextConverter.plainText(from: entry.line)
            for span in MathDelimiters.inlineSpans(in: entry.line) {
                XCTAssertTrue(converted.contains((entry.line as NSString).substring(with: span.range)), "\(entry.line) → \(converted)")
            }
        }
        XCTAssertEqual(MarkdownPlainTextConverter.plainText(from: #"see \(note\) for **more**"#), "see (note) for more")
        let block = "\\[\na*b*c \\\\ d\n```\n\\]\n**after**"
        XCTAssertEqual(MarkdownPlainTextConverter.plainText(from: block), "\\[\na*b*c \\\\ d\n```\n\\]\nafter",
                       "display math is LaTeX source — no strips, no unescape, no fence handling inside")
    }

    func testCodeSpanBeatsMathEverywhere() {
        let line = #"run `\(x\)` literally"#
        let provider = CountingMathProvider()
        XCTAssertTrue(renderPreview(line, provider: provider).string.contains(#"\(x\)"#))
        XCTAssertEqual(provider.latex, [])
        var requested = 0
        let html = MarkdownHTMLRenderer.body(for: line) { _ in requested += 1; return Data([0]) }
        XCTAssertEqual(requested, 0)
        XCTAssertTrue(html.contains(#"<code>\(x\)</code>"#), html)
        XCTAssertEqual(MarkdownPlainTextConverter.plainText(from: line), #"run \(x\) literally"#)
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: line), #"run \(x\) literally"#)
    }

    func testEditorHighlighterDoesNotColorMathAsLinkOrCode() {
        for entry in corpus {
            let spans = MathDelimiters.inlineSpans(in: entry.line).map(\.range)
            let tokens = MarkdownRangeAnalyzer().ranges(in: entry.line)
            for token in tokens where [.codeSpan, .linkText, .linkDestination].contains(token.kind) {
                XCTAssertFalse(spans.contains { NSIntersectionRange($0, token.range).length > 0 }, "\(entry.line): \(token)")
            }
        }
    }

    // MARK: Quick Look appex hand-mirror

    private func appSpans(_ line: String) -> [QuickLookMarkdownRenderer.MathRange] {
        MathDelimiters.inlineSpans(in: line).map { .init(range: $0.range, isDisplay: $0.style == .display) }
    }

    func testAppexMirrorAgreesOnCorpus() {
        let extra = [#"costs $5 to $10"#, #"$$x$$ and $$y$$"#, #"$x$ \$y$ $$z$$"#, #"$ x$ and $x $"#, "$$", "$$$$"]
        for line in corpus.map(\.line) + extra {
            XCTAssertEqual(QuickLookMarkdownRenderer.mathRanges(in: line), appSpans(line), line)
        }
    }

    /// Seeded fuzz over every character the two detectors branch on, `$` included.
    func testAppexMirrorAgreesUnderFuzz() {
        let alphabet = ["\\", "\\", "$", "$", "(", ")", "[", "]", "x", "note", " ", "^", "5", "é", "👍🏽", "ab"]
        var state: UInt64 = 0x2026_1112
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33)
        }
        for _ in 0..<5000 {
            let line = (0..<(next() % 24)).map { _ in alphabet[next() % alphabet.count] }.joined()
            XCTAssertEqual(QuickLookMarkdownRenderer.mathRanges(in: line), appSpans(line), line)
            XCTAssertEqual(QuickLookMarkdownRenderer.isSingleLineMathBlock(line.trimmingCharacters(in: .whitespaces)),
                           MathBlockFence.singleLineBlock(line) != nil, line)
        }
    }

    func testAppexShowsMathSourceVerbatimAndUnescapesProse() {
        let plain = QuickLookMarkdownRenderer.render("where \\(a*b*c\\) and \\(note\\)\n\n\\[\nx_1 *y*\n\\]\n\ntail").string
        XCTAssertTrue(plain.contains(#"where \(a*b*c\) and (note)"#), plain)
        XCTAssertTrue(plain.contains("\\[\nx_1 *y*\n\\]"), plain)
        XCTAssertTrue(plain.contains("tail"), plain)
    }

    func testAppexShowsDollarMathVerbatim() {
        let plain = QuickLookMarkdownRenderer.render("so $a*b*c$ and $x_1$ cost $5\n\n$$\nE = *mc*^2\n```\n$$\n# After").string
        XCTAssertTrue(plain.contains("so $a*b*c$ and $x_1$ cost $5"), "no emphasis inside `$…$`: \(plain)")
        XCTAssertTrue(plain.contains("$$\nE = *mc*^2\n```\n$$"), "a `$$` block stays its own lines, fence inside is body: \(plain)")
        XCTAssertTrue(plain.contains("After"), plain)
    }

    func testAppexBlockDelimitersOnlyCloseTheirOwnKind() {
        let plain = QuickLookMarkdownRenderer.render("$$\nx\n\\]\n**still math**\n$$\n**bold**").string
        XCTAssertTrue(plain.contains("\\]\n**still math**\n$$"), plain)
        XCTAssertTrue(plain.contains("bold") && !plain.contains("**bold**"), plain)
    }

    func testAppexSingleLineDisplayMathIsItsOwnBlock() {
        let plain = QuickLookMarkdownRenderer.render("intro line\n$$a*b*c$$\noutro line").string
        XCTAssertTrue(plain.contains("intro line\n$$a*b*c$$\noutro line"), "not merged into the paragraph: \(plain)")
    }

    func testAppexInlinePassIsLineLocalLikeTheApp() {
        let plain = QuickLookMarkdownRenderer.render("a $x\ny$ b and **one\ntwo**").string
        XCTAssertTrue(plain.contains("a $x y$ b and **one two**"), "a span split across lines stays literal: \(plain)")
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = out.last, r.location <= NSMaxRange(last) { out[out.count - 1] = NSUnionRange(last, r) } else { out.append(r) }
        }
        return out
    }
}
