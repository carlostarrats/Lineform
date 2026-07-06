import AppKit

extension NSAttributedString.Key {
    /// Attached to a rendered task-checkbox glyph; value is an `NSValue` boxing the `NSRange` of the
    /// `[ ]`/`[x]` marker in the source document, so a click on the glyph can toggle that span.
    static let checkboxSourceRange = NSAttributedString.Key("lineform.checkboxSourceRange")
}

struct MarkdownPreviewRenderer {
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
    /// Table cell text renders at this fraction of the reading font size — denser than prose, but
    /// still relative so it scales with the user's size setting. Dial-able.
    static let tableTextScale: CGFloat = 0.9
    private static let headingSizeBoosts: [Int: CGFloat] = [
        1: 11,
        2: 3,
        3: 2,
        4: 1,
        5: 0,
        6: 0
    ]

    /// Back-compat convenience (used by tests and any caller that doesn't render mermaid): uses
    /// a disabled mermaid provider so ```mermaid blocks fall back to a captioned source block.
    func render(_ text: String, profile: ReadingProfile) -> NSAttributedString {
        render(
            text,
            profile: profile,
            columnWidth: CGFloat(profile.columnWidth),
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "0"
        )
    }

    func render(
        _ text: String,
        profile: ReadingProfile,
        columnWidth: CGFloat,
        mermaidProvider: MermaidImageProviding,
        mathProvider: MathImageProviding,
        diagramLog: DiagramFailureLogging,
        reportRegistry: DiagramReportRegistry,
        appVersion: String,
        // Export/print sets this so tables shrink to fit the page (proportional percentage
        // columns, cells wrap) instead of overflowing a narrow page column. On screen it stays
        // false so the wide reading column keeps content-sized columns.
        fitTablesToWidth: Bool = false
    ) -> NSAttributedString {
        reportRegistry.reset()
        let output = NSMutableAttributedString(string: "")
        let bodyAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        let bodyBlockSpacingAttributes = blockSpacingAttributes(bodyAttributes, profile: profile)
        let codeAttributes = codeAttributes(profile: profile)
        let codeBlockSpacingAttributes = blockSpacingAttributes(codeAttributes, profile: profile)
        let lines = text.components(separatedBy: "\n")
        let blockSpacingLineIndexes = Set(MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes(inLines: lines))
        let theme = Theme.theme(for: profile)

        // Group the lines once, then render each block. `.lines` runs reproduce the original
        // per-line output exactly (headings / inline-with-math / fenced code), and the mermaid /
        // display-math blocks reuse the same emitters and the same trailing-newline rules as
        // before — byte-identical for the existing constructs. New block constructs become new
        // cases here plus their own emitter.
        for block in markdownBlocks(in: lines) {
            switch block {
            case .lines(let range):
                appendLines(
                    range,
                    to: output,
                    lines: lines,
                    profile: profile,
                    theme: theme,
                    mathProvider: mathProvider,
                    bodyAttributes: bodyAttributes,
                    bodyBlockSpacingAttributes: bodyBlockSpacingAttributes,
                    codeAttributes: codeAttributes,
                    codeBlockSpacingAttributes: codeBlockSpacingAttributes,
                    blockSpacingLineIndexes: blockSpacingLineIndexes
                )
            case .singleLineMath(let latex, let lineIndex):
                appendMathBlock(
                    latex: latex,
                    to: output,
                    profile: profile,
                    theme: theme,
                    columnWidth: columnWidth,
                    codeAttributes: codeAttributes,
                    mathProvider: mathProvider
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
                    mathProvider: mathProvider
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
                    reportRegistry: reportRegistry,
                    appVersion: appVersion
                )
                appendBlockSeparator(afterLine: closingIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .horizontalRule(let lineIndex):
                appendHorizontalRule(to: output, profile: profile, theme: theme)
                appendBlockSeparator(afterLine: lineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .blockquote(let quoteLines, let lastLineIndex):
                appendBlockquote(quoteLines, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, mathProvider: mathProvider)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .list(let items, let lastLineIndex):
                appendList(items, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, mathProvider: mathProvider)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            case .table(let table, let lastLineIndex):
                appendTable(table, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, fitToWidth: fitTablesToWidth)
                appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
            }
        }

        return output
    }

    /// Emit a GFM table as a native `NSTextTable`: live, selectable, theme-colored text that lays
    /// out responsively to the reading column and wraps cell text when narrow (columns auto-size).
    /// The header row is distinguished; per-column alignment comes from the delimiter row; gridlines
    /// are quiet and contrast-derived from the theme so they read on light and dark pages.
    private func appendTable(
        _ table: MarkdownTable,
        to output: NSMutableAttributedString,
        baseAttributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile,
        theme: Theme,
        fitToWidth: Bool = false
    ) {
        let columns = table.columnCount
        guard columns > 0 else { return }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        // When exporting to a fixed page, content-sized columns can overflow the (narrow) page
        // column and clip on the right. Give each column a percentage width proportional to its
        // longest cell, summing to a value under 100% (leaving room for per-cell padding/borders),
        // so the whole table fits the page and long cells wrap. On screen this stays off and the
        // wide reading column keeps natural content-sized columns.
        let allRows: [(cells: [String], isHeader: Bool)] =
            [(table.headers, true)] + table.rows.map { ($0, false) }
        let columnPercentages: [CGFloat]? = fitToWidth ? Self.fitColumnPercentages(rows: allRows, columns: columns) : nil

        let borderColor = theme.textColor.withAlphaComponent(0.25)
        let headerFill = theme.textColor.withAlphaComponent(0.06)
        let baseFont = (baseAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CGFloat(profile.fontSize))
        // Table cells render slightly smaller than prose (a common, denser table convention) while
        // still tracking the reading font size — so it scales with the user's accessibility setting
        // and just fits more per column, easing the too-wide case. Relative, never a fixed size.
        let cellFont = NSFont(descriptor: baseFont.fontDescriptor, size: baseFont.pointSize * Self.tableTextScale) ?? baseFont
        let headerFont = NSFontManager.shared.convert(cellFont, toHaveTrait: .boldFontMask)

        for (rowIndex, row) in allRows.enumerated() {
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
                if let columnPercentages {
                    block.setContentWidth(columnPercentages[column], type: .percentageValueType)
                }
                if row.isHeader {
                    block.backgroundColor = headerFill
                }

                let paragraph = mutableParagraphStyle(from: baseAttributes)
                paragraph.textBlocks = [block]
                paragraph.alignment = nsAlignment(table.alignments[column])

                var attributes = baseAttributes
                attributes[.paragraphStyle] = paragraph
                attributes[.font] = row.isHeader ? headerFont : cellFont

                let cellText = column < row.cells.count ? row.cells[column] : ""
                output.append(NSAttributedString(string: cellText + "\n", attributes: attributes))
            }
        }
    }

    /// Percentage content widths (of the page column) per table column, proportional to each
    /// column's longest cell, summing to a budget under 100% so per-cell padding + borders don't
    /// push the table past the page column. Used only for export (fit-to-width). A small floor
    /// keeps a short column from collapsing.
    static func fitColumnPercentages(rows: [(cells: [String], isHeader: Bool)], columns: Int) -> [CGFloat] {
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

    private func nsAlignment(_ alignment: MarkdownTableAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
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
        mathProvider: MathImageProviding
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
                mathProvider: mathProvider
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
        mathProvider: MathImageProviding
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
                mathProvider: mathProvider
            ))
            if offset < quoteLines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
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

    /// Render a maximal run of ordinary lines (body, headings, fenced code) exactly as the original
    /// per-line loop did: fence state starts closed (every `.lines` run begins where the grouping
    /// was outside any fence), each line emits its content plus a trailing newline unless it is the
    /// document's last line, and block-spacing attributes are looked up by original line index.
    private func appendLines(
        _ range: Range<Int>,
        to output: NSMutableAttributedString,
        lines: [String],
        profile: ReadingProfile,
        theme: Theme,
        mathProvider: MathImageProviding,
        bodyAttributes: [NSAttributedString.Key: Any],
        bodyBlockSpacingAttributes: [NSAttributedString.Key: Any],
        codeAttributes: [NSAttributedString.Key: Any],
        codeBlockSpacingAttributes: [NSAttributedString.Key: Any],
        blockSpacingLineIndexes: Set<Int>
    ) {
        var inFence = false
        for index in range {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let usesBlockSpacing = blockSpacingLineIndexes.contains(index)
            let activeBodyAttributes = usesBlockSpacing ? bodyBlockSpacingAttributes : bodyAttributes
            let activeCodeAttributes = usesBlockSpacing ? codeBlockSpacingAttributes : codeAttributes
            var lineTerminatorAttributes = activeBodyAttributes

            if MermaidFence.isFenceDelimiter(trimmed) {
                inFence.toggle()
                output.append(NSAttributedString(string: line, attributes: activeCodeAttributes))
                lineTerminatorAttributes = activeCodeAttributes
            } else if inFence {
                output.append(NSAttributedString(string: line, attributes: activeCodeAttributes))
                lineTerminatorAttributes = activeCodeAttributes
            } else if let heading = heading(in: line) {
                let activeHeadingAttributes = headingAttributes(
                    level: heading.level,
                    profile: profile,
                    usesBlockSpacing: usesBlockSpacing
                )
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
                    mathProvider: mathProvider
                ))
            }

            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: lineTerminatorAttributes))
            }
        }
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
        reportRegistry: DiagramReportRegistry,
        appVersion: String
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
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
            image.accessibilityDescription = "Mermaid diagram. \(source)"
            let attachment = BlockRenderedAttachment()
            attachment.image = image
            let natural = image.size
            let width = min(natural.width, max(columnWidth, 1))
            let height = natural.width > 0 ? natural.height * (width / natural.width) : natural.height
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            output.append(NSAttributedString(attachment: attachment))
        case .skipped:
            // Size-guard skip: not a render failure, so no report affordance.
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes, reportHash: nil)
        case .failed(let error):
            diagramLog.record(source: source, error: error, appVersion: appVersion)
            let hash = DiagramLog.sourceHash(source)
            reportRegistry.register(hash: hash, source: source, error: error)
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes, reportHash: hash)
        }
    }

    private func appendMermaidFallback(
        source: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        codeAttributes: [NSAttributedString.Key: Any],
        reportHash: String?
    ) {
        var captionAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        captionAttributes[.foregroundColor] = Theme.theme(for: profile).textColor.withAlphaComponent(0.6)
        if let font = captionAttributes[.font] as? NSFont {
            captionAttributes[.font] = NSFont.systemFont(ofSize: max(10, font.pointSize - 2))
        }
        output.append(NSAttributedString(string: "Mermaid diagram (source)", attributes: captionAttributes))
        if let reportHash, let url = DiagramReportLink.url(hash: reportHash) {
            var linkAttributes = captionAttributes
            linkAttributes[.link] = url
            linkAttributes[.foregroundColor] = NSColor.linkColor
            // The read view is selectable, so this link is already reachable (VoiceOver reads it as
            // a link; Full Keyboard Access can focus it). The tooltip explains what the terse
            // "Report this" does — shown on hover, and bridged to assistive tech as help where the
            // text system supports it.
            linkAttributes[.toolTip] = "Send the diagram source and error to the developer to improve rendering."
            output.append(NSAttributedString(string: "  ", attributes: captionAttributes))
            output.append(NSAttributedString(string: "Report this", attributes: linkAttributes))
        }
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
        mathProvider: MathImageProviding
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
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
            image.accessibilityDescription = "Math. \(latex)"
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
        var captionAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        captionAttributes[.foregroundColor] = Theme.theme(for: profile).textColor.withAlphaComponent(0.6)
        if let font = captionAttributes[.font] as? NSFont {
            captionAttributes[.font] = NSFont.systemFont(ofSize: max(10, font.pointSize - 2))
        }
        output.append(NSAttributedString(string: "Math (source)", attributes: captionAttributes))
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
        mathProvider: MathImageProviding
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
                output.append(NSAttributedString(string: nsLine.substring(from: location), attributes: baseAttributes))
                return output
            case (_, nil): useMath = false
            case (nil, _): useMath = true
            case let (.some(token), .some(span)): useMath = span.range.location < token.range.location
            }

            let elementRange = useMath ? mathSpan!.range : regexToken!.range
            if elementRange.location > location {
                output.append(NSAttributedString(
                    string: nsLine.substring(with: NSRange(location: location, length: elementRange.location - location)),
                    attributes: baseAttributes
                ))
            }
            if useMath {
                appendInlineMath(mathSpan!, to: output, baseAttributes: baseAttributes, profile: profile, theme: theme, mathProvider: mathProvider)
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
        mathProvider: MathImageProviding
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
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
            image.accessibilityDescription = "Math. \(span.latex)"
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            // Sit the equation's own baseline on the surrounding text baseline: the image extends
            // `descent` points below its baseline, so offset the attachment down by that much.
            attachment.bounds = CGRect(x: 0, y: -descent, width: size.width, height: size.height)
            output.append(NSAttributedString(attachment: attachment))
        } else {
            var codeAttrs = baseAttributes
            codeAttrs[.font] = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            output.append(NSAttributedString(string: span.latex, attributes: codeAttrs))
        }
    }

    private func heading(in line: String) -> (level: Int, title: String)? {
        MarkdownHeadingParser.heading(in: line)
    }

    private func headingAttributes(level: Int, profile: ReadingProfile, usesBlockSpacing: Bool) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        let bodyFont = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        let sizeBoost = Self.headingSizeBoosts[level] ?? 0
        let headingFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let resolvedHeadingFont = NSFont(descriptor: headingFont.fontDescriptor, size: bodyFont.pointSize + sizeBoost) ?? headingFont
        let paragraphStyle = usesBlockSpacing
            ? MarkdownSyntaxHighlighter.blockSpacingParagraphStyle(for: profile, font: resolvedHeadingFont, additionalSpacing: 4)
            : MarkdownSyntaxHighlighter.paragraphStyle(for: profile, font: resolvedHeadingFont)

        return [
            NSAttributedString.Key.font: resolvedHeadingFont,
            NSAttributedString.Key.foregroundColor: theme.textColor,
            NSAttributedString.Key.paragraphStyle: paragraphStyle,
            NSAttributedString.Key.kern: profile.letterSpacing
        ]
    }

    private func codeAttributes(profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        var attributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
        return attributes
    }

    private func blockSpacingAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile
    ) -> [NSAttributedString.Key: Any] {
        guard profile.paragraphSpacing > 0, let font = attributes[.font] as? NSFont else {
            return attributes
        }

        var spacedAttributes = attributes
        spacedAttributes[.paragraphStyle] = MarkdownSyntaxHighlighter.blockSpacingParagraphStyle(for: profile, font: font)
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
                        string: nsLine.substring(with: NSRange(location: location, length: token.range.location - location)),
                        attributes: baseAttributes
                    ))
                }
                output.append(NSAttributedString(string: token.text, attributes: token.attributes(baseAttributes, profile)))
                location = NSMaxRange(token.range)
            } else {
                output.append(NSAttributedString(
                    string: nsLine.substring(from: location),
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
            inlineToken(regex: Self.boldRegex, kind: .bold, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.italicRegex, kind: .italic, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.codeRegex, kind: .code, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.strikethroughRegex, kind: .strikethrough, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            imageToken(in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.linkRegex, kind: .link, in: line, nsLine: nsLine, from: location),
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
        guard let match = Self.imageRegex.firstMatch(in: line, range: searchRange) else {
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
            label = filename.isEmpty ? "Image" : filename
        }
        return InlineToken(kind: .image, text: "🖼 \(label)", range: match.range)
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
            if let font = base[.font] as? NSFont {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        case .italic:
            if let font = base[.font] as? NSFont {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
        case .code:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
        case .strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case .image:
            if let color = base[.foregroundColor] as? NSColor {
                attributes[.foregroundColor] = color.withAlphaComponent(0.6)
            }
        case .link:
            attributes[.foregroundColor] = NSColor.linkColor
        }
        return attributes
    }
}
