import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// Markdown highlighting in the iPhone editor: whole-document base attributes, token inks only
/// over the visible window plus a margin, and no restyling while an input method is composing.
@MainActor
final class HighlightingTests: XCTestCase {
    func testHeadingAndCodeAreTokenStyled() throws {
        let text = "# Title\n\nSome `x` here\n"
        let textView = makeEditor(text)

        let expected = NSTextStorage(string: text)
        MarkdownTokenStyler.apply(to: expected, profile: .original, tokenScope: nil)

        let marker = 0
        XCTAssertEqual(
            textView.textStorage.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? UIColor,
            expected.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? UIColor,
            "the heading marker carries the styler's heading ink"
        )
        XCTAssertNotEqual(
            textView.textStorage.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? UIColor,
            Theme.theme(for: ReadingProfile.original).textColor,
            "the heading marker is not body ink"
        )

        let code = (text as NSString).range(of: "`x`").location + 1
        let font = try XCTUnwrap(textView.textStorage.attribute(.font, at: code, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font, expected.attribute(.font, at: code, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), "inline code is monospaced")
        XCTAssertEqual(
            textView.textStorage.attribute(.foregroundColor, at: code, effectiveRange: nil) as? UIColor,
            expected.attribute(.foregroundColor, at: code, effectiveRange: nil) as? UIColor,
            "inline code carries the styler's code ink"
        )
    }

    func testBaseAttributesCoverWholeDocument() throws {
        let text = Self.longDocument(lines: 5_000)
        let textView = makeEditor(text)
        let base = MarkdownTextStyle.baseAttributes(for: .original)
        let baseStyle = try XCTUnwrap(base[.paragraphStyle] as? NSParagraphStyle)
        let full = NSRange(location: 0, length: textView.textStorage.length)

        var runs = 0
        textView.textStorage.enumerateAttribute(.paragraphStyle, in: full) { value, _, _ in
            runs += 1
            XCTAssertEqual(value as? NSParagraphStyle, baseStyle)
        }
        XCTAssertGreaterThan(runs, 0)
        textView.textStorage.enumerateAttribute(.kern, in: full) { value, _, _ in
            XCTAssertEqual((value as? NSNumber)?.doubleValue, ReadingProfile.original.letterSpacing)
        }
        let last = textView.textStorage.length - 2
        XCTAssertEqual(textView.textStorage.attribute(.font, at: last, effectiveRange: nil) as? UIFont, base[.font] as? UIFont)
    }

    func testTokensScopedToVisibleWindow() {
        let text = Self.longDocument(lines: 5_000)
        let textView = makeEditor(text)
        let ns = text as NSString
        let markerInk = MarkdownTextStyle.markdownMarkerColor(for: .original)
        let bodyInk = Theme.theme(for: ReadingProfile.original).textColor

        let near = ns.range(of: "- item 3 ").location
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: near, effectiveRange: nil) as? UIColor, markerInk,
                       "a list marker on screen is styled")

