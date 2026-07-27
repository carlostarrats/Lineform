import AppKit

/// Stages a file write so an interrupted or failed producer can never damage the destination.
///
/// Exists because `NSPrintOperation` renders STRAIGHT into its `jobSavingURL`: overwriting an
/// existing PDF truncates it the moment the job starts, so a disk-full/render failure (or a crash)
/// leaves the user with a corrupt file where a good one used to be. The producer writes into a
/// staging file in the app's own temporary directory — deliberately NOT a sibling of the
/// destination, since an `NSSavePanel` grant covers only the chosen path — and the finished bytes
/// are then copied into place with a single atomic write.
///
/// It copies through memory rather than moving the file: `moveItem` fails outright when the
/// destination exists, and overwrite is the whole point. `Data.write(options: .atomic)` is chosen
/// over `replaceItemAt` because it is the exact pattern the RTF branch of this same export already
/// ships against an `NSSavePanel` URL — both stage a sibling temp and rename, so the choice is
/// proven-in-production rather than a difference in sandbox capability. (The Markdown branch is not
/// a precedent either way: it goes through `NSDocument`'s own safe-save.) The cost is holding one PDF in
/// memory briefly — tens of MB for a long illustrated document, acceptable for a user-initiated
/// export and the price of a write that cannot half-land. Note the atomic rename gives an
/// overwritten file a new inode, so Finder tags/xattrs on the REPLACED file don't carry over (the
/// same trade the RTF branch already makes).
enum AtomicFileWrite {
    /// Runs `produce` against a staging URL and, only if it reports success AND left a non-empty
    /// file, atomically writes those bytes to `destination`. Returns whether `destination` was
    /// updated; on any failure `destination` is left exactly as it was (including not existing).
    @discardableResult
    static func write(to destination: URL, produce: (URL) -> Bool) -> Bool {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-staged-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: staging) }

        guard produce(staging) else { return false }
        // An empty file is a failed render even when the producer claims success.
        guard let data = try? Data(contentsOf: staging), !data.isEmpty else { return false }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Paper sizes offered for PDF export / print. Sizes are in PostScript points (1/72"). Covers the
/// common US (Letter/Legal/Tabloid) and ISO (A3/A4/A5) sheets printers use.
enum ExportPaperSize: CaseIterable {
    case usLetter
    case usLegal
    case tabloid
    case a4
    case a3
    case a5

    var sizeInPoints: NSSize {
        switch self {
        case .usLetter:
            return NSSize(width: 612, height: 792)    // 8.5 × 11"
        case .usLegal:
            return NSSize(width: 612, height: 1008)   // 8.5 × 14"
        case .tabloid:
            return NSSize(width: 792, height: 1224)   // 11 × 17"
        case .a4:
            return NSSize(width: 595, height: 842)     // 210 × 297 mm
        case .a3:
            return NSSize(width: 842, height: 1191)    // 297 × 420 mm
        case .a5:
            return NSSize(width: 420, height: 595)     // 148 × 210 mm
        }
    }

    var displayName: String {
        switch self {
        case .usLetter:
            return "US Letter"
        case .usLegal:
            return "US Legal"
        case .tabloid:
            return "Tabloid"
        case .a4:
            return "A4"
        case .a3:
            return "A3"
        case .a5:
            return "A5"
        }
    }
}

/// Builds the rich, print-ready rendering of a document for **Print (⌘P)** and **Export as PDF**.
///
/// The export reuses the exact Read-mode renderer (`MarkdownPreviewRenderer`), so the printed
/// page matches what the user sees rendered — headings, inline styling, fenced code, mermaid
/// diagrams, math, lists, blockquotes, native tables. Two things differ from Read mode:
///   * the page is forced **white** with the app's near-black ink regardless of the reader
///     theme, by handing the renderer a profile pinned to the static `.system` theme (see
///     `exportProfile(from:)`) AND painting the page white in `ExportTextView` (NSTextView's
///     printed output does not carry `backgroundColor`, so the fill must be drawn);
///   * prose wraps to the paper's content width, not the on-screen reading-column width.
///
/// The **Styled** preset renders resolvable local image files (given a `documentDirectory` and an
/// `imageProvider`), matching Read mode; the **Normal** (raw-source) preset and RTF export still
/// show the `🖼 alt` placeholder / caption text. Mermaid and math already render as images and so
/// appear in the PDF regardless of preset.
enum DocumentExportRenderer {
    /// 1-inch margins on every side — print convention.
    static let margin: CGFloat = 72

    /// Fixed body point size for print/PDF. A PDF is a saved/shared artifact, so it gets a
    /// consistent standard-document size rather than the on-screen reading size — the reading
    /// size (often 17–18pt in a very wide reading column) reads as large-print on a page.
    /// Headings scale up from this in the renderer (body + per-level boost).
    static let bodyPointSize: Double = 12

    /// The reader profile adapted for a fixed, white, document-style page. Forces:
    ///   * a deterministic white page with the app's near-black ink — `.system` resolves to the
    ///     **static** #FFFFFF / #1F1F1F colors in `LineformColors`, and clearing high contrast
    ///     avoids the dynamic system colors that would invert on a dark app appearance;
    ///   * a fixed body point size (`bodyPointSize`) so the PDF reads like a normal document
    ///     regardless of the reader's on-screen size.
    /// The user's font **face** and rhythm (line height, paragraph + letter spacing) are kept.
    static func exportProfile(from profile: ReadingProfile) -> ReadingProfile {
        var copy = profile
        copy.themeID = .system
        copy.highContrastEnabled = false
        copy.fontSize = bodyPointSize
        return copy
    }

    /// Content rect size = paper minus margins on all sides. This is the prose wrap width and
    /// the diagram/math image cap width. `preset` supplies the margins (`.standard`'s are the
    /// same flat 72pt as `margin` on every edge, so the default is byte-identical to before
    /// presets existed).
    static func contentSize(for paper: ExportPaperSize, preset: ExportTypographyPreset = .standard) -> NSSize {
        let paperSize = paper.sizeInPoints
        let insets = preset.pageMargins
        return NSSize(
            width: paperSize.width - insets.left - insets.right,
            height: paperSize.height - insets.top - insets.bottom
        )
    }

    // MARK: - Rendering

    /// An offscreen, print-aware `NSTextView` holding the rich rendered document. Using
    /// `NSTextView` (the same component that renders Read mode on screen) rather than
    /// hand-rolled CGContext pagination means table cells, attachments, and pagination are
    /// handled by AppKit exactly as on screen — fidelity is inherited, not re-implemented.
    @MainActor
    static func makeExportTextView(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset = .standard,
        documentDirectory: URL? = nil,
        imageProvider: ImageAttachmentProviding = ImageAttachmentProvider()
    ) -> NSTextView {
        let content = contentSize(for: paper, preset: preset)
        let attributed: NSAttributedString
        if preset.rendersMarkdown {
            attributed = MarkdownPreviewRenderer().render(
                text,
                profile: preset.exportReadingProfile(basedOn: profile),
                columnWidth: content.width,
                mermaidProvider: MermaidImageProvider(),
                mathProvider: MathImageProvider(),
                // Export never writes to the diagram failure log — a failed diagram just prints its
                // captioned-source fallback.
                diagramLog: NullDiagramFailureLog(),
                reportRegistry: DiagramReportRegistry(),
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                // Tables shrink to fit the fixed page column rather than overflowing off the right edge.
                fitTablesToWidth: true,
                // Exported/printed code stays monochrome — a deliberate product decision (see the
                // "highlightsCode" parameter above).
                highlightsCode: false,
                documentDirectory: documentDirectory,
                imageProvider: imageProvider,
                headingScale: preset.headingScale
            )
        } else {
            // "Normal": print the RAW markdown SOURCE (visible #, **, etc.) as a plain monospaced
            // document — never run through the renderer, so the reader sees the actual markdown text.
            attributed = rawSourceAttributedString(text, preset: preset)
        }

        // Classic TextKit 1 stack, matching the on-screen preview view — the renderer's
        // NSTextTable / NSTextAttachment output is TextKit-1 shaped.
        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: content.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = ExportTextView(frame: NSRect(origin: .zero, size: content), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = .zero
        // The white page is painted by ExportTextView.draw; NSTextView's own background is not
        // carried into the print context, so drawsBackground would be a no-op on paper.
        textView.drawsBackground = false

        // Force layout so the operation has a real content height to paginate against.
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        textView.setFrameSize(NSSize(width: content.width, height: max(content.height, used.height)))
        return textView
    }

    /// The RAW markdown source laid out as a plain document: a monospaced face at the preset body
    /// size, dark ink on the white page, with the preset's line height. No markdown parsing — the
    /// `#`, `**`, backticks, etc. print verbatim, exactly as typed in Write mode.
    @MainActor
    private static func rawSourceAttributedString(_ text: String, preset: ExportTypographyPreset) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: preset.bodyPointSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = preset.lineHeightMultiple ?? 1.2
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: DiagramPalette.ink(isDark: false),
            .paragraphStyle: paragraph
        ])
    }

    /// `NSPrintInfo` configured for `paper` with `preset`'s margins (`.standard`'s are the same
    /// flat 72pt as the old fixed `margin` on every edge, so the default is unchanged). Natural-
    /// size pagination (`.automatic`) — never `.fit`, which would scale the type off the
    /// inherited point size.
    @MainActor
    static func makePrintInfo(for paper: ExportPaperSize, preset: ExportTypographyPreset = .standard) -> NSPrintInfo {
        let info = NSPrintInfo()
        let insets = preset.pageMargins
        info.paperSize = paper.sizeInPoints
        info.leftMargin = insets.left
        info.rightMargin = insets.right
        info.topMargin = insets.top
        info.bottomMargin = insets.bottom
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.scalingFactor = 1
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    // MARK: - Running the operation

    /// Runs a print operation for the document. The offscreen text view is hosted in a
    /// borderless (never-ordered-front) window for the duration of the run: an NSPrintOperation
    /// view that belongs to no window prints unreliably — the interactive spool path fails with
    /// AppKit's generic "Error while printing." The window is a local that outlives the
    /// synchronous `run()`. Returns whether the operation succeeded.
    @MainActor
    @discardableResult
    private static func runOperation(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset = .standard,
        printInfo: NSPrintInfo,
        showsPanel: Bool,
        documentDirectory: URL? = nil
    ) -> Bool {
        let view = makeExportTextView(text: text, profile: profile, paper: paper, preset: preset, documentDirectory: documentDirectory)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.contentView = nil }

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = showsPanel
        operation.showsProgressPanel = showsPanel
        return operation.run()
    }

    /// Presents the interactive print panel (paper size, copies, and the OS "Save as PDF").
    @MainActor
    static func runInteractivePrint(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil) {
        runOperation(text: text, profile: profile, paper: paper, preset: preset, printInfo: makePrintInfo(for: paper, preset: preset), showsPanel: true, documentDirectory: documentDirectory)
    }

    /// Renders a paginated PDF directly to `url` (Export as PDF's chosen destination). Returns
    /// whether the operation succeeded.
    ///
    /// NOTE: this writes STRAIGHT to `url` — a mid-render failure leaves a truncated file, and
    /// overwriting an existing PDF destroys it before the new one is complete. Callers exporting to
    /// a user-chosen destination must go through `writePDFAtomically` instead; this stays public for
    /// the temp-file callers (`pdfData`) where there is nothing to lose.
    @MainActor
    @discardableResult
    static func writePDF(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil, to url: URL) -> Bool {
        let info = makePrintInfo(for: paper, preset: preset)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        return runOperation(text: text, profile: profile, paper: paper, preset: preset, printInfo: info, showsPanel: false, documentDirectory: documentDirectory)
    }

    /// Crash-safe PDF export: renders to a staging file and only replaces `url` once a non-empty
    /// PDF exists. A failed or interrupted render can therefore never truncate the file the user
    /// chose to overwrite. Returns whether the destination now holds the new PDF.
    @MainActor
    @discardableResult
    static func writePDFAtomically(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil, to url: URL) -> Bool {
        AtomicFileWrite.write(to: url) { staging in
            writePDF(text: text, profile: profile, paper: paper, preset: preset, documentDirectory: documentDirectory, to: staging)
        }
    }

    /// Renders a paginated PDF and returns its bytes (writes to a temp file then reads back).
    /// Used by tests and any caller wanting the data rather than a file.
    @MainActor
    static func pdfData(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil) -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-export-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        writePDF(text: text, profile: profile, paper: paper, preset: preset, documentDirectory: documentDirectory, to: tempURL)
        return (try? Data(contentsOf: tempURL)) ?? Data()
    }
}

