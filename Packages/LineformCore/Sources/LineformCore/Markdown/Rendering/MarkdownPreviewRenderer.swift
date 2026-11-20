import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Attached to a rendered task-checkbox glyph; value is an `NSValue` boxing the `NSRange` of the
    /// `[ ]`/`[x]` marker in the source document, so a click on the glyph can toggle that span.
    public static let checkboxSourceRange = NSAttributedString.Key("lineform.checkboxSourceRange")

    /// Attached to rendered heading text; value is an `NSValue` boxing the `NSRange` of the
    /// heading line in the source document, so the outline sidebar can sync its scroll state.
    public static let headingSourceRange = NSAttributedString.Key("lineform.headingSourceRange")

    /// Attached to a rendered fenced-code body; value is an `NSValue` boxing the `NSRange` of the
    /// code body in the SOURCE document, so the hover copy pill can copy the raw code.
    public static let codeBlockSourceRange = NSAttributedString.Key("lineform.codeBlockSourceRange")

    /// Attached to a rendered "🖼 label" image placeholder run; value is an `NSValue` boxing the
    /// `NSRange` of the WHOLE image line in the source document (an own-line `![alt](path)`), so a
    /// Reconnect affordance can re-verify and rewrite the exact source substring.
    public static let imageSourceRange = NSAttributedString.Key("lineform.imageSourceRange")

    /// A marker (`NSNumber(true)`) on an image placeholder run indicating a Reconnect pill should be
    /// offered — set whenever the image did NOT resolve to a rendered `BlockRenderedAttachment`
    /// (remote, unresolved, or a local file that failed to load).
    public static let imageReconnect = NSAttributedString.Key("lineform.imageReconnect")

    /// Attached to every rendered run; value is an `NSValue` boxing the SOURCE `NSRange` that the run
    /// maps back to — a single source line for prose/heading runs (from `appendLines`), or the whole
    /// source span of a multi-line block (blockquote/list/table/callout/…). Gives a full
    /// rendered→source position map (finer than `.headingSourceRange`, which only marks headings) so
    /// Read/Preview can report and restore the reading position across a display-mode switch. The
    /// span's LENGTH bounds the sub-line offset the reader adds, so a position inside a multi-line
    /// block can never overshoot past the block (which would mis-restore and mis-bold the outline).
    public static let sourceSpan = NSAttributedString.Key("lineform.sourceSpan")
}

@MainActor
public struct MarkdownPreviewRenderer {
    /// Table cell text renders at this fraction of the reading font size — denser than prose, but
    /// still relative so it scales with the user's size setting. Dial-able.
    public static let tableTextScale: CGFloat = 0.9
    private static let headingSizeBoosts: [Int: CGFloat] = [
        1: 11,
        2: 3,
        3: 2,
        4: 1,
        5: 0,
        6: 0
    ]

    public init() {}

    /// Back-compat convenience (used by tests and any caller that doesn't render mermaid): uses
    /// a disabled mermaid provider so ```mermaid blocks fall back to a captioned source block.
    public func render(
        _ text: String,
        profile: ReadingProfile,
        displayMetrics: RenderDisplayMetrics = .current
    ) -> NSAttributedString {
        render(
            text,
            profile: profile,
            columnWidth: CGFloat(profile.columnWidth),
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            displayMetrics: displayMetrics
        )
    }

