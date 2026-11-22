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

    /// Non-empty lines of the extracted text, `\r` dropped first: a CRLF printed as two breaks
    /// would double them.
    private func nonEmptyLines(_ string: String?) -> [String] {
        (string ?? "").replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func testCRLFDocumentExportsSameTextAsLF() throws {
        let lf = "# Title\n\nA paragraph with **bold**.\n\n```\nlet a = 1\nlet b = 2\nlet c = 3\n```\n\n- one\n- two\n\nThe end."
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let bomCRLF = "\u{FEFF}" + crlf
        for preset in [ExportTypographyPreset.standard, .styled] {
            let lfDocument = try pdf(lf, preset: preset)
            let lfText = collapsed(lfDocument.string)
            XCTAssertFalse(lfText.isEmpty)
            for (name, variant) in [("CRLF", crlf), ("BOM + CRLF", bomCRLF)] {
                let document = try pdf(variant, preset: preset)
                XCTAssertEqual(document.pageCount, lfDocument.pageCount, "\(preset.id) \(name): page count")
                XCTAssertEqual(nonEmptyLines(document.string), nonEmptyLines(lfDocument.string),
                               "\(preset.id) \(name): the lines differ (doubled, or merged)")
                XCTAssertFalse((document.string ?? "").contains("\u{FEFF}"), "\(preset.id) \(name): a BOM was printed")
                XCTAssertEqual(collapsed(document.string), lfText, "\(preset.id) \(name): printed different text")
            }
        }
        // Styled: the fenced block is three lines of code, not one block swallowing the rest.
        let styledLines = nonEmptyLines(try pdf(bomCRLF, preset: .styled).string)
        for code in ["let a = 1", "let b = 2", "let c = 3"] {
            XCTAssertTrue(styledLines.contains(code), "\(code) is not a line of its own: \(styledLines)")
        }
        XCTAssertTrue(styledLines.contains("The end."), "the text after the fence is not prose: \(styledLines)")
    }

    // MARK: - Pages taller than the page

    /// A top-down chain of `nodes` nodes: far taller than an A5 page once scaled to its width.
    private func tallDiagram(nodes: Int = 30) -> String {
        "```mermaid\ngraph TD\n" + (0..<(nodes - 1)).map { "  N\($0)[Step \($0)] --> N\($0 + 1)[Step \($0 + 1)]" }
            .joined(separator: "\n") + "\n```"
    }

    /// The render really holds a picture taller than the page, so the tests below test C1.
    private func assertHasAttachmentTallerThanPage(_ text: String, paper: ExportPaperSize,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let rendered = PhonePDFRenderer.attributedString(text: text, profile: .original, paper: paper, preset: .styled, documentDirectory: nil)
        var tallest: CGFloat = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            tallest = max(tallest, (value as? NSTextAttachment)?.bounds.height ?? 0)
        }
        XCTAssertGreaterThan(tallest, paper.contentSize(preset: .styled).height,
                             "the diagram did not render taller than the page", file: file, line: line)
    }

    /// No page draws into its bottom margin: a picture taller than the page would run past it.
    private func assertNothingInBottomMargin(_ document: PDFDocument, file: StaticString = #filePath, line: UInt = #line) throws {
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let height = page.bounds(for: .mediaBox).height
            let scan = try PhoneRasterInk(thumbnail(page, scale: 1))
            let last = try XCTUnwrap(scan.lastInkRow, "page \(index) is blank", file: file, line: line)
            XCTAssertLessThanOrEqual(CGFloat(last) * height / CGFloat(scan.height), height - 72 + 1,
                                     "page \(index) draws into its bottom margin: a picture was cut off", file: file, line: line)
        }
    }

    func testTallDiagramFirstKeepsTheRestOfTheDocument() throws {
        let text = tallDiagram() + "\n\nEND-MARKER after the diagram."
        assertHasAttachmentTallerThanPage(text, paper: .a5)
        let document = try pdf(text, preset: .styled, paper: .a5)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("END-MARKER"), "the text after a page-tall first diagram was dropped: \(last)")
        try assertNothingInBottomMargin(document)
    }

    func testTallDiagramMidDocumentKeepsTheRestOfTheDocument() throws {
        let text = "An opening paragraph.\n\n" + tallDiagram() + "\n\nEND-MARKER after the diagram.\n\nAnd a closing one."
        assertHasAttachmentTallerThanPage(text, paper: .a5)
        let document = try pdf(text, preset: .styled, paper: .a5)
        let all = collapsed(document.string)
        XCTAssertTrue(all.contains("An opening paragraph."), all)
        XCTAssertTrue(all.contains("END-MARKER after the diagram."), "the text after the diagram was dropped: \(all)")
        XCTAssertTrue(all.contains("And a closing one."), "the end of the document was dropped: \(all)")
        try assertNothingInBottomMargin(document)
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

    private let page = CGSize(width: 468, height: 648)

    /// The pages' characters run through the document once: no gap, no overlap, nothing left.
    private func assertCoversOnce(_ layout: PhonePageLayout, length: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var next = 0
        for range in layout.pageCharacterRanges {
            XCTAssertEqual(range.location, next, "a gap or an overlap before page character \(range.location)", file: file, line: line)
            next = NSMaxRange(range)
        }
        XCTAssertEqual(next, length, "characters \(next)..<\(length) are on no page", file: file, line: line)
    }

    /// Draws every page into a PDF.
    private func draw(_ layout: PhonePageLayout) throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: page.width + 144, height: page.height + 144)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<layout.pageCount {
                context.beginPage()
                layout.drawPage(index, contentOrigin: CGPoint(x: 72, y: 72))
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    func testPageLayoutDrawsEveryGlyphOnce() throws {
        let text = (1...200).map { "Line \($0) of the layout." }.joined(separator: "\n")
        let attributed = ExportContent.rawSource(text: text, preset: .standard)
        let layout = try XCTUnwrap(PhonePageLayout(attributed: attributed, pageContentSize: page))
        XCTAssertGreaterThan(layout.pageCount, 1)
        assertCoversOnce(layout, length: attributed.length)

        let empty = try XCTUnwrap(PhonePageLayout(attributed: NSAttributedString(string: ""), pageContentSize: page))
        XCTAssertEqual(empty.pageCount, 1, "an empty document still exports one page")
        assertCoversOnce(empty, length: 0)
    }

    /// A line taller than the page that is not a picture (so it is not scaled before
    /// pagination): it gets a page of its own, drawn scaled down, and the text goes on after it.
    private func hugeLine() -> NSAttributedString {
        NSAttributedString(string: "W\n", attributes: [.font: UIFont.systemFont(ofSize: 1_500)])
    }

    func testLineTallerThanThePageMidDocumentGetsItsOwnPage() throws {
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let attributed = NSMutableAttributedString(string: "Before the tall line.\n", attributes: body)
        attributed.append(hugeLine())
        attributed.append(NSAttributedString(string: "END-MARKER after it.", attributes: body))
        let layout = try XCTUnwrap(PhonePageLayout(attributed: attributed, pageContentSize: page))
        XCTAssertEqual(layout.pageCount, 3)
        assertCoversOnce(layout, length: attributed.length)
        XCTAssertLessThan(layout.scale(ofPage: 1), 1, "the tall line is drawn scaled down")
        XCTAssertEqual(layout.scale(ofPage: 2), 1)

        let document = try draw(layout)
        XCTAssertTrue(try XCTUnwrap(document.page(at: 0)?.string).contains("Before the tall line."))
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)?.string).contains("W"), "the tall line is drawn")
        XCTAssertTrue(try XCTUnwrap(document.page(at: 2)?.string).contains("END-MARKER"), "the text after it is drawn")
    }

    func testLineTallerThanThePageFirstKeepsTheDocument() throws {
        let attributed = NSMutableAttributedString(attributedString: hugeLine())
        attributed.append(NSAttributedString(string: "END-MARKER after it.", attributes: [.font: UIFont.systemFont(ofSize: 12)]))
        let layout = try XCTUnwrap(PhonePageLayout(attributed: attributed, pageContentSize: page))
        XCTAssertEqual(layout.pageCount, 2)
        assertCoversOnce(layout, length: attributed.length)
        XCTAssertLessThan(layout.scale(ofPage: 0), 1, "the tall line is drawn scaled down")
        let document = try draw(layout)
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)?.string).contains("END-MARKER"))
    }

    func testTallPictureIsScaledToThePageBeforePagination() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 2_000)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 2_000))
        }
        let attachment = BlockRenderedAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: 100, height: 2_000)
        let original = NSMutableAttributedString(attachment: attachment)
        original.append(NSAttributedString(string: "\nEND-MARKER"))
        let fitted = PhonePageLayout.fittingAttachments(of: original, to: page)
        let scaled = try XCTUnwrap(fitted.attribute(.attachment, at: 0, effectiveRange: nil) as? BlockRenderedAttachment)
        XCTAssertLessThanOrEqual(scaled.bounds.height, page.height * PhonePageLayout.attachmentHeightFraction + 0.5)
        XCTAssertEqual(scaled.bounds.width / scaled.bounds.height, 100.0 / 2_000.0, accuracy: 0.001, "the aspect is kept")
        XCTAssertEqual(attachment.bounds.height, 2_000, "the original string is never changed")

        let layout = try XCTUnwrap(PhonePageLayout(attributed: original, pageContentSize: page))
        assertCoversOnce(layout, length: original.length)
        XCTAssertEqual(layout.pageCount, 1, "the fitted picture and the line after it share the page")
    }

    func testDocumentPastThePageCapFailsInsteadOfTruncating() throws {
        let text = (1...200).map { "Line \($0) of the layout." }.joined(separator: "\n")
        let attributed = ExportContent.rawSource(text: text, preset: .standard)
        XCTAssertNil(PhonePageLayout(attributed: attributed, pageContentSize: page, maximumPageCount: 2),
                     "a document that needs more pages than the cap is not cut short")
    }

    // MARK: - Appearance

    /// Raw RGBA bytes of a page, for an exact comparison.
    private func pixels(_ document: PDFDocument) throws -> [UInt8] {
        let pdfPage = try XCTUnwrap(document.page(at: 0))
        let cgImage = try XCTUnwrap(thumbnail(pdfPage, scale: 1).cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    /// An export made while the app is in Dark Mode is the same white page with the same inks:
    /// a link's dynamic colour resolves in the light appearance.
    func testDarkModeDoesNotChangeTheExport() throws {
        let text = "A [link to somewhere](https://example.com) and ![a missing picture](nowhere.png) and `code`."
        var light: Data?
        var dark: Data?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            light = PhonePDFRenderer.pdfData(text: text, profile: .original, paper: .usLetter, preset: .styled, documentDirectory: nil)
        }
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            dark = PhonePDFRenderer.pdfData(text: text, profile: .original, paper: .usLetter, preset: .styled, documentDirectory: nil)
        }
        let lightDocument = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(light)))
        let darkDocument = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(dark)))
        let same = try pixels(darkDocument) == pixels(lightDocument)
        XCTAssertTrue(same, "the Dark Mode export differs from the light one")
    }
}

