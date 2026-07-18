import AppKit
import XCTest
@testable import Lineform

final class MarkdownPreviewRendererTests: XCTestCase {
    func testRendersMarkdownToNativeAttributedString() {
        let rendered = MarkdownPreviewRenderer().render("# Heading\n\nParagraph", profile: .original)

        XCTAssertEqual(rendered.string, "Heading\n\nParagraph")
        XCTAssertGreaterThan(rendered.length, 0)
    }

    func testHeadingUsesLargerFontThanBody() throws {
        let rendered = MarkdownPreviewRenderer().render("# Heading\n\nBody", profile: .original)
        let headingFont = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? NSFont)

        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize)
    }

    func testHeadingLevelsUseDistinctVisualHierarchy() throws {
        let rendered = MarkdownPreviewRenderer().render("# Top\n## Section\nBody", profile: .original)
        let h1Font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let h2Font = try XCTUnwrap(rendered.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? NSFont)

        XCTAssertGreaterThanOrEqual(h1Font.pointSize - h2Font.pointSize, 7)
        XCTAssertGreaterThanOrEqual(h2Font.pointSize - bodyFont.pointSize, 2)
    }

    func testRendererUsesReadingProfileColors() throws {
        let profile = ReadingPreset.lowLight.profile
        let rendered = MarkdownPreviewRenderer().render("Body", profile: profile)
        let color = try XCTUnwrap(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

        XCTAssertEqual(color, Theme.night.textColor)
    }

    func testDoesNotTreatHeadingsInsideFencedCodeAsHeadings() {
        // Fence delimiter lines are no longer emitted (Task 4: fenced code is its own
        // `.fencedCode` block, consumed before any inner line is inspected for headings).
        let rendered = MarkdownPreviewRenderer().render("# Real\n```\n# Not a heading\n```", profile: .original)

        XCTAssertEqual(rendered.string, "Real\n# Not a heading")
    }

    func testPreviewUsesSharedHeadingRules() {
        let rendered = MarkdownPreviewRenderer().render("### Detail ###\n####### Not a heading", profile: .original)

        XCTAssertEqual(rendered.string, "Detail\n####### Not a heading")
    }

    func testReadModeHidesCommonInlineMarkdownMarkers() {
        let rendered = MarkdownPreviewRenderer().render(
            "This is **bold**, _clear_, `code`, and [a link](https://example.com).",
            profile: .original
        )

        XCTAssertEqual(rendered.string, "This is bold, clear, code, and a link.")
    }

    func testReadModeRendersStrikethroughAndHidesMarkers() throws {
        let rendered = MarkdownPreviewRenderer().render("done ~~old~~ text", profile: .original)
        XCTAssertEqual(rendered.string, "done old text")
        let style = rendered.attribute(.strikethroughStyle, at: ("done " as NSString).length, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
    }

    func testStrikethroughInsideCodeSpanStaysLiteral() {
        // A code span starts earlier, so `~~x~~` inside it must not be struck.
        let rendered = MarkdownPreviewRenderer().render("`~~x~~`", profile: .original)
        XCTAssertEqual(rendered.string, "~~x~~")
    }

    func testHorizontalRuleRendersAsAttachment() {
        let rendered = MarkdownPreviewRenderer().render("a\n\n---\n\nb", profile: .original)
        var hasRule = false
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value is HorizontalRuleAttachment { hasRule = true }
        }
        XCTAssertTrue(hasRule)
    }

    func testDashesUnderParagraphAreNotRenderedAsRule() {
        let rendered = MarkdownPreviewRenderer().render("paragraph\n---\nmore", profile: .original)
        var hasRule = false
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value is HorizontalRuleAttachment { hasRule = true }
        }
        XCTAssertFalse(hasRule)
    }

    func testBlockquoteIndentsAndHidesMarker() throws {
        let rendered = MarkdownPreviewRenderer().render("> quoted", profile: .original)
        XCTAssertEqual(rendered.string, "quoted")
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, 0)
        XCTAssertGreaterThan(style.firstLineHeadIndent, 0)
    }

    func testNestedBlockquoteIndentsFurther() throws {
        let shallow = MarkdownPreviewRenderer().render("> one", profile: .original)
        let deep = MarkdownPreviewRenderer().render(">> two", profile: .original)
        let shallowIndent = try XCTUnwrap(shallow.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle).headIndent
        let deepIndent = try XCTUnwrap(deep.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle).headIndent
        XCTAssertGreaterThan(deepIndent, shallowIndent)
    }

    func testCalloutBodyMatchesSharedQuoteRendering() throws {
        // A quote and a callout body over the same lines must render identical body runs. First,
        // the plain-blockquote sanity checks this test used to assert in isolation (kept so the
        // baseline blockquote shape is still covered directly).
        let quote = MarkdownPreviewRenderer().render("> alpha\n> beta", profile: .original)
        XCTAssertEqual(quote.string, "alpha\nbeta")
        let firstStyle = try XCTUnwrap(quote.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(firstStyle.headIndent, 0)
        // De-emphasis: quote body foreground is the theme ink at reduced alpha (not full ink).
        let color = try XCTUnwrap(quote.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertLessThan(color.alphaComponent, 1.0)

        // Now the genuine equivalence assertion: the callout body (everything after the title row)
        // must be attribute-identical to a plain blockquote's body over the same lines — proving the
        // title row was ADDED without disturbing the shared `appendQuoteLines` body rendering.
        let callout = MarkdownPreviewRenderer().render("> [!NOTE]\n> alpha\n> beta", profile: .original)

        let ns = callout.string as NSString
        XCTAssertTrue(callout.string.hasSuffix("alpha\nbeta"))
        let bodyStart = ns.range(of: "alpha\nbeta").location
        XCTAssertNotEqual(bodyStart, NSNotFound)

        let calloutBody = callout.attributedSubstring(from: NSRange(location: bodyStart, length: ns.length - bodyStart))
        XCTAssertEqual(calloutBody.string, quote.string)

        // Compare attributes run-by-run (paragraph style headIndent/firstLineHeadIndent, foreground
        // color, font) at each character offset in the shared body text.
        for offset in 0..<calloutBody.length {
            let calloutStyle = try XCTUnwrap(calloutBody.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
            let quoteStyle = try XCTUnwrap(quote.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(calloutStyle.headIndent, quoteStyle.headIndent)
            XCTAssertEqual(calloutStyle.firstLineHeadIndent, quoteStyle.firstLineHeadIndent)

            let calloutColor = try XCTUnwrap(calloutBody.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
            let quoteColor = try XCTUnwrap(quote.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(calloutColor, quoteColor)

            let calloutFont = try XCTUnwrap(calloutBody.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            let quoteFont = try XCTUnwrap(quote.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(calloutFont, quoteFont)
        }
    }

    func testCalloutRendersDefaultTitleAndBody() throws {
        let rendered = MarkdownPreviewRenderer().render("> [!NOTE]\n> body text", profile: .original)
        // Title row shows the capitalized type name; body follows on its own line.
        XCTAssertTrue(rendered.string.contains("Note"))
        XCTAssertTrue(rendered.string.contains("body text"))
        // A leading SF-Symbol attachment glyph (object-replacement char) precedes the title.
        XCTAssertTrue(rendered.string.contains("\u{FFFC}"))
        let attachment = rendered.attribute(.attachment, at: 0, effectiveRange: nil)
        XCTAssertNotNil(attachment)
    }

    func testCalloutUsesCustomTitleWhenPresent() {
        let rendered = MarkdownPreviewRenderer().render("> [!TIP] Pro move\n> details", profile: .original)
        XCTAssertTrue(rendered.string.contains("Pro move"))
        XCTAssertFalse(rendered.string.contains("Tip")) // custom title replaces the default name
        XCTAssertTrue(rendered.string.contains("details"))
    }

    func testCalloutTitleIsFullInkNotDeemphasized() throws {
        // Title row ink is the theme text color at full alpha (monochrome, not the 0.8 body tint).
        let rendered = MarkdownPreviewRenderer().render("> [!WARNING]\n> body", profile: .original)
        // Find the first title glyph (skip the attachment char at 0 and the following space).
        let ns = rendered.string as NSString
        let titleIndex = ns.range(of: "Warning").location
        XCTAssertNotEqual(titleIndex, NSNotFound)
        let color = try XCTUnwrap(rendered.attribute(.foregroundColor, at: titleIndex, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testCalloutWithNoBodyRendersOnlyTitleRow() {
        let rendered = MarkdownPreviewRenderer().render("> [!CAUTION]", profile: .original)
        XCTAssertTrue(rendered.string.contains("Caution"))
        XCTAssertFalse(rendered.string.contains("\n")) // no body → no separator newline
    }

    func testCalloutBodyIsIndentedLikeBlockquote() throws {
        let rendered = MarkdownPreviewRenderer().render("> [!NOTE]\n> quoted body", profile: .original)
        let ns = rendered.string as NSString
        let bodyIndex = ns.range(of: "quoted body").location
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: bodyIndex, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, 0)
    }

    func testImageRendersQuietPlaceholderWithAltTextAndNoBangOrURL() {
        let rendered = MarkdownPreviewRenderer().render("![a cat](cat.png)", profile: .original).string
        XCTAssertTrue(rendered.contains("a cat"))
        XCTAssertTrue(rendered.contains("🖼"))
        XCTAssertFalse(rendered.contains("!"))
        XCTAssertFalse(rendered.contains("cat.png")) // URL never shown; file never touched
    }

    func testImageWithNoAltUsesFilename() {
        let rendered = MarkdownPreviewRenderer().render("![](photos/mountain.png)", profile: .original).string
        XCTAssertTrue(rendered.contains("🖼"))
        XCTAssertTrue(rendered.contains("mountain.png"))   // filename gives context
        XCTAssertFalse(rendered.contains("photos/"))       // just the filename, not the full path
    }

    func testImageWithNoAltStripsQueryFromFilename() {
        let rendered = MarkdownPreviewRenderer().render("![](https://x.test/img/cat.png?v=2)", profile: .original).string
        XCTAssertTrue(rendered.contains("cat.png"))
        XCTAssertFalse(rendered.contains("v=2"))
    }

    func testImageWithNoAltAndNoUsableFilenameFallsBackToLabel() {
        let rendered = MarkdownPreviewRenderer().render("![](   )", profile: .original).string
        XCTAssertTrue(rendered.contains("🖼"))
        XCTAssertTrue(rendered.contains("Image"))
    }

    func testPlainLinkStillRendersNormally() {
        let rendered = MarkdownPreviewRenderer().render("[a link](https://example.com)", profile: .original).string
        XCTAssertEqual(rendered, "a link")
    }

    func testTaskCheckboxRendersGlyphWithSourceRangeAttribute() throws {
        let rendered = MarkdownPreviewRenderer().render("- [ ] task", profile: .original)
        XCTAssertTrue(rendered.string.contains("☐"))
        XCTAssertTrue(rendered.string.contains("task"))
        XCTAssertFalse(rendered.string.contains("[ ]")) // marker replaced by the glyph
        let glyphIndex = (rendered.string as NSString).range(of: "☐").location
        let value = rendered.attribute(.checkboxSourceRange, at: glyphIndex, effectiveRange: nil) as? NSValue
        XCTAssertEqual(value?.rangeValue, NSRange(location: 2, length: 3))
    }

    func testCheckedTaskRendersFilledGlyph() {
        let rendered = MarkdownPreviewRenderer().render("- [x] done", profile: .original).string
        XCTAssertTrue(rendered.contains("☑"))
        XCTAssertFalse(rendered.contains("[x]"))
    }

    func testTableRendersAsNativeTextTableWithCellText() throws {
        let rendered = MarkdownPreviewRenderer().render("| a | b |\n|---|---|\n| 1 | 2 |", profile: .original)
        // Cell text is present and live; the pipes / delimiter dashes are gone.
        for cell in ["a", "b", "1", "2"] {
            XCTAssertTrue(rendered.string.contains(cell), "missing cell \(cell)")
        }
        XCTAssertFalse(rendered.string.contains("|"))
        XCTAssertFalse(rendered.string.contains("---"))
        // The content is laid out via a native NSTextTable (paragraph carries a text block).
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(style.textBlocks.contains { $0 is NSTextTableBlock })
    }

    func testTableTextIsRelativelySmallerThanReadingFont() throws {
        var profile = ReadingProfile.original
        profile.fontSize = 20
        let rendered = MarkdownPreviewRenderer().render("| a | b |\n|---|---|\n| 1 | 2 |", profile: profile)
        let cellIndex = (rendered.string as NSString).range(of: "1").location
        let cellFont = try XCTUnwrap(rendered.attribute(.font, at: cellIndex, effectiveRange: nil) as? NSFont)
        // Relative reduction: tracks the reading size (20) but a bit smaller, and scales with it.
        XCTAssertEqual(cellFont.pointSize, 20 * MarkdownPreviewRenderer.tableTextScale, accuracy: 0.01)
        XCTAssertLessThan(cellFont.pointSize, 20)
    }

    func testTableColumnAlignmentFollowsDelimiter() throws {
        // Header "b" column is centered by ":--:"; find a cell in that column and check its alignment.
        let rendered = MarkdownPreviewRenderer().render("| a | b |\n|:--|:--:|\n| 1 | 2 |", profile: .original)
        let bIndex = (rendered.string as NSString).range(of: "b").location
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: bIndex, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
    }

    func testBulletedListRendersBulletWithHangingIndent() throws {
        let rendered = MarkdownPreviewRenderer().render("- item", profile: .original)
        XCTAssertTrue(rendered.string.contains("•"))
        XCTAssertTrue(rendered.string.contains("item"))
        XCTAssertFalse(rendered.string.hasPrefix("-"))
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, style.firstLineHeadIndent) // wrapped lines hang under the text
    }

    func testNumberedListRendersSequentialNumbers() {
        let rendered = MarkdownPreviewRenderer().render("1. a\n1. b", profile: .original).string
        XCTAssertTrue(rendered.contains("1."))
        XCTAssertTrue(rendered.contains("2."))
    }

    func testBlockSpacingAppliesOnlyToMarkdownBlockEndings() throws {
        var profile = ReadingProfile.original
        profile.paragraphSpacing = 18
        let rendered = MarkdownPreviewRenderer().render("First line\nsame paragraph\n\nNext paragraph", profile: profile)
        let firstLineStyle = try paragraphStyle(in: rendered, searchText: "First line")
        let sameParagraphStyle = try paragraphStyle(in: rendered, searchText: "same paragraph")
        let nextParagraphStyle = try paragraphStyle(in: rendered, searchText: "Next paragraph")

        XCTAssertEqual(firstLineStyle.paragraphSpacing, 0)
        XCTAssertEqual(sameParagraphStyle.paragraphSpacing, 18)
        XCTAssertEqual(nextParagraphStyle.paragraphSpacing, 0)
    }

    func testHeadingsAndTheirLineTerminatorsReceiveBlockSpacingEvenWithoutBlankLine() throws {
        var profile = ReadingProfile.original
        profile.paragraphSpacing = 18
        let rendered = MarkdownPreviewRenderer().render("# Title\nBody\n## Section\nBody", profile: profile)
        let titleStyle = try paragraphStyle(in: rendered, searchText: "Title")
        let titleTerminatorStyle = try paragraphStyle(in: rendered, location: ("Title" as NSString).length)
        let sectionStyle = try paragraphStyle(in: rendered, searchText: "Section")
        let bodyBeforeSectionStyle = try paragraphStyle(in: rendered, searchText: "Body")
        let finalBodyStyle = try paragraphStyle(in: rendered, searchText: "Body", occurrence: 2)

        XCTAssertEqual(titleStyle.paragraphSpacing, 22)
        XCTAssertEqual(titleTerminatorStyle.paragraphSpacing, 22)
        XCTAssertEqual(sectionStyle.paragraphSpacing, 22)
        XCTAssertEqual(bodyBeforeSectionStyle.paragraphSpacing, 18)
        XCTAssertEqual(finalBodyStyle.paragraphSpacing, 0)
    }

    func testBodyBeforeHeadingReceivesBlockSpacingWithoutBlankLine() throws {
        var profile = ReadingProfile.original
        profile.paragraphSpacing = 18
        let rendered = MarkdownPreviewRenderer().render("Body paragraph\n# Title\nBody", profile: profile)
        let bodyBeforeHeadingStyle = try paragraphStyle(in: rendered, searchText: "Body paragraph")
        let headingStyle = try paragraphStyle(in: rendered, searchText: "Title")

        XCTAssertEqual(bodyBeforeHeadingStyle.paragraphSpacing, 18)
        XCTAssertEqual(headingStyle.paragraphSpacing, 22)
    }

    func testBlockSpacingDoesNotTreatFencedCodeContentsAsMarkdownBlocks() throws {
        // A `# heading`-looking line inside a code fence must not pick up heading paragraph
        // spacing; it renders as plain fenced-code body. The fence delimiters themselves are no
        // longer emitted (Task 4: fenced code is its own `.fencedCode` block, not `.lines`).
        var profile = ReadingProfile.original
        profile.paragraphSpacing = 18
        let rendered = MarkdownPreviewRenderer().render("```\n# Not a heading\n\n```\n\nBody", profile: profile)
        let fencedHeadingStyle = try paragraphStyle(in: rendered, searchText: "# Not a heading")

        XCTAssertEqual(fencedHeadingStyle.paragraphSpacing, 0)

        // A block AFTER the fenced code resumes correct paragraph spacing. Paragraph spacing is a
        // property of the PRECEDING paragraph (space *after* it), so the gap before "Body" is
        // carried by the lone separator newline emitted right after the code block, not by "Body"
        // itself or by the code content (which must stay at 0, per the assertion above). The
        // source has a blank line right after the closing fence, so that boundary is flagged for
        // block spacing and Task 5's `appendCodeBlock`/dispatch threads `codeBlockSpacingAttributes`
        // onto that separator, restoring the pre-Task-4 rhythm.
        // Rendered string is "# Not a heading\n\n\nBody": the code body's own trailing "\n", the
        // block separator's "\n" (the boundary this asserts on), then the blank source line's own
        // "\n" (rendered by the following `.lines` run) before "Body".
        let full = rendered.string as NSString
        let bodyLocation = full.range(of: "Body").location
        let separatorStyle = try paragraphStyle(in: rendered, location: bodyLocation - 2)
        XCTAssertEqual(separatorStyle.paragraphSpacing, 18)
    }

    @MainActor
    func testPreviewTextViewRecalculatesColumnInsetWhenResized() {
        let textView = MarkdownPreviewTextView()
        var profile = ReadingProfile.original
        profile.columnWidth = 820
        profile.marginWidth = 40

        textView.apply(text: "Body copy", profile: profile)
        textView.setFrameSize(NSSize(width: 1_200, height: 500))

        XCTAssertEqual(textView.textContainerInset.width, 190)

        textView.setFrameSize(NSSize(width: 700, height: 500))

        XCTAssertEqual(textView.textContainerInset.width, 40)
    }

    @MainActor
    func testResizingNarrowerShrinksAWideBlockAttachment() throws {
        let textView = MarkdownPreviewTextView()
        var profile = ReadingProfile.original
        profile.columnWidth = 800
        profile.marginWidth = 20
        textView.apply(text: "seed", profile: profile)   // sets activeProfile

        // A wide block diagram rendered at the column width (800), natural raster 1200 wide.
        let attachment = BlockRenderedAttachment()
        attachment.image = NSImage(size: NSSize(width: 1200, height: 600))
        attachment.bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        textView.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))

        textView.setFrameSize(NSSize(width: 1000, height: 600))   // wide: fits at 800, no change
        XCTAssertEqual(attachment.bounds.width, 800, accuracy: 0.5)

        textView.setFrameSize(NSSize(width: 300, height: 600))    // narrow: must shrink to fit
        XCTAssertLessThan(attachment.bounds.width, 800)
        XCTAssertEqual(attachment.bounds.height, attachment.bounds.width * 0.5, accuracy: 0.5)  // aspect kept
    }

    /// Read/Preview mode regression (2026-07-17): when a side drawer narrows the view, the text
    /// rewraps but the scroll offset used to stay at its old pixel value, so the passage being
    /// read visibly shifted. The view must keep the top visible character at the same viewport
    /// offset across a width change, mirroring Write mode's visual-anchor preservation.
    @MainActor
    func testNarrowingPreviewKeepsTopVisibleTextAnchoredWhileRewrapping() throws {
        let text = (0..<40)
            .map { index in
                "Paragraph \(index): " + String(
                    repeating: "calm words that wrap at ordinary reading widths without effort ",
                    count: 4
                )
            }
            .joined(separator: "\n\n")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
        scrollView.hasVerticalScroller = true
        let textView = MarkdownPreviewTextView()
        scrollView.documentView = textView
        textView.apply(text: text, profile: .original)
        textView.setFrameSize(NSSize(width: 1_000, height: 100))

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let laidOutHeight = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        // Generous height so the rewrapped (taller) document still fits without clip clamping.
        textView.setFrameSize(NSSize(width: 1_000, height: laidOutHeight * 2))

        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 800))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let anchorIndex = try topVisibleCharacterIndex(in: textView)
        XCTAssertGreaterThan(anchorIndex, 0, "The fixture must be scrolled into the document body.")
        let offsetBefore = try viewportOffset(ofCharacterAt: anchorIndex, in: textView)
        let containerYBefore = try containerY(ofCharacterAt: anchorIndex, in: textView)

        textView.setFrameSize(NSSize(width: 640, height: textView.frame.height))
        layoutManager.ensureLayout(for: container)

        let containerYAfter = try containerY(ofCharacterAt: anchorIndex, in: textView)
        XCTAssertGreaterThan(
            abs(containerYAfter - containerYBefore),
            10,
            "The fixture must actually rewrap: the anchor character should move within the document."
        )

        let offsetAfter = try viewportOffset(ofCharacterAt: anchorIndex, in: textView)
        XCTAssertEqual(
            offsetAfter,
            offsetBefore,
            accuracy: 1.0,
            "The top visible text must stay put in the viewport while the column rewraps."
        )
    }

    /// Same invariant, driven the way a MANUAL WINDOW RESIZE reaches the text view: through the
    /// scroll view's own frame change (clip view resize → documentView autoresizing), not a direct
    /// `setFrameSize` on the text view.
    @MainActor
    func testNarrowingScrollViewKeepsTopVisibleTextAnchoredWhileRewrapping() throws {
        let text = (0..<40)
            .map { index in
                "Paragraph \(index): " + String(
                    repeating: "calm words that wrap at ordinary reading widths without effort ",
                    count: 4
                )
            }
            .joined(separator: "\n\n")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
        scrollView.hasVerticalScroller = true
        let textView = MarkdownPreviewTextView()
        scrollView.documentView = textView
        textView.apply(text: text, profile: .original)
        textView.setFrameSize(NSSize(width: 1_000, height: 100))

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let laidOutHeight = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        textView.setFrameSize(NSSize(width: 1_000, height: laidOutHeight * 2))

        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 800))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let anchorIndex = try topVisibleCharacterIndex(in: textView)
        XCTAssertGreaterThan(anchorIndex, 0, "The fixture must be scrolled into the document body.")
        let offsetBefore = try viewportOffset(ofCharacterAt: anchorIndex, in: textView)
        let containerYBefore = try containerY(ofCharacterAt: anchorIndex, in: textView)

        scrollView.setFrameSize(NSSize(width: 640, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: container)

        XCTAssertEqual(textView.frame.width, 640, accuracy: 0.5, "The clip resize must reach the document view.")
        let containerYAfter = try containerY(ofCharacterAt: anchorIndex, in: textView)
        XCTAssertGreaterThan(
            abs(containerYAfter - containerYBefore),
            10,
            "The fixture must actually rewrap: the anchor character should move within the document."
        )

        let offsetAfter = try viewportOffset(ofCharacterAt: anchorIndex, in: textView)
        XCTAssertEqual(
            offsetAfter,
            offsetBefore,
            accuracy: 1.0,
            "The top visible text must stay put in the viewport across a window-driven resize."
        )
    }

    /// Top-of-document pin for Read/Preview: a view at the very top stays at exactly the top
    /// through width changes (see the Write-mode counterpart for rationale).
    @MainActor
    func testNarrowingPreviewAtTopStaysPinnedToTop() throws {
        let text = (0..<40)
            .map { index in
                "Paragraph \(index): " + String(
                    repeating: "calm words that wrap at ordinary reading widths without effort ",
                    count: 4
                )
            }
            .joined(separator: "\n\n")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
        scrollView.hasVerticalScroller = true
        let textView = MarkdownPreviewTextView()
        scrollView.documentView = textView
        textView.apply(text: text, profile: .original)
        textView.setFrameSize(NSSize(width: 1_000, height: 100))
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let laidOutHeight = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        textView.setFrameSize(NSSize(width: 1_000, height: laidOutHeight * 2))

        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        for width in [900, 780, 640, 780, 1_000] as [CGFloat] {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            layoutManager.ensureLayout(for: container)
            XCTAssertEqual(
                scrollView.contentView.bounds.origin.y,
                0,
                accuracy: 0.5,
                "A top-anchored view must stay at the top at width \(width)."
            )
        }
    }

    @MainActor
    private func topVisibleCharacterIndex(in textView: MarkdownPreviewTextView) throws -> Int {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        var visibleRect = clipView.bounds
        visibleRect.origin.x -= textView.textContainerOrigin.x
        visibleRect.origin.y -= textView.textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
    }

    @MainActor
    private func containerY(ofCharacterAt characterIndex: Int, in textView: MarkdownPreviewTextView) throws -> CGFloat {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).minY
    }

    @MainActor
    private func viewportOffset(ofCharacterAt characterIndex: Int, in textView: MarkdownPreviewTextView) throws -> CGFloat {
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        let yInContainer = try containerY(ofCharacterAt: characterIndex, in: textView)
        return yInContainer + textView.textContainerOrigin.y - clipView.bounds.origin.y
    }

    @MainActor
    func testPreviewTextViewDoesNotRerenderUnchangedContent() {
        let textView = MarkdownPreviewTextView()

        textView.apply(text: "Body copy", profile: .original)
        textView.setSelectedRange(NSRange(location: 5, length: 4))
        textView.apply(text: "Body copy", profile: .original)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 4))
    }

    private func paragraphStyle(
        in rendered: NSAttributedString,
        searchText: String,
        occurrence: Int = 1
    ) throws -> NSParagraphStyle {
        let nsString = rendered.string as NSString
        var searchRange = NSRange(location: 0, length: nsString.length)
        var range = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            range = nsString.range(of: searchText, range: searchRange)
            if range.location == NSNotFound {
                break
            }
            let nextLocation = NSMaxRange(range)
            searchRange = NSRange(location: nextLocation, length: nsString.length - nextLocation)
        }
        XCTAssertNotEqual(range.location, NSNotFound)
        return try paragraphStyle(in: rendered, location: range.location)
    }

    private func paragraphStyle(in rendered: NSAttributedString, location: Int) throws -> NSParagraphStyle {
        return try XCTUnwrap(rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
    }
}

