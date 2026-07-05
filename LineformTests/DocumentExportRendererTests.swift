import AppKit
import XCTest
@testable import Lineform

/// Pure, print-free coverage of the export renderer — runs in the DEFAULT plan.
///
/// The tests that actually invoke `NSPrintOperation` to produce PDF bytes live in
/// `DocumentExportPDFHostedTests` (hosted plan). The OS print subsystem has a
/// nondeterministic cold-start latency (the `kCPLCopyDefaultPrinter` lookup can hang for
/// minutes the first time it is contacted in a fresh sandboxed process), which is exactly the
/// kind of environment sensitivity the hosted plan exists to quarantine — so it is kept out of
/// the "runs in seconds" default suite. Everything here is deterministic value/render logic.
@MainActor
final class DocumentExportRendererTests: XCTestCase {

    // MARK: - Paper metrics

    func testPaperSizesInPoints() {
        XCTAssertEqual(ExportPaperSize.usLetter.sizeInPoints, NSSize(width: 612, height: 792))
        XCTAssertEqual(ExportPaperSize.a4.sizeInPoints, NSSize(width: 595, height: 842))
    }

    func testContentSizeIsPaperMinusMargins() {
        let margin = DocumentExportRenderer.margin
        let letter = DocumentExportRenderer.contentSize(for: .usLetter)
        XCTAssertEqual(letter.width, 612 - margin * 2)
        XCTAssertEqual(letter.height, 792 - margin * 2)

        let a4 = DocumentExportRenderer.contentSize(for: .a4)
        XCTAssertEqual(a4.width, 595 - margin * 2)
        XCTAssertEqual(a4.height, 842 - margin * 2)
    }

    // MARK: - White-page forcing via the export profile

    func testExportProfileForcesSystemThemeAndDropsHighContrast() {
        var source = ReadingProfile.original
        source.themeID = .night
        source.highContrastEnabled = true

        let exported = DocumentExportRenderer.exportProfile(from: source)

        XCTAssertEqual(exported.themeID, .system)
        XCTAssertFalse(exported.highContrastEnabled)
    }

    func testExportProfileFixesBodySizeButKeepsFaceAndRhythm() {
        var source = ReadingProfile.original
        source.themeID = .night
        source.highContrastEnabled = true
        source.fontID = .newYork
        source.fontSize = 21
        source.lineHeightMultiple = 1.7
        source.paragraphSpacing = 13
        source.letterSpacing = 1.5

        let exported = DocumentExportRenderer.exportProfile(from: source)

        // Body size is fixed for print (a shared/saved artifact reads at a standard document
        // size, not the on-screen reading size).
        XCTAssertEqual(exported.fontSize, DocumentExportRenderer.bodyPointSize)
        // Face and rhythm are kept.
        XCTAssertEqual(exported.fontID, .newYork)
        XCTAssertEqual(exported.lineHeightMultiple, 1.7)
        XCTAssertEqual(exported.paragraphSpacing, 13)
        XCTAssertEqual(exported.letterSpacing, 1.5)
    }

