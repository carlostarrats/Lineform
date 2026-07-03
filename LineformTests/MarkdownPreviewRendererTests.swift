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
        let rendered = MarkdownPreviewRenderer().render("# Real\n```\n# Not a heading\n```", profile: .original)

        XCTAssertEqual(rendered.string, "Real\n```\n# Not a heading\n```")
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
        var profile = ReadingProfile.original
        profile.paragraphSpacing = 18
        let rendered = MarkdownPreviewRenderer().render("```\n# Not a heading\n\n```\n\nBody", profile: profile)
        let fencedHeadingStyle = try paragraphStyle(in: rendered, searchText: "# Not a heading")
        let closingFenceStyle = try paragraphStyle(in: rendered, searchText: "```", occurrence: 2)

        XCTAssertEqual(fencedHeadingStyle.paragraphSpacing, 0)
        XCTAssertEqual(closingFenceStyle.paragraphSpacing, 18)
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
}
