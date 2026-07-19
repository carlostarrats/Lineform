import AppKit
import XCTest
@testable import Lineform

/// A stub provider that returns a fixed image for any URL, so the export wiring can be proven
/// without decoding a real image file (ImageResolver only checks existence + extension).
private final class StubImageProvider: ImageAttachmentProviding {
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        NSImage(size: NSSize(width: 10, height: 10))
    }
}

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
        // `.styled` renders the document Read-mode style (markers stripped). `.standard` prints the
        // raw markdown source — covered separately by `testStandardPresetPrintsRawMarkdownSource`.
        let view = DocumentExportRenderer.makeExportTextView(
            text: "# Export Heading\n\nBody paragraph text.",
            profile: .original,
            paper: .usLetter,
            preset: .styled
        )

        let contents = view.textStorage?.string ?? ""
        XCTAssertTrue(contents.contains("Export Heading"), "Heading text should be rendered (marker stripped).")
        XCTAssertFalse(contents.contains("# Export Heading"), "Styled render strips the heading marker.")
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
            paper: .usLetter,
            preset: .styled
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

    func testStandardPresetPrintsRawMarkdownSource() {
        // "Normal" (the `.standard` preset) prints the raw markdown SOURCE verbatim — the #, **, and
        // fence markers stay visible — in a monospaced document face, not the rendered version.
        let source = "# Heading\n\nSome **bold** text.\n\n```swift\nlet x = 42\n```"
        let view = DocumentExportRenderer.makeExportTextView(
            text: source,
            profile: .original,
            paper: .usLetter,
            preset: .standard
        )
        let contents = view.textStorage?.string ?? ""
        XCTAssertEqual(contents, source, "Normal export must print the raw markdown source unchanged.")

        // The whole source is one monospaced font in a single ink color — no rendering, no palette.
        guard let storage = view.textStorage, storage.length > 0 else {
            XCTFail("Export text view should have backing text storage.")
            return
        }
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false,
                      "Raw-source export should use a monospaced face.")
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

    // --- image export coverage (added for Styled PDF image rendering) ---
    private func makeDirWithImage() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-img-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("pic.png").path, contents: Data())
        return dir
    }

    private func attachmentCount(_ view: NSTextView) -> Int {
        var count = 0
        let storage = view.textStorage!
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }

    func testStyledExportRendersResolvableLocalImage() {
        let dir = makeDirWithImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = DocumentExportRenderer.makeExportTextView(
            text: "![cat](pic.png)", profile: .original, paper: .usLetter,
            preset: .styled, documentDirectory: dir, imageProvider: StubImageProvider())
        XCTAssertGreaterThanOrEqual(attachmentCount(view), 1)
        XCTAssertFalse(view.textStorage!.string.contains("🖼"))
    }

    func testStyledExportWithDisabledProviderKeepsPlaceholder() {
        let dir = makeDirWithImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = DocumentExportRenderer.makeExportTextView(
            text: "![cat](pic.png)", profile: .original, paper: .usLetter,
            preset: .styled, documentDirectory: dir, imageProvider: DisabledImageAttachmentProvider())
        XCTAssertTrue(view.textStorage!.string.contains("🖼"))
    }

    func testNormalExportNeverRendersImage() {
        let dir = makeDirWithImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = DocumentExportRenderer.makeExportTextView(
            text: "![cat](pic.png)", profile: .original, paper: .usLetter,
            preset: .standard, documentDirectory: dir, imageProvider: StubImageProvider())
        // Normal prints raw source: the literal reference text is present, no image attachment.
        XCTAssertTrue(view.textStorage!.string.contains("![cat](pic.png)"))
        XCTAssertEqual(attachmentCount(view), 0)
    }

    // MARK: - Atomic staged write (crash-safe overwrite)

    private func makeScratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-atomic-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testStagedWriteDeliversProducedBytesToDestination() {
        let dir = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")

        let ok = AtomicFileWrite.write(to: destination) { temp in
            (try? Data("rendered".utf8).write(to: temp)) != nil
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(try? Data(contentsOf: destination), Data("rendered".utf8))
    }

    func testStagedWriteLeavesAnExistingFileIntactWhenProductionFails() {
        let dir = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")
        let original = Data("the user's previous export".utf8)
        try! original.write(to: destination)

        // The renderer half-wrote the staging file and then failed (disk full, print error).
        let ok = AtomicFileWrite.write(to: destination) { temp in
            try? Data("truncated gar".utf8).write(to: temp)
            return false
        }

        XCTAssertFalse(ok)
        XCTAssertEqual(try? Data(contentsOf: destination), original,
            "A failed export must never damage the file it was overwriting.")
    }

    func testStagedWriteFailsWithoutTouchingDestinationWhenNothingWasProduced() {
        let dir = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")
        let original = Data("previous".utf8)
        try! original.write(to: destination)

        // Claims success but produced no file at all.
        XCTAssertFalse(AtomicFileWrite.write(to: destination) { _ in true })
        XCTAssertEqual(try? Data(contentsOf: destination), original)

        // Claims success but produced a 0-byte file — an empty PDF is a failed render.
        XCTAssertFalse(AtomicFileWrite.write(to: destination) { temp in
            (try? Data().write(to: temp)) != nil
        })
        XCTAssertEqual(try? Data(contentsOf: destination), original)
    }

    func testStagedWriteCreatesNoFileWhenTheDestinationDidNotExist() {
        let dir = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")

        XCTAssertFalse(AtomicFileWrite.write(to: destination) { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
            "A failed export must not leave a stub behind.")
    }

    func testStagedWriteHandlesAnExtensionlessDestination() {
        let dir = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("no-extension")

        XCTAssertTrue(AtomicFileWrite.write(to: destination) { temp in
            XCTAssertFalse(temp.lastPathComponent.hasSuffix("."), "No dangling dot on the staging name.")
            return (try? Data("bytes".utf8).write(to: temp)) != nil
        })
        XCTAssertEqual(try? Data(contentsOf: destination), Data("bytes".utf8))
    }

    func testStagedWriteRemovesItsStagingFile() {
        let dir = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")
        var stagingURL: URL?

        _ = AtomicFileWrite.write(to: destination) { temp in
            stagingURL = temp
            return (try? Data("x".utf8).write(to: temp)) != nil
        }

        let staging = try! XCTUnwrap(stagingURL)
        XCTAssertNotEqual(staging.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
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

    /// The staged export path end-to-end: a real print job renders into staging and the finished
    /// PDF replaces whatever the user chose to overwrite.
    func testAtomicPDFExportReplacesAnExistingFileWithARealPDF() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-atomic-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")
        try Data("an older export the user is replacing".utf8).write(to: destination)

        let ok = DocumentExportRenderer.writePDFAtomically(
            text: "# Title\n\nBody paragraph.\n", profile: .original, paper: .usLetter, to: destination)

        XCTAssertTrue(ok)
        let written = try Data(contentsOf: destination)
        XCTAssertTrue(written.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(written.count, 100)
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

    func testStyledPDFEmbedsResolvableLocalImage() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-img-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 240x240 deterministic-noise PNG: poorly compressible, so the embedded raster adds an
        // unambiguous number of bytes to the PDF (a tiny flat-color image compresses to almost
        // nothing and would give a flaky margin).
        let side = 240
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<side {
            for x in 0..<side {
                let v = (x * 31 + y * 17) & 0xFF
                rep.setColor(NSColor(
                    deviceRed: CGFloat(v) / 255.0,
                    green: CGFloat((v &* 7) & 0xFF) / 255.0,
                    blue: CGFloat((v &* 13) & 0xFF) / 255.0,
                    alpha: 1), atX: x, y: y)
            }
        }
        let png = rep.representation(using: .png, properties: [:])!
        try! png.write(to: dir.appendingPathComponent("pic.png"))

        // Image doc vs an image-FREE doc (no `![...]`, so no 🖼 placeholder / emoji-font subset to
        // confound the size). The only difference is the embedded raster, so the image doc must be
        // larger. This proves the resolvable local image survives into the actual PDF bytes.
        let withImage = DocumentExportRenderer.pdfData(
            text: "# Title\n\n![cat](pic.png)\n",
            profile: .original, paper: .usLetter, preset: .styled, documentDirectory: dir)
        let noImage = DocumentExportRenderer.pdfData(
            text: "# Title\n\nplain paragraph text\n",
            profile: .original, paper: .usLetter, preset: .styled, documentDirectory: nil)

        XCTAssertFalse(withImage.isEmpty)
        XCTAssertGreaterThan(withImage.count, noImage.count,
            "A rendered raster image should add bytes over an image-free document.")
    }

}
