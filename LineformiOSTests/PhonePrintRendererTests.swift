import LineformCore
import PDFKit
import UIKit
import XCTest
@testable import LineformiOS

/// Print: the Styled layout, paginated for whatever sheet the print panel currently has, and
/// re-laid when that sheet changes. The print system sets `paperRect` and `printableRect`; the
/// tests set them the same way, with key-value coding.
@MainActor
final class PhonePrintRendererTests: XCTestCase {
    private let longText = (1...200).map { "Paragraph \($0) of a document that is long enough to fill several pages." }
        .joined(separator: "\n\n")

    private func renderer(_ text: String) -> PhonePrintRenderer {
        PhonePrintRenderer(text: text, profile: .original, documentDirectory: nil)
    }

    /// Sets the sheet the way the print system does: the paper, and a printable area inside it
    /// (a typical printer's hardware margin, smaller than the preset's 72 pt).
    private func setPaper(_ size: CGSize, on renderer: PhonePrintRenderer) {
        let paper = CGRect(origin: .zero, size: size)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 18, dy: 18)), forKey: "printableRect")
    }

    func testPageCountFollowsPaper() {
        let letter = renderer(longText)
        setPaper(ExportPaperSize.usLetter.sizeInPoints, on: letter)
        let a5 = renderer(longText)
        setPaper(ExportPaperSize.a5.sizeInPoints, on: a5)

        XCTAssertGreaterThan(letter.numberOfPages, 1)
        XCTAssertGreaterThan(a5.numberOfPages, letter.numberOfPages, "a smaller sheet takes more pages")
    }

    func testReflowsWhenPaperChanges() {
        let printer = renderer(longText)
        setPaper(ExportPaperSize.usLetter.sizeInPoints, on: printer)
        let letterPages = printer.numberOfPages

        setPaper(ExportPaperSize.a5.sizeInPoints, on: printer)
        let a5Pages = printer.numberOfPages

        XCTAssertGreaterThan(a5Pages, letterPages, "the same renderer re-laid out for the new sheet")

        setPaper(ExportPaperSize.usLetter.sizeInPoints, on: printer)
        XCTAssertEqual(printer.numberOfPages, letterPages, "back on Letter, the Letter page count")
    }

    /// The text sits at the preset's 72 pt margins measured from the paper, not at the printer's
    /// smaller hardware margin.
    func testContentRectIsThePresetMarginsInsideThePaper() {
        let printer = renderer(longText)
        setPaper(ExportPaperSize.usLetter.sizeInPoints, on: printer)
        XCTAssertEqual(printer.contentRect, CGRect(x: 72, y: 72, width: 612 - 144, height: 792 - 144))
    }

    func testDrawsIntoPDFContext() throws {
        let printer = renderer("# Title\n\nThe first paragraph of the print.\n\nA second one.")
        let size = ExportPaperSize.usLetter.sizeInPoints
        setPaper(size, on: printer)
        let pages = printer.numberOfPages
        XCTAssertEqual(pages, 1)

        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                printer.drawPage(at: index, in: printer.printableRect)
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let string = try XCTUnwrap(document.string)
        XCTAssertTrue(string.contains("The first paragraph of the print."), string)
        XCTAssertTrue(string.contains("Title"), string)
        XCTAssertFalse(string.contains("#"), "Print is the Styled render, not the source: \(string)")

        // White page: drawn over red, the corner still reads white.
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = try PhoneRasterInk(PhoneRasterInk.renderOnRed(page, scale: 1))
        XCTAssertFalse(scan.isInk(x: 2, y: 2), "the page's corner is not white")
    }

    /// Every value is read before the print system has set a sheet: nothing was left to a stored
    /// default, and an unsized renderer reports no pages instead of crashing.
    func testFactoryHasNoStoredDefaults() {
        let printer = renderer(longText)
        XCTAssertEqual(printer.paperRect, .zero)
        XCTAssertEqual(printer.printableRect, .zero)
        XCTAssertEqual(printer.headerHeight, 0)
        XCTAssertEqual(printer.footerHeight, 0)
        XCTAssertEqual(printer.contentRect, .zero)
        XCTAssertEqual(printer.numberOfPages, 0)
        // Drawing a page that does not exist is a no-op.
        _ = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).pdfData { context in
            context.beginPage()
            printer.drawPage(at: 3, in: .zero)
        }
    }

    func testPrintInfo() {
        let info = PhonePrintRenderer.printInfo(jobName: "Notes")
        XCTAssertEqual(info.outputType, .general)
        XCTAssertEqual(info.jobName, "Notes")
    }
}
