import LineformCore
import UIKit

/// Paginates an attributed string with TextKit 1, the stack the iPhone Read view and the Mac's
/// export both use: an `NSTextStorage`, an `NSLayoutManager`, and one page-sized `NSTextContainer`
/// per page, added until every glyph is laid out. The Mac paginates through `NSPrintOperation`;
/// the iPhone has none for a file, so the pages are the containers themselves.
///
/// **No content is ever dropped.** A line taller than the page (a tall diagram or picture is one
/// line) does not fit any container: TextKit either puts nothing in the container, and nothing in
/// any later one, which would end the document there, or (as measured on the current iOS
/// simulator) puts the line in clipped to the page height, which cuts the picture off. Two rules
/// prevent both:
///
/// 1. Before pagination, a picture (a diagram, display math, an image) taller than
///    `attachmentHeightFraction` of the page (less its paragraph's spacing), or wider than the
///    page, is scaled down on a copy of the string so it fits.
/// 2. A page that still takes no glyphs, or whose first line fills it (a line taller than the page
///    for any other reason, such as a huge font), never ends pagination: that one line gets a page
///    of its own, laid out without a height limit and drawn scaled down to fit, and the text after
///    it continues on the next page in a new layout. A document that would need more than `maximumPageCount` pages fails (`init`
///    returns nil) rather than being cut short.
///
/// Tables are the renderer's tab-stop rows; like the Read view, the hairline grid is drawn behind
/// them here (the rows carry `.markdownTableRow` and `.markdownTableColumnFractions`), across
/// `tableWidth`, the column width the render placed their tab stops for.
///
/// Not main-actor bound: Print lays out and draws on the print system's own threads (see
/// `PhonePrintRenderer`). One thread uses an instance at a time; the string it is given is never
/// changed.
final class PhonePageLayout {
    /// A runaway guard: a document never produces more pages than this. Past it, `init` fails.
    static let maximumPageCount = 2_000
    /// The share of the page height a picture may take; the rest is room for its line's leading.
    static let attachmentHeightFraction: CGFloat = 0.9

    /// One run of the document laid out in its own TextKit stack. `offset` is where its string
    /// starts in the document.
    private final class Segment {
        let offset: Int
        let textStorage: NSTextStorage
        let layoutManager: NSLayoutManager

        init(_ document: NSAttributedString, from offset: Int, length: Int) {
            self.offset = offset
            textStorage = NSTextStorage(attributedString: document.attributedSubstring(from: NSRange(location: offset, length: length)))
            layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
        }

        /// Adds a container of `size` with no padding, the export's text column.
        @discardableResult
        func addContainer(_ size: CGSize) -> NSTextContainer {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            return container
        }
    }

    private struct Page {
        let segment: Segment
        let glyphs: NSRange
        /// 1 for a flowed page; below 1 for a line taller than the page, drawn scaled down.
        let scale: CGFloat
        /// Where a scaled line's fragment starts in its container.
        let top: CGFloat
    }

    let pageContentSize: CGSize
    let tableWidth: CGFloat
    private let gridInk: UIColor
    private let maximumPageCount: Int
    private var pages: [Page]

    /// Lays `attributed` out on pages of `pageContentSize`; nil when the document would need
    /// more than `maximumPageCount` pages (a parameter only for tests). `tableWidth` is the
    /// column width the render fitted tables to (the page width when nil).
    init?(
        attributed: NSAttributedString,
        pageContentSize: CGSize,
        tableWidth: CGFloat? = nil,
        gridInk: UIColor = PhonePageLayout.defaultGridInk,
        maximumPageCount: Int = PhonePageLayout.maximumPageCount
    ) {
        self.pageContentSize = pageContentSize
        self.maximumPageCount = maximumPageCount
        self.tableWidth = min(tableWidth ?? pageContentSize.width, pageContentSize.width)
        self.gridInk = gridInk
        pages = []
        guard paginate(Self.fittingAttachments(of: attributed, to: pageContentSize)) else { return nil }
    }

    var pageCount: Int { pages.count }

    /// Each page's characters in the document, in page order. Together they cover the document
    /// once, with no gap and no overlap.
    var pageCharacterRanges: [NSRange] {
        pages.map { page in
            let range = page.segment.layoutManager.characterRange(forGlyphRange: page.glyphs, actualGlyphRange: nil)
            return NSRange(location: range.location + page.segment.offset, length: range.length)
        }
    }

