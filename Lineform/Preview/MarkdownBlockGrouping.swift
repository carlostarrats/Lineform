import Foundation

/// A structural grouping of the document's lines, produced in a single pass so the preview
/// renderer can render block-by-block instead of re-deriving block boundaries inline. This is the
/// seam new block constructs (horizontal rule, blockquote, list, table) hang off — each becomes a
/// new case here plus a matching emitter in `MarkdownPreviewRenderer`.
///
/// The existing constructs are preserved **exactly**: `.lines` runs are rendered by the renderer's
/// unchanged per-line logic (heading / inline-with-math / fenced-code), and mermaid / display-math
/// blocks carry only what the renderer needs to reproduce its current output (the inner source and
/// the closing line index, `nil` when the block was never closed and is flushed at end-of-document).
enum MarkdownBlock: Equatable {
    /// A maximal run of ordinary lines (body, headings, and fenced code), rendered per line exactly
    /// as before. The range is over the original line indices so block-spacing lookups and the
    /// "newline after every line except the last" rule are reproduced unchanged.
    case lines(Range<Int>)
    /// A whole-line display block `$$…$$`, rendered as one centered equation at `lineIndex`.
    case singleLineMath(latex: String, lineIndex: Int)
    /// A fenced display-math block delimited by lines that are exactly `$$`. `closingIndex` is the
    /// index of the closing `$$` line, or `nil` when the block ran to end-of-document unclosed.
    case fencedMath(latex: String, closingIndex: Int?)
    /// A ```mermaid fenced block. `closingIndex` is the index of the closing fence, or `nil` when it
    /// ran to end-of-document unclosed.
    case mermaid(source: String, closingIndex: Int?)
    /// A thematic break (`---` / `***` / `___` on its own line) rendered as a quiet divider.
    /// `lineIndex` is the original line so the trailing-newline rule is reproduced.
    case horizontalRule(lineIndex: Int)
    /// A contiguous run of `>`-quoted lines (markers stripped, per-line nesting depth kept).
    /// `lastLineIndex` is the last original line the block covers, for the trailing-newline rule.
    case blockquote(lines: [MarkdownQuoteLine], lastLineIndex: Int)
    /// A blockquote whose first line is a GitHub callout marker (`> [!TYPE]`). `title` is the optional
    /// custom title from the marker line; `body` is the remaining quote lines (markers stripped).
    /// `lastLineIndex` is the last original line the block covers, for the trailing-newline rule.
    case callout(kind: CalloutKind, title: String?, body: [MarkdownQuoteLine], lastLineIndex: Int)
    /// A contiguous run of list items (bulleted and/or numbered), with resolved ordinals and
    /// nesting levels. `lastLineIndex` is the last original line the block covers.
    case list(items: [MarkdownListItem], lastLineIndex: Int)
    /// A GFM pipe table (header + delimiter + body rows). `lastLineIndex` is the last covered line.
    case table(MarkdownTable, lastLineIndex: Int)
    /// A plain ``` / ~~~ fenced code block (NOT mermaid — that is routed separately above).
    /// `language` is the fence's info tag (lowercased first word, "" when absent), `body` is the
    /// inner lines joined by "\n", `openingIndex` is the opening fence line, and `closingIndex` is
    /// the closing fence line or `nil` when the block ran to end-of-document unclosed.
    case fencedCode(language: String, body: String, openingIndex: Int, closingIndex: Int?)
    /// A line whose ENTIRE trimmed content is a single `![alt](path)` image (own-line image).
    /// Mid-text images (text before/after) never produce this case — they stay in `.lines` and
    /// flow through the existing inline `imageToken` placeholder. `sourceRange` spans the WHOLE
    /// source line (UTF-16), including any surrounding whitespace, so Reconnect's rewrite can
    /// re-verify the exact `![…](…)` substring inside it.
    case image(alt: String, path: String, sourceRange: NSRange)
}

/// Pure detection of a line that is solely a single `![alt](path)` image, with no other text.
enum MarkdownImageLine {
    private static let wholeLineImageRegex = try! NSRegularExpression(
        pattern: #"^!\[([^\]\n]*)\]\(([^\)\n]+)\)$"#
    )

    /// Returns `(alt, path)` when the TRIMMED line is entirely one image reference, else `nil`.
    static func wholeLineImage(_ line: String) -> (alt: String, path: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let nsTrimmed = trimmed as NSString
        guard let match = wholeLineImageRegex.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: nsTrimmed.length)
        ) else { return nil }
        let alt = nsTrimmed.substring(with: match.range(at: 1))
        let path = nsTrimmed.substring(with: match.range(at: 2))
        return (alt, path)
    }
}