// MARK: - Math rendering

private final class FakeMathProvider: MathImageProviding {
    let result: MathRenderOutcome
    init(_ result: MathRenderOutcome) { self.result = result }
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome { result }
}

/// Captures the foreground the renderer asks for, to prove block math uses the fixed ink and
/// inline math stays theme-aware.
private final class SpyMathProvider: MathImageProviding {
    private(set) var captured: [NSColor] = []
    let result: MathRenderOutcome
    init(_ result: MathRenderOutcome) { self.result = result }
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
        captured.append(foreground)
        return result
    }
}

private final class SpyMermaidProvider: MermaidImageProviding {
    private(set) var captured: [(background: NSColor, foreground: NSColor)] = []
    let result: MermaidRenderOutcome
    init(_ result: MermaidRenderOutcome) { self.result = result }
    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
        captured.append((background, foreground))
        return result
    }
}

// MARK: - Block diagram/math background + fixed ink (Task 3b)

final class MarkdownPreviewRendererBackgroundTests: XCTestCase {
    private func renderMermaid(profile: ReadingProfile, provider: SpyMermaidProvider) {
        _ = MarkdownPreviewRenderer().render(
            "```mermaid\ngraph TD;A-->B;\n```",
            profile: profile,
            columnWidth: 600,
            mermaidProvider: provider,
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "1.0"
        )
    }