    /// The scale page `index` is drawn at: 1, or less for a line taller than the page.
    func scale(ofPage index: Int) -> CGFloat {
        pages.indices.contains(index) ? pages[index].scale : 1
    }

    // MARK: - Pagination

    private func paginate(_ document: NSAttributedString) -> Bool {
        let length = document.length
        guard length > 0 else {
            // An empty document still exports one (blank) page.
            let segment = Segment(document, from: 0, length: 0)
            segment.addContainer(pageContentSize)
            pages.append(Page(segment: segment, glyphs: NSRange(location: 0, length: 0), scale: 1, top: 0))
            return true
        }
        var start = 0
        while start < length {
            let segment = Segment(document, from: start, length: length - start)
            let glyphCount = segment.layoutManager.numberOfGlyphs
            var laidOut = 0
            while laidOut < glyphCount {
                guard pages.count < maximumPageCount else { return false }
                let container = segment.addContainer(pageContentSize)
                // Asking for the container's glyphs lays it out.
                let range = segment.layoutManager.glyphRange(for: container)
                // A line taller than the page: depending on the OS, TextKit leaves the container
                // empty (and every later one too) or puts the line in clipped to the page height,
                // cutting the picture off. Either way this layout ends here, before that line.
                if range.length == 0 || Self.fillsPage(segment.layoutManager, at: range.location, height: pageContentSize.height) {
                    segment.layoutManager.removeTextContainer(at: segment.layoutManager.textContainers.count - 1)
                    laidOut = range.length == 0 ? laidOut : range.location
                    break
                }
                pages.append(Page(segment: segment, glyphs: range, scale: 1, top: 0))
                laidOut = NSMaxRange(range)
            }
            guard laidOut < glyphCount else { return true }

            // The line at `laidOut` gets a page of its own, scaled to fit; the text after it
            // starts a new layout on the next page.
            guard pages.count < maximumPageCount else { return false }
            let lineStart = segment.offset + segment.layoutManager.characterIndexForGlyph(at: laidOut)
            guard let lineEnd = appendScaledLinePage(document, from: lineStart), lineEnd > lineStart else { return false }
            start = lineEnd
        }
        return true
    }

    /// Whether the line at `glyph` is as tall as the page: the line alone filled it.
    private static func fillsPage(_ layoutManager: NSLayoutManager, at glyph: Int, height: CGFloat) -> Bool {
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height >= height - 0.5
    }

