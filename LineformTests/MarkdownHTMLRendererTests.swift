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

    // MARK: Blocks

    private func body(_ markdown: String) -> String {
        MarkdownHTMLRenderer.body(for: markdown, generatedImage: { _ in nil })
    }

    func testHeadingsBecomeHeadingTags() {
        XCTAssertTrue(body("# Title").contains("<h1>Title</h1>"))
        XCTAssertTrue(body("### Deeper").contains("<h3>Deeper</h3>"))
    }

    func testHeadingTextGetsInlineTreatment() {
        XCTAssertTrue(body("## A **bold** heading").contains("<h2>A <strong>bold</strong> heading</h2>"))
    }

    func testParagraphLinesJoinWithLineBreaks() {
        XCTAssertTrue(body("one\ntwo").contains("<p>one<br>two</p>"))
    }

    func testBlankLineSeparatesParagraphs() {
        let html = body("one\n\ntwo")
        XCTAssertTrue(html.contains("<p>one</p>"))
        XCTAssertTrue(html.contains("<p>two</p>"))
    }

    func testBulletListBecomesUnorderedList() {
        let html = body("- a\n- b")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>a</li>"))
        XCTAssertTrue(html.contains("<li>b</li>"))
        XCTAssertTrue(html.contains("</ul>"))
    }

    func testNumberedListBecomesOrderedList() {
        let html = body("1. a\n1. b")
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>a</li>"))
    }

    func testNestedListNestsTags() {
        let html = body("- a\n  - b")
        XCTAssertTrue(html.contains("<ul><li>a<ul><li>b</li></ul></li></ul>"))
    }

    func testAscendingOutOfANestedListClosesBothTagsInOrder() {
        // Regression: with only two items the end-of-list drain ran, which was already correct;
        // a THIRD item back at the outer level takes the ascend path, which emitted
        // `<li>b</ul></li></li>` — an unclosed inner <li> and a doubled close.
        let html = body("- a\n  - b\n- c")
        XCTAssertTrue(
            html.contains("<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>"),
            "Malformed nesting: \(html)"
        )
        XCTAssertFalse(html.contains("</li></li>"))
    }

    func testAscendingTwoLevelsAtOnceClosesEveryOpenList() {
        let html = body("- a\n  - b\n    - c\n- d")
        XCTAssertFalse(html.contains("</li></li>"))
        XCTAssertEqual(
            html.components(separatedBy: "<ul>").count,
            html.components(separatedBy: "</ul>").count,
            "Unbalanced <ul> tags: \(html)"
        )
        XCTAssertEqual(
            html.components(separatedBy: "<li>").count,
            html.components(separatedBy: "</li>").count,
            "Unbalanced <li> tags: \(html)"
        )
    }

    func testTaskItemsBecomeDisabledCheckboxes() {
        let html = body("- [ ] todo\n- [x] done")
        XCTAssertTrue(html.contains(#"<input type="checkbox" disabled> todo"#))
        XCTAssertTrue(html.contains(#"<input type="checkbox" disabled checked> done"#))
    }

    func testBlockquoteBecomesBlockquote() {
        XCTAssertTrue(body("> quoted").contains("<blockquote><p>quoted</p></blockquote>"))
    }

    func testNestedBlockquoteNests() {
        XCTAssertTrue(body("> > deep").contains("<blockquote><blockquote><p>deep</p></blockquote></blockquote>"))
    }

    func testCalloutCarriesKindClassAndTitle() {
        let html = body("> [!WARNING]\n> careful")
        XCTAssertTrue(html.contains(#"<blockquote class="callout callout-warning">"#))
        XCTAssertTrue(html.contains(#"<p class="callout-title">Warning</p>"#))
        XCTAssertTrue(html.contains("careful"))
    }

    func testCalloutUsesCustomTitleWhenGiven() {
        XCTAssertTrue(body("> [!NOTE] Heads up\n> body").contains(#"<p class="callout-title">Heads up</p>"#))
    }

    func testTableEmitsHeaderBodyAndAlignment() {
        let html = body("| a | b |\n| :-- | --: |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<thead>"))
        XCTAssertTrue(html.contains(#"<th style="text-align:left">a</th>"#))
        XCTAssertTrue(html.contains(#"<th style="text-align:right">b</th>"#))
        XCTAssertTrue(html.contains("<tbody>"))
        XCTAssertTrue(html.contains(#"<td style="text-align:left">1</td>"#))
    }

    func testFencedCodeCarriesLanguageClassAndIsEscaped() {
        let html = body("```swift\nlet a = b < c\n```")
        XCTAssertTrue(html.contains(#"<pre><code class="language-swift">"#))
        XCTAssertTrue(html.contains("let a = b &lt; c"))
        XCTAssertFalse(html.contains("b < c"))
    }

    func testFencedCodeWithoutLanguageOmitsClass() {
        XCTAssertTrue(body("```\nx\n```").contains("<pre><code>"))
    }

    func testFencedCodeIsNotInlineParsed() {
        XCTAssertTrue(body("```\n**not bold**\n```").contains("**not bold**"))
    }

    func testHorizontalRuleBecomesHR() {
        XCTAssertTrue(body("a\n\n---\n\nb").contains("<hr>"))
    }

    func testOwnLineImageKeepsPathExactly() {
        XCTAssertTrue(body("![d](images/a.png)").contains(#"<img src="images/a.png" alt="d">"#))
    }

    func testRelativePathIsNeverRewritten() {
        // The single most important guarantee: what the user wrote is what comes out, with no
        // resolution against any document directory and no data: inlining.
        let html = body("![d](../shared/pic.png)")
        XCTAssertTrue(html.contains(#"src="../shared/pic.png""#))
        XCTAssertFalse(html.contains("data:"))
    }

    func testNoUnescapedAngleBracketSurvivesFromSourceText() {
        XCTAssertFalse(body("a < b and 3 > 2").contains("a < b"))
    }

    // MARK: Document shell

    func testHTMLHasDoctypeCharsetAndTitle() {
        let html = MarkdownHTMLRenderer.html(for: "# Hi", title: "My Notes", generatedImage: { _ in nil })
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains(#"<meta charset="utf-8">"#))
        XCTAssertTrue(html.contains("<title>My Notes</title>"))
        XCTAssertTrue(html.contains("<h1>Hi</h1>"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }

    func testTitleIsEscaped() {
        let html = MarkdownHTMLRenderer.html(for: "", title: "A & B <c>", generatedImage: { _ in nil })
        XCTAssertTrue(html.contains("<title>A &amp; B &lt;c&gt;</title>"))
    }

    func testShellEmbedsStylesAndReferencesNothingExternal() {
        let html = MarkdownHTMLRenderer.html(for: "# Hi", title: "t", generatedImage: { _ in nil })
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertFalse(html.contains("<link"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testMathEmbedsProvidedImageBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let html = MarkdownHTMLRenderer.html(for: "$$x^2$$", title: "t", generatedImage: { image in
            guard case .math = image else { return nil }
            return png
        })
        XCTAssertTrue(html.contains("data:image/png;base64,\(png.base64EncodedString())"))
        XCTAssertTrue(html.contains(#"alt="x^2""#))
    }

    func testMultiLineAltTextNeverBreaksTheAttribute() {
        // Regression: a mermaid source used as `alt` carried its raw newlines straight into the
        // attribute, splitting `alt="graph TD;` across real lines in the exported file.
        let html = MarkdownHTMLRenderer.html(
            for: "```mermaid\ngraph TD;\nA-->B;\n```",
            title: "t",
            generatedImage: { _ in Data([0x89]) }
        )
        let imgLine = html.components(separatedBy: "\n").first { $0.contains("<img") }
        XCTAssertNotNil(imgLine)
        XCTAssertTrue(imgLine?.hasSuffix("</p>") == true, "alt attribute split across lines: \(html)")
        XCTAssertTrue(html.contains("&#10;"))
    }

    func testAttributeEscapingEncodesNewlinesButTextDoesNot() {
        XCTAssertEqual(MarkdownHTMLRenderer.escapeAttribute("a\nb"), "a&#10;b")
        XCTAssertEqual(MarkdownHTMLRenderer.escape("a\nb"), "a\nb")
    }

    func testMermaidFallsBackToSourceWhenProviderDeclines() {
        let html = MarkdownHTMLRenderer.html(
            for: "```mermaid\ngraph TD;\n```",
            title: "t",
            generatedImage: { _ in nil }
        )
        XCTAssertTrue(html.contains("graph TD;"))
        XCTAssertFalse(html.contains("data:"))
    }
}
