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
        cursor = NSMaxRange(caretLine)
        while cursor < ns.length {
            let next = lineRange(in: ns, at: cursor + 1)
            guard next.location > cursor,
                  MarkdownTableParser.looksLikeRow(ns.substring(with: next)) else { break }
            runLines.append(next)
            cursor = NSMaxRange(next)
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
