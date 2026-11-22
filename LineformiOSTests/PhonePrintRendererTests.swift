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

    private func renderer(_ text: String, paper: ExportPaperSize = .usLetter, directory: URL? = nil) -> PhonePrintRenderer {
        PhonePrintRenderer(text: text, profile: .original, paper: paper, documentDirectory: directory)
    }

    /// Every page drawn into a PDF of the renderer's current paper, as the print system does.
    private func printed(_ printer: PhonePrintRenderer) throws -> PDFDocument {
        let pages = printer.numberOfPages
        let data = UIGraphicsPDFRenderer(bounds: printer.paperRect).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                printer.drawPage(at: index, in: printer.printableRect)
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
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
        let a5 = renderer(longText, paper: .a5)
        setPaper(ExportPaperSize.a5.sizeInPoints, on: a5)

        XCTAssertGreaterThan(letter.numberOfPages, 1)
        XCTAssertGreaterThan(a5.numberOfPages, letter.numberOfPages, "a smaller sheet takes more pages")
    }

    func testReflowsWhenPaperChanges() async {
        let printer = renderer(longText)
        // The panel is up: every other sheet's render follows on main.
        await printer.renderRemainingSheets()
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

    // MARK: - Threading

    /// The print system calls `numberOfPages` and `drawPage` on its own threads (observed under
    /// the print panel: `UIPrintPreviewViewController.updatePageCountThread` and an unnamed
    /// drawing thread), possibly while main waits on it. Both must finish without the main thread.
    func testCountsAndDrawsOffMainWhileMainWaits() throws {
        let printer = renderer(longText)
        setPaper(ExportPaperSize.usLetter.sizeInPoints, on: printer)
        final class Box: @unchecked Sendable {
            var pages = 0
            var wasMain = true
            var data = Data()
        }
        let box = Box()
        nonisolated(unsafe) let unsafePrinter = printer
        let paper = CGRect(origin: .zero, size: ExportPaperSize.usLetter.sizeInPoints)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.wasMain = Thread.isMainThread
            box.pages = unsafePrinter.numberOfPages
            box.data = UIGraphicsPDFRenderer(bounds: paper).pdfData { context in
                for index in 0..<box.pages {
                    context.beginPage()
                    unsafePrinter.drawPage(at: index, in: paper)
                }
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        // Main blocks here, as it may while the panel waits on the print system: a hop to main
        // from the print thread would never return.
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success, "counting or drawing waited on the main thread")
        XCTAssertFalse(box.wasMain)
        XCTAssertGreaterThan(box.pages, 1)
        let document = try XCTUnwrap(PDFDocument(data: box.data))
        XCTAssertEqual(document.pageCount, box.pages)
        XCTAssertTrue(try XCTUnwrap(document.page(at: box.pages - 1)?.string).contains("Paragraph 200"))
    }

    // MARK: - Sheets

    /// A landscape A4 page is 451 pt tall, shorter than a picture the portrait render allows:
    /// the picture is scaled to the page, and the text after it still prints.
    func testLandscapePrintWithTallImageKeepsTextAfterIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 1_500)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 1_500))
        }
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("tall.png"))
        let text = "An opening line.\n\n![A tall picture](tall.png)\n\nEND-MARKER after the picture."

        // The render's picture really is taller than the landscape page.
        let rendered = PhonePDFRenderer.attributedString(text: text, profile: .original, paper: .a4, preset: .styled, documentDirectory: folder)
        var tallest: CGFloat = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            tallest = max(tallest, (value as? NSTextAttachment)?.bounds.height ?? 0)
        }
        XCTAssertGreaterThan(tallest, 595 - 144, "the picture is not taller than a landscape A4 page")

        let printer = renderer(text, paper: .a4, directory: folder)
        setPaper(CGSize(width: 842, height: 595), on: printer)
        let document = try printed(printer)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("END-MARKER"), "printing stopped at the picture: \(last)")
        // And the picture is whole: no page draws into its bottom margin.
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let scan = try PhoneRasterInk(page.thumbnail(of: CGSize(width: 842, height: 595), for: .mediaBox))
            let lastRow = try XCTUnwrap(scan.lastInkRow, "page \(index) is blank")
            XCTAssertLessThanOrEqual(CGFloat(lastRow) * 595 / CGFloat(scan.height), 595 - 72 + 1,
                                     "page \(index) draws into its bottom margin: the picture was cut off")
        }
    }

    /// Paper narrower than every offered sheet (a 4×6 photo, 144 pt of content): the page is
    /// drawn scaled down, so a fitted table never runs past the right margin.
    func testPaperSmallerThanEverySheetStaysInsideTheMargin() throws {
        let header = "| " + (1...6).map { "Heading \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: 6)
        let row = "| " + (1...6).map { "Cell value \($0)" }.joined(separator: " | ") + " |"
        let printer = renderer([header, rule, row, row, "", "END-MARKER"].joined(separator: "\n"), paper: .a4)
        let size = CGSize(width: 288, height: 432)
        setPaper(size, on: printer)
        XCTAssertEqual(printer.contentRect.width, 144)
        let document = try printed(printer)
        XCTAssertTrue(collapsed(document.string).contains("END-MARKER"))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = try PhoneRasterInk(page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox))
        let rightmost = try XCTUnwrap(scan.rightmostInkColumn, "the page has no ink")
        XCTAssertLessThanOrEqual(CGFloat(rightmost), (288 - 72) * 2 + 1, "ink at column \(rightmost) is past the right margin")
    }

    func testIdealColumnWidthFitsTheRect() {
        let widths = PhonePrintRenderer.columnWidths
        XCTAssertEqual(widths.first, ExportPaperSize.a5.contentSize(preset: .styled).width)
        XCTAssertEqual(PhonePrintRenderer.idealColumnWidth(forContentWidth: 468), 468, "Letter")
        XCTAssertEqual(PhonePrintRenderer.idealColumnWidth(forContentWidth: 460), 451, "a little narrower than Letter: A4")
        XCTAssertEqual(PhonePrintRenderer.idealColumnWidth(forContentWidth: 144), widths.first, "narrower than every sheet: the narrowest")
        XCTAssertEqual(PhonePrintRenderer.representative(forColumnWidth: 468), .usLetter)
    }

    private func collapsed(_ string: String?) -> String {
        (string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func testPrintInfo() {
        let info = PhonePrintRenderer.printInfo(jobName: "Notes")
        XCTAssertEqual(info.outputType, .general)
        XCTAssertEqual(info.jobName, "Notes")
    }
}

