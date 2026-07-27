import XCTest
@testable import Lineform

final class ExportFormatTests: XCTestCase {
    func testEachFormatHasADistinctNonEmptyDescription() {
        let descriptions = ExportFormat.allCases.map(\.description)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
        XCTAssertEqual(Set(descriptions).count, ExportFormat.allCases.count)
    }

    func testStyledPDFDescriptionMentionsImages() {
        XCTAssertTrue(ExportFormat.styledPDF.description.lowercased().contains("image"))
    }

    func testNormalPDFDescriptionMentionsSource() {
        XCTAssertTrue(ExportFormat.pdf.description.lowercased().contains("source"))
    }

    func testMarkdownIsNotAnExportFormat() {
        // Markdown is Save As, not Export As. A "markdown" export entry would put two routes on
        // the same file and reintroduce the confusion the split exists to remove.
        XCTAssertFalse(ExportFormat.allCases.map(\.pathExtension).contains("md"))
    }

    func testHTMLFormatUsesHTMLExtensionAndNoPaper() {
        XCTAssertEqual(ExportFormat.html.pathExtension, "html")
        XCTAssertFalse(ExportFormat.html.usesPaper)
    }

    func testOnlyPDFFormatsUsePaper() {
        XCTAssertEqual(ExportFormat.allCases.filter(\.usesPaper), [.pdf, .styledPDF])
    }
}