/// Pure RTF serialization — no `NSPrintOperation`, no offscreen window. Reuses the same export
/// `ReadingProfile` and content width as the PDF path, but with `imagesAsText: true` since plain
/// RTF cannot portably embed rasterized math/mermaid images (they degrade to caption + source
/// text instead).
extension DocumentExportRenderer {
    /// The rendered export attributed string for RTF (text-only: math/mermaid become caption/source
    /// text). Reuses the export ReadingProfile and content width; no attachments.
    @MainActor
    static func makeRTFAttributedString(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard) -> NSAttributedString {
        let content = contentSize(for: paper, preset: preset)
        return MarkdownPreviewRenderer().render(
            text,
            profile: preset.exportReadingProfile(basedOn: profile),
            columnWidth: content.width,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            fitTablesToWidth: true,
            imagesAsText: true,
            headingScale: preset.headingScale
        )
    }

    /// Rendered document as RTF data. Pure NSAttributedString serialization — no print subsystem.
    @MainActor
    static func rtfData(for document: LineformDocument, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard) throws -> Data {
        let attributed = makeRTFAttributedString(text: document.text, profile: profile, paper: paper, preset: preset)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// The document as a standalone HTML file.
    ///
    /// `MarkdownHTMLRenderer` is pure and passes every user-authored path through untouched; the
    /// ONLY bytes produced here are the math and mermaid pictures, which have no path to preserve.
    /// Nothing on disk is read and the network is never touched — a local image the user
    /// referenced is emitted as its `src` string, exactly as written, and left for the browser to
    /// resolve relative to wherever they put the file.
    @MainActor
    static func htmlData(text: String, title: String) -> Data {
        // Constructed per export, matching `makeExportTextView`: these carry caches sized for a
        // long editing session, and an export is a one-shot.
        let mathProvider = MathImageProvider()
        let mermaidProvider = MermaidImageProvider()
        let ink = DiagramPalette.ink(isDark: false)

        let html = MarkdownHTMLRenderer.html(for: text, title: title) { generated in
            let image: NSImage
            switch generated {
            case let .math(latex):
                guard case let .image(rendered, _) = mathProvider.outcome(
                    latex: latex, style: .display, foreground: ink, pointSize: 16, scale: 2
                ) else { return nil }
                image = rendered
            case let .mermaid(source):
                guard case let .image(rendered) = mermaidProvider.outcome(
                    source: source, background: .white, foreground: ink, scale: 2
                ) else { return nil }
                image = rendered
            }
            return pngData(from: image)
        }
        return Data(html.utf8)
    }

    /// PNG bytes for a rendered diagram/equation, or nil so the emitter falls back to the source.
    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// An `NSTextView` that paints its page white before drawing text. NSTextView's `backgroundColor`
/// is not carried into the print graphics context, so a white page must be drawn explicitly —
/// otherwise the exported PDF is transparent (renders black on dark viewers) despite the white
/// export theme.
private final class ExportTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
