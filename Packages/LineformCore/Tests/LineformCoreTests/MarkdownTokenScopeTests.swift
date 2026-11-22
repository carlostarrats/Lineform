import XCTest
@testable import LineformCore

/// The pure half of the former `ScopedSyntaxHighlightingTests` (Mac app), moved with
/// `MarkdownTokenScope`. The text-view cases stay in the app.
final class MarkdownTokenScopeTests: XCTestCase {

    // MARK: - scopedTokenRange

    func testScopedTokenRangeExpandsByMarginAndSnapsToLineBoundaries() {
        let text = "aaaa\nbbbb\ncccc\ndddd\neeee" as NSString // 5 lines, 4 chars + \n each
        // Visible = the "cccc" line (location 10, length 4). Margin 1 char each side.
        let scope = MarkdownTokenScope.scopedTokenRange(
            in: text, around: NSRange(location: 10, length: 4), margin: 1
        )
        // 10-1=9 (the \n after "bbbb") snaps back to the start of "bbbb" (loc 5); 14+1=15
        // (the 'd' of "dddd") snaps out to the end of the "dddd" line incl. its \n (loc 20).
        XCTAssertEqual(scope, NSRange(location: 5, length: 15))
    }

    func testScopedTokenRangeClampsAtDocumentEdges() {
        let text = "aaaa\nbbbb\ncccc" as NSString // length 14
        let scope = MarkdownTokenScope.scopedTokenRange(
            in: text, around: NSRange(location: 0, length: 4), margin: 10_000
        )
        XCTAssertEqual(scope, NSRange(location: 0, length: 14))
    }

    func testScopedTokenRangeOnEmptyTextIsEmpty() {
        let scope = MarkdownTokenScope.scopedTokenRange(
            in: "" as NSString, around: NSRange(location: 0, length: 0), margin: 3000
        )
        XCTAssertEqual(scope, NSRange(location: 0, length: 0))
    }

    // MARK: - scoped tokens byte-identical to whole-doc

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

        // Window snapped over the middle (covering the fence + surrounding lines).
        let window = MarkdownTokenScope.scopedTokenRange(
            in: ns, around: NSRange(location: ns.length / 3, length: ns.length / 3), margin: 5
        )

        let scoped = MarkdownTokenScope.tokens(in: ns, scope: window)
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
        XCTAssertTrue(MarkdownTokenScope.tokens(in: "# H" as NSString, scope: NSRange(location: 0, length: 0)).isEmpty)
    }

    func testLinkTokenizationIsLineLocal() {
        // A link split across lines must NOT be tokenized (newline-excluded regex) — this is what
        // keeps the analyzer fully line-local so scoped highlighting is byte-identical.
        let kinds = MarkdownRangeAnalyzer().ranges(in: "[label\nspill](https://example.com)").map(\.kind)
        XCTAssertFalse(kinds.contains(.linkText))
        XCTAssertFalse(kinds.contains(.linkDestination))
        // A same-line link still tokenizes.
        let sameLine = MarkdownRangeAnalyzer().ranges(in: "see [label](https://example.com) here").map(\.kind)
        XCTAssertTrue(sameLine.contains(.linkText))
        XCTAssertTrue(sameLine.contains(.linkDestination))
    }

    func testRangeCovers() {
        XCTAssertTrue(MarkdownTokenScope.range(NSRange(location: 0, length: 10), covers: NSRange(location: 2, length: 3)))
        XCTAssertFalse(MarkdownTokenScope.range(NSRange(location: 0, length: 10), covers: NSRange(location: 8, length: 5)))
    }
}
