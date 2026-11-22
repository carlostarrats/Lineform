import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// iOS only: on every run of a rendered table row; value is the row's index (`NSNumber`,
    /// header = 0), so the iPhone Read view can draw the grid behind the tab-aligned rows.
    public static let markdownTableRow = NSAttributedString.Key("lineform.markdownTableRow")
    /// iOS only: on every run of a rendered table row; value is each column's share of the column
    /// width the row's tab stops were placed for (`[NSNumber]`, fractions of 1, from
    /// `fitColumnPercentages`), so the iPhone Read view draws the grid's column edges from the
    /// same numbers as the stops.
    public static let markdownTableColumnFractions = NSAttributedString.Key("lineform.markdownTableColumnFractions")
}

/// Emits a parsed GFM table as live, selectable, theme-colored text.
///
/// macOS: a native `NSTextTable` that lays out responsively to the reading column and wraps cell
/// text when narrow. iOS has no text tables: one paragraph per row, cells joined by tabs and
/// placed by `NSTextTab`s at each column's share of the column width.
enum MarkdownTableEmitter {
    @MainActor
    static func append(
        rows: [(cells: [String], isHeader: Bool)],
        alignments: [MarkdownTableAlignment],
        columnPercentages: [CGFloat],
        columnWidth: CGFloat,
        fitToWidth: Bool,
        cellFont: PlatformFont,
        headerFont: PlatformFont,
        baseAttributes: [NSAttributedString.Key: Any],
        theme: Theme,
        to output: NSMutableAttributedString
    ) {
        let columns = alignments.count
        guard columns > 0 else { return }

        #if os(macOS)
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        let borderColor = theme.textColor.withAlphaComponent(0.25)
        let headerFill = theme.textColor.withAlphaComponent(0.06)

        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                let block = NSTextTableBlock(
                    table: textTable,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setBorderColor(borderColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                // When exporting to a fixed page, content-sized columns can overflow the (narrow)
                // page column and clip on the right, so each column gets a percentage width
                // proportional to its longest cell (`fitColumnPercentages`). On screen this stays
                // off and the wide reading column keeps natural content-sized columns.
                if fitToWidth {
                    block.setContentWidth(columnPercentages[column], type: .percentageValueType)
                }
                if row.isHeader {
                    block.backgroundColor = headerFill
                }

                let paragraph = mutableParagraphStyle(from: baseAttributes)
                paragraph.textBlocks = [block]
                paragraph.alignment = nsAlignment(alignments[column])

                var attributes = baseAttributes
                attributes[.paragraphStyle] = paragraph
                attributes[.font] = row.isHeader ? headerFont : cellFont

                let cellText = column < row.cells.count ? row.cells[column] : ""
                output.append(NSAttributedString(string: cellText + "\n", attributes: attributes))
            }
        }
        #else
        let paragraph = mutableParagraphStyle(from: baseAttributes)
        paragraph.tabStops = tabStops(alignments: alignments, columnPercentages: columnPercentages, columnWidth: columnWidth)
        // A left-aligned first column starts at the line's leading edge; any other first column
        // needs a leading tab to reach its own stop.
        let leading = alignments[0] == .left ? "" : "\t"
        let fractions = (0..<columns).map { column in
            NSNumber(value: Double(column < columnPercentages.count ? columnPercentages[column] / 100 : 0))
        }

        for (rowIndex, row) in rows.enumerated() {
            var attributes = baseAttributes
            attributes[.paragraphStyle] = paragraph
            attributes[.font] = row.isHeader ? headerFont : cellFont
            attributes[.markdownTableRow] = NSNumber(value: rowIndex)
            attributes[.markdownTableColumnFractions] = fractions

            let cells = (0..<columns).map { column in column < row.cells.count ? row.cells[column] : "" }
            output.append(NSAttributedString(string: leading + cells.joined(separator: "\t") + "\n", attributes: attributes))
        }
        #endif
    }

    /// A mutable copy of the base paragraph style (or a fresh one).
    private static func mutableParagraphStyle(from attributes: [NSAttributedString.Key: Any]) -> NSMutableParagraphStyle {
        if let base = attributes[.paragraphStyle] as? NSParagraphStyle,
           let mutable = base.mutableCopy() as? NSMutableParagraphStyle {
            return mutable
        }
        return NSMutableParagraphStyle()
    }

    private static func nsAlignment(_ alignment: MarkdownTableAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    #if os(iOS)
    /// One stop per column at the cumulative `columnPercentages × columnWidth`: left at the
    /// column's start, center at its middle, right at its end. A stop that would not lie past the
    /// previous one (a right-aligned column followed by a left-aligned one share a location) moves
    /// one point on, so every column keeps a stop of its own.
    private static func tabStops(
        alignments: [MarkdownTableAlignment],
        columnPercentages: [CGFloat],
        columnWidth: CGFloat
    ) -> [NSTextTab] {
        var stops: [NSTextTab] = []
        var start: CGFloat = 0
        var previous: CGFloat = -1
        for (column, alignment) in alignments.enumerated() {
            let percentage = column < columnPercentages.count ? columnPercentages[column] : 0
            let width = max(0, percentage / 100 * columnWidth)
            let location: CGFloat
            switch alignment {
            case .left: location = start
            case .center: location = start + width / 2
            case .right: location = start + width
            }
            let placed = max(location, previous + 1)
            stops.append(NSTextTab(textAlignment: nsAlignment(alignment), location: placed))
            previous = placed
            start += width
        }
        return stops
    }
    #endif
}