    private func renderMath(_ text: String, profile: ReadingProfile, provider: SpyMathProvider) {
        _ = MarkdownPreviewRenderer().render(
            text,
            profile: profile,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: provider,
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "1.0"
        )
    }

    private func profile(theme: ThemeID) -> ReadingProfile {
        var p = ReadingProfile.original
        p.themeID = theme
        return p
    }

    func testBlockDiagramIsTransparentWithLightInkOnLightTheme() throws {
        let spy = SpyMermaidProvider(.skipped)
        renderMermaid(profile: profile(theme: .system), provider: spy)
        let cap = try XCTUnwrap(spy.captured.first)
        XCTAssertEqual(cap.background.alphaComponent, 0, "block diagram canvas is transparent")
        XCTAssertEqual(cap.foreground, DiagramPalette.ink(isDark: false))
    }

    func testBlockDiagramUsesPageMatchedCanvasOnDarkTheme() throws {
        // Dark themes set the canvas to the page color so Mermaid's node boxes get a visible outline;
        // it still reads as "no box" because the canvas matches the page.
        let spy = SpyMermaidProvider(.skipped)
        renderMermaid(profile: profile(theme: .night), provider: spy)
        let cap = try XCTUnwrap(spy.captured.first)
        XCTAssertEqual(cap.background, Theme.night.backgroundColor)
        XCTAssertEqual(cap.foreground, Theme.night.textColor)
    }

