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

    func testReadModeHidesCommonInlineMarkdownMarkers() {
        let rendered = MarkdownPreviewRenderer().render(
            "This is **bold**, _clear_, `code`, and [a link](https://example.com).",
            profile: .original
        )

        XCTAssertEqual(rendered.string, "This is bold, clear, code, and a link.")
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
}
