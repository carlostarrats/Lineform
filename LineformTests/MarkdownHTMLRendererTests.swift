import XCTest
@testable import Lineform

final class MarkdownHTMLRendererTests: XCTestCase {

    // MARK: Escaping

    func testEscapeReplacesMarkupCharacters() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.escape("a & b < c > d \" e"),
            "a &amp; b &lt; c &gt; d &quot; e"
        )
    }

    func testEscapeLeavesOrdinaryTextAlone() {
        XCTAssertEqual(MarkdownHTMLRenderer.escape("plain text 123"), "plain text 123")
    }

    // MARK: Inline

    func testInlineEmitsStrongEmphasisCodeAndStrikethrough() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("**bold** and _italic_ and `code` and ~~gone~~"),
            "<strong>bold</strong> and <em>italic</em> and <code>code</code> and <del>gone</del>"
        )
    }

    func testInlineEmitsLinkWithHrefExactlyAsWritten() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("see [the docs](../guide/index.html)"),
            #"see <a href="../guide/index.html">the docs</a>"#
        )
    }

    func testInlineEmitsImageWithSourcePathExactlyAsWritten() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("![flow diagram](images/flow.png)"),
            #"<img src="images/flow.png" alt="flow diagram">"#
        )
    }

    func testInlineLeavesRemoteURLsUntouched() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("![x](https://example.com/a.png)"),
            #"<img src="https://example.com/a.png" alt="x">"#
        )
    }

    func testInlineEscapesSurroundingTextAndAttributes() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML(#"5 < 6 [a "b"](p?x=1&y=2)"#),
            #"5 &lt; 6 <a href="p?x=1&amp;y=2">a &quot;b&quot;</a>"#
        )
    }

    func testInlineImageWinsOverLinkAtSamePosition() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("![a](b.png)"),
            #"<img src="b.png" alt="a">"#
        )
    }
}