/// Per-column text alignment for a table, read from the delimiter row's colons.
enum MarkdownTableAlignment: Equatable {
    case left, center, right
}

/// A parsed GFM pipe table: header cells, per-column alignment, and body rows. Every row is padded
/// or truncated to the column count so rendering is uniform even for malformed input.
struct MarkdownTable: Equatable {
    var headers: [String]
    var alignments: [MarkdownTableAlignment]
    var rows: [[String]]

    var columnCount: Int { alignments.count }
}

/// Pure GFM pipe-table parsing: delimiter-row detection, cell splitting, alignment, and assembly.
enum MarkdownTableParser {
    /// A candidate table row: non-empty and containing a pipe. (GFM multi-column rows use pipes.)
    static func looksLikeRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.contains("|")
    }

    /// A delimiter row: it must contain a pipe (a bare `---` with no pipe is a setext/thematic
    /// break, never a 1-column table delimiter), and every cell is dashes with optional
    /// leading/trailing colons (`:--`, `--:`, `:-:`, `---`).
    static func isDelimiterRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cellStrings = cells(in: line)
        guard !cellStrings.isEmpty else { return false }
        return cellStrings.allSatisfy { cell in
            delimiterCellRegex.firstMatch(in: cell, range: NSRange(location: 0, length: (cell as NSString).length)) != nil
        }
    }

    /// Split a row into trimmed cell strings, dropping the optional outer pipes. Escaped `\|` is a
    /// known limitation (v1 splits on every pipe).
    static func cells(in row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignment(of delimiterCell: String) -> MarkdownTableAlignment {
        let hasLeading = delimiterCell.hasPrefix(":")
        let hasTrailing = delimiterCell.hasSuffix(":")
        switch (hasLeading, hasTrailing) {
        case (true, true): return .center
        case (false, true): return .right
        default: return .left
        }
    }

    /// Assemble a table from its header, delimiter, and body lines. Columns are defined by the
    /// delimiter row; every row is padded/truncated to that width.
    static func parse(header: String, delimiter: String, body: [String]) -> MarkdownTable {
        let alignments = cells(in: delimiter).map(alignment(of:))
        let columns = alignments.count
        let headers = fit(cells(in: header), to: columns)
        let rows = body.map { fit(cells(in: $0), to: columns) }
        return MarkdownTable(headers: headers, alignments: alignments, rows: rows)
    }

    private static func fit(_ cells: [String], to columns: Int) -> [String] {
        if cells.count == columns { return cells }
        if cells.count > columns { return Array(cells.prefix(columns)) }
        return cells + Array(repeating: "", count: columns - cells.count)
    }

    private static let delimiterCellRegex = try! NSRegularExpression(pattern: #"^:?-+:?$"#)
}

/// One rendered list item: its text, its nesting level, and — for numbered items — the sequential
/// number to display (`nil` for bullets). Ordinals are resolved during grouping so `1.` / `1.` /
/// `1.` renders as 1, 2, 3 and nested levels count independently. A task item (`- [ ]` / `- [x]`)
/// carries `checkbox`, and its display `text` has the `[ ]`/`[x]` marker stripped.
struct MarkdownListItem: Equatable {
    var text: String
    var indentLevel: Int
    var ordinal: Int?
    var checkbox: MarkdownCheckbox?
}

/// A rendered task checkbox: whether it is checked, and the exact `NSRange` of the `[ ]`/`[x]`
/// marker in the source document (UTF-16) so a click can toggle that precise span.
struct MarkdownCheckbox: Equatable {
    var isChecked: Bool
    var sourceRange: NSRange

    /// Whether a list item's text is a GFM task marker, and — if so — its checked state and the
    /// remaining text after the marker. Matches `[ ]`, `[x]`, or `[X]` that is followed by
    /// whitespace-then-text or nothing (end of line). `- [x](link)` is NOT a task — GFM requires
    /// whitespace after the bracket — so it stays a normal bullet.
    static func detect(in text: String) -> (isChecked: Bool, remaining: String)? {
        let ns = text as NSString
        guard let match = detectRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let mark = ns.substring(with: match.range(at: 1))
        let remainingRange = match.range(at: 2)
        let remaining = remainingRange.location == NSNotFound ? "" : ns.substring(with: remainingRange)
        return (isChecked: mark.lowercased() == "x", remaining: remaining)
    }

    private static let detectRegex = try! NSRegularExpression(pattern: #"^\[([ xX])\](?:[ \t]+(.*))?$"#)
}

/// List-item line parsing: `-` / `*` / `+` bullets and `1.` / `1)` numbers, with a leading-indent
/// nesting level. Pure syntax; ordinal resolution happens in the grouping pass.
enum MarkdownList {
    struct Parsed: Equatable {
        var indentLevel: Int
        var ordered: Bool
        var text: String
        /// UTF-16 column in the line where the item text begins (just past the marker + whitespace).
        var textColumn: Int
    }

    private static let regex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|[0-9]{1,9}[.)])[ \t]+(.*)$"#)

    static func parse(_ line: String) -> Parsed? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let indentText = ns.substring(with: match.range(at: 1))
        let marker = ns.substring(with: match.range(at: 2))
        let text = ns.substring(with: match.range(at: 3))
        // Tabs count as two columns; every two columns of leading space is one nesting level.
        let width = indentText.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let ordered = marker.first.map { $0.isNumber } ?? false
        return Parsed(indentLevel: width / 2, ordered: ordered, text: text, textColumn: match.range(at: 3).location)
    }
}

