import LineformCore
import UIKit

/// Print on iPhone: the Styled layout, like the Mac's ⌘P, through the system print panel.
///
/// The pages are the Styled PDF's: the same attributed string (`PhonePDFRenderer.attributedString`
/// with `.styled`) paginated by the same `PhonePageLayout`, so Print and Styled PDF cannot drift.
/// The text sits at the preset's 72 pt margins measured from `paperRect`, clipped to the printer's
/// `printableRect` when its hardware margin is wider.
///
/// **Threading.** UIKit calls `numberOfPages` and `drawPage(at:in:)` OFF the main thread: run under
/// the print panel in the iOS 26 simulator, `numberOfPages` came on
/// `com.apple.UIKit.UIPrintPreviewViewController.updatePageCountThread` and `prepare`/`drawPage`
/// on an unnamed secondary thread, never on main. So neither override may hop to the main thread
/// (main can be waiting on the print system) or touch main-actor state. The main-actor work, the
/// Markdown render, is done on main BEFORE the panel is up: `init` renders for `paper` (the
/// region's everyday sheet, which the panel starts on), and `renderRemainingSheets()`, run on
/// main once the panel is presented, renders for every other offered sheet width. The overrides
/// only lay out and draw those finished, never-changed strings with TextKit 1, on the calling
/// thread, under `Pages`'s lock (an `NSLayoutManager` with no view is used by one thread at a
/// time, not only by main).
///
/// **Sheets.** For a content rect the best render is the offered sheet with the widest content
/// that still fits the rect's width (so tables and pictures never run past the margin), else the
/// narrowest offered sheet. While that render is not ready, the starting sheet's is used. A render
/// narrower than the rect reflows its text to the full width (a landscape page); one wider than
/// the rect (paper smaller than every offered sheet, such as a 4×6 photo) is laid out at its own
/// width and drawn scaled down to fit. The layout is made again only when the rect or the render
/// changes, and `drawPage` always draws the layout `numberOfPages` counted.
///
/// UIKit subclass: no stored property relies on a default value; everything is assigned in `init`.
@MainActor
final class PhonePrintRenderer: UIPrintPageRenderer {
    /// One finished render: the Styled string for a sheet, and the column width it was made for.
    struct Render: @unchecked Sendable {
        let columnWidth: CGFloat
        let attributed: NSAttributedString
    }

    /// The renders and the current layout, shared by the print system's threads.
    final class Pages: @unchecked Sendable {
        private let lock: NSLock
        private let startingWidth: CGFloat
        private let gridInk: UIColor
        private var renders: [CGFloat: Render]
        private var layoutKey: (rect: CGRect, width: CGFloat)?
        private var layout: PhonePageLayout?
        private var layoutScale: CGFloat

        init(starting: Render, gridInk: UIColor) {
            lock = NSLock()
            startingWidth = starting.columnWidth
            self.gridInk = gridInk
            renders = [starting.columnWidth: starting]
            layoutKey = nil
            layout = nil
            layoutScale = 1
        }

        func add(_ render: Render) {
            lock.withLock { renders[render.columnWidth] = render }
        }

        func hasRender(width: CGFloat) -> Bool {
            lock.withLock { renders[width] != nil }
        }

        /// The page count for `content`, laying out again if needed. 0 when the document cannot
        /// be paginated (past `PhonePageLayout.maximumPageCount`): nothing prints rather than a
        /// part of it.
        func pageCount(content: CGRect) -> Int {
            lock.withLock { currentLayout(content: content)?.pageCount ?? 0 }
        }

        /// Draws page `index` of the layout the last count made (made now if there is none).
        func draw(_ index: Int, content: CGRect, paper: CGRect, in context: CGContext) {
            lock.withLock {
                guard let layout = layoutKey?.rect == content ? layout : currentLayout(content: content),
                      index >= 0, index < layout.pageCount else { return }
                context.saveGState()
                defer { context.restoreGState() }
                context.setFillColor(UIColor.white.cgColor)
                context.fill(paper)
                context.translateBy(x: content.minX, y: content.minY)
                context.scaleBy(x: layoutScale, y: layoutScale)
                layout.drawPage(index, contentOrigin: .zero)
            }
        }

