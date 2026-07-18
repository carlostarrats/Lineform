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

    // Reviewer-flagged coverage gap: `testExportModeCodeIsMonochrome` (in
    // MarkdownPreviewRendererTests) proves the mechanism (`highlightsCode: false` strips
    // per-token color), but nothing exercised the actual export wiring — the wrapper that
    // Print/Export as PDF call. This drives `makeExportTextView` directly with a fenced code
    // block in a recognized language (swift) that WOULD be multi-colored on screen, and asserts
    // the exported attributed string carries exactly one foreground color over the code body.
    func testExportTextViewCodeBlockIsMonochrome() {
        let view = DocumentExportRenderer.makeExportTextView(
            text: "```swift\nlet x = 42\n```",
            profile: .original,
            paper: .usLetter
        )

        guard let storage = view.textStorage else {
            XCTFail("Export text view should have backing text storage.")
            return
        }
        let full = storage.string as NSString
        let bodyRange = full.range(of: "let x = 42")
        XCTAssertNotEqual(bodyRange.location, NSNotFound, "Code body text should be rendered (fence markers stripped).")

        var colors: Set<NSColor> = []
        storage.enumerateAttribute(.foregroundColor, in: bodyRange, options: []) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        XCTAssertEqual(colors.count, 1, "Exported code body should use a single monochrome ink, not the multi-color CodeSyntaxPalette.")
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

    // Regression: several narrow columns next to one wide column each hit the per-column floor.
    // A plain `max(floor, share)` would add those floors on top of the wide column's full share
    // and push the total past the page column (>100%), clipping the exported table. The
    // reserve-floor-then-distribute formula must keep the sum inside the budget.
    func testFitColumnPercentagesStayUnderBudgetWithManyNarrowColumns() {
        let rows: [(cells: [String], isHeader: Bool)] = [
            (["a", "b", "c", "d", "e"], true),
            (["x", "y", "z", "w", String(repeating: "M", count: 100)], false)
        ]
        let pct = MarkdownPreviewRenderer.fitColumnPercentages(rows: rows, columns: 5)

        XCTAssertEqual(pct.count, 5)
        // Must never exceed the page column, and stays within the padding/border budget.
        XCTAssertLessThanOrEqual(pct.reduce(0, +), 90)
        // The wide last column still dominates; the four narrow ones keep a nonzero floor.
        XCTAssertEqual(pct.firstIndex(of: pct.max()!), 4)
        XCTAssertTrue(pct.allSatisfy { $0 > 0 })
    }

    // MARK: - RTF export (pure serialization, no NSPrintOperation)

    func testRTFDataIsNonEmptyAndReadableRTF() throws {
        let doc = LineformDocument(text: "# Heading\n\nBody paragraph.")
        let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
        XCTAssertFalse(data.isEmpty)
        // RTF documents start with the "{\rtf" control word.
        let prefix = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(prefix, "{\\rtf")
        // Round-trips back into an attributed string.
        let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        XCTAssertTrue(reread.string.contains("Heading"))
        XCTAssertTrue(reread.string.contains("Body paragraph."))
    }

    func testRTFRoundTripPreservesBoldItalicAndInlineCode() throws {
        // Lineform's italic syntax is single underscores (`_italic_`), not asterisks — matching
        // MarkdownPreviewRenderer.italicRegex, not the brief's generic `*italic*` sketch.
        let doc = LineformDocument(text: "This is **bold** and _italic_ and `code` text.")
        let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
        let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))

        func hasTrait(_ trait: NSFontDescriptor.SymbolicTraits, around substring: String) -> Bool {
            let ns = reread.string as NSString
            let r = ns.range(of: substring)
            guard r.location != NSNotFound else { return false }
            var found = false
            reread.enumerateAttribute(.font, in: r) { value, _, _ in
                if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(trait) { found = true }
            }
            return found
        }
        XCTAssertTrue(hasTrait(.bold, around: "bold"), "bold run survives RTF round-trip")
        XCTAssertTrue(hasTrait(.italic, around: "italic"), "italic run survives RTF round-trip")
        // Inline code renders in a monospaced face.
        let ns = reread.string as NSString
        let codeRange = ns.range(of: "code")
        var monospaced = false
        reread.enumerateAttribute(.font, in: codeRange) { value, _, _ in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.monoSpace) { monospaced = true }
        }
        XCTAssertTrue(monospaced, "inline code keeps a monospaced font through RTF")
    }

    func testRTFHasNoImageAttachmentsForMathAndMermaid() throws {
        let doc = LineformDocument(text: "$$x^2$$\n\n```mermaid\nflowchart TD\nA-->B\n```")
        let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
        let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        var attachmentCount = 0
        reread.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reread.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 0, "RTF must contain no image attachments")
        XCTAssertTrue(reread.string.contains("x^2"), "math source present as text")
        XCTAssertTrue(reread.string.contains("flowchart TD"), "mermaid source present as text")
    }

    func testRTFRoundTripPreservesListsAndBlockquotes() throws {
        let doc = LineformDocument(text: "- first\n- second\n\n> quoted line")
        let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
        let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        XCTAssertTrue(reread.string.contains("first"))
        XCTAssertTrue(reread.string.contains("second"))
        XCTAssertTrue(reread.string.contains("quoted line"))
        // Blockquote indentation survives as a non-zero paragraph indent somewhere in the doc.
        var sawIndent = false
        reread.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reread.length)) { value, _, _ in
            if let p = value as? NSParagraphStyle, p.headIndent > 0 || p.firstLineHeadIndent > 0 { sawIndent = true }
        }
        XCTAssertTrue(sawIndent, "list/blockquote indent carries into RTF paragraph styles")
    }

    func testRTFRoundTripPreservesHeadingFormatting() throws {
        // Reviewer coverage gap: the original testRTFDataIsNonEmptyAndReadableRTF only checks that
        // "Heading" text is present, NOT that it survives as a styled (bold/larger-font) run.
        let doc = LineformDocument(text: "# Heading\n\nBody paragraph.")
        let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
        let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))

        // Verify the heading text is present.
        let ns = reread.string as NSString
        let headingRange = ns.range(of: "Heading")
        XCTAssertNotEqual(headingRange.location, NSNotFound, "Heading text must be present in RTF")

        // Find a body run to compare sizes.
        let bodyRange = ns.range(of: "Body paragraph")
        XCTAssertNotEqual(bodyRange.location, NSNotFound, "Body text must be present in RTF")

        var headingFont: NSFont?
        var bodyFont: NSFont?

        reread.enumerateAttribute(.font, in: headingRange) { value, _, _ in
            if let font = value as? NSFont { headingFont = font }
        }
        reread.enumerateAttribute(.font, in: bodyRange) { value, _, _ in
            if let font = value as? NSFont { bodyFont = font }
        }

        let heading = try XCTUnwrap(headingFont, "Heading run must have a font")
        let body = try XCTUnwrap(bodyFont, "Body run must have a font")

        // Assert heading is either bold or larger than body (common heading styling patterns).
        let isBold = heading.fontDescriptor.symbolicTraits.contains(.bold)
        let isLarger = heading.pointSize > body.pointSize
        XCTAssertTrue(isBold || isLarger, "Heading must be styled as bold or larger point size than body; heading=\(heading.pointSize)pt, body=\(body.pointSize)pt")
    }

    func testRTFRoundTripPreservesCallouts() throws {
        // Reviewer coverage gap: no callout (> [!NOTE] ...) round-trip test existed; only plain
        // blockquotes were covered. Callouts render a title row + body, both of which must survive RTF.
        let doc = LineformDocument(text: "> [!NOTE] Remember\n> body text")
        let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
        let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))

        // Both the callout title ("Remember" or the default "Note" + marker) and body must survive.
        XCTAssertTrue(reread.string.contains("Remember"), "Callout custom title must survive RTF round-trip")
        XCTAssertTrue(reread.string.contains("body text"), "Callout body text must survive RTF round-trip")
        // Callout indentation survives like blockquotes (non-zero paragraph indent).
        var sawIndent = false
        reread.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reread.length)) { value, _, _ in
            if let p = value as? NSParagraphStyle, p.headIndent > 0 || p.firstLineHeadIndent > 0 { sawIndent = true }
        }
        XCTAssertTrue(sawIndent, "Callout indent carries into RTF paragraph styles")
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
