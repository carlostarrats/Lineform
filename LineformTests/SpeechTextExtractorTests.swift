import XCTest
@testable import Lineform

final class SpeechTextExtractorTests: XCTestCase {
    func testStripsInlineEmphasisAndCodeMarkers() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("**bold** and _italic_ and `code`"),
                       "bold and italic and code")
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("a ~~struck~~ word"), "a struck word")
    }

    // Read-aloud shares the emphasis rules, so it must not swallow the underscores in a
    // filename and say "maketestfile".
    func testKeepsUnderscoresInsideAWord() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("run make_test_file now"),
                       "run make_test_file now")
    }

    func testStripsSingleAsteriskEmphasis() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("an *emphasised* word"),
                       "an emphasised word")
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("2 * 3 * 4"), "2 * 3 * 4")
    }

    func testStripsLinkToDisplayTextAndImageToAlt() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("see [the docs](https://x.com)"),
                       "see the docs")
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("![a diagram](img.png) here"),
                       "a diagram here")
    }

    func testStripsNestedInlineMarkers() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("**[a](b)**"), "a")
    }

    func testImageWithEmptyAltFallsBackToFilename() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("![](photos/cat.png)"), "cat.png")
    }

    func testHeadingReadsTitleWithoutHashes() {
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "# Hello World"), "Hello World")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "### A **bold** section"), "A bold section")
    }

    func testParagraphsBecomeSeparateSpokenUnits() {
        let md = "First line.\nSecond line."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "First line.\nSecond line.")
    }

    func testFencedCodeIsSkipped() {
        let md = "Before.\n```swift\nlet x = 1\nprint(x)\n```\nAfter."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Before.\nAfter.")
    }

    func testBlockMathIsSkipped() {
        let md = "Intro.\n$$\n\\int x\\,dx\n$$\nOutro."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Intro.\nOutro.")
    }

    func testSingleLineMathIsSkipped() {
        let md = "Intro.\n$$E = mc^2$$\nOutro."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Intro.\nOutro.")
    }

    func testMermaidIsSkipped() {
        let md = "Intro.\n```mermaid\nflowchart TD\nA-->B\n```\nOutro."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Intro.\nOutro.")
    }

    func testHorizontalRuleIsSkipped() {
        let md = "Above.\n\n---\n\nBelow."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Above.\nBelow.")
    }

    func testListItemsAreReadAsPlainText() {
        let md = "- first item\n- **second** item\n1. numbered one"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md),
                       "first item\nsecond item\nnumbered one")
    }

    func testCheckboxItemsReadTextWithoutMarker() {
        let md = "- [ ] todo one\n- [x] done two"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "todo one\ndone two")
    }

    func testBlockquoteIsRead() {
        let md = "> quoted wisdom\n> more of it"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "quoted wisdom\nmore of it")
    }

    func testCalloutMarkerIsDropped() {
        let md = "> [!NOTE] Remember this\n> and this"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Remember this\nand this")
    }

    func testTableIsReadCellByCell() {
        let md = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n| Alan | 41 |"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md),
                       "Name, Age\nAda, 36\nAlan, 41")
    }

    func testEmptyDocumentProducesEmptyString() {
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: ""), "")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "   \n\n  "), "")
    }

    // MARK: - Cases added for enum cases that grew since the brief was written
    // (.fencedCode, .callout, .image are now distinct MarkdownBlock cases; the brief's
    // "fenced code lives inside .lines" assumption is stale — markdownBlocks now routes
    // plain code fences to their own .fencedCode block before .lines ever sees them.)

    func testBareCalloutMarkerWithNoTitleEmitsNothingForThatLine() {
        let md = "> [!NOTE]\n> body only"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "body only")
    }

    func testStandaloneImageBlockReadsAltText() {
        let md = "Before.\n![a lovely diagram](diagram.png)\nAfter."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Before.\na lovely diagram\nAfter.")
    }

    func testUnknownCalloutTokenIsSpokenVerbatim() {
        // An unrecognized `[!type]` degrades to an ordinary blockquote and renders the token
        // literally, so speech must read it verbatim rather than silently dropping it.
        let md = "> [!UNKNOWN] hello there"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "[!UNKNOWN] hello there")
    }

    func testStandaloneImageBlockWithNoAltReadsFilename() {
        let md = "![](photos/cat.png)"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "cat.png")
    }
}
