import XCTest
@testable import Lineform

final class LargeDocumentPerformanceTests: XCTestCase {
    func testLargeDocumentStatisticsAndOutlineStayPredictable() {
        let text = (1...1_000)
            .map { index in index.isMultiple(of: 50) ? "## Section \(index)\nBody text for section \(index)." : "Body text for line \(index)." }
            .joined(separator: "\n")

        let stats = DocumentStatistics(text: text)
        let outlineItems = MarkdownOutlineParser().items(in: text)

        XCTAssertGreaterThan(stats.wordCount, 4_000)
        XCTAssertEqual(outlineItems.count, 20)
    }

    @MainActor
    func testLargeDocumentHighlightingPreservesSourceText() {
        let text = (1...700)
            .map { index in index.isMultiple(of: 12) ? "### Heading \(index)\n- **Important** item \(index)" : "Paragraph with _emphasis_ and `code` \(index)." }
            .joined(separator: "\n")
        let textView = LineformTextView()
        textView.string = text

        textView.refreshMarkdownHighlighting()

        XCTAssertEqual((textView.string as NSString).length, (text as NSString).length)
        XCTAssertTrue(textView.string.contains("### Heading 12"))
        XCTAssertTrue(textView.string.contains("Paragraph with _emphasis_ and `code` 699."))
    }
}