    public func render(
        _ text: String,
        profile: ReadingProfile,
        columnWidth: CGFloat,
        mermaidProvider: MermaidImageProviding,
        mathProvider: MathImageProviding,
        diagramLog: DiagramFailureLogging,
        appVersion: String,
        // Export/print sets this so tables shrink to fit the page (proportional percentage
        // columns, cells wrap) instead of overflowing a narrow page column. On screen it stays
        // false so the wide reading column keeps content-sized columns.
        fitTablesToWidth: Bool = false,
        // Export/print (RTF) sets this so math and mermaid blocks emit their caption + source text
        // instead of a rasterized attachment — plain RTF can't portably embed images. On screen
        // it stays false so math/mermaid render as images as they do today.
        imagesAsText: Bool = false,
        // True on screen (Read/Preview) → code is syntax-highlighted; false from
        // DocumentExportRenderer → code stays MONOCHROME in PDFs (user decision).
        highlightsCode: Bool = true,
        codeHighlighter: CodeSyntaxHighlighting = CodeSyntaxHighlighter(),
        // The open document's containing folder, used to resolve relative local image paths
        // (`ImageResolver.resolve(path:documentDirectory:)`). nil → relative paths stay
        // unresolved (placeholder). On-screen Read/Preview and RTF/Normal-source export leave
        // this nil (placeholder). The Styled PDF/Print export path passes the document's real
        // directory so resolvable local images render (see `DocumentExportRenderer`).
        documentDirectory: URL? = nil,
        // Local-image-file loading seam (mirrors mermaidProvider/mathProvider). Defaults to a
        // provider that never loads, so callers that don't care about images (tests, export)
        // get the placeholder fallback for free.
        imageProvider: ImageAttachmentProviding = DisabledImageAttachmentProvider(),
        // Export/print's Style presets scale heading sizes over body (multiplier on the
        // per-level boost). Not a `ReadingProfile` field. Defaults to a no-op so on-screen
        // Read/Preview rendering is byte-identical.
        headingScale: CGFloat = 1.0,
        // The display the rasters (diagrams, math, images) are drawn for. The default is read
        // per call — on macOS from `NSScreen.main` — so a window that moved to a screen of
        // another scale renders for that screen.
        displayMetrics: RenderDisplayMetrics = .current
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let bodyAttributes = MarkdownTextStyle.baseAttributes(for: profile)
        let bodyBlockSpacingAttributes = blockSpacingAttributes(bodyAttributes, profile: profile)
        let codeAttributes = codeAttributes(profile: profile)
        let codeBlockSpacingAttributes = blockSpacingAttributes(codeAttributes, profile: profile)
        // CR-stripped lines with ranges measured against the ORIGINAL text, so a CRLF document
        // groups into real blocks while every source range still points at the right bytes.
        let source = markdownSourceLines(in: text)
        let lines = source.lines
        let lineRanges = source.ranges
        let blockSpacingLineIndexes = Set(MarkdownTextStyle.markdownBlockSpacingLineIndexes(inLines: lines))
        let theme = Theme.theme(for: profile)

        // Group the lines once, then render each block. `.lines` runs reproduce the original
        // per-line output exactly (headings / inline-with-math / fenced code), and the mermaid /
        // display-math blocks reuse the same emitters and the same trailing-newline rules as
        // before — byte-identical for the existing constructs. New block constructs become new
        // cases here plus their own emitter.
        // Running cursor over source line indices. `markdownBlocks` is a strict contiguous partition
        // of the lines (ordinary lines are flushed as `.lines` between special blocks), so each
        // block's FIRST source line is the line after the previous block's last — which lets a
        // `lastLineIndex`-only block still know its full source span.
        var sourceLineCursor = 0
        for block in markdownBlocks(in: lines, lineRanges: lineRanges) {
            let blockRenderStart = output.length
            let blockFirstLine = sourceLineCursor
            switch block {
            case .lines(let range):
                appendLines(
                    range,
                    to: output,
                    lines: lines,
                    lineRanges: lineRanges,
                    profile: profile,
                    theme: theme,
                    mathProvider: mathProvider,
                    bodyAttributes: bodyAttributes,
                    bodyBlockSpacingAttributes: bodyBlockSpacingAttributes,
                    blockSpacingLineIndexes: blockSpacingLineIndexes,
                    imagesAsText: imagesAsText,
                    headingScale: headingScale,
                    displayMetrics: displayMetrics
                )
            case .singleLineMath(let latex, let lineIndex):
                appendMathBlock(
                    latex: latex,
                    to: output,
                    profile: profile,
                    theme: theme,
                    columnWidth: columnWidth,
                    codeAttributes: codeAttributes,
                    mathProvider: mathProvider,
                    imagesAsText: imagesAsText,
                    displayMetrics: displayMetrics
                )
                if lineIndex < lines.count - 1 {
                    let usesBlockSpacing = blockSpacingLineIndexes.contains(lineIndex)
                    let activeBodyAttributes = usesBlockSpacing ? bodyBlockSpacingAttributes : bodyAttributes
                    output.append(NSAttributedString(string: "\n", attributes: activeBodyAttributes))
                }
            case .fencedMath(let latex, let closingIndex):
                appendMathBlock(
                    latex: latex,
                    to: output,
                    profile: profile,
                    theme: theme,
                    columnWidth: columnWidth,
                    codeAttributes: codeAttributes,
                    mathProvider: mathProvider,
                    imagesAsText: imagesAsText,
                    displayMetrics: displayMetrics
                )
                appendBlockSeparator(afterLine: closingIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .mermaid(let source, let closingIndex):
                appendMermaidBlock(
                    source: source,
                    to: output,
                    profile: profile,
                    theme: theme,
                    columnWidth: columnWidth,
                    codeAttributes: codeAttributes,
                    mermaidProvider: mermaidProvider,
                    diagramLog: diagramLog,
                    appVersion: appVersion,
                    imagesAsText: imagesAsText,
                    displayMetrics: displayMetrics
                )
                appendBlockSeparator(afterLine: closingIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .horizontalRule(let lineIndex):
                appendHorizontalRule(to: output, profile: profile, theme: theme)
                appendBlockSeparator(afterLine: lineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .blockquote(let quoteLines, let lastLineIndex):
                appendBlockquote(quoteLines, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, mathProvider: mathProvider, imagesAsText: imagesAsText, displayMetrics: displayMetrics)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .callout(let kind, let title, let body, let lastLineIndex):
                appendCallout(kind: kind, title: title, body: body, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, mathProvider: mathProvider, imagesAsText: imagesAsText, displayMetrics: displayMetrics)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .list(let items, let lastLineIndex):
                appendList(items, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, mathProvider: mathProvider, imagesAsText: imagesAsText, displayMetrics: displayMetrics)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .table(let table, let lastLineIndex):
                appendTable(table, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, columnWidth: columnWidth, fitToWidth: fitTablesToWidth)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .fencedCode(let language, let body, let openingIndex, let closingIndex):
                appendCodeBlock(
                    language: language,
                    body: body,
                    openingIndex: openingIndex,
                    closingIndex: closingIndex,
                    to: output,
                    lines: lines,
                    lineRanges: lineRanges,
                    theme: theme,
                    highlightsCode: highlightsCode,
                    codeHighlighter: codeHighlighter,
                    codeAttributes: codeAttributes
                )
                // When the closing fence's own source line was flagged for block spacing (a blank
                // line follows the fence), the pre-Task-4 renderer carried that bumped spacing on
                // the (then-rendered) closing fence line itself. That line is no longer rendered,
                // so the same rhythm is restored on the block separator right after the code —
                // the paragraph whose trailing spacing actually creates the gap before whatever
                // follows.
                let separatorAttributes = closingIndex.map { blockSpacingLineIndexes.contains($0) } == true
                    ? codeBlockSpacingAttributes
                    : bodyAttributes
                appendBlockSeparator(
                    afterLine: closingIndex ?? openingIndex,
                    to: output,
                    totalLines: lines.count,
                    attributes: separatorAttributes
                )
            case .image(let alt, let path, let sourceRange, let lineIndex):
                appendImageBlock(
                    alt: alt,
                    path: path,
                    sourceRange: sourceRange,
                    to: output,
                    profile: profile,
                    theme: theme,
                    columnWidth: columnWidth,
                    documentDirectory: documentDirectory,
                    imageProvider: imageProvider,
                    bodyAttributes: bodyAttributes,
                    isLastLine: lineIndex >= lines.count - 1,
                    displayMetrics: displayMetrics
                )
            }

            // Advance the cursor past this block, then tag it. `.lines` blocks attach a precise
            // per-line source span themselves (in `appendLines`); every OTHER block gets ONE span —
            // its FULL source range (first line start … last line end) — over its whole rendered
            // range, so a position inside it is anchored within the block and can't overshoot past
            // it (the multi-line-block overshoot bug).
            let blockLastLine = Self.blockLastLine(block, totalLines: lines.count)
            sourceLineCursor = blockLastLine + 1
            if case .lines = block {} else if
                lines.indices.contains(blockFirstLine),
                lines.indices.contains(blockLastLine),
                output.length > blockRenderStart
            {
                let start = lineRanges[blockFirstLine].location
                let span = NSRange(location: start, length: max(0, NSMaxRange(lineRanges[blockLastLine]) - start))
                output.addAttribute(
                    .sourceSpan,
                    value: NSValue(range: span),
                    range: NSRange(location: blockRenderStart, length: output.length - blockRenderStart)
                )
            }
        }

        return output
    }

    /// The last SOURCE line index a block covers — must mirror `markdownBlocks`' line consumption
    /// exactly, so the running `sourceLineCursor` stays aligned with the partition.
    private static func blockLastLine(_ block: MarkdownBlock, totalLines: Int) -> Int {
        switch block {
        case .lines(let range):
            return range.upperBound - 1
        case .singleLineMath(_, let lineIndex):
            return lineIndex
        case .fencedMath(_, let closingIndex):
            return closingIndex ?? (totalLines - 1)
        case .mermaid(_, let closingIndex):
            return closingIndex ?? (totalLines - 1)
        case .horizontalRule(let lineIndex):
            return lineIndex
        case .blockquote(_, let lastLineIndex):
            return lastLineIndex
        case .callout(_, _, _, let lastLineIndex):
            return lastLineIndex
        case .list(_, let lastLineIndex):
            return lastLineIndex
        case .table(_, let lastLineIndex):
            return lastLineIndex
        case .fencedCode(_, _, _, let closingIndex):
            return closingIndex ?? (totalLines - 1)
        case .image(_, _, _, let lineIndex):
            return lineIndex
        }
    }

    /// Emit a GFM table as live, selectable, theme-colored text (`MarkdownTableEmitter`: a native
    /// `NSTextTable` on macOS that lays out responsively to the reading column and wraps cell text
    /// when narrow; tab-aligned rows on iOS). The header row is distinguished; per-column
    /// alignment comes from the delimiter row; gridlines are quiet and contrast-derived from the
    /// theme so they read on light and dark pages.
    private func appendTable(
        _ table: MarkdownTable,
        to output: NSMutableAttributedString,
        baseAttributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        columnWidth: CGFloat,
        fitToWidth: Bool = false
    ) {
        let columns = table.columnCount
        guard columns > 0 else { return }

        // When exporting to a fixed page, content-sized columns can overflow the (narrow) page
        // column and clip on the right. Give each column a percentage width proportional to its
        // longest cell, summing to a value under 100% (leaving room for per-cell padding/borders),
        // so the whole table fits the page and long cells wrap. On screen the Mac emitter ignores
        // them and the wide reading column keeps natural content-sized columns; the iPhone
        // emitter places its tab stops with them.
        let allRows: [(cells: [String], isHeader: Bool)] =
            [(table.headers, true)] + table.rows.map { ($0, false) }
        let columnPercentages = Self.fitColumnPercentages(rows: allRows, columns: columns)

        let baseFont = (baseAttributes[.font] as? PlatformFont) ?? PlatformFont.systemFont(ofSize: CGFloat(profile.fontSize))
        // Table cells render slightly smaller than prose (a common, denser table convention) while
        // still tracking the reading font size — so it scales with the user's accessibility setting
        // and just fits more per column, easing the too-wide case. Relative, never a fixed size.
        let cellFont = Self.font(baseFont, size: baseFont.pointSize * Self.tableTextScale)
        let headerFont = lineformFont(cellFont, adding: .bold)

        MarkdownTableEmitter.append(
            rows: allRows,
            alignments: table.alignments,
            columnPercentages: columnPercentages,
            columnWidth: columnWidth,
            fitToWidth: fitToWidth,
            cellFont: cellFont,
            headerFont: headerFont,
            baseAttributes: baseAttributes,
            theme: theme,
            to: output
        )
    }

    /// `font`'s face at `size`. macOS: `NSFont(descriptor:size:)`, falling back to `font` when
    /// that fails, exactly as the renderer always has. iOS: `UIFont(descriptor:size:)`.
    private static func font(_ font: PlatformFont, size: CGFloat) -> PlatformFont {
        #if os(macOS)
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        #else
        UIFont(descriptor: font.fontDescriptor, size: size)
        #endif
    }

    /// Sets the VoiceOver description of a rendered image. macOS: `accessibilityDescription`.
    /// iOS: `accessibilityLabel`.
    private static func setAccessibilityDescription(_ description: String, on image: PlatformImage) {
        #if os(macOS)
        image.accessibilityDescription = description
        #else
        image.accessibilityLabel = description
        #endif
    }

    /// Percentage content widths (of the page column) per table column, proportional to each
    /// column's longest cell, summing to a budget under 100% so per-cell padding + borders don't
    /// push the table past the page column. Used only for export (fit-to-width). A small floor
    /// keeps a short column from collapsing.
    public static func fitColumnPercentages(rows: [(cells: [String], isHeader: Bool)], columns: Int) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var weights = [CGFloat](repeating: 1, count: columns)
        for column in 0..<columns {
            var longest = 1
            for row in rows {
                let cell = column < row.cells.count ? row.cells[column] : ""
                longest = max(longest, cell.count)
            }
            weights[column] = CGFloat(longest)
        }
        let total = weights.reduce(0, +)
        // Reserve headroom for each column's padding (6pt × 2) and border so the sum of content
        // widths plus that fixed overhead stays within the page column.
        let budget: CGFloat = 88
        let floor: CGFloat = 100 / CGFloat(columns) * 0.25
        // Give every column its floor first, then split the remaining budget proportionally by
        // weight. This guarantees the total is exactly `budget` (never over) even when many narrow
        // columns would each be raised to the floor — a plain `max(floor, share)` could otherwise
        // sum past the page column and clip the table off the right margin. `floor * columns` is a
        // constant 25 (floor = 25/columns), so `distributable` is always positive under `budget`.
        let reserved = floor * CGFloat(columns)
        let distributable = max(0, budget - reserved)
        return weights.map { floor + ($0 / total) * distributable }
    }

    /// Emit a list: Google-Docs-style with a slight indent per nesting level, real bullets (•) and
    /// sequence numbers, and a hanging indent so wrapped lines align under the item text rather than
    /// the marker. Inline styling inside an item still renders.
    private func appendList(
        _ items: [MarkdownListItem],
        to output: NSMutableAttributedString,
        baseAttributes baseBody: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        let levelStep: CGFloat = 24
        let markerColumn: CGFloat = 22

        for (offset, item) in items.enumerated() {
            let base = CGFloat(item.indentLevel) * levelStep
            let textIndent = base + markerColumn
            let paragraph = mutableParagraphStyle(from: baseBody)
            paragraph.firstLineHeadIndent = base
            paragraph.headIndent = textIndent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: textIndent)]

            var attributes = baseBody
            attributes[.paragraphStyle] = paragraph

            if let checkbox = item.checkbox {
                // A task item: draw a check glyph carrying its source range for click-to-toggle,
                // then the item text. The glyph replaces the bullet.
                var glyphAttributes = attributes
                glyphAttributes[.checkboxSourceRange] = NSValue(range: checkbox.sourceRange)
                let glyph = checkbox.isChecked ? "☑" : "☐"
                output.append(NSAttributedString(string: glyph, attributes: glyphAttributes))
                output.append(NSAttributedString(string: "\t", attributes: attributes))
            } else {
                let marker = item.ordinal.map { "\($0)." } ?? "•"
                output.append(NSAttributedString(string: "\(marker)\t", attributes: attributes))
            }
            output.append(inlineWithMath(
                in: item.text,
                baseAttributes: attributes,
                profile: profile,
                theme: theme,
                mathProvider: mathProvider,
                imagesAsText: imagesAsText,
                displayMetrics: displayMetrics
            ))
            if offset < items.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
    }

    /// A mutable copy of the base paragraph style (or a fresh one) for block emitters that layer
    /// indents / tab stops / text blocks on top of the profile's line height.
    private func mutableParagraphStyle(from attributes: [NSAttributedString.Key: Any]) -> NSMutableParagraphStyle {
        if let base = attributes[.paragraphStyle] as? NSParagraphStyle,
           let mutable = base.mutableCopy() as? NSMutableParagraphStyle {
            return mutable
        }
        return NSMutableParagraphStyle()
    }

    /// Append the inter-block separator newline — the "\n" after a block unless it is the document's
    /// last line. `afterLine` is the block's last source line index, or nil (an unclosed block) →
    /// no separator.
    private func appendBlockSeparator(
        afterLine lineIndex: Int?,
        to output: NSMutableAttributedString,
        totalLines: Int,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let lineIndex, lineIndex < totalLines - 1 else { return }
        output.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    /// Emit a blockquote: each quoted line indented by its nesting depth (markers hidden) and
    /// gently de-emphasized so it reads as a set-apart quote while staying readable on every theme.
    /// Inline styling inside the quote (bold/italic/code/link/math) still renders.
    private func appendBlockquote(
        _ quoteLines: [MarkdownQuoteLine],
        to output: NSMutableAttributedString,
        baseAttributes baseBody: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        appendQuoteLines(quoteLines, to: output, baseAttributes: baseBody, profile: profile, theme: theme, mathProvider: mathProvider, imagesAsText: imagesAsText, displayMetrics: displayMetrics)
    }

    /// Emit a run of blockquote lines: each indented by its nesting depth (markers hidden) and gently
    /// de-emphasized. Inline styling (bold/italic/code/link/math) still renders. Shared by
    /// `appendBlockquote` and `appendCallout` so the two produce identical body output.
    private func appendQuoteLines(
        _ quoteLines: [MarkdownQuoteLine],
        to output: NSMutableAttributedString,
        baseAttributes baseBody: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        let quoteColor = theme.textColor.withAlphaComponent(0.8)
        let indentStep: CGFloat = 22

        for (offset, quote) in quoteLines.enumerated() {
            let indent = CGFloat(max(1, quote.depth)) * indentStep
            let paragraph = mutableParagraphStyle(from: baseBody)
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent

            var attributes = baseBody
            attributes[.paragraphStyle] = paragraph
            attributes[.foregroundColor] = quoteColor

            output.append(inlineWithMath(
                in: quote.text,
                baseAttributes: attributes,
                profile: profile,
                theme: theme,
                mathProvider: mathProvider,
                imagesAsText: imagesAsText,
                displayMetrics: displayMetrics
            ))
            if offset < quoteLines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
    }

    /// Emit a monochrome callout: a title row (tinted SF Symbol + title, medium weight, full ink)
    /// indented like the quote body, then the body via the shared `appendQuoteLines`. No color, no
    /// background, no bar — restraint over the multi-color admonition look, and export-safe.
    private func appendCallout(
        kind: CalloutKind,
        title: String?,
        body: [MarkdownQuoteLine],
        to output: NSMutableAttributedString,
        baseAttributes baseBody: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        let indentStep: CGFloat = 22
        let paragraph = mutableParagraphStyle(from: baseBody)
        paragraph.firstLineHeadIndent = indentStep
        paragraph.headIndent = indentStep

        let baseFont = (baseBody[.font] as? PlatformFont) ?? PlatformFont.systemFont(ofSize: CGFloat(profile.fontSize))
        let titleFont = lineformFont(baseFont, adding: .bold)

        var titleAttributes = baseBody
        titleAttributes[.paragraphStyle] = paragraph
        titleAttributes[.foregroundColor] = theme.textColor
        titleAttributes[.font] = titleFont

        // Tinted SF Symbol, baseline-aligned to the title font, carrying the title paragraph style so
        // the glyph shares the row's indent.
        if let symbol = calloutSymbolImage(for: kind, color: theme.textColor, pointSize: titleFont.pointSize) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = CGRect(x: 0, y: titleFont.descender, width: symbol.size.width, height: symbol.size.height)
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.addAttributes(titleAttributes, range: NSRange(location: 0, length: glyph.length))
            output.append(glyph)
            output.append(NSAttributedString(string: " ", attributes: titleAttributes))
        }

        let titleText = title ?? kind.displayName
        output.append(NSAttributedString(string: titleText, attributes: titleAttributes))

        if !body.isEmpty {
            output.append(NSAttributedString(string: "\n", attributes: titleAttributes))
            appendQuoteLines(body, to: output, baseAttributes: baseBody, profile: profile, theme: theme, mathProvider: mathProvider, imagesAsText: imagesAsText, displayMetrics: displayMetrics)
        }
    }

    /// A monochrome SF Symbol image tinted to `color` (the theme ink), sized to the body font, for the
    /// callout title row. Returns nil if the symbol is unavailable (caller then omits the glyph).
    private func calloutSymbolImage(for kind: CalloutKind, color: PlatformColor, pointSize: CGFloat) -> PlatformImage? {
        #if os(macOS)
        guard let base = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.displayName) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config) ?? base
        #else
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [color]))
        let image = UIImage(systemName: kind.symbolName, withConfiguration: config)
        image?.accessibilityLabel = kind.displayName
        return image
        #endif
    }

    /// Emit a quiet, full-width divider as a self-sizing attachment. The line is low-contrast
    /// (theme text at a low alpha), so it stays readable on every theme without a heavy bar.
    private func appendHorizontalRule(
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        theme: Theme
    ) {
        let attachment = HorizontalRuleAttachment(
            color: theme.textColor.withAlphaComponent(0.22),
            height: CGFloat(profile.fontSize)
        )
        output.append(NSAttributedString(attachment: attachment))
    }

    /// Render a maximal run of ordinary lines (body, headings) exactly as the original per-line
    /// loop did: each line emits its content plus a trailing newline unless it is the document's
    /// last line, and block-spacing attributes are looked up by original line index. Fence
    /// delimiter lines can never reach this function — `.fencedCode` consumes them wholesale at
    /// the grouping layer (`markdownBlocks(in:)`) before `.lines` runs are formed, and every
    /// fenced-code body is rendered by `appendCodeBlock` instead.
    private func appendLines(
        _ range: Range<Int>,
        to output: NSMutableAttributedString,
        lines: [String],
        lineRanges: [NSRange],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        bodyAttributes: [NSAttributedString.Key: Any],
        bodyBlockSpacingAttributes: [NSAttributedString.Key: Any],
        blockSpacingLineIndexes: Set<Int>,
        imagesAsText: Bool = false,
        headingScale: CGFloat = 1.0,
        displayMetrics: RenderDisplayMetrics
    ) {
        for index in range {
            let line = lines[index]
            let usesBlockSpacing = blockSpacingLineIndexes.contains(index)
            let activeBodyAttributes = usesBlockSpacing ? bodyBlockSpacingAttributes : bodyAttributes
            var lineTerminatorAttributes = activeBodyAttributes
            // Everything this source line emits carries its source offset, for exact cross-mode
            // scroll restore (see `.sourceSpan`).
            let renderedLineStart = output.length

            if let heading = heading(in: line) {
                var activeHeadingAttributes = headingAttributes(
                    level: heading.level,
                    profile: profile,
                    usesBlockSpacing: usesBlockSpacing,
                    headingScale: headingScale
                )
                if range.contains(index) {
                    activeHeadingAttributes[.headingSourceRange] = NSValue(range: lineRanges[index])
                }
                output.append(NSAttributedString(
                    string: heading.title,
                    attributes: activeHeadingAttributes
                ))
                lineTerminatorAttributes = activeHeadingAttributes
            } else {
                output.append(inlineWithMath(
                    in: line,
                    baseAttributes: activeBodyAttributes,
                    profile: profile,
                    theme: theme,
                    mathProvider: mathProvider,
                    imagesAsText: imagesAsText,
                    displayMetrics: displayMetrics
                ))
            }

            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: lineTerminatorAttributes))
            }

            if output.length > renderedLineStart {
                output.addAttribute(
                    .sourceSpan,
                    value: NSValue(range: lineRanges[index]),
                    range: NSRange(location: renderedLineStart, length: output.length - renderedLineStart)
                )
            }
        }
    }

    /// Emit a fenced code block: monospace body (fence delimiter lines hidden, like other markup),
    /// optionally syntax-highlighted. Highlighting is pure foreground color over token ranges —
    /// display-only, no rasters, nothing written to disk. The whole body carries a
    /// `.codeBlockSourceRange` attribute (the body's range in the SOURCE document) so the hover copy
    /// pill can copy the raw code.
    private func appendCodeBlock(
        language: String,
        body: String,
        openingIndex: Int,
        closingIndex: Int?,
        to output: NSMutableAttributedString,
        lines: [String],
        lineRanges: [NSRange],
        theme: Theme,
        highlightsCode: Bool,
        codeHighlighter: CodeSyntaxHighlighting,
        codeAttributes: [NSAttributedString.Key: Any]
    ) {
        guard !body.isEmpty else { return }   // empty fence → nothing to render or copy

        let coded = NSMutableAttributedString(string: body, attributes: codeAttributes)

        // Syntax colors only on screen (highlightsCode) and only for a recognized language; export
        // and unknown languages stay monochrome (the codeAttributes foreground is untouched).
        if highlightsCode {
            for token in codeHighlighter.tokens(for: body, language: language) where token.kind != .plain {
                guard NSMaxRange(token.range) <= (body as NSString).length else { continue }
                coded.addAttribute(.foregroundColor, value: CodeSyntaxPalette.color(for: token.kind, theme: theme), range: token.range)
            }
        }

        // BOTH endpoints come from `lineRanges`, never from the rendered body. `lineRanges` is
        // measured against the ORIGINAL text while `body` was joined from CR-STRIPPED lines, so
        // taking the length from `body` made the range short by one unit per body line on a
        // CRLF file — the copy pill then put the code on the pasteboard with its last
        // (bodyLines − 1) characters chopped off, silently. This is the drift the
        // `markdownSourceLines` invariant warns about, and it names copy as a consumer.
        let bodyFirst = openingIndex + 1
        let bodyLast = (closingIndex ?? lineRanges.count) - 1
        let sourceRange: NSRange
        if bodyFirst < lineRanges.count, bodyLast >= bodyFirst, bodyLast < lineRanges.count, bodyLast < lines.count {
            let start = lineRanges[bodyFirst].location
            // The last body line's CONTENT end, not its range end. A line's range spans the
            // ORIGINAL text, so on a CRLF file it includes the trailing `\r`; `lines[bodyLast]` is
            // the CR-stripped text, so location + its length lands exactly after the last real
            // character. Without this the pasteboard carried a stray carriage return with no `\n`
            // after it — found by clicking the pill on a real CRLF document, not by a test.
            let end = lineRanges[bodyLast].location + (lines[bodyLast] as NSString).length
            sourceRange = NSRange(location: start, length: max(0, end - start))
        } else {
            // Empty body (fence immediately closed): a zero-length range at the opening line's end.
            let start = openingIndex < lineRanges.count
                ? NSMaxRange(lineRanges[openingIndex])
                : 0
            sourceRange = NSRange(location: start, length: 0)
        }
        coded.addAttribute(.codeBlockSourceRange, value: NSValue(range: sourceRange), range: NSRange(location: 0, length: coded.length))

        output.append(coded)
    }

    /// Emit a mermaid block: a rendered diagram image (constrained to the column width, with a
    /// VoiceOver description) or the captioned-source fallback, logging failures.
    private func appendMermaidBlock(
        source: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        theme: Theme,
        columnWidth: CGFloat,
        codeAttributes: [NSAttributedString.Key: Any],
        mermaidProvider: MermaidImageProviding,
        diagramLog: DiagramFailureLogging,
        appVersion: String,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        if imagesAsText {
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes)
            return
        }
        let scale = displayMetrics.scale
        // Block diagrams: LIGHT themes render on a TRANSPARENT canvas (no box; dark ink draws crisp
        // node borders on the light page) with a fixed ink, so switching among light themes redraws
        // nothing. DARK themes render on a canvas set to the theme's own page color — it still reads
        // as "no box" (it matches the page) but gives Mermaid's node boxes a clearly visible outline,
        // which a transparent canvas can't (Mermaid derives the node fill from the canvas). That's
        // per-theme on the dark side, so switching between the two dark themes re-renders — cheap,
        // and Task 3a's memory cache keeps both.
        let isDark = theme.usesDarkChrome
        let outcome = mermaidProvider.outcome(
            source: source,
            background: isDark ? theme.backgroundColor : .clear,
            foreground: isDark ? theme.textColor : DiagramPalette.ink(isDark: false),
            scale: scale
        )

        switch outcome {
        case .image(let image):
            Self.setAccessibilityDescription(String(localized: "Mermaid diagram. \(source)", bundle: .module), on: image)
            let attachment = BlockRenderedAttachment()
            attachment.image = image
            let natural = image.size
            let width = min(natural.width, max(columnWidth, 1))
            let height = natural.width > 0 ? natural.height * (width / natural.width) : natural.height
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            output.append(NSAttributedString(attachment: attachment))
        case .skipped:
            // Size-guard skip: not a render failure, so no report affordance.
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes)
        case .unsupported:
            // Recognized-but-unrenderable mermaid type: clean fallback, not a bug — no log, no report.
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes)
        case .failed(let error):
            // Recorded to the LOCAL log only. There is deliberately no way to send it: nothing
            // in Lineform transmits document content off the device.
            diagramLog.record(source: source, error: error, appVersion: appVersion)
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes)
        }
    }

    private func appendMermaidFallback(
        source: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        codeAttributes: [NSAttributedString.Key: Any]
    ) {
        var captionAttributes = MarkdownTextStyle.baseAttributes(for: profile)
        // Through the contrast floor: a flat 0.6 alpha put this below AA on four of five themes,
        // and the caption is already drawn smaller than body text.
        captionAttributes[.foregroundColor] = Theme.theme(for: profile)
            .readableInk(Theme.theme(for: profile).textColor.withAlphaComponent(0.6))
        if let font = captionAttributes[.font] as? PlatformFont {
            captionAttributes[.font] = PlatformFont.systemFont(ofSize: max(10, font.pointSize - 2))
        }
        output.append(NSAttributedString(string: String(localized: "Mermaid diagram (source)", bundle: .module), attributes: captionAttributes))
        output.append(NSAttributedString(string: "\n", attributes: captionAttributes))
        output.append(NSAttributedString(string: source, attributes: codeAttributes))
    }

    /// Emit a display-math block: a centered rendered equation (constrained to the column width,
    /// with a VoiceOver description) or the captioned-source fallback. Math failures are the
    /// user's own LaTeX, so — unlike Mermaid — nothing is logged or offered for reporting.
    private func appendMathBlock(
        latex: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        theme: Theme,
        columnWidth: CGFloat,
        codeAttributes: [NSAttributedString.Key: Any],
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        if imagesAsText {
            appendMathFallback(latex: latex, to: output, profile: profile, codeAttributes: codeAttributes)
            return
        }
        let scale = displayMetrics.scale
        let pointSize = CGFloat(profile.fontSize)
        // Block math renders transparent (no canvas) with a fixed light/dark ink, so it matches
        // every theme's page and is exempt from theme-switch redraw.
        let isDark = theme.usesDarkChrome
        let outcome = mathProvider.outcome(
            latex: latex,
            style: .display,
            foreground: DiagramPalette.ink(isDark: isDark),
            pointSize: pointSize,
            scale: scale
        )

        switch outcome {
        case .image(let image, _):
            Self.setAccessibilityDescription(String(localized: "Math. \(latex)", bundle: .module), on: image)
            let attachment = BlockRenderedAttachment()
            attachment.image = image
            let natural = image.size
            let width = min(natural.width, max(columnWidth, 1))
            let height = natural.width > 0 ? natural.height * (width / natural.width) : natural.height
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            output.append(NSAttributedString(attachment: attachment))
        case .skipped, .failed:
            appendMathFallback(latex: latex, to: output, profile: profile, codeAttributes: codeAttributes)
        }
    }

    private func appendMathFallback(
        latex: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        codeAttributes: [NSAttributedString.Key: Any]
    ) {
        var captionAttributes = MarkdownTextStyle.baseAttributes(for: profile)
        // Through the contrast floor: a flat 0.6 alpha put this below AA on four of five themes,
        // and the caption is already drawn smaller than body text.
        captionAttributes[.foregroundColor] = Theme.theme(for: profile)
            .readableInk(Theme.theme(for: profile).textColor.withAlphaComponent(0.6))
        if let font = captionAttributes[.font] as? PlatformFont {
            captionAttributes[.font] = PlatformFont.systemFont(ofSize: max(10, font.pointSize - 2))
        }
        output.append(NSAttributedString(string: String(localized: "Math (source)", bundle: .module), attributes: captionAttributes))
        output.append(NSAttributedString(string: "\n", attributes: captionAttributes))
        output.append(NSAttributedString(string: latex, attributes: codeAttributes))
    }

    /// Render a body line, treating inline `$…$` / `$$…$$` math as a first-class inline token that
    /// competes with bold/italic/code/link by position. Math loses to an earlier code span or
    /// emphasis run (so `` `$x$` `` stays literal code and math is never detected inside another
    /// inline token), and wins when it starts first. Lines with no math take the existing fast path
    /// and behave exactly as before.
    private func inlineWithMath(
        in line: String,
        baseAttributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) -> NSAttributedString {
        let mathSpans = MathDelimiters.inlineSpans(in: line)
        guard !mathSpans.isEmpty else {
            return inlineMarkdown(in: line, baseAttributes: baseAttributes, profile: profile)
        }

        let output = NSMutableAttributedString()
        let nsLine = line as NSString
        var location = 0

        while location < nsLine.length {
            let regexToken = nextInlineToken(in: line, nsLine: nsLine, from: location)
            let mathSpan = mathSpans.first { $0.range.location >= location }

            // Choose whichever inline element starts first. `$`, `*`, `_`, backtick and `[` are
            // distinct characters, so a math span and a regex token never start at the same index.
            let useMath: Bool
            switch (regexToken, mathSpan) {
            case (nil, nil):
                // `unescape` on the plain runs, exactly as the no-math fast path does. The
                // lookbehind that stops `\*` from opening emphasis and the unescape that then
                // removes the backslash are ONE feature; this loop had only the first half, so
                // adding a single `$x$` to a line turned off escape processing for the whole
                // line and printed a literal `\*` on screen and into every render-based export.
                output.append(NSAttributedString(
                    string: MarkdownInlineSyntax.unescape(nsLine.substring(from: location)),
                    attributes: baseAttributes
                ))
                return output
            case (_, nil): useMath = false
            case (nil, _): useMath = true
            case let (.some(token), .some(span)): useMath = span.range.location < token.range.location
            }

            let elementRange = useMath ? mathSpan!.range : regexToken!.range
            if elementRange.location > location {
                // Unescaped for the same reason as the tail run above.
                let plain = nsLine.substring(with: NSRange(location: location, length: elementRange.location - location))
                output.append(NSAttributedString(
                    string: MarkdownInlineSyntax.unescape(plain),
                    attributes: baseAttributes
                ))
            }
            if useMath {
                appendInlineMath(mathSpan!, to: output, baseAttributes: baseAttributes, profile: profile, theme: theme, mathProvider: mathProvider, imagesAsText: imagesAsText, displayMetrics: displayMetrics)
            } else {
                let token = regexToken!
                output.append(NSAttributedString(string: token.text, attributes: token.attributes(baseAttributes, profile)))
            }
            location = NSMaxRange(elementRange)
        }
        return output
    }

    /// Append one inline-math span as a baseline-aligned attachment, or its raw LaTeX in
    /// inline-code style if rendering fails.
    private func appendInlineMath(
        _ span: MathSpan,
        to output: NSMutableAttributedString,
        baseAttributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        imagesAsText: Bool = false,
        displayMetrics: RenderDisplayMetrics
    ) {
        if imagesAsText {
            var codeAttrs = baseAttributes
            codeAttrs[.font] = PlatformFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
            output.append(NSAttributedString(string: span.latex, attributes: codeAttrs))
            return
        }
        let scale = displayMetrics.scale
        let pointSize = CGFloat(profile.fontSize)
        // Inline math stays fully theme-aware.
        let outcome = mathProvider.outcome(
            latex: span.latex,
            style: span.style,
            foreground: theme.textColor,
            pointSize: pointSize,
            scale: scale
        )
        if case .image(let image, let descent) = outcome {
            Self.setAccessibilityDescription(String(localized: "Math. \(span.latex)", bundle: .module), on: image)
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            // Sit the equation's own baseline on the surrounding text baseline: the image extends
            // `descent` points below its baseline, so offset the attachment down by that much.
            attachment.bounds = CGRect(x: 0, y: -descent, width: size.width, height: size.height)
            output.append(NSAttributedString(attachment: attachment))
        } else {
            var codeAttrs = baseAttributes
            codeAttrs[.font] = PlatformFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            output.append(NSAttributedString(string: span.latex, attributes: codeAttrs))
        }
    }

    private func heading(in line: String) -> (level: Int, title: String)? {
        MarkdownHeadingParser.heading(in: line)
    }

    private func headingAttributes(level: Int, profile: ReadingProfile, usesBlockSpacing: Bool, headingScale: CGFloat = 1.0) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        // `resolved(for:)`, not `option(for:)?` + a bare `?? .systemFont(…)` tail: a RETIRED
        // FontID resolves to nil here. The tail renders the SAME face today (the default option
        // is SF Pro), so this is forward insurance against the next retirement — not a fix for a
        // visible defect. See `FontOption.resolved(for:)`.
        let bodyFont = FontOption.resolved(for: profile.fontID).resolvedFont(size: CGFloat(profile.fontSize))
        let sizeBoost = Self.headingSizeBoosts[level] ?? 0
        let headingFont = lineformFont(bodyFont, adding: .bold)
        let resolvedHeadingFont = Self.font(headingFont, size: bodyFont.pointSize + sizeBoost * headingScale)
        let paragraphStyle = usesBlockSpacing
            ? MarkdownTextStyle.blockSpacingParagraphStyle(for: profile, font: resolvedHeadingFont, additionalSpacing: 4)
            : MarkdownTextStyle.paragraphStyle(for: profile, font: resolvedHeadingFont)

        return [
            NSAttributedString.Key.font: resolvedHeadingFont,
            NSAttributedString.Key.foregroundColor: theme.textColor,
            NSAttributedString.Key.paragraphStyle: paragraphStyle,
            NSAttributedString.Key.kern: profile.letterSpacing
        ]
    }

    private func codeAttributes(profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        var attributes = MarkdownTextStyle.baseAttributes(for: profile)
        attributes[.font] = PlatformFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
        return attributes
    }

    private func blockSpacingAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile
    ) -> [NSAttributedString.Key: Any] {
        guard profile.paragraphSpacing > 0, let font = attributes[.font] as? PlatformFont else {
            return attributes
        }

        var spacedAttributes = attributes
        spacedAttributes[.paragraphStyle] = MarkdownTextStyle.blockSpacingParagraphStyle(for: profile, font: font)
        return spacedAttributes
    }

    private func inlineMarkdown(in line: String, baseAttributes: [NSAttributedString.Key: Any], profile: ReadingProfile) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let nsLine = line as NSString
        var location = 0

        while location < nsLine.length {
            if let token = nextInlineToken(in: line, nsLine: nsLine, from: location) {
                if token.range.location > location {
                    output.append(NSAttributedString(
                        // Unescaped, like every plain run: a `\*` that correctly declined to open
                        // emphasis must not then be drawn as a literal backslash-asterisk.
                        string: MarkdownInlineSyntax.unescape(
                            nsLine.substring(with: NSRange(location: location, length: token.range.location - location))
                        ),
                        attributes: baseAttributes
                    ))
                }
                output.append(NSAttributedString(string: token.text, attributes: token.attributes(baseAttributes, profile)))
                location = NSMaxRange(token.range)
            } else {
                output.append(NSAttributedString(
                    string: MarkdownInlineSyntax.unescape(nsLine.substring(from: location)),
                    attributes: baseAttributes
                ))
                location = nsLine.length
            }
        }

        return output
    }

    private func nextInlineToken(in line: String, nsLine: NSString, from location: Int) -> InlineToken? {
        var earliest: InlineToken?

        consider(
            inlineToken(regex: MarkdownInlineSyntax.bold, kind: .bold, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: MarkdownInlineSyntax.italic, kind: .italic, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: MarkdownInlineSyntax.italicAsterisk, kind: .italic, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: MarkdownInlineSyntax.code, kind: .code, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: MarkdownInlineSyntax.strikethrough, kind: .strikethrough, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            imageToken(in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: MarkdownInlineSyntax.link, kind: .link, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )

        return earliest
    }

    private func consider(_ candidate: InlineToken?, earliest: inout InlineToken?) {
        guard let candidate else { return }

        if let current = earliest, current.range.location <= candidate.range.location {
            return
        }

        earliest = candidate
    }

    private func inlineToken(regex: NSRegularExpression, kind: InlineToken.Kind, in line: String, nsLine: NSString, from location: Int) -> InlineToken? {
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = regex.firstMatch(in: line, range: searchRange) else {
            return nil
        }

        return InlineToken(kind: kind, text: nsLine.substring(with: match.range(at: 1)), range: match.range)
    }

    /// An `![alt](url)` image rendered as a quiet, file-free, network-free placeholder: a small
    /// image glyph plus the alt text. The file is never opened and the network is never touched —
    /// deliberate, consistent with local-first privacy and the deferred-images decision. The `!`
    /// and the URL are consumed so nothing leaks into the rendered text.
    private func imageToken(in line: String, nsLine: NSString, from location: Int) -> InlineToken? {
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = MarkdownInlineSyntax.image.firstMatch(in: line, range: searchRange) else {
            return nil
        }
        let alt = nsLine.substring(with: match.range(at: 1))
        // Prefer the alt text; with none, use the image's filename (last path component) so the
        // placeholder still carries context — a lead to find the file later — rather than a lone
        // glyph or a generic word. Falls back to "Image" only when there's no usable filename.
        // Still file-free/network-free: this only reads the path string already in the document.
        let label: String
        if !alt.isEmpty {
            label = alt
        } else {
            let filename = Self.imageFilename(from: nsLine.substring(with: match.range(at: 2)))
            label = filename.isEmpty ? String(localized: "Image", bundle: .module) : filename
        }
        return InlineToken(kind: .image, text: "🖼 \(label)", range: match.range)
    }

    /// Emit an own-line `![alt](path)` image block: a left-aligned rendered picture
    /// (`BlockRenderedAttachment`, like mermaid — no centering paragraph style) for a resolved
    /// local file, or the quiet "🖼 label" placeholder — tagged `.imageSourceRange` +
    /// `.imageReconnect` so a later Reconnect affordance can act on it — for anything else
    /// (remote, unresolved, or a local file that failed to load). No network access ever.
    private func appendImageBlock(
        alt: String,
        path: String,
        sourceRange: NSRange,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        theme: Theme,
        columnWidth: CGFloat,
        documentDirectory: URL?,
        imageProvider: ImageAttachmentProviding,
        bodyAttributes: [NSAttributedString.Key: Any],
        isLastLine: Bool,
        displayMetrics: RenderDisplayMetrics
    ) {
        let spacedAttributes = imageBlockSpacing(bodyAttributes, profile: profile)

        if case .localFile(let url) = ImageResolver.resolve(path: path, documentDirectory: documentDirectory) {
            let scale = displayMetrics.scale
            // The renderer has no live view to measure a real viewport at initial-render time;
            // approximate with the display's visible height (`displayMetrics`; on macOS the main
            // screen's, read at render time — almost always resolves near the
            // flat 500pt ceiling). This is HARMLESS: the raster itself is downscale-only (never
            // upscaled), and the resize-refit path (`MarkdownPreviewTextView.refitBlockAttachments`,
            // which fires unconditionally right after this render via `apply()`) re-clamps the
            // attachment's on-screen HEIGHT to the real viewport via `appliesViewportHeightCap`, so
            // the initial approximation is corrected before the user ever sees it.
            let maxHeight = ImageFit.maxHeight(visibleViewportHeight: displayMetrics.visibleViewportHeight)
            if let baseImage = imageProvider.image(at: url, maxSize: CGSize(width: columnWidth, height: maxHeight), scale: scale) {
                let natural = baseImage.size
                let width = min(natural.width, max(columnWidth, 1))
                let height = natural.width > 0 ? natural.height * (width / natural.width) : natural.height
                // Bake an EQUAL transparent vertical margin into the attachment image itself, so the
                // picture has identical visual space above and below it regardless of TextKit's
                // paragraph-spacing behaviour (which is why `imageBlockSpacing` no longer adds any).
                // Transparent margin baked above and below the picture for calm, symmetric breathing
                // room. The text line AFTER the image gets its line-height leading added ABOVE it,
                // which enlarges the visual gap BELOW the image; compensate by adding that same
                // leading to the TOP margin so the picture ends up with EQUAL space above and below.
                let baseMargin = max(18, CGFloat(profile.paragraphSpacing))
                let font = (bodyAttributes[.font] as? PlatformFont) ?? PlatformFont.systemFont(ofSize: max(1, CGFloat(profile.fontSize)))
                let naturalLineHeight = max(font.ascender - font.descender + font.leading, font.pointSize)
                let leadingExtra = max(0, naturalLineHeight * (CGFloat(profile.lineHeightMultiple) - 1))
                let topMargin = baseMargin + leadingExtra
                let bottomMargin = baseMargin
                #if os(macOS)
                let padded = NSImage(size: NSSize(width: width, height: height + topMargin + bottomMargin))
                padded.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                baseImage.draw(in: NSRect(x: 0, y: bottomMargin, width: width, height: height))
                padded.unlockFocus()
                #else
                // UIKit's origin is top-left, so the picture sits `topMargin` down.
                let format = UIGraphicsImageRendererFormat()
                format.scale = displayMetrics.scale
                format.opaque = false
                let padded = UIGraphicsImageRenderer(
                    size: CGSize(width: width, height: height + topMargin + bottomMargin),
                    format: format
                ).image { context in
                    context.cgContext.interpolationQuality = .high
                    baseImage.draw(in: CGRect(x: 0, y: topMargin, width: width, height: height))
                }
                #endif
                Self.setAccessibilityDescription(alt.isEmpty ? String(localized: "Image", bundle: .module) : alt, on: padded)
                let attachment = BlockRenderedAttachment()
                attachment.image = padded
                attachment.appliesViewportHeightCap = true
                attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height + topMargin + bottomMargin)
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttributes(spacedAttributes, range: NSRange(location: 0, length: attachmentString.length))
                output.append(attachmentString)
                // Terminate the image's paragraph with ITS OWN attributes (not the body's), so the
                // whole paragraph shares one paragraph style. A body-attributed "\n" (line-height
                // ×multiple) here would inflate the image line's bottom and make the gap below the
                // image bigger than above. The equal above/below gap is baked into the padded image.
                if !isLastLine {
                    output.append(NSAttributedString(string: "\n", attributes: spacedAttributes))
                }
                return
            }
        }

        // Remote, unresolved, or a local file that failed to load: quiet placeholder + Reconnect tag.
        // Unlike the rendered picture (which bakes its breathing room into the image), the "🖼 label"
        // placeholder is a plain TEXT line, so it needs the SAME one-sided block spacing every other
        // block uses — otherwise it butts straight up against the surrounding paragraphs.
        let placeholderSpacing = blockSpacingAttributes(bodyAttributes, profile: profile)
        appendImagePlaceholder(alt: alt, path: path, sourceRange: sourceRange, to: output, attributes: placeholderSpacing)
        if !isLastLine {
            output.append(NSAttributedString(string: "\n", attributes: placeholderSpacing))
        }
    }

    /// The "🖼 label" placeholder run for an image that did not resolve to a rendered picture:
    /// styled like the inline `imageToken` (link color), tagged with the image's SOURCE range and a
    /// Reconnect marker. File-free, network-free — only the alt/path STRINGS already in the document
    /// are read.
    private func appendImagePlaceholder(
        alt: String,
        path: String,
        sourceRange: NSRange,
        to output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label: String
        if !alt.isEmpty {
            label = alt
        } else {
            let filename = Self.imageFilename(from: path)
            label = filename.isEmpty ? String(localized: "Image", bundle: .module) : filename
        }
        var placeholderAttributes = attributes
        placeholderAttributes[.foregroundColor] = PlatformColor.lineformLink
        placeholderAttributes[.imageSourceRange] = NSValue(range: sourceRange)
        placeholderAttributes[.imageReconnect] = NSNumber(value: true)
        // A broken-heart glyph between the frame and the label signals "this image didn't
        // resolve" (remote/missing/unloadable) at a glance — the Reconnect pill is the fix.
        output.append(NSAttributedString(string: "🖼 💔 \(label)", attributes: placeholderAttributes))
    }

    /// Paragraph spacing for an image block (rendered picture OR placeholder). Images use the SAME
    /// one-sided block spacing as every other block — `paragraphSpacing` (after) only, NO
    /// `paragraphSpacingBefore`. Setting a spacing-BEFORE would COMPOUND with the preceding block's
    /// spacing-after, making the gap ABOVE the image roughly double the gap below it (the "crazy
    /// gap above" bug). One-sided spacing keeps the gaps above and below symmetric and consistent
    /// with the rest of the document's rhythm. Applied identically to the resolved picture and the
    /// placeholder so spacing never jumps when an image resolves ↔ falls back.
    private func imageBlockSpacing(
        _ base: [NSAttributedString.Key: Any],
        profile: ReadingProfile
    ) -> [NSAttributedString.Key: Any] {
        // Build a paragraph style specifically for the image line. CRUCIAL: do NOT apply the
        // reading profile's `lineHeightMultiple` here. That multiplier (~1.5–1.7) is meant to open
        // up readable TEXT line height, but applied to a tall image-attachment line it multiplies
        // the ~image-height line into a much taller one, and the extra height renders as a large
        // gap ABOVE the image. `lineHeightMultiple = 1` makes the line exactly the image's height.
        // Spacing between the image and neighbours comes only from `paragraphSpacing` (after), the
        // same one-sided model every other block uses, so gaps stay symmetric.
        // No paragraph spacing and no line-height multiple: the equal gap above and below the image
        // is baked into the attachment image as transparent padding (see `appendImageBlock`), which
        // is reliable regardless of TextKit's paragraph-spacing quirks. lineHeightMultiple must be 1
        // so a tall attachment line isn't inflated.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        var result = base
        result[.paragraphStyle] = paragraph
        return result
    }

    /// The last path component of an image URL/path (the filename), stripped of any query or
    /// fragment. Pure string work — never resolves or touches the file.
    private static func imageFilename(from url: String) -> String {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let withoutFragment = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
        let lastComponent = withoutFragment.split(separator: "/").last.map(String.init) ?? withoutFragment
        return lastComponent.trimmingCharacters(in: .whitespaces)
    }
}

private struct InlineToken {
    enum Kind {
        case bold
        case italic
        case code
        case strikethrough
        case image
        case link
    }

    var kind: Kind
    var text: String
    var range: NSRange

    func attributes(_ base: [NSAttributedString.Key: Any], _ profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        var attributes = base
        switch kind {
        case .bold:
            if let font = base[.font] as? PlatformFont {
                attributes[.font] = lineformFont(font, adding: .bold)
            }
        case .italic:
            if let font = base[.font] as? PlatformFont {
                attributes[.font] = lineformFont(font, adding: .italic)
            }
        case .code:
            attributes[.font] = PlatformFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
        case .strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case .image:
            // Color the placeholder like a link so a not-yet-rendered image reference reads clearly
            // as a reference rather than dim body text.
            attributes[.foregroundColor] = PlatformColor.lineformLink
        case .link:
            attributes[.foregroundColor] = PlatformColor.lineformLink
        }
        return attributes
    }
}
