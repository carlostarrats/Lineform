import AppKit
import XCTest
@testable import Lineform

final class ScopedSyntaxHighlightingTests: XCTestCase {

    // MARK: - Task 1: scopedTokenRange

    func testScopedTokenRangeExpandsByMarginAndSnapsToLineBoundaries() {
        let text = "aaaa\nbbbb\ncccc\ndddd\neeee" as NSString // 5 lines, 4 chars + \n each
        // Visible = the "cccc" line (location 10, length 4). Margin 1 char each side.
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: 10, length: 4), margin: 1, in: text
        )
        // 10-1=9 snaps back to start of "bbbb" (loc 5); 14+1=15 snaps to end of "dddd" line (loc 19).
        XCTAssertEqual(scope, NSRange(location: 5, length: 14))
    }

    func testScopedTokenRangeClampsAtDocumentEdges() {
        let text = "aaaa\nbbbb\ncccc" as NSString // length 14
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: 0, length: 4), margin: 10_000, in: text
        )
        XCTAssertEqual(scope, NSRange(location: 0, length: 14))
    }

    func testScopedTokenRangeOnEmptyTextIsEmpty() {
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: 0, length: 0), margin: 3000, in: "" as NSString
        )
        XCTAssertEqual(scope, NSRange(location: 0, length: 0))
    }

    // MARK: - Task 2: scoped tokens byte-identical to whole-doc

    func testScopedTokensEqualWholeDocTokensFilteredToWindow() {
        // Multi-construct doc incl. a fenced block and headings/lists so a naive scope could
        // diverge if there were cross-line state (there isn't — the analyzer is line-local).
        let doc = """
        # Heading one
        - list item with `code`
        > a quote
        ```
        # not a heading (inside fence)
        - not a list
        ```
        Paragraph with [link](https://example.com) and more.
        Another `span` here.
        """
        let ns = doc as NSString
        let highlighter = MarkdownSyntaxHighlighter()

        // Window snapped over the middle (covering the fence + surrounding lines).
        let window = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: ns.length / 3, length: ns.length / 3),
            margin: 5, in: ns
        )

        let scoped = highlighter.tokens(in: ns, scope: window)
        let wholeFiltered = MarkdownRangeAnalyzer().ranges(in: doc).filter {
            $0.range.location >= window.location && NSMaxRange($0.range) <= NSMaxRange(window)
        }

        let sort: (MarkdownTokenRange, MarkdownTokenRange) -> Bool = {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length < $1.range.length
        }
        XCTAssertEqual(scoped.sorted(by: sort), wholeFiltered.sorted(by: sort))
        XCTAssertFalse(scoped.isEmpty)
    }

    func testScopedTokensEmptyScopeIsEmpty() {
        let highlighter = MarkdownSyntaxHighlighter()
        XCTAssertTrue(highlighter.tokens(in: "# H" as NSString, scope: NSRange(location: 0, length: 0)).isEmpty)
    }

    // MARK: - Task 3: base pass + scoped token pass

    @MainActor
    func testHighlightWithTokenScopeColorsOnlyInsideScope() {
        // Heading at top (loc 0) and a heading far below; scope only the top.
        let doc = "# Top heading\n" + String(repeating: "plain body line\n", count: 200) + "# Bottom heading"
        let textView = LineformTextView()
        textView.string = doc
        let highlighter = MarkdownSyntaxHighlighter()

        let topScope = NSRange(location: 0, length: 13) // "# Top heading"
        highlighter.highlight(textView: textView, profile: .original, tokenScope: topScope)

        let storage = textView.textStorage!
        let markerColor = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        let topMarker = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        assertSameRGB(topMarker!, markerColor) // '#' colored in scope

        let bottomHashLocation = (doc as NSString).range(of: "# Bottom heading").location
        let bottomMarker = storage.attribute(.foregroundColor, at: bottomHashLocation, effectiveRange: nil) as? NSColor
        // Off-scope '#' stays base text color, NOT marker color.
        assertSameRGB(bottomMarker!, Theme.theme(for: .original).textColor)
    }

    @MainActor
    func testRefreshTokensColorsOnlyItsScopeAndLeavesRestUntouched() {
        let doc = "# A\n# B\n# C"
        let textView = LineformTextView()
        textView.string = doc
        let highlighter = MarkdownSyntaxHighlighter()
        // Start from all-base (no tokens applied anywhere).
        highlighter.highlight(textView: textView, profile: .original, tokenScope: NSRange(location: 0, length: 0))

        let storage = textView.textStorage!
        let base = Theme.theme(for: .original).textColor
        assertSameRGB(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor, base)

        // Refresh only the second heading's line ("# B" starts at loc 4).
        highlighter.refreshTokens(textView: textView, profile: .original, scope: NSRange(location: 4, length: 3))
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        assertSameRGB(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as! NSColor, marker) // '#' of B
        assertSameRGB(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor, base)   // A still base
    }

    func testRangeCovers() {
        XCTAssertTrue(MarkdownSyntaxHighlighter.range(NSRange(location: 0, length: 10), covers: NSRange(location: 2, length: 3)))
        XCTAssertFalse(MarkdownSyntaxHighlighter.range(NSRange(location: 0, length: 10), covers: NSRange(location: 8, length: 5)))
    }

    // MARK: - Task 4: text-view wiring

    @MainActor
    func testNoScrollViewFallsBackToFullHighlight() {
        // A bare text view (no scroll view) must colorize a heading anywhere in the doc.
        let doc = String(repeating: "plain line\n", count: 300) + "# Deep heading"
        let textView = LineformTextView()
        textView.string = doc
        textView.refreshMarkdownHighlighting()

        let storage = textView.textStorage!
        let deepHash = (doc as NSString).range(of: "# Deep heading").location
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        assertSameRGB(storage.attribute(.foregroundColor, at: deepHash, effectiveRange: nil) as! NSColor, marker)
        XCTAssertNil(textView.currentVisibleTokenScope()) // no scroll view → nil scope
    }

    // MARK: - Helper

    private func assertSameRGB(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let ac = a.usingColorSpace(.sRGB)!, bc = b.usingColorSpace(.sRGB)!
        XCTAssertEqual(ac.redComponent, bc.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.greenComponent, bc.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.blueComponent, bc.blueComponent, accuracy: 0.01, file: file, line: line)
    }
}