        /// Call with the lock held.
        private func currentLayout(content: CGRect) -> PhonePageLayout? {
            guard content.width > 0, content.height > 0 else { return nil }
            let ideal = PhonePrintRenderer.idealColumnWidth(forContentWidth: content.width)
            guard let render = renders[ideal] ?? renders[startingWidth] else { return nil }
            if let layoutKey, layoutKey.rect == content, layoutKey.width == render.columnWidth { return layout }

            // Narrower than the rect: reflow to the full width. Wider: lay out at the render's
            // width and draw scaled down.
            let scale = min(1, content.width / render.columnWidth)
            let size = scale < 1
                ? CGSize(width: render.columnWidth, height: content.height / scale)
                : content.size
            layout = PhonePageLayout(
                attributed: render.attributed, pageContentSize: size, tableWidth: render.columnWidth, gridInk: gridInk
            )
            layoutScale = scale
            layoutKey = (content, render.columnWidth)
            return layout
        }
    }

    nonisolated private static let preset = ExportTypographyPreset.styled

    private let text: String
    private let profile: ReadingProfile
    private let documentDirectory: URL?
    private let pages: Pages

    /// Renders the document for `paper` now, on main; the other sheets follow in
    /// `renderRemainingSheets()`.
    init(text: String, profile: ReadingProfile, paper: ExportPaperSize, documentDirectory: URL?) {
        self.text = text
        self.profile = profile
        self.documentDirectory = documentDirectory
        let starting = Self.representative(forColumnWidth: Self.columnWidth(of: paper))
        pages = Pages(
            starting: Render(
                columnWidth: Self.columnWidth(of: paper),
                attributed: PhonePDFRenderer.attributedString(
                    text: text, profile: profile, paper: starting, preset: Self.preset, documentDirectory: documentDirectory
                )
            ),
            gridInk: PhonePageLayout.defaultGridInk
        )
        super.init()
    }

    /// A print job named `jobName` (the document's base name), text and graphics.
    static func printInfo(jobName: String) -> UIPrintInfo {
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName
        return info
    }

    /// Renders every offered sheet width not rendered yet, one per main-loop turn, so a paper or
    /// orientation change in the panel finds its render ready.
    func renderRemainingSheets() async {
        for width in Self.columnWidths where !pages.hasRender(width: width) {
            let paper = Self.representative(forColumnWidth: width)
            pages.add(Render(
                columnWidth: width,
                attributed: PhonePDFRenderer.attributedString(
                    text: text, profile: profile, paper: paper, preset: Self.preset, documentDirectory: documentDirectory
                )
            ))
            await Task.yield()
        }
    }

    // MARK: - Sheets

    nonisolated static func columnWidth(of paper: ExportPaperSize) -> CGFloat {
        paper.contentSize(preset: preset).width
    }

    /// The offered sheets' distinct content widths, narrowest first.
    nonisolated static var columnWidths: [CGFloat] {
        Array(Set(ExportPaperSize.allCases.map(columnWidth(of:)))).sorted()
    }

    /// The first offered sheet with this content width (US Letter for Letter and Legal).
    nonisolated static func representative(forColumnWidth width: CGFloat) -> ExportPaperSize {
        ExportPaperSize.allCases.first { columnWidth(of: $0) == width } ?? .usLetter
    }

    /// The render that suits a content width: the widest offered column that fits it, else the
    /// narrowest offered column.
    nonisolated static func idealColumnWidth(forContentWidth width: CGFloat) -> CGFloat {
        let widths = columnWidths
        return widths.last { $0 <= width + 0.5 } ?? widths[0]
    }

    // MARK: - The print system's calls (on its own threads)

    /// The print system's sheet, read through key-value coding: the typed properties are
    /// main-actor isolated in Swift, and these calls never run on main.
    nonisolated private var sheet: (paper: CGRect, printable: CGRect) {
        let paper = (value(forKey: "paperRect") as? NSValue)?.cgRectValue ?? .zero
        let printable = (value(forKey: "printableRect") as? NSValue)?.cgRectValue ?? .zero
        return (paper, printable)
    }

    /// Where the text goes on the current sheet: the paper inset by the preset's margins, inside
    /// the printable area. `.zero` before the print system has set a sheet.
    nonisolated var contentRect: CGRect {
        Self.contentRect(paper: sheet.paper, printable: sheet.printable)
    }

    nonisolated static func contentRect(paper: CGRect, printable: CGRect) -> CGRect {
        guard paper.width > 0, paper.height > 0 else { return .zero }
        var content = paper.inset(by: preset.pageMargins)
        if printable.width > 0, printable.height > 0 {
            content = content.intersection(printable)
        }
        guard !content.isNull, content.width > 0, content.height > 0 else { return .zero }
        return content
    }

    nonisolated override var numberOfPages: Int {
        pages.pageCount(content: contentRect)
    }

    nonisolated override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let sheet = sheet
        let content = Self.contentRect(paper: sheet.paper, printable: sheet.printable)
        guard content != .zero else { return }
        pages.draw(pageIndex, content: content, paper: sheet.paper, in: context)
    }
}