/// One line of a blockquote: its nesting depth (number of `>` markers) and the text after the
/// markers are stripped.
struct MarkdownQuoteLine: Equatable {
    var depth: Int
    var text: String
}

/// Blockquote line parsing: a line is quoted when, after optional leading whitespace, it starts
/// with `>`. Nested `> >` / `>>` raise the depth; one optional space after each marker is consumed.
enum MarkdownBlockquote {
    static func quoteLine(_ line: String) -> MarkdownQuoteLine? {
        var rest = Substring(line)
        while rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
        guard rest.first == ">" else { return nil }
        var depth = 0
        while rest.first == ">" {
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return MarkdownQuoteLine(depth: depth, text: String(rest))
    }
}

/// The 5 GitHub-standard callout kinds. Raw values are the lowercased marker types matched
/// case-insensitively against `> [!TYPE]`.
enum CalloutKind: String, Equatable {
    case note, tip, important, warning, caution

    /// The default title shown when the marker line carries no custom title.
    var displayName: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    /// The monochrome SF Symbol drawn in the title row (tinted to the ink tone, never colored).
    var symbolName: String {
        switch self {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }
}

/// Pure callout-marker classifier. Operates on the FIRST quote line's already-stripped text
/// (markers removed by `MarkdownBlockquote.quoteLine`), so it sees `[!NOTE]` / `[!NOTE] Title`.
enum MarkdownCallout {
    // Anchored at the start of the stripped text: `[!TYPE]` then optional whitespace + title.
    // Type is 1+ letters; the trailing `.*` captures a custom title (may be empty/whitespace).
    private static let regex = try! NSRegularExpression(pattern: #"^\[!([A-Za-z]+)\][ \t]*(.*)$"#)

    /// Returns `(kind, title)` when `firstQuoteText` is `[!TYPE]` (optionally `[!TYPE] Custom title`)
    /// with a KNOWN type. `title` is the trimmed remainder, or `nil` when absent/empty. Unknown type,
    /// missing `!`, empty type (`[!]`), or any other shape → `nil` (caller keeps it a blockquote).
    static func parse(firstQuoteText: String) -> (kind: CalloutKind, title: String?)? {
        let ns = firstQuoteText as NSString
        guard let match = regex.firstMatch(in: firstQuoteText, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let typeText = ns.substring(with: match.range(at: 1)).lowercased()
        guard let kind = CalloutKind(rawValue: typeText) else { return nil }
        let rawTitle = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        return (kind: kind, title: trimmed.isEmpty ? nil : trimmed)
    }
}

/// Thematic-break (horizontal-rule) detection, kept separate so its two gotchas are explicit:
/// a leading `---` opening front matter and a `---` directly under paragraph text (a setext
/// heading underline) are NOT rules.
enum MarkdownHorizontalRule {
    /// Whether a trimmed line is a thematic-break candidate by syntax alone (3+ of the same
    /// `-` / `*` / `_`, spaces allowed), returning the marker character.
    static func candidate(_ trimmed: String) -> Character? {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first),
              compact.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    /// Whether the line at `index` is a real thematic break, given the surrounding lines. Only `-`
    /// carries the front-matter / setext ambiguity; `*` and `_` are always rules when they match.
    static func isRule(lines: [String], index: Int) -> Bool {
        guard let marker = candidate(lines[index].trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        guard marker == "-" else { return true }
        // A leading `---` opens YAML front matter, not a divider.
        if index == 0 { return false }
        // `---` immediately under a non-blank PARAGRAPH line is a setext heading underline. Lines
        // that are their own block above it — a heading, a fence, a blockquote, or a list item —
        // don't form a setext heading, so `---` after them is still a real rule.
        let previous = lines[index - 1]
        let previousTrimmed = previous.trimmingCharacters(in: .whitespaces)
        if !previousTrimmed.isEmpty
            && !previousTrimmed.hasPrefix("#")
            && !MermaidFence.isFenceDelimiter(previousTrimmed)
            && MarkdownBlockquote.quoteLine(previous) == nil
            && MarkdownList.parse(previous) == nil {
            return false
        }
        return true
    }
}

/// Group already-split lines into blocks. Mirrors the detection order of the original renderer loop
/// (single-line `$$…$$`, then a `$$` fence, then a ```mermaid fence, then a plain ``` / ~~~ code
/// fence). A plain code fence is consumed wholesale (opening → closing) into its own `.fencedCode`
/// block before any inner line is inspected, so `$$` / `---` / `>` / `|` lines inside it are never
/// re-parsed as math/rule/quote/table. Pure — no AppKit, no rendering.
func markdownBlocks(in lines: [String]) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var linesStart: Int?
    var index = 0

    // UTF-16 offset where each line begins in the joined source (lines are joined by "\n"), so a
    // task checkbox's marker can be given its exact source range for click-to-toggle.
    var lineStartOffsets = [Int](repeating: 0, count: lines.count)
    var runningOffset = 0
    for i in lines.indices {
        lineStartOffsets[i] = runningOffset
        runningOffset += (lines[i] as NSString).length + 1
    }

    func flushLines(upTo end: Int) {
        if let start = linesStart, start < end {
            blocks.append(.lines(start..<end))
        }
        linesStart = nil
    }

    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

        if let inner = MathBlockFence.singleLineBlock(trimmed) {
            flushLines(upTo: index)
            blocks.append(.singleLineMath(latex: inner, lineIndex: index))
            index += 1
            continue
        }

        if MathBlockFence.blockDelimiterOnly(trimmed) {
            flushLines(upTo: index)
            var body: [String] = []
            var cursor = index + 1
            var closing: Int?
            while cursor < lines.count {
                if MathBlockFence.blockDelimiterOnly(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    closing = cursor
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            blocks.append(.fencedMath(latex: body.joined(separator: "\n"), closingIndex: closing))
            index = (closing ?? lines.count - 1) + 1
            continue
        }

        if MermaidFence.isMermaidOpening(trimmed) {
            flushLines(upTo: index)
            var body: [String] = []
            var cursor = index + 1
            var closing: Int?
            while cursor < lines.count {
                if MermaidFence.isFenceDelimiter(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    closing = cursor
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            blocks.append(.mermaid(source: body.joined(separator: "\n"), closingIndex: closing))
            index = (closing ?? lines.count - 1) + 1
            continue
        }

        if MermaidFence.isFenceDelimiter(trimmed) {
            // A plain code fence: consume to the next fence delimiter as its own block so it renders
            // through appendCodeBlock (highlighting + copy pill), parallel to mermaid/math routing.
            flushLines(upTo: index)
            let language = CodeFence.language(fromOpening: trimmed)
            var body: [String] = []
            var cursor = index + 1
            var closing: Int?
            while cursor < lines.count {
                if MermaidFence.isFenceDelimiter(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    closing = cursor
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            blocks.append(.fencedCode(
                language: language,
                body: body.joined(separator: "\n"),
                openingIndex: index,
                closingIndex: closing
            ))
            index = (closing ?? lines.count - 1) + 1
            continue
        }

        if index + 1 < lines.count,
           MarkdownTableParser.looksLikeRow(lines[index]),
           MarkdownTableParser.isDelimiterRow(lines[index + 1]),
           // GFM requires the header and delimiter rows to have the same column count. This gate
           // also keeps a pipe-containing line above a bare `---` (a setext heading / rule) from
           // being mis-read as a 1-column table.
           MarkdownTableParser.cells(in: lines[index]).count == MarkdownTableParser.cells(in: lines[index + 1]).count {
            flushLines(upTo: index)
            var cursor = index + 2
            var body: [String] = []
            while cursor < lines.count, MarkdownTableParser.looksLikeRow(lines[cursor]) {
                body.append(lines[cursor])
                cursor += 1
            }
            let table = MarkdownTableParser.parse(header: lines[index], delimiter: lines[index + 1], body: body)
            blocks.append(.table(table, lastLineIndex: cursor - 1))
            index = cursor
            continue
        }

        if MarkdownHorizontalRule.isRule(lines: lines, index: index) {
            flushLines(upTo: index)
            blocks.append(.horizontalRule(lineIndex: index))
            index += 1
            continue
        }

        if let firstQuote = MarkdownBlockquote.quoteLine(lines[index]) {
            flushLines(upTo: index)
            var quoteLines = [firstQuote]
            var cursor = index + 1
            while cursor < lines.count, let quote = MarkdownBlockquote.quoteLine(lines[cursor]) {
                quoteLines.append(quote)
                cursor += 1
            }
            if let firstText = quoteLines.first?.text,
               let callout = MarkdownCallout.parse(firstQuoteText: firstText) {
                blocks.append(.callout(
                    kind: callout.kind,
                    title: callout.title,
                    body: Array(quoteLines.dropFirst()),
                    lastLineIndex: cursor - 1
                ))
            } else {
                blocks.append(.blockquote(lines: quoteLines, lastLineIndex: cursor - 1))
            }
            index = cursor
            continue
        }

        if let firstItem = MarkdownList.parse(lines[index]) {
            flushLines(upTo: index)
            var parsed = [firstItem]
            var cursor = index + 1
            while cursor < lines.count, let item = MarkdownList.parse(lines[cursor]) {
                parsed.append(item)
                cursor += 1
            }
            let items = resolveListItems(parsed, firstLineIndex: index, lineStartOffsets: lineStartOffsets)
            blocks.append(.list(items: items, lastLineIndex: cursor - 1))
            index = cursor
            continue
        }

        if let (alt, path) = MarkdownImageLine.wholeLineImage(lines[index]) {
            flushLines(upTo: index)
            let sourceRange = NSRange(location: lineStartOffsets[index], length: (lines[index] as NSString).length)
            blocks.append(.image(alt: alt, path: path, sourceRange: sourceRange))
            index += 1
            continue
        }

        if linesStart == nil {
            linesStart = index
        }
        index += 1
    }

    flushLines(upTo: lines.count)
    return blocks
}

/// Resolve a run of parsed list items into rendered items: numbered items count sequentially
/// within their nesting level (so `1.` `1.` `1.` renders as 1, 2, 3) with re-entering a deeper
/// level restarting its counter; an unordered item whose text is a `[ ]`/`[x]` task marker becomes
/// a checkbox (marker stripped from the text, no ordinal) carrying the marker's source range.
/// `firstLineIndex` is the source line index of the first item; items are contiguous after it.
private func resolveListItems(
    _ parsed: [MarkdownList.Parsed],
    firstLineIndex: Int,
    lineStartOffsets: [Int]
) -> [MarkdownListItem] {
    var counters: [Int: Int] = [:]
    return parsed.enumerated().map { offset, item in
        counters = counters.filter { $0.key <= item.indentLevel }

        var checkbox: MarkdownCheckbox?
        var displayText = item.text
        if !item.ordered, let detected = MarkdownCheckbox.detect(in: item.text) {
            let lineIndex = firstLineIndex + offset
            let markerLocation = lineStartOffsets[lineIndex] + item.textColumn
            checkbox = MarkdownCheckbox(isChecked: detected.isChecked, sourceRange: NSRange(location: markerLocation, length: 3))
            displayText = detected.remaining
        }

        var ordinal: Int?
        if item.ordered {
            counters[item.indentLevel, default: 0] += 1
            ordinal = counters[item.indentLevel]
        }
        return MarkdownListItem(text: displayText, indentLevel: item.indentLevel, ordinal: ordinal, checkbox: checkbox)
    }
}

/// Pure toggle of a task checkbox in the source text: swaps `[ ]`↔`[x]` at `range`, returning the
/// new text — or `nil` when `range` does not hold a `[ ]`/`[x]` marker (a stale range after an
/// external edit), so the caller can safely ignore it.
enum CheckboxToggle {
    static func toggledText(in text: String, at range: NSRange) -> String? {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length, range.length == 3 else { return nil }
        let current = ns.substring(with: range)
        let toggled: String
        switch current {
        case "[ ]": toggled = "[x]"
        case "[x]", "[X]": toggled = "[ ]"
        default: return nil
        }
        return ns.replacingCharacters(in: range, with: toggled)
    }
}