    /// Lays out the line that starts at `location` without a height limit, adds it as a page
    /// drawn scaled down to the page, and returns where the line ends.
    private func appendScaledLinePage(_ document: NSAttributedString, from location: Int) -> Int? {
        let unbounded = CGSize(width: pageContentSize.width, height: .greatestFiniteMagnitude)
        let rest = Segment(document, from: location, length: document.length - location)
        rest.addContainer(unbounded)
        guard rest.layoutManager.numberOfGlyphs > 0 else { return nil }
        var lineGlyphs = NSRange(location: 0, length: 0)
        let rect = rest.layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &lineGlyphs)
        let lineLength = rest.layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil).length
        guard lineLength > 0 else { return nil }

        // The page draws this line from a layout of only this line.
        let line = Segment(document, from: location, length: lineLength)
        let glyphs = line.layoutManager.glyphRange(for: line.addContainer(unbounded))
        let scale = min(1, pageContentSize.height / max(rect.height, 1))
        pages.append(Page(segment: line, glyphs: glyphs, scale: scale, top: rect.minY))
        return location + lineLength
    }

    /// A copy of `attributed` in which every picture taller than its share of `page`, or wider
    /// than it, is scaled down (aspect kept) to fit. The original is never changed: Print lays
    /// one render out for several sheets.
    static func fittingAttachments(of attributed: NSAttributedString, to page: CGSize) -> NSAttributedString {
        var replacements: [(NSRange, NSTextAttachment)] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            // Only image attachments: a horizontal rule sizes itself to the line.
            guard let attachment = value as? NSTextAttachment,
                  type(of: attachment) == BlockRenderedAttachment.self || type(of: attachment) == NSTextAttachment.self,
                  let image = attachment.image else { return }
            let bounds = attachment.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let multiple = max(1, style?.lineHeightMultiple ?? 1)
            let spacing = (style?.paragraphSpacingBefore ?? 0) + (style?.paragraphSpacing ?? 0)
            let maxHeight = max(1, (page.height * attachmentHeightFraction - spacing) / multiple)
            let factor = min(1, maxHeight / bounds.height, page.width / bounds.width)
            guard factor < 1 else { return }
            let fitted = attachment is BlockRenderedAttachment ? BlockRenderedAttachment() : NSTextAttachment()
            fitted.image = image
            fitted.bounds = CGRect(
                x: bounds.minX * factor, y: bounds.minY * factor,
                width: bounds.width * factor, height: bounds.height * factor
            )
            replacements.append((range, fitted))
        }
        guard !replacements.isEmpty else { return attributed }
        let copy = NSMutableAttributedString(attributedString: attributed)
        for (range, attachment) in replacements {
            copy.addAttribute(.attachment, value: attachment, range: range)
        }
        return copy
    }

    // MARK: - Drawing

    /// Draws page `index`'s backgrounds, glyphs (attachments included) and table grid into the
    /// current UIKit context, with the page's text at `contentOrigin`. Dynamic colours (a link's
    /// ink) resolve in the light appearance: the page is always white, whatever the app's mode.
    func drawPage(_ index: Int, contentOrigin: CGPoint) {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        guard page.glyphs.length > 0, let context = UIGraphicsGetCurrentContext() else { return }
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            context.saveGState()
            defer { context.restoreGState() }
            var origin = contentOrigin
            if page.scale < 1 {
                context.translateBy(x: contentOrigin.x, y: contentOrigin.y)
                context.scaleBy(x: page.scale, y: page.scale)
                origin = CGPoint(x: 0, y: -page.top)
            }
            let layoutManager = page.segment.layoutManager
            layoutManager.drawBackground(forGlyphRange: page.glyphs, at: origin)
            drawTableGrid(in: page.glyphs, of: page.segment, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: page.glyphs, at: origin)
        }
    }

    // MARK: - Table grid

    /// The grid's ink on the white page: the Read view's grid alpha over the export ink, through
    /// the same contrast floor.
    static var defaultGridInk: UIColor {
        Theme.theme(for: .system).readableInk(
            DiagramPalette.ink(isDark: false).withAlphaComponent(LineformReadView.tableGridAlpha),
            minimumRatio: LineformReadView.tableGridMinimumRatio,
            on: .white
        )
    }

    /// The Read view's grid (`LineformReadView.tableGridPath`) for the rows on this page: a line
    /// above each table's first row on the page, one under every row, and the column edges from the
    /// rows' fractions of `tableWidth`. A table that continues from the previous page starts its
    /// lines at this page's first row.
    private func drawTableGrid(in glyphs: NSRange, of segment: Segment, at origin: CGPoint) {
        let layoutManager = segment.layoutManager
        let textStorage = segment.textStorage
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var tables: [[NSRange]] = []
        textStorage.enumerateAttribute(.markdownTableRow, in: characters) { value, range, _ in
            guard let number = value as? NSNumber else { return }
            if number.intValue == 0 || tables.isEmpty {
                tables.append([range])
            } else {
                tables[tables.count - 1].append(range)
            }
        }
        guard !tables.isEmpty else { return }

        let width = tableWidth
        let path = UIBezierPath()
        for table in tables {
            var rowTops: [CGFloat] = []
            var bottom: CGFloat = 0
            for range in table {
                let rowGlyphs = NSIntersectionRange(
                    layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs
                )
                guard rowGlyphs.length > 0 else { continue }
                let first = layoutManager.lineFragmentRect(forGlyphAt: rowGlyphs.location, effectiveRange: nil)
                let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(rowGlyphs) - 1, effectiveRange: nil)
                rowTops.append(first.minY + origin.y)
                bottom = last.maxY + origin.y
            }
            guard let top = rowTops.first else { continue }
            for y in rowTops + [bottom] {
                path.move(to: CGPoint(x: origin.x, y: y))
                path.addLine(to: CGPoint(x: origin.x + width, y: y))
            }
            if let fractions = textStorage.attribute(.markdownTableColumnFractions, at: table[0].location, effectiveRange: nil) as? [NSNumber] {
                for x in LineformReadView.columnEdges(fractions: fractions.map { CGFloat($0.doubleValue) }, fitWidth: width) {
                    path.move(to: CGPoint(x: origin.x + x, y: top))
                    path.addLine(to: CGPoint(x: origin.x + x, y: bottom))
                }
            }
        }
        gridInk.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