    func testBlockDiagramInkIsIdenticalAcrossTwoLightThemes() throws {
        // Two different light themes must yield identical ink → identical cache key → no redraw on
        // the switch (the freeze fix).
        let paper = SpyMermaidProvider(.skipped)
        let calm = SpyMermaidProvider(.skipped)
        renderMermaid(profile: profile(theme: .paper), provider: paper)
        renderMermaid(profile: profile(theme: .calm), provider: calm)
        XCTAssertEqual(try XCTUnwrap(paper.captured.first).foreground, try XCTUnwrap(calm.captured.first).foreground)
    }

    func testBlockMathUsesFixedInk() throws {
        let spy = SpyMathProvider(.image(NSImage(size: NSSize(width: 20, height: 12)), descent: 0))
        renderMath("$$\nx^2\n$$", profile: profile(theme: .system), provider: spy)
        XCTAssertEqual(try XCTUnwrap(spy.captured.first), DiagramPalette.ink(isDark: false))
    }

    func testInlineMathStaysThemeAware() throws {
        let spy = SpyMathProvider(.image(NSImage(size: NSSize(width: 10, height: 8)), descent: 2))
        renderMath("value $x^2$ here", profile: profile(theme: .night), provider: spy)
        XCTAssertEqual(try XCTUnwrap(spy.captured.first), Theme.night.textColor)  // theme-aware
    }
}

