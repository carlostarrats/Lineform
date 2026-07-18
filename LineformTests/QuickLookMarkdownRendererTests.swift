import XCTest
import AppKit
// No @testable import: QuickLookMarkdownRenderer is compiled directly into this test target.

final class QuickLookMarkdownRendererTests: XCTestCase {
    // MARK: - Extraction / block rendering unchanged

    func testRendererIsReachableAndRendersHeadingBold() {
        let output = QuickLookMarkdownRenderer.render("# Title\n")
        XCTAssertTrue(output.string.contains("Title"))
        // Heading uses a bold font (existing block behavior, unchanged by the extraction).
        let font = output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testPlainParagraphRendersAsBodyText() {
        let output = QuickLookMarkdownRenderer.render("just some words\n")
        XCTAssertEqual(output.string, "just some words\n")
    }

    // MARK: - Inline formatting

    private func base() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.labelColor]
    }

    private func hasTrait(_ s: NSAttributedString, _ trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        var found = false
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if let f = value as? NSFont, f.fontDescriptor.symbolicTraits.contains(trait) {
                found = true; stop.pointee = true
            }
        }
        return found
    }

    func testBoldMarkersRemovedAndTraitApplied() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "a **b** c", baseAttributes: base())
        XCTAssertEqual(s.string, "a b c")
        XCTAssertTrue(hasTrait(s, .bold))
    }

    func testItalicMarkersRemovedAndTraitApplied() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "a *b* c", baseAttributes: base())
        XCTAssertEqual(s.string, "a b c")
        XCTAssertTrue(hasTrait(s, .italic))
    }

    func testInlineCodeIsMonospacedAndLiteral() {
        // A marker inside code stays literal (code wins precedence).
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "x `**y**` z", baseAttributes: base())
        XCTAssertEqual(s.string, "x **y** z")
        XCTAssertTrue(hasTrait(s, .monoSpace))
        XCTAssertFalse(hasTrait(s, .bold))
    }

    func testLinkTextShownWithLinkAttribute() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "see [docs](https://example.com) now", baseAttributes: base())
        XCTAssertEqual(s.string, "see docs now")
        var url: Any?
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if value != nil { url = value; stop.pointee = true }
        }
        XCTAssertEqual((url as? URL)?.absoluteString, "https://example.com")
    }

    func testStrikethroughApplied() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "a ~~b~~ c", baseAttributes: base())
        XCTAssertEqual(s.string, "a b c")
        var struck = false
        s.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if let n = value as? Int, n != 0 { struck = true; stop.pointee = true }
        }
        XCTAssertTrue(struck)
    }

    func testUnderscoreInWordIsNotItalic() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "snake_case_name", baseAttributes: base())
        XCTAssertEqual(s.string, "snake_case_name")
        XCTAssertFalse(hasTrait(s, .italic))
    }

    func testEscapedMarkerRendersLiterally() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: #"a \*b\* c"#, baseAttributes: base())
        XCTAssertEqual(s.string, "a *b* c")
        XCTAssertFalse(hasTrait(s, .italic))
    }
}
