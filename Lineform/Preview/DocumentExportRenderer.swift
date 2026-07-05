import AppKit

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
/// Real image files stay the `🖼 alt` placeholder (Task 6 deferred image rendering); mermaid and
/// math already render as images and so appear in the PDF.
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
    /// the diagram/math image cap width.
    static func contentSize(for paper: ExportPaperSize) -> NSSize {
        let paperSize = paper.sizeInPoints
        return NSSize(width: paperSize.width - margin * 2, height: paperSize.height - margin * 2)
    }

    // MARK: - Rendering

    /// An offscreen, print-aware `NSTextView` holding the rich rendered document. Using
    /// `NSTextView` (the same component that renders Read mode on screen) rather than
    /// hand-rolled CGContext pagination means table cells, attachments, and pagination are
    /// handled by AppKit exactly as on screen — fidelity is inherited, not re-implemented.
    @MainActor
    static func makeExportTextView(text: String, profile: ReadingProfile, paper: ExportPaperSize) -> NSTextView {
        let content = contentSize(for: paper)
        let attributed = MarkdownPreviewRenderer().render(
            text,
            profile: exportProfile(from: profile),
            columnWidth: content.width,
            mermaidProvider: MermaidImageProvider(),
            mathProvider: MathImageProvider(),
            // Export never writes to the diagram failure log — a failed diagram just prints its
            // captioned-source fallback.
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            // Tables shrink to fit the fixed page column rather than overflowing off the right edge.
            fitTablesToWidth: true
        )

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

    /// `NSPrintInfo` configured for `paper` with the shared margins. Natural-size pagination
    /// (`.automatic`) — never `.fit`, which would scale the type off the inherited point size.
    @MainActor
    static func makePrintInfo(for paper: ExportPaperSize) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = paper.sizeInPoints
        info.leftMargin = margin
        info.rightMargin = margin
        info.topMargin = margin
        info.bottomMargin = margin
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
        printInfo: NSPrintInfo,
        showsPanel: Bool
    ) -> Bool {
        let view = makeExportTextView(text: text, profile: profile, paper: paper)
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
    static func runInteractivePrint(text: String, profile: ReadingProfile, paper: ExportPaperSize) {
        runOperation(text: text, profile: profile, paper: paper, printInfo: makePrintInfo(for: paper), showsPanel: true)
    }

    /// Renders a paginated PDF directly to `url` (Export as PDF's chosen destination). Returns
    /// whether the operation succeeded.
    @MainActor
    @discardableResult
    static func writePDF(text: String, profile: ReadingProfile, paper: ExportPaperSize, to url: URL) -> Bool {
        let info = makePrintInfo(for: paper)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        return runOperation(text: text, profile: profile, paper: paper, printInfo: info, showsPanel: false)
    }

    /// Renders a paginated PDF and returns its bytes (writes to a temp file then reads back).
    /// Used by tests and any caller wanting the data rather than a file.
    @MainActor
    static func pdfData(text: String, profile: ReadingProfile, paper: ExportPaperSize) -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-export-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        writePDF(text: text, profile: profile, paper: paper, to: tempURL)
        return (try? Data(contentsOf: tempURL)) ?? Data()
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