final class MarkdownPreviewRendererMathTests: XCTestCase {
    private func render(_ text: String, math: MathRenderOutcome) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: FakeMathProvider(math),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "1.0"
        )
    }

    private func firstAttachment(_ s: NSAttributedString) -> NSTextAttachment? {
        var found: NSTextAttachment?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if let a = v as? NSTextAttachment { found = a; stop.pointee = true }
        }
        return found
    }

    // Block $$…$$

    func testBlockMathRendersAttachmentWithAccessibility() throws {
        let image = NSImage(size: NSSize(width: 20, height: 12))
        let rendered = render("$$\nx^2+y^2\n$$", math: .image(image, descent: 0))
        let a = try XCTUnwrap(firstAttachment(rendered))
        XCTAssertEqual(a.image?.accessibilityDescription, "Math. x^2+y^2")
    }

    func testBlockMathAttachmentIsMarkedBlockForRefit() throws {
        // Block attachments must be the refit-eligible subclass so a resize rescales them.
        let image = NSImage(size: NSSize(width: 20, height: 12))
        let rendered = render("$$\nx^2\n$$", math: .image(image, descent: 0))
        let a = try XCTUnwrap(firstAttachment(rendered))
        XCTAssertTrue(a is BlockRenderedAttachment)
    }

    func testInlineMathAttachmentIsNotMarkedBlock() throws {
        // Inline math must stay a plain attachment so the resize refit never rescales it (which
        // would break its baseline offset).
        let image = NSImage(size: NSSize(width: 10, height: 8))
        let rendered = render("value $x^2$ here", math: .image(image, descent: 3))
        let a = try XCTUnwrap(firstAttachment(rendered))
        XCTAssertFalse(a is BlockRenderedAttachment)
    }

    func testSingleLineBlockMathRenders() throws {
        let image = NSImage(size: NSSize(width: 20, height: 12))
        let rendered = render("$$E=mc^2$$", math: .image(image, descent: 0))
        let a = try XCTUnwrap(firstAttachment(rendered))
        XCTAssertEqual(a.image?.accessibilityDescription, "Math. E=mc^2")
    }

    func testBlockMathFailureFallsBackToSource() {
        let out = render("$$\n\\frac{\n$$", math: .failed("boom")).string
        XCTAssertTrue(out.contains("Math (source)"))
        XCTAssertTrue(out.contains("\\frac{"))
        XCTAssertFalse(out.contains("$$"))
    }

    // Inline $…$

    func testInlineMathRendersBaselineAlignedAttachment() throws {
        let image = NSImage(size: NSSize(width: 10, height: 8))
        let rendered = render("the value $x^2$ is fixed", math: .image(image, descent: 3))
        XCTAssertTrue(rendered.string.contains("the value "))
        XCTAssertTrue(rendered.string.contains(" is fixed"))
        let a = try XCTUnwrap(firstAttachment(rendered))
        XCTAssertEqual(a.image?.accessibilityDescription, "Math. x^2")
        XCTAssertEqual(a.bounds.origin.y, -3, accuracy: 0.001)  // sits on the baseline via -descent
    }

    func testInlineMathFailureFallsBackToRawSource() {
        let out = render("bad $\\frac{$ here", math: .failed("boom")).string
        XCTAssertTrue(out.contains("\\frac{"))
    }

    func testProseDollarsAreNotTreatedAsMath() {
        // The provider would fail if ever called; a clean pass proves "$5/$10" stayed literal.
        let out = render("it costs $5 to $10 today", math: .failed("should not be called")).string
        XCTAssertEqual(out, "it costs $5 to $10 today")
    }

    func testMathInsideInlineCodeIsNotRendered() {
        // `$x$` inside a code span must stay literal code — no math attachment, backticks not orphaned.
        let image = NSImage(size: NSSize(width: 10, height: 8))
        let rendered = render("Set `$x$` to 5", math: .image(image, descent: 2))
        XCTAssertNil(firstAttachment(rendered), "no math attachment inside a code span")
        XCTAssertTrue(rendered.string.contains("$x$"), "the code span keeps its literal $x$")
    }

    func testEmphasisWrappingMathKeepsBoldAndDoesNotRenderMathInside() {
        // Bold starts before the math and wins; math inside stays literal (consistent with how
        // code inside bold already behaves). The point is no corruption and bold is preserved.
        let image = NSImage(size: NSSize(width: 10, height: 8))
        let rendered = render("**energy $E=mc^2$ total**", math: .image(image, descent: 2))
        XCTAssertNil(firstAttachment(rendered))
        XCTAssertTrue(rendered.string.contains("energy $E=mc^2$ total"))
        XCTAssertFalse(rendered.string.contains("**"), "bold markers are consumed")
    }

    func testMidLineDisplayMathRendersWithoutStrayDollars() throws {
        let image = NSImage(size: NSSize(width: 20, height: 12))
        let rendered = render("the famous $$E=mc^2$$ equation", math: .image(image, descent: 0))
        let a = try XCTUnwrap(firstAttachment(rendered))
        XCTAssertEqual(a.image?.accessibilityDescription, "Math. E=mc^2")
        XCTAssertFalse(rendered.string.contains("$"), "no stray dollar signs around inline display math")
        XCTAssertTrue(rendered.string.contains("the famous "))
        XCTAssertTrue(rendered.string.contains(" equation"))
    }
}

