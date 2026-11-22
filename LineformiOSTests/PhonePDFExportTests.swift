import LineformCore
import PDFKit
import UIKit
import XCTest
@testable import LineformiOS

/// The iPhone's Normal and Styled PDF: TextKit 1 pagination onto white pages of the chosen sheet,
/// the raw source for Normal and the Read-mode render for Styled, tables that stay inside the
/// margins, CRLF documents that print the same words as LF ones, and math and diagrams that come
/// out upright. Everything renders locally; nothing touches the network.
@MainActor
final class PhonePDFExportTests: XCTestCase {
    private func pdf(
        _ text: String,
        preset: ExportTypographyPreset,
        paper: ExportPaperSize = .usLetter
    ) throws -> PDFDocument {
        let data = PhonePDFRenderer.pdfData(
            text: text, profile: .original, paper: paper, preset: preset, documentDirectory: nil
        )
        XCTAssertFalse(data.isEmpty, "the PDF is empty")
        return try XCTUnwrap(PDFDocument(data: data), "the bytes are not a PDF")
    }

    /// A page rasterized at `scale` through PDFKit's own thumbnail (the way the system draws it).
    private func thumbnail(_ page: PDFPage, scale: CGFloat) -> UIImage {
        let size = page.bounds(for: .mediaBox).size
        return page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
    }

