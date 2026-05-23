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

        XCTAssertEqual(color, Theme.lowLight.textColor)
    }
}
