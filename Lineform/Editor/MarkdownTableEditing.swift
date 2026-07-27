import Foundation

/// A GFM pipe table located in the source text: the block's character range, the range of each
/// of its lines, the parsed table, and the indentation its lines share.
struct MarkdownTableRegion: Equatable {
    /// The whole table block, with no trailing newline.
    var range: NSRange
    /// One range per source line — header, delimiter, then body — each excluding its terminator.
    var lineRanges: [NSRange]
    var table: MarkdownTable
    /// Leading whitespace of the header line, re-emitted on every rewritten line.
    var indent: String

    /// The index into `lineRanges` of the delimiter row, which is never a navigable row.
    static let delimiterLineIndex = 1
}

/// Table authoring: locating the table under the caret, inserting a skeleton, aligning the
/// pipes, and moving between cells on Tab.
///
/// Pure over `(text, selectedRange)` — no AppKit, no view state — so the whole decision surface
/// is testable without a window. `LineformTextView` is the only caller.
///
/// Detection deliberately delegates to `MarkdownTableParser`, the same parser the renderer uses
/// (`MarkdownBlockGrouping.swift:427-444`). If the editor's definition of "a table" and the
/// renderer's ever diverge, Tab intercepts a construct the reader never saw as a table and
/// Reformat rewrites it.
enum MarkdownTableEditing {
    static func locate(in text: String, at location: Int) -> MarkdownTableRegion? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }

        let caretLine = lineRange(in: ns, at: location)
        guard MarkdownTableParser.looksLikeRow(ns.substring(with: caretLine)) else { return nil }

        // Maximal run of consecutive pipe-bearing lines around the caret. A blank line or a
        // pipe-free line ends the run, exactly as it ends the renderer's paragraph accumulation.
        var runLines = [caretLine]
        var cursor = caretLine.location
        while cursor > 0 {
            let previous = lineRange(in: ns, at: cursor - 1)
            guard MarkdownTableParser.looksLikeRow(ns.substring(with: previous)) else { break }
            runLines.insert(previous, at: 0)
            cursor = previous.location
        }
        // Step to the next line through the PARAGRAPH range, which includes the whole terminator.
        // `NSMaxRange(caretLine) + 1` assumed a one-character one: in a CRLF document it landed on
        // the `\n` still inside THIS line's `\r\n`, so `lineRange` handed back the same line, the
        // walk broke immediately, and no table was ever found below the caret — Tab between cells
        // and Reformat simply did not work in a Windows-authored file.
        func startOfLineAfter(_ line: NSRange) -> Int {
            NSMaxRange(ns.lineRange(for: NSRange(location: line.location, length: 0)))
        }
        cursor = startOfLineAfter(caretLine)
        while cursor < ns.length {
            let next = lineRange(in: ns, at: cursor)
            guard MarkdownTableParser.looksLikeRow(ns.substring(with: next)) else { break }
            runLines.append(next)
            let following = startOfLineAfter(next)
            guard following > cursor else { break }
            cursor = following
        }

        // Within the run, the table starts at the FIRST line whose successor is a matching
        // delimiter row — the same line the renderer's sequential scan would settle on. Lines
        // before it are an ordinary paragraph that happens to contain a pipe.
        guard let header = (0..<max(0, runLines.count - 1)).first(where: { index in
            let headerLine = ns.substring(with: runLines[index])
            let delimiterLine = ns.substring(with: runLines[index + 1])
            return MarkdownTableParser.isDelimiterRow(delimiterLine)
                && MarkdownTableParser.cells(in: headerLine).count
                    == MarkdownTableParser.cells(in: delimiterLine).count
        }) else { return nil }

        let lines = Array(runLines[header...])
        guard let first = lines.first, let last = lines.last else { return nil }
        guard location >= first.location, location <= NSMaxRange(last) else { return nil }

        // Only now, after two cheap line-local checks have passed, pay for the whole-document
        // fence scan. Tab on ordinary prose never reaches this.
        guard !MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
            location: first.location,
            in: text
        ) else { return nil }

        let texts = lines.map { ns.substring(with: $0) }
        let table = MarkdownTableParser.parse(
            header: texts[0],
            delimiter: texts[1],
            body: Array(texts.dropFirst(2))
        )
        return MarkdownTableRegion(
            range: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
            lineRanges: lines,
            table: table,
            indent: String(texts[0].prefix(while: { $0 == " " || $0 == "\t" }))
        )
    }

    enum TabOutcome: Equatable {
        /// Pure selection move — edits nothing, so it costs no undo step.
        case select(NSRange)
        /// Tab off the last cell: the only Tab that writes. One localized insertion.
        case appendRow(insertion: String, at: Int, selecting: NSRange)
        /// Consume the key and do nothing — Shift-Tab at the head of a table. Inserting a
        /// literal tab there would corrupt the table.
        ///
        /// Named `stay`, not `none`: `tabTarget` returns `TabOutcome?`, and a bare `return .none`
        /// there would silently resolve to `Optional.none` — "fall through and insert a literal
        /// tab", the exact opposite of what this case means.
        case stay
    }

    /// `nil` means "not a table cell" — the text view should fall through to `super` and insert
    /// an ordinary tab, exactly as it does today.
    static func tabTarget(in text: String, selectedRange: NSRange, forward: Bool) -> TabOutcome? {
        guard let region = locate(in: text, at: selectedRange.location) else { return nil }

        let ns = text as NSString
        // An explicit multi-line selection is the writer's, not ours to reinterpret.
        guard NSMaxRange(selectedRange) <= NSMaxRange(region.range),
              selectedRange.length == 0
                || lineRange(in: ns, at: selectedRange.location)
                    == lineRange(in: ns, at: NSMaxRange(selectedRange)) else { return nil }

        let navigable = region.lineRanges.indices.filter { $0 != MarkdownTableRegion.delimiterLineIndex }
        var cells: [NSRange] = []
        for line in navigable {
            cells.append(contentsOf: contentRanges(ofLine: line, in: region, text: text))
        }
        guard !cells.isEmpty else { return nil }

        let caret = selectedRange.location
        // No cell starts at or before the caret means it sits ahead of the first cell's content —
        // at the very start of the line, before the opening pipe. Tab from there belongs IN the
        // first cell; treating it as "already in cell 0" would skip straight past it.
        guard let current = cells.lastIndex(where: { $0.location <= caret }) else {
            return forward ? .select(cells[0]) : .stay
        }
        let target = forward ? current + 1 : current - 1

        if target < 0 { return .stay }
        if target < cells.count { return .select(cells[target]) }

        let ending = MarkdownLineEnding.inForce(at: region.range.location, in: ns)
        let insertion = ending.text + row(
            cells: Array(repeating: "", count: region.table.columnCount),
            widths: columnWidths(for: region),
            indent: region.indent
        )
        let at = NSMaxRange(region.range)
        return .appendRow(
            insertion: insertion,
            at: at,
            // Past the line ending, the indent, the opening pipe, and its following space.
            selecting: NSRange(location: at + ending.length + (region.indent as NSString).length + 2, length: 0)
        )
    }

    static let insertedColumnCount = 3
    static let insertedBodyRowCount = 2

    /// A 3×2 starter table, written as its own block. Fixed size by design: every other Format
    /// command acts immediately, and gaining a column is one pipe plus Reformat — cheaper than
    /// any size dialog.
    static func insertion(in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let caretLine = lineRange(in: ns, at: selectedRange.location)
        let lineIsBlank = ns.substring(with: caretLine).trimmingCharacters(in: .whitespaces).isEmpty
        let replaced = lineIsBlank ? caretLine : NSRange(location: NSMaxRange(caretLine), length: 0)

        let before = ns.substring(to: replaced.location)
        let after = ns.substring(from: NSMaxRange(replaced))
        // Blank-line separation is measured and written in the document's OWN line ending, so a
        // table inserted into a CRLF file does not seed LF lines around itself.
        let ending = MarkdownLineEnding.inForce(at: selectedRange.location, in: ns).text
        let blankLine = ending + ending
        let leading = before.isEmpty || before.hasSuffix(blankLine) ? "" : (before.hasSuffix(ending) ? ending : blankLine)
        let trailing = after.isEmpty || after.hasPrefix(blankLine) ? "" : (after.hasPrefix(ending) ? ending : blankLine)

        let widths = Array(repeating: 3, count: insertedColumnCount)
        let blank = Array(repeating: "", count: insertedColumnCount)
        var lines = [row(cells: blank, widths: widths, indent: "")]
        lines.append(row(cells: widths.map { String(repeating: "-", count: $0) }, widths: widths, indent: ""))
        for _ in 0..<insertedBodyRowCount {
            lines.append(row(cells: blank, widths: widths, indent: ""))
        }

        let replacement = leading + lines.joined(separator: ending) + trailing
        var edited = text
        if let swiftRange = Range(replaced, in: edited) {
            edited.replaceSubrange(swiftRange, with: replacement)
        }

        // Caret in the first header cell: past the leading blank lines, the opening pipe, and
        // its following space.
        let caret = replaced.location + (leading as NSString).length + 2
        return MarkdownEdit(text: edited, selectedRange: NSRange(location: caret, length: 0))
    }

    /// Pads the pipes of the table under the caret so its columns line up in the source.
    ///
    /// Returns `nil` — a silent no-op, no undo step — when there is no table under the caret,
    /// when the table is already aligned, or when rewriting it would be unsafe. The
    /// already-aligned case is how idempotence is expressed: a second ⌃⌘R does nothing at all.
    ///
    /// The safety refusal is load-bearing. `MarkdownTableParser.cells(in:)` splits on EVERY
    /// pipe; escaped pipes are a documented v1 limitation. That is harmless while rendering,
    /// but Reformat rewrites the file, so the same wrong split would permanently destroy
    /// `a \| b` or `` `a|b` ``. The backtick half of the test is deliberately over-broad: it
    /// declines some tables it could safely rewrite, and it never corrupts one.
    static func reformat(in text: String, selectedRange: NSRange) -> MarkdownEdit? {
        guard let region = locate(in: text, at: selectedRange.location) else { return nil }

        let ns = text as NSString
        let original = ns.substring(with: region.range)
        guard !original.contains("\\|"), !original.contains("`") else { return nil }

        let widths = columnWidths(for: region)
        // Read the colons off the ORIGINAL delimiter rather than `region.table.alignments`.
        // `MarkdownTableParser.alignment(of:)` maps both `---` and `:--` to `.left` — correct for
        // rendering, where they are identical — so rebuilding from it would silently rewrite
        // every explicit `:--` a writer typed. Markdown handling here stays structure-preserving.
        let delimiters = MarkdownTableParser.cells(in: ns.substring(with: region.lineRanges[1]))
        var lines = [row(cells: region.table.headers, widths: widths, indent: region.indent)]
        lines.append(row(
            cells: widths.enumerated().map { column, width in
                delimiterCell(
                    original: delimiters.indices.contains(column) ? delimiters[column] : "-",
                    width: width
                )
            },
            widths: widths,
            indent: region.indent
        ))
        lines.append(contentsOf: region.table.rows.map { row(cells: $0, widths: widths, indent: region.indent) })

        // `region.range` spans the table's interior terminators, so this rewrites them — joining
        // with a bare "\n" silently converted a CRLF table to LF on every ⌃⌘R.
        let replacement = lines.joined(separator: MarkdownLineEnding.inForce(at: region.range.location, in: ns).text)
        guard replacement != original else { return nil }

        var edited = text
        guard let swiftRange = Range(region.range, in: edited) else { return nil }
        edited.replaceSubrange(swiftRange, with: replacement)

        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(
                location: caretAfterReformat(
                    region: region,
                    text: text,
                    replacement: replacement,
                    caret: selectedRange.location
                ),
                length: 0
            )
        )
    }

    /// Keeps the caret in the same cell, at the same offset into that cell's content, so
    /// Reformat never yanks the writer somewhere else in the table.
    private static func caretAfterReformat(
        region: MarkdownTableRegion,
        text: String,
        replacement: String,
        caret: Int
    ) -> Int {
        guard let line = region.lineRanges.firstIndex(where: {
            caret >= $0.location && caret <= NSMaxRange($0)
        }) else { return region.range.location }

        let cells = contentRanges(ofLine: line, in: region, text: text)
        guard let cell = cells.firstIndex(where: { caret <= NSMaxRange($0) }) else {
            return region.range.location
        }
        let offset = max(0, caret - cells[cell].location)

        var rebuiltText = text
        guard let swiftRange = Range(region.range, in: rebuiltText) else { return region.range.location }
        rebuiltText.replaceSubrange(swiftRange, with: replacement)

        let rebuilt = MarkdownTableRegion(
            range: NSRange(location: region.range.location, length: (replacement as NSString).length),
            lineRanges: lineRanges(of: replacement, startingAt: region.range.location),
            table: region.table,
            indent: region.indent
        )
        let rebuiltCells = contentRanges(ofLine: line, in: rebuilt, text: rebuiltText)
        guard rebuiltCells.indices.contains(cell) else { return region.range.location }
        return min(rebuiltCells[cell].location + offset, NSMaxRange(rebuiltCells[cell]))
    }

    /// Line ranges of the rebuilt block, in document coordinates. Every range EXCLUDES its
    /// terminator, matching what `locate` produces — `contentRanges` reads a `\r` left on the end
    /// of a line as cell content, which in a CRLF table added a phantom trailing cell and landed
    /// the caret a column away from the one it was in before ⌃⌘R.
    private static func lineRanges(of block: String, startingAt origin: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = origin
        for line in block.components(separatedBy: "\n") {
            let rawLength = (line as NSString).length
            let contentLength = line.hasSuffix("\r") ? rawLength - 1 : rawLength
            ranges.append(NSRange(location: location, length: contentLength))
            location += rawLength + 1
        }
        return ranges
    }

    /// `| a   | b   |` — always with outer pipes, cells right-padded to the column width.
    ///
    /// The padding is APPENDED rather than produced by `String.padding(toLength:…)`. That method
    /// bridges to NSString and measures in UTF-16 units, while `columnWidths` measures in
    /// Characters — so any cell holding an emoji, a non-BMP character, or a decomposed accent has
    /// a UTF-16 length greater than its Character count and `padding(toLength:)` TRUNCATES it.
    /// `| 😀😀😀😀 |` came back as `| 😀😀 |`, and Reformat writes that to disk. Appending can
    /// only ever add spaces, so a cell is now impossible to shorten.
    static func row(cells: [String], widths: [Int], indent: String) -> String {
        let padded = widths.enumerated().map { index, width -> String in
            let content = cells.indices.contains(index) ? cells[index] : ""
            return content + String(repeating: " ", count: max(0, width - content.count))
        }
        return indent + "| " + padded.joined(separator: " | ") + " |"
    }

    /// Re-emits one delimiter cell at the new width, carrying over exactly the colons the writer
    /// wrote — including an explicit-left `:--`, which renders the same as `---` but is not the
    /// same text.
    private static func delimiterCell(original: String, width: Int) -> String {
        let leading = original.hasPrefix(":")
        let trailing = original.count > 1 && original.hasSuffix(":")
        switch (leading, trailing) {
        case (true, true):
            return ":" + String(repeating: "-", count: max(1, width - 2)) + ":"
        case (true, false):
            return ":" + String(repeating: "-", count: max(1, width - 1))
        case (false, true):
            return String(repeating: "-", count: max(1, width - 1)) + ":"
        case (false, false):
            return String(repeating: "-", count: width)
        }
    }

    /// Document-coordinate ranges of each cell's TRIMMED content on one line of the region.
    ///
    /// Mirrors `MarkdownTableParser.cells(in:)` — optional outer pipes dropped, split on every
    /// remaining pipe — but keeps the positions the parser throws away, which is what Tab needs
    /// in order to select a cell.
    ///
    /// An all-whitespace cell yields a zero-length range where content WOULD start in a
    /// reformatted row — past the pipe and its following space — so Tab into an empty cell puts
    /// the caret where a writer expects to type rather than against the pipe.
    static func contentRanges(ofLine index: Int, in region: MarkdownTableRegion, text: String) -> [NSRange] {
        guard region.lineRanges.indices.contains(index) else { return [] }
        let lineRange = region.lineRanges[index]
        let ns = text as NSString
        let lineNS = ns.substring(with: lineRange) as NSString

        var start = 0
        while start < lineNS.length, isWhitespace(lineNS.character(at: start)) { start += 1 }
        var end = lineNS.length
        while end > start, isWhitespace(lineNS.character(at: end - 1)) { end -= 1 }
        guard start < end else { return [] }

        let pipe = UInt16(UnicodeScalar("|").value)
        if lineNS.character(at: start) == pipe { start += 1 }
        if end - 1 > start, lineNS.character(at: end - 1) == pipe { end -= 1 }
        guard start <= end else { return [] }

        var boundaries: [Int] = [start]
        for offset in start..<end where lineNS.character(at: offset) == pipe {
            boundaries.append(offset)
            boundaries.append(offset + 1)
        }
        boundaries.append(end)

        var ranges: [NSRange] = []
        for pair in stride(from: 0, to: boundaries.count, by: 2) {
            let segmentStart = boundaries[pair]
            let segmentEnd = boundaries[pair + 1]
            var contentStart = segmentStart
            var contentEnd = segmentEnd
            while contentStart < contentEnd, isWhitespace(lineNS.character(at: contentStart)) { contentStart += 1 }
            while contentEnd > contentStart, isWhitespace(lineNS.character(at: contentEnd - 1)) { contentEnd -= 1 }

            if contentStart == contentEnd {
                let anchor = segmentStart + min(1, segmentEnd - segmentStart)
                ranges.append(NSRange(location: lineRange.location + anchor, length: 0))
            } else {
                ranges.append(NSRange(
                    location: lineRange.location + contentStart,
                    length: contentEnd - contentStart
                ))
            }
        }
        return ranges
    }

    /// Per-column render width: the widest cell in that column, floored at 3 so every delimiter
    /// cell can still spell `---`, `:--`, `--:`, or `:-:`.
    ///
    /// Width is measured in Characters (grapheme clusters), not display width, so CJK and emoji
    /// cells under-pad. Pipe alignment is a source-readability nicety, not a layout guarantee.
    static func columnWidths(for region: MarkdownTableRegion) -> [Int] {
        let rows = [region.table.headers] + region.table.rows
        return (0..<region.table.columnCount).map { column in
            rows.reduce(3) { widest, row in
                guard row.indices.contains(column) else { return widest }
                return max(widest, row[column].count)
            }
        }
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == UInt16(UnicodeScalar(" ").value) || character == UInt16(UnicodeScalar("\t").value)
    }

    /// `NSString.lineRange(for:)` includes the terminator; every caller here measures against the
    /// line's own text, so the terminator is trimmed off.
    static func lineRange(in ns: NSString, at location: Int) -> NSRange {
        let clamped = min(max(location, 0), ns.length)
        let paragraph = ns.lineRange(for: NSRange(location: clamped, length: 0))
        var end = NSMaxRange(paragraph)
        while end > paragraph.location {
            let character = ns.substring(with: NSRange(location: end - 1, length: 1))
            guard character == "\n" || character == "\r" else { break }
            end -= 1
        }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }
}