extension MarkdownPreviewRendererTests {
    private func renderReadMode(_ text: String, highlightsCode: Bool = true) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "0",
            highlightsCode: highlightsCode
        )
    }

    /// The set of distinct non-nil foreground colors applied over the rendered code body.
    private func codeForegroundColors(in attributed: NSAttributedString, bodySubstring: String) -> Set<NSColor> {
        let full = attributed.string as NSString
        let bodyRange = full.range(of: bodySubstring)
        guard bodyRange.location != NSNotFound else { return [] }
        var colors: Set<NSColor> = []
        attributed.enumerateAttribute(.foregroundColor, in: bodyRange, options: []) { value, _, _ in
            if let c = value as? NSColor { colors.insert(c) }
        }
        return colors
    }

    func testReadModeCodeIsMultiColored() {
        let out = renderReadMode("```swift\nlet x = 42\n```")
        // Highlighted code uses more than one foreground color (keyword + number + plain).
        XCTAssertGreaterThan(codeForegroundColors(in: out, bodySubstring: "let x = 42").count, 1)
    }

    func testExportModeCodeIsMonochrome() {
        let out = renderReadMode("```swift\nlet x = 42\n```", highlightsCode: false)
        // No coloring: the body is a single foreground color (the theme's code ink).
        XCTAssertEqual(codeForegroundColors(in: out, bodySubstring: "let x = 42").count, 1)
    }

    func testUnknownLanguageCodeIsMonochromeEvenInReadMode() {
        let out = renderReadMode("```yaml\nkey: value\n```")
        XCTAssertEqual(codeForegroundColors(in: out, bodySubstring: "key: value").count, 1)
    }

    func testFenceDelimitersAreNotRendered() {
        let out = renderReadMode("```swift\nlet x = 1\n```")
        XCTAssertFalse(out.string.contains("```"))
    }

    func testCodeBlockCarriesSourceRangeAttribute() {
        let out = renderReadMode("```swift\nlet x = 1\n```")
        let full = out.string as NSString
        let bodyRange = full.range(of: "let x = 1")
        var found: NSRange?
        out.enumerateAttribute(.codeBlockSourceRange, in: bodyRange, options: []) { value, _, stop in
            if let v = value as? NSValue { found = v.rangeValue; stop.pointee = true }
        }
        // Source range points at the body within the ORIGINAL text ("```swift\n" is 9 UTF-16 units).
        XCTAssertEqual(found, NSRange(location: 9, length: ("let x = 1" as NSString).length))
    }
}

