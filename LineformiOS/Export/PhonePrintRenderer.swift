import LineformCore
import UIKit

/// Print on iPhone: the Styled layout, like the Mac's ⌘P, through the system print panel.
///
/// The pages are the Styled PDF's: the same attributed string (`PhonePDFRenderer.attributedString`
/// with `.styled`) paginated by the same `PhonePageLayout`, so Print and Styled PDF cannot drift.
/// The text sits at the preset's 72 pt margins measured from `paperRect`, clipped to the printer's
/// `printableRect` when its hardware margin is wider.
///
/// The print panel can change the sheet (paper, orientation) after the renderer exists. Each
/// `numberOfPages` lays out again when the content rect changed, the iPhone's twin of the Mac's
/// `knowsPageRange` reflow; the attributed string is rendered again only when the nearest
/// offered sheet changes (tables and images are fitted to that sheet's portrait content width).
///
/// UIKit subclass: no stored property relies on a default value. The inputs are assigned in
/// `init`; the layout cache lives in `State`, made on first use.
@MainActor
final class PhonePrintRenderer: UIPrintPageRenderer {
    /// The layout made for one content rect, and the render it paginates.
    final class State {
        var laidOutRect: CGRect
        var renderedPaper: ExportPaperSize?
        var attributed: NSAttributedString?
        var layout: PhonePageLayout?

        init() {
            laidOutRect = .null
            renderedPaper = nil
            attributed = nil
            layout = nil
        }
    }

    private static let preset = ExportTypographyPreset.styled

    private let text: String
    private let profile: ReadingProfile
    private let documentDirectory: URL?
    private var stateStorage: State?

    private var state: State {
        if let stateStorage { return stateStorage }
        let state = State()
        stateStorage = state
        return state
    }

    init(text: String, profile: ReadingProfile, documentDirectory: URL?) {
        self.text = text
        self.profile = profile
        self.documentDirectory = documentDirectory
        self.stateStorage = nil
        super.init()
    }

    /// A print job named `jobName` (the document's base name), text and graphics.
    static func printInfo(jobName: String) -> UIPrintInfo {
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName
        return info
    }

    /// Where the text goes on the current sheet: the paper inset by the preset's margins, inside
    /// the printable area. `.zero` before the print system has set a sheet.
    var contentRect: CGRect {
        let paper = paperRect
        guard paper.width > 0, paper.height > 0 else { return .zero }
        var content = paper.inset(by: Self.preset.pageMargins)
        let printable = printableRect
        if printable.width > 0, printable.height > 0 {
            content = content.intersection(printable)
        }
        guard !content.isNull, content.width > 0, content.height > 0 else { return .zero }
        return content
    }

    // The print system may call these two off the main thread; the layout is main-actor work, so
    // it always runs on the main thread. `nonisolated(unsafe)`: the renderer and the page context
    // are only touched there, while the calling thread waits.

    override var numberOfPages: Int {
        nonisolated(unsafe) let renderer = self
        return Self.onMain { renderer.currentLayout()?.pageCount ?? 0 }
    }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        // The page's context belongs to the calling thread's UIKit stack; push it on the main
        // thread for the drawing.
        guard let context = UIGraphicsGetCurrentContext() else { return }
        nonisolated(unsafe) let pageContext = context
        nonisolated(unsafe) let renderer = self
        Self.onMain {
            UIGraphicsPushContext(pageContext)
            defer { UIGraphicsPopContext() }
            renderer.drawOnMain(pageIndex)
        }
    }

    private func drawOnMain(_ pageIndex: Int) {
        guard let layout = currentLayout(), pageIndex >= 0, pageIndex < layout.pageCount else { return }
        UIColor.white.setFill()
        UIRectFill(paperRect)
        layout.drawPage(pageIndex, contentOrigin: contentRect.origin)
    }

    nonisolated private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// The layout for the current content rect, made again when the rect changed.
    private func currentLayout() -> PhonePageLayout? {
        let content = contentRect
        guard content != .zero else { return nil }
        let state = state
        if let layout = state.layout, state.laidOutRect == content { return layout }

        let paper = ExportPaperSize.closest(toPortrait: paperRect.size)
        if state.attributed == nil || state.renderedPaper != paper {
            state.attributed = PhonePDFRenderer.attributedString(
                text: text, profile: profile, paper: paper, preset: Self.preset, documentDirectory: documentDirectory
            )
            state.renderedPaper = paper
        }
        guard let attributed = state.attributed else { return nil }
        let layout = PhonePageLayout(attributed: attributed, pageContentSize: content.size)
        state.layout = layout
        state.laidOutRect = content
        return layout
    }
}