        let far = ns.range(of: "- item 4900 ").location
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: far, effectiveRange: nil) as? UIColor, bodyInk,
                       "a list marker far below the window carries no token ink")
        let scope = textView.lastHighlightedTokenRange ?? NSRange(location: 0, length: ns.length)
        XCTAssertLessThan(scope.length, ns.length / 4, "the token pass covers the window plus its margin, not the document")
    }

    func testScrollingPastTheWindowStylesTheNewLines() {
        let text = Self.longDocument(lines: 5_000)
        let textView = makeEditor(text)
        let far = (text as NSString).range(of: "- item 4900 ").location
        let glyphs = textView.layoutManager.glyphRange(forCharacterRange: NSRange(location: far, length: 1), actualCharacterRange: nil)
        let line = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        // Scroll by moving the bounds, as a pan does (off-window, `setContentOffset` is ignored).
        textView.bounds.origin = CGPoint(x: 0, y: line.minY)
        XCTAssertFalse(MarkdownTokenScope.range(textView.lastHighlightedTokenRange ?? NSRange(), covers: textView.currentTokenScope()),
                       "the new window is outside the last pass")

        textView.refreshVisibleTokensIfNeeded()

        XCTAssertEqual(
            textView.textStorage.attribute(.foregroundColor, at: far, effectiveRange: nil) as? UIColor,
            MarkdownTextStyle.markdownMarkerColor(for: .original),
            "the scroll pass styles what is now on screen"
        )
    }

    func testNoRestyleDuringMarkedText() {
        let textView = makeEditor("# Title\n")
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(textView.markedTextRange)
        let probe = NSRange(location: 2, length: 3)
        textView.textStorage.addAttribute(.foregroundColor, value: UIColor.systemPink, range: probe)

        // The typing-delay pass first: once a full pass has been deferred, the others defer to it.
        textView.refreshHighlightingAfterTypingDelay()
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, .systemPink,
                       "the typing-delay pass is skipped while composing")
        textView.lastHighlightedTokenRangeForTesting = NSRange(location: 0, length: 0)
        textView.refreshVisibleTokensIfNeeded()
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, .systemPink,
                       "the scroll pass is skipped while composing")
        textView.refreshHighlighting()
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, .systemPink,
                       "no pass restyles the document while an input method is composing")

        textView.unmarkText()
        XCTAssertNil(textView.markedTextRange)
        textView.refreshHighlightingAfterTypingDelay()
        XCTAssertNotEqual(textView.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, .systemPink,
                          "the pass after composition ends catches up")
    }

    func testProfileChangeDuringMarkedTextCatchesUpAfterComposition() throws {
        let textView = makeEditor("Hello\n")
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        var profile = ReadingProfile.original
        profile.fontSize = 24
        textView.profile = profile
        let font = try XCTUnwrap(textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 17, "the storage is not rewritten mid-composition")

        textView.unmarkText()
        textView.refreshHighlightingAfterTypingDelay()
        let after = try XCTUnwrap(textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(after.pointSize, 24, "the skipped full pass runs once composition ends")
    }

    /// Performance: the per-edit pass on a 1 MB document is scoped to the window, so it is at
    /// least 4× faster than tokenizing the whole document.
    func testHighlightPassIsScoped() {
        let text = Self.megabyteDocument()
        XCTAssertGreaterThanOrEqual((text as NSString).length, 1_000_000)
        let textView = makeEditor(text)

        let whole = Self.bestOf(2) {
            let storage = NSTextStorage(string: text)
            let start = CFAbsoluteTimeGetCurrent()
            MarkdownTokenStyler.apply(to: storage, profile: .original, tokenScope: nil)
            return CFAbsoluteTimeGetCurrent() - start
        }
        let scoped = Self.bestOf(3) {
            let start = CFAbsoluteTimeGetCurrent()
            textView.refreshHighlightingAfterTypingDelay()
            return CFAbsoluteTimeGetCurrent() - start
        }
        let full = Self.bestOf(2) {
            let start = CFAbsoluteTimeGetCurrent()
            textView.refreshHighlighting()
            return CFAbsoluteTimeGetCurrent() - start
        }
        let ratio = whole / max(scoped, 0.000_001)
        print(String(format: "[perf] iPhone highlight 1 MB: scoped %.2f ms, full refresh %.2f ms, whole-document tokens %.2f ms, ratio %.1fx",
                     scoped * 1000, full * 1000, whole * 1000, ratio))
        XCTAssertGreaterThanOrEqual(ratio, 4, "the scoped pass must be at least 4× faster than a whole-document pass")
    }

    // MARK: - Helpers

    private func makeEditor(_ text: String, profile: ReadingProfile = .original) -> LineformTextView {
        let textView = LineformTextView.make(profile: profile)
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        textView.setDocumentText(text)
        textView.layoutIfNeeded()
        textView.refreshHighlighting()
        return textView
    }

    static func longDocument(lines: Int) -> String {
        (0..<lines).map { "- item \($0) with `code` and *words*" }.joined(separator: "\n") + "\n"
    }

    static func megabyteDocument() -> String {
        let block = """
        # Heading for a section

        Some prose with **bold**, *italic*, `inline code` and a [link](https://example.com/path).

        - a list item with `code`
        - [ ] a task item
        > a quoted line with ![image](images/pic.png)

        ```swift
        let value = compute(42)
        ```


        """
        var out = ""
        while (out as NSString).length < 1_000_000 { out += block }
        return out
    }

    private static func bestOf(_ runs: Int, _ body: () -> CFAbsoluteTime) -> CFAbsoluteTime {
        (0..<runs).map { _ in body() }.min() ?? 0
    }
}
