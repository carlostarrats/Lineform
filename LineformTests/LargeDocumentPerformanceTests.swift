import AppKit
import XCTest
@testable import Lineform

final class LargeDocumentPerformanceTests: XCTestCase {
    func testLargeDocumentStatisticsAndOutlineStayPredictable() {
        let text = Self.statisticsAndOutlineDocument

        let stats = DocumentStatistics(text: text)
        let outlineItems = MarkdownOutlineParser().items(in: text)

        XCTAssertGreaterThan(stats.wordCount, 4_000)
        XCTAssertEqual(outlineItems.count, 20)
    }

    func testLargePreviewRenderingPreservesExpectedMarkdownOutput() {
        let text = Self.previewDocument

        let rendered = MarkdownPreviewRenderer().render(text, profile: .original)

        XCTAssertTrue(rendered.string.contains("Section 40"))
        XCTAssertFalse(rendered.string.contains("## Section 40 ##"))
        XCTAssertTrue(rendered.string.contains("Paragraph with bold, emphasis, code, and link 1199."))
    }

    @MainActor
    func testLargeDocumentHighlightingPreservesSourceText() {
        let text = Self.highlightingDocument
        let textView = LineformTextView()
        textView.string = text

        textView.refreshMarkdownHighlighting()

        XCTAssertEqual((textView.string as NSString).length, (text as NSString).length)
        XCTAssertTrue(textView.string.contains("### Heading 12"))
        XCTAssertTrue(textView.string.contains("Paragraph with _emphasis_ and `code` 699."))
    }

    func testBenchmarkLargeDocumentStatistics() {
        let text = Self.statisticsAndOutlineDocument
        var wordCount = 0

        measure(metrics: [XCTClockMetric()]) {
            wordCount = DocumentStatistics(text: text).wordCount
        }

        XCTAssertGreaterThan(wordCount, 4_000)
    }

    func testBenchmarkLargeOutlineParsing() {
        let text = Self.statisticsAndOutlineDocument
        var headingCount = 0

        measure(metrics: [XCTClockMetric()]) {
            headingCount = MarkdownOutlineParser().items(in: text).count
        }

        XCTAssertEqual(headingCount, 20)
    }

    func testBenchmarkLargePreviewRendering() {
        let text = Self.previewDocument
        var renderedLength = 0

        measure(metrics: [XCTClockMetric()]) {
            renderedLength = MarkdownPreviewRenderer().render(text, profile: .original).length
        }

        XCTAssertGreaterThan(renderedLength, 50_000)
    }

    @MainActor
    func testBenchmarkLargeSyntaxHighlighting() {
        let text = Self.highlightingDocument
        let textView = LineformTextView()
        textView.string = text

        measure(metrics: [XCTClockMetric()]) {
            textView.refreshMarkdownHighlighting()
        }

        XCTAssertEqual((textView.string as NSString).length, (text as NSString).length)
    }

    @MainActor
    func testBenchmarkRepeatedLargePreviewApplyForUnchangedContent() {
        let text = Self.previewDocument
        let textView = MarkdownPreviewTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        textView.apply(text: text, profile: .original)
        var renderedLength = 0

        measure(metrics: [XCTClockMetric()]) {
            textView.apply(text: text, profile: .original)
            renderedLength = textView.textStorage?.length ?? 0
        }

        XCTAssertGreaterThan(renderedLength, 50_000)
    }

    private static let statisticsAndOutlineDocument = (1...1_000)
        .map { index in
            index.isMultiple(of: 50)
                ? "## Section \(index)\nBody text for section \(index)."
                : "Body text for line \(index)."
        }
        .joined(separator: "\n")

    private static let previewDocument = (1...1_200)
        .map { index in
            index.isMultiple(of: 40)
                ? "## Section \(index) ##"
                : "Paragraph with **bold**, _emphasis_, `code`, and [link](https://example.com) \(index)."
        }
        .joined(separator: "\n")

    private static let highlightingDocument = (1...700)
        .map { index in
            index.isMultiple(of: 12)
                ? "### Heading \(index)\n- **Important** item \(index)"
                : "Paragraph with _emphasis_ and `code` \(index)."
        }
        .joined(separator: "\n")
}
