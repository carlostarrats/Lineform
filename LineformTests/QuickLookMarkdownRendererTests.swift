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

    // Finder's preview and the app must agree about what counts as emphasis. These two cases
    // were the last places they disagreed: Quick Look italicised the 3 in `2 * 3 * 4`, and read
    // `__init__` as bold "init" — a construct the app deliberately does not render at all.
    func testSpacedAsterisksAreNotItalic() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "2 * 3 * 4", baseAttributes: base())
        XCTAssertEqual(s.string, "2 * 3 * 4")
        XCTAssertFalse(hasTrait(s, .italic))
    }

    func testDoubleUnderscoreWordIsNotBold() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "call __init__ here", baseAttributes: base())
        XCTAssertEqual(s.string, "call __init__ here")
        XCTAssertFalse(hasTrait(s, .bold))
    }

    // Fences are the other place the hand-copy drifted: the appex knew only about ``` , so a
    // `~~~` code block rendered in Finder as prose with its delimiters showing, and a ``` block
    // quoting a `~~~` line closed early. The app matches fences per CommonMark (same delimiter
    // character), and the preview must agree — a Finder preview that disagrees with the editor is
    // the same document looking like two different files.
    func testTildeFenceRendersAsCodeNotProse() {
        let rendered = QuickLookMarkdownRenderer.render("~~~\nlet x = 1\n~~~\n").string
        XCTAssertFalse(rendered.contains("~~~"), rendered)
        XCTAssertTrue(rendered.contains("let x = 1"), rendered)
    }

    func testInnerTildeLineDoesNotCloseABacktickFence() {
        let rendered = QuickLookMarkdownRenderer.render("```\n~~~\n# Not a heading\n```\nAfter\n").string
        // The whole block, delimiters and all, stays inside the code run — so the `#` line is
        // never promoted to a heading and "After" is still ordinary prose outside the block.
        XCTAssertTrue(rendered.contains("~~~"), rendered)
        XCTAssertTrue(rendered.contains("# Not a heading"), rendered)
        XCTAssertTrue(rendered.contains("After"), rendered)
    }

    func testEscapedMarkerRendersLiterally() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: #"a \*b\* c"#, baseAttributes: base())
        XCTAssertEqual(s.string, "a *b* c")
        XCTAssertFalse(hasTrait(s, .italic))
    }
}