    func testExportProfileResolvesToWhitePageWithDarkInk() {
        var source = ReadingProfile.original
        source.themeID = .night
        source.highContrastEnabled = true

        let theme = Theme.theme(for: DocumentExportRenderer.exportProfile(from: source))
        let bg = theme.backgroundColor.usingColorSpace(.sRGB)!
        let ink = theme.textColor.usingColorSpace(.sRGB)!

        // White page.
        XCTAssertEqual(bg.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(bg.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(bg.blueComponent, 1, accuracy: 0.01)
        // Near-black ink (the app's #1F1F1F primary text), NOT the night theme's light text.
        XCTAssertLessThan(ink.redComponent, 0.2)
        XCTAssertLessThan(ink.greenComponent, 0.2)
        XCTAssertLessThan(ink.blueComponent, 0.2)
    }

    func testRenderedExportTextUsesDarkInkEvenFromADarkProfile() {
        var source = ReadingProfile.original
        source.themeID = .night
        source.highContrastEnabled = true

        let attributed = MarkdownPreviewRenderer().render(
            "Hello export world.",
            profile: DocumentExportRenderer.exportProfile(from: source)
        )
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let ink = try! XCTUnwrap(color).usingColorSpace(.sRGB)!
        XCTAssertLessThan(ink.redComponent, 0.2)
        XCTAssertLessThan(ink.greenComponent, 0.2)
        XCTAssertLessThan(ink.blueComponent, 0.2)
    }

    // MARK: - Export text view (rich render, no printing)

    func testExportTextViewRendersDocumentOnAWhitePageAtContentWidth() {
        let view = DocumentExportRenderer.makeExportTextView(
            text: "# Export Heading\n\nBody paragraph text.",
            profile: .original,
            paper: .usLetter
        )

        let contents = view.textStorage?.string ?? ""
        XCTAssertTrue(contents.contains("Export Heading"), "Heading text should be rendered (marker stripped).")
        XCTAssertTrue(contents.contains("Body paragraph text."))

        // The page is painted white by ExportTextView.draw (NSTextView's own background is not
        // carried into the print context), so drawsBackground is off and white is drawn.
        XCTAssertFalse(view.drawsBackground)
        let rendered = renderToImage(view)
        // Sample a blank lower-right region (the short doc's text sits at the top).
        let corner = pixel(in: rendered, atFraction: (0.85, 0.9))
        XCTAssertEqual(corner.red, 1, accuracy: 0.02, "Content area should paint white.")
        XCTAssertEqual(corner.green, 1, accuracy: 0.02)
        XCTAssertEqual(corner.blue, 1, accuracy: 0.02)

        XCTAssertEqual(view.frame.width, DocumentExportRenderer.contentSize(for: .usLetter).width, accuracy: 0.5)
    }

    func testFitColumnPercentagesAreProportionalAndFitUnderFullWidth() {
        let rows: [(cells: [String], isHeader: Bool)] = [
            (["Construct", "Read", "PDF", "Align"], true),
            (["A very long construct name", "y", "y", "left"], false)
        ]
        let pct = MarkdownPreviewRenderer.fitColumnPercentages(rows: rows, columns: 4)

        XCTAssertEqual(pct.count, 4)
        // Sum stays under 100% so per-cell padding/borders don't push the table off the page.
        XCTAssertLessThanOrEqual(pct.reduce(0, +), 90)
        // The widest column (the long construct name) gets the most width.
        XCTAssertEqual(pct.firstIndex(of: pct.max()!), 0)
        // No column collapses to zero.
        XCTAssertTrue(pct.allSatisfy { $0 > 0 })
    }

    // Draws a view into a bitmap so a pixel can be sampled (used to assert the white page fill).
    private func renderToImage(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func pixel(in rep: NSBitmapImageRep, atFraction f: (x: CGFloat, y: CGFloat)) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let x = Int(CGFloat(rep.pixelsWide) * f.x)
        let y = Int(CGFloat(rep.pixelsHigh) * f.y)
        let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return (color?.redComponent ?? 0, color?.greenComponent ?? 0, color?.blueComponent ?? 0)
    }
}

/// PDF-byte generation via `NSPrintOperation` — HOSTED plan only (see the class note above and
/// `CLAUDE.md`'s hosted-plan section). Quarantined because the print subsystem's cold start is
/// environment-sensitive, not because these tests are unreliable in themselves.
@MainActor
final class DocumentExportPDFHostedTests: XCTestCase {

    func testPDFDataIsAValidPDF() {
        let data = DocumentExportRenderer.pdfData(
            text: "# Title\n\nPortable **Markdown** with a list:\n\n- one\n- two\n",
            profile: .original,
            paper: .usLetter
        )
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(data.count, 100)
    }

    func testPDFPaginatesLongDocuments() throws {
        let longText = (1...400)
            .map { "Line \($0): Lineform keeps Markdown files portable across normal file tools." }
            .joined(separator: "\n\n")
        let data = DocumentExportRenderer.pdfData(text: longText, profile: .original, paper: .usLetter)

        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertGreaterThan(pdf.numberOfPages, 1)
    }

    func testAllPaperSizesProduceValidPDFs() {
        for paper in ExportPaperSize.allCases {
            let data = DocumentExportRenderer.pdfData(text: "# Heading\n\nBody text.", profile: .original, paper: paper)
            XCTAssertTrue(data.starts(with: Data("%PDF".utf8)), "\(paper.displayName) should produce a PDF")
        }
    }

}
