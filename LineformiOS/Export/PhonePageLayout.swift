import LineformCore
import UIKit

/// Paginates an attributed string with TextKit 1, the stack the iPhone Read view and the Mac's
/// export both use: one `NSTextStorage`, one `NSLayoutManager`, and one page-sized
/// `NSTextContainer` per page, added until every glyph is laid out. The Mac paginates through
/// `NSPrintOperation`; the iPhone has none for a file, so the pages are the containers themselves.
///
/// Tables are the renderer's tab-stop rows; like the Read view, the hairline grid is drawn behind
/// them here (the rows carry `.markdownTableRow` and `.markdownTableColumnFractions`).
@MainActor
final class PhonePageLayout {
    /// A runaway guard: a document never produces more pages than this.
    static let maximumPageCount = 2_000

    let pageContentSize: CGSize
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private var containers: [NSTextContainer] = []

    init(attributed: NSAttributedString, pageContentSize: CGSize) {
        self.pageContentSize = pageContentSize
        textStorage = NSTextStorage(attributedString: attributed)
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        paginate()
    }

    var pageCount: Int { containers.count }

    private func paginate() {
        let glyphCount = layoutManager.numberOfGlyphs
        repeat {
            let container = NSTextContainer(size: pageContentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            // Asking for the container's glyphs lays it out.
            let range = layoutManager.glyphRange(for: container)
            if NSMaxRange(range) >= glyphCount { break }
            // A page that took nothing (a line taller than the page) would repeat forever:
            // stop rather than emit blank pages up to the cap.
            if range.length == 0, containers.count > 1 {
                layoutManager.removeTextContainer(at: containers.count - 1)
                containers.removeLast()
                break
            }
        } while containers.count < Self.maximumPageCount
    }

    /// Draws page `index`'s backgrounds, glyphs (attachments included) and table grid into the
    /// current UIKit context, with the page's text container at `contentOrigin`.
    func drawPage(_ index: Int, contentOrigin: CGPoint) {
        guard containers.indices.contains(index) else { return }
        let glyphs = layoutManager.glyphRange(for: containers[index])
        guard glyphs.length > 0 else { return }
        layoutManager.drawBackground(forGlyphRange: glyphs, at: contentOrigin)
        drawTableGrid(in: glyphs, at: contentOrigin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: contentOrigin)
    }

    // MARK: - Table grid

    /// The Read view's grid (`LineformReadView.tableGridPath`) for the rows on this page: a line
    /// above each table's first row on the page, one under every row, and the column edges from the
    /// rows' fractions of the page width (the width the export placed their tab stops for). A table
    /// that continues from the previous page starts its lines at this page's first row.
    private func drawTableGrid(in glyphs: NSRange, at origin: CGPoint) {
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

        let width = pageContentSize.width
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
        let theme = Theme.theme(for: .system)
        theme.readableInk(
            DiagramPalette.ink(isDark: false).withAlphaComponent(LineformReadView.tableGridAlpha),
            minimumRatio: LineformReadView.tableGridMinimumRatio,
            on: .white
        ).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