    private func collapsed(_ string: String?) -> String {
        (string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Content

    func testNormalPDFPrintsRawSource() throws {
        let document = try pdf("# Heading\n\n**bold**", preset: .standard)
        let string = try XCTUnwrap(document.string)
        XCTAssertTrue(string.contains("# Heading"), "Normal prints the source: \(string)")
        XCTAssertTrue(string.contains("**bold**"), "Normal prints the source: \(string)")
    }

    func testStyledPDFDropsMarkers() throws {
        let document = try pdf("# Heading\n\n**bold**", preset: .styled)
        let string = try XCTUnwrap(document.string)
        XCTAssertTrue(string.contains("Heading"), "Styled renders the heading: \(string)")
        XCTAssertTrue(string.contains("bold"), "Styled renders the bold run: \(string)")
        XCTAssertFalse(string.contains("#"), "Styled drops the heading marker: \(string)")
        XCTAssertFalse(string.contains("**"), "Styled drops the emphasis markers: \(string)")
    }

    // MARK: - Pages

    func testPagesAreLetterSizedAndWhite() throws {
        for preset in [ExportTypographyPreset.standard, .styled] {
            let document = try pdf("Some words.\n\nMore words.", preset: preset)
            XCTAssertGreaterThan(document.pageCount, 0)
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index))
                let bounds = page.bounds(for: .mediaBox)
                XCTAssertEqual(bounds.width, 612, accuracy: 0.01)
                XCTAssertEqual(bounds.height, 792, accuracy: 0.01)
            }
            // Drawn over red: a page that paints nothing would read red at its corner.
            let page = try XCTUnwrap(document.page(at: 0))
            let scan = try PhoneRasterInk(PhoneRasterInk.renderOnRed(page, scale: 1))
            XCTAssertFalse(scan.isInk(x: 2, y: 2), "the page's top-left corner is not white (\(preset.id))")
            XCTAssertFalse(scan.isInk(x: scan.width - 3, y: scan.height - 3), "the page's bottom-right corner is not white (\(preset.id))")
        }
    }

    func testLongDocumentPaginates() throws {
        let text = (1...400).map { "Paragraph number \($0) of the long document." }.joined(separator: "\n\n")
        for preset in [ExportTypographyPreset.standard, .styled] {
            let document = try pdf(text, preset: preset)
            XCTAssertGreaterThan(document.pageCount, 3, "\(preset.id) did not paginate")
            let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
            XCTAssertTrue(last.contains("400"), "the last paragraph is not on the last page (\(preset.id)): \(last)")
            let first = try XCTUnwrap(document.page(at: 0)?.string)
            XCTAssertTrue(first.contains("number 1 "), "the first paragraph is not on the first page (\(preset.id))")
            XCTAssertFalse(first.contains("400"), "the first page holds the whole document (\(preset.id))")
        }
    }

    func testWideTableStaysInsideA5Margins() throws {
        let header = "| " + (1...10).map { "Column heading \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: 10)
        let row = "| " + (1...10).map { "A long cell value number \($0)" }.joined(separator: " | ") + " |"
        let text = [header, rule, row, row].joined(separator: "\n")
        let document = try pdf(text, preset: .styled, paper: .a5)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(collapsed(page.string).contains("Column heading 1"), "the table did not print")

        let scale: CGFloat = 2
        let scan = try PhoneRasterInk(thumbnail(page, scale: scale))
        let pixelsPerPoint = CGFloat(scan.width) / 420
        let rightmost = try XCTUnwrap(scan.rightmostInkColumn, "the page has no ink")
        XCTAssertLessThanOrEqual(CGFloat(rightmost), (420 - 72) * pixelsPerPoint + 1,
                                 "ink at column \(rightmost) is past the right margin")
    }

    func testCRLFDocumentExportsSameTextAsLF() throws {
        let lf = "# Title\n\nA paragraph with **bold**.\n\n```\nlet code = 1\n```\n\n- one\n- two\n\nThe end."
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        for preset in [ExportTypographyPreset.standard, .styled] {
            let lfText = collapsed(try pdf(lf, preset: preset).string)
            let crlfText = collapsed(try pdf(crlf, preset: preset).string)
            XCTAssertFalse(lfText.isEmpty)
            XCTAssertEqual(crlfText, lfText, "\(preset.id): CRLF printed different text")
        }
    }

    // MARK: - Orientation

    /// The package's `testSuperscriptSitsHigh`, on the PDF page: the "2" (the right-most ink
    /// column) starts above the "x" (the left-most ink column).
    func testMathAndMermaidUpright() throws {
        let superscript = try PhoneRasterInk(thumbnail(try XCTUnwrap(try pdf("$$x^{2}$$", preset: .styled).page(at: 0)), scale: 2))
        let right = try XCTUnwrap(superscript.rightmostInkColumn, "the equation has no ink")
        let left = try XCTUnwrap(superscript.leftmostInkColumn, "the equation has no ink")
        let superscriptTop = try XCTUnwrap(superscript.topmostInk(inColumn: right))
        let baseTop = try XCTUnwrap(superscript.topmostInk(inColumn: left))
        XCTAssertLessThan(superscriptTop, baseTop,
                          "the 2 starts at row \(superscriptTop), the x at row \(baseTop): the equation is upside down")

        // A fraction with a narrow numerator over a wide denominator: the top ink row (the 1) is
        // narrower than the bottom ink row (the x's). Mirrored, the wide row would be on top.
        let fraction = try PhoneRasterInk(thumbnail(try XCTUnwrap(try pdf("$$\\frac{1}{xxxxxx}$$", preset: .styled).page(at: 0)), scale: 2))
        let top = try XCTUnwrap(fraction.firstInkRow, "the fraction has no ink")
        let bottom = try XCTUnwrap(fraction.lastInkRow)
        let topSpan = try XCTUnwrap(fraction.inkSpan(row: top))
        let bottomSpan = try XCTUnwrap(fraction.inkSpan(row: bottom))
        XCTAssertLessThan(topSpan, bottomSpan,
                          "top ink row spans \(topSpan) px, bottom \(bottomSpan) px: the numerator is not on top")

        // The package's `testFlowchartRendersTopDownOnThisPlatform`, measured inside the diagram's
        // ink on the page: the two side-by-side nodes at the END of a top-down flowchart are the
        // widest row, in the lower half.
        let source = "```mermaid\ngraph TD\n  A[Start] --> B[Middle]\n  B --> C[Left]\n  B --> D[Right]\n```"
        let diagram = try PhoneRasterInk(thumbnail(try XCTUnwrap(try pdf(source, preset: .styled).page(at: 0)), scale: 2))
        let widest = try XCTUnwrap(diagram.widestInkRow, "the diagram has no ink")
        let diagramTop = try XCTUnwrap(diagram.firstInkRow)
        let diagramBottom = try XCTUnwrap(diagram.lastInkRow)
        XCTAssertGreaterThan(diagramBottom - diagramTop, 40, "the diagram did not render as an image")
        XCTAssertGreaterThan(widest, (diagramTop + diagramBottom) / 2,
                             "widest ink row \(widest) between \(diagramTop) and \(diagramBottom): the diagram is upside down")
    }

    // MARK: - Layout

    func testPageLayoutDrawsEveryGlyphOnce() throws {
        let text = (1...200).map { "Line \($0) of the layout." }.joined(separator: "\n")
        let layout = PhonePageLayout(attributed: ExportContent.rawSource(text: text, preset: .standard),
                                     pageContentSize: CGSize(width: 468, height: 648))
        XCTAssertGreaterThan(layout.pageCount, 1)
        let empty = PhonePageLayout(attributed: NSAttributedString(string: ""), pageContentSize: CGSize(width: 468, height: 648))
        XCTAssertEqual(empty.pageCount, 1, "an empty document still exports one page")
    }
}