// MARK: - Image blocks

final class MarkdownPreviewRendererImageTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testUnresolvedImageEmitsPlaceholderWithReconnectMarker() {
        let out = render("![cat](missing.png)", documentDirectory: nil, imageProvider: DisabledImageAttachmentProvider())
        XCTAssertTrue(out.string.contains("🖼 cat"))

        var foundSourceRange = false
        var foundReconnect = false
        out.enumerateAttribute(.imageSourceRange, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value is NSValue { foundSourceRange = true }
        }
        out.enumerateAttribute(.imageReconnect, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value is NSNumber { foundReconnect = true }
        }
        XCTAssertTrue(foundSourceRange)
        XCTAssertTrue(foundReconnect)
    }

    func testRemoteImageStaysPlaceholder() {
        let out = render("![c](https://x/y.png)", documentDirectory: nil, imageProvider: DisabledImageAttachmentProvider())
        XCTAssertTrue(out.string.contains("🖼 c"))

        var foundReconnect = false
        var foundAttachment = false
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { attrs, _, _ in
            if attrs[.imageReconnect] is NSNumber { foundReconnect = true }
            if attrs[.attachment] is BlockRenderedAttachment { foundAttachment = true }
        }
        XCTAssertTrue(foundReconnect)
        XCTAssertFalse(foundAttachment)
    }

    func testResolvedLocalImageEmitsBlockAttachment() throws {
        let url = try writePNG(named: "pic.png", width: 400, height: 200)
        let out = render("![cat](pic.png)", documentDirectory: tempDirectory, imageProvider: ImageAttachmentProvider())

        var foundAttachment: BlockRenderedAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let attachment = value as? BlockRenderedAttachment { foundAttachment = attachment }
        }
        var foundReconnect = false
        out.enumerateAttribute(.imageReconnect, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value is NSNumber { foundReconnect = true }
        }

        let attachment = try XCTUnwrap(foundAttachment)
        XCTAssertEqual(attachment.image?.accessibilityDescription, "cat")
        XCTAssertFalse(foundReconnect)
        _ = url
    }

    func testPlaceholderAndImageUseSameBlockSpacing() throws {
        let url = try writePNG(named: "pic2.png", width: 400, height: 200)
        let resolved = render("![cat](pic2.png)", documentDirectory: tempDirectory, imageProvider: ImageAttachmentProvider())
        let unresolved = render("![cat](missing2.png)", documentDirectory: nil, imageProvider: DisabledImageAttachmentProvider())

        // Both blocks are single-run documents: read the paragraph spacing at location 0.
        let resolvedStyle = try XCTUnwrap(resolved.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let unresolvedStyle = try XCTUnwrap(unresolved.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)

        let expected = max(12, CGFloat(ReadingProfile.original.paragraphSpacing) + 6)
        XCTAssertEqual(resolvedStyle.paragraphSpacing, expected, accuracy: 0.01)
        XCTAssertEqual(unresolvedStyle.paragraphSpacing, expected, accuracy: 0.01)
        _ = url
    }

    func testOtherConstructsUnchanged() {
        let out = render("# H\n\nBody", documentDirectory: nil, imageProvider: DisabledImageAttachmentProvider())
        XCTAssertEqual(out.string, "H\n\nBody")
    }

    // MARK: - Helpers

    private func render(_ text: String, documentDirectory: URL?, imageProvider: ImageAttachmentProviding) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "0",
            documentDirectory: documentDirectory,
            imageProvider: imageProvider
        )
    }

    @discardableResult
    private func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
}
