import Foundation

/// Setting the ATX heading level of the lines a selection touches.
///
/// Pure and AppKit-free so it tests in the default plan, matching `MarkdownListContinuation`
/// and `MarkdownTableEditing`.
///
/// Heading detection is deliberately LOCAL rather than reusing
/// `MarkdownHeadingParser.heading(in:)`: that parser requires a non-empty title, so it reports
/// `nil` for `"## "` — a heading whose text has not been typed yet. Treating that as prose
/// would prepend a second marker and produce `"## ## "`, which is the exact stacking bug this
/// type exists to remove. The two agree on every line that has content, which is the only case
/// the outline sidebar sees.
///
/// See `docs/superpowers/specs/2026-07-26-heading-levels-design.md`.
enum MarkdownHeadingEditing {
    /// The maximum ATX heading level. A seventh `#` is not a heading.
    static let maximumLevel = 6

    enum Line: Equatable {
        /// Blank, a list item, a blockquote, or an indented code block: left byte-identical.
        case skipped
        /// Prose or an existing heading. `level` is `nil` for body text. `contentOffset` is the
        /// NSString offset within the line where its own text begins, after indent and marker.
        case editable(indent: String, level: Int?, contentOffset: Int)
    }

    static func classify(line: String) -> Line {
        let ns = line as NSString
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let hash = UInt16(UnicodeScalar("#").value)

        // Columns, not characters: a tab is four, so a tab-indented code block is recognised
        // as one rather than read as prose.
        var cursor = 0
        var columns = 0
        while cursor < ns.length, ns.character(at: cursor) == space || ns.character(at: cursor) == tab {
            columns += ns.character(at: cursor) == tab ? 4 : 1
            cursor += 1
        }

        // Blank, or an indented code block: four or more columns of leading whitespace.
        guard cursor < ns.length, columns < 4 else {
            return .skipped
        }

        // A list marker or blockquote arrow wins — those lines are never rewritten. Shared with
        // `MarkdownListContinuation` so the two can't disagree about what starts a line.
        if LinePrefix(line: line) != nil {
            return .skipped
        }

        // A fence delimiter itself. `isInsideCodeOrFrontMatter` reports the OPENING ``` as
        // outside the block it opens, so without this line-local check the opening fence is
        // treated as prose and gets a marker.
        let rest = ns.substring(from: cursor)
        if rest.hasPrefix("```") || rest.hasPrefix("~~~") {
            return .skipped
        }

        let indent = ns.substring(with: NSRange(location: 0, length: cursor))

        var hashes = 0
        var scan = cursor
        while scan < ns.length, ns.character(at: scan) == hash {
            hashes += 1
            scan += 1
        }

        // A heading is 1...6 hashes followed by a space or the end of the line. The
        // end-of-line case is what makes `"##"` and `"## "` headings rather than prose.
        if hashes > 0, hashes <= maximumLevel, scan == ns.length || ns.character(at: scan) == space {
            let contentOffset = scan < ns.length ? scan + 1 : scan
            return .editable(indent: indent, level: hashes, contentOffset: contentOffset)
        }

        return .editable(indent: indent, level: nil, contentOffset: cursor)
    }

    /// The edit that sets every editable line the selection touches to `level`, or to body text
    /// when `level` is `nil`.
    ///
    /// Returns `nil` when nothing would change — no editable line, or every line already reads
    /// that way. Bailing here is what keeps a dead keypress out of the undo stack.
    static func setLevel(_ level: Int?, in text: String, selectedRange: NSRange) -> MarkdownEdit? {
        let ns = text as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= ns.length else {
            return nil
        }
        if let level, level < 1 || level > maximumLevel {
            return nil
        }

        let block = ns.lineRange(for: selectedRange)
        guard block.length > 0 || ns.length == 0 else {
            return nil
        }

        var lineStarts: [Int] = []
        var contents: [String] = []
        var terminators: [String] = []
        var cursor = block.location
        while cursor < NSMaxRange(block) {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let full = ns.substring(with: lineRange) as NSString
            let contentLength = full.length - terminatorLength(of: full)
            lineStarts.append(lineRange.location)
            contents.append(full.substring(to: contentLength))
            terminators.append(full.substring(from: contentLength))
            cursor = NSMaxRange(lineRange)
        }
        guard !lineStarts.isEmpty else {
            return nil
        }

        // ONE scoped pass for the whole block, never `isInsideCodeOrFrontMatter` per line —
        // that rescans from the start of the document on every call, which would make Select
        // All + a heading key quadratic in document length.
        let protected = MarkdownWritingToolsProtection.protectedRanges(in: ns, intersecting: block)
        var classifications: [Line] = []
        for (index, content) in contents.enumerated() {
            let classified = classify(line: content)
            let isProtected = protected.contains { NSLocationInRange(lineStarts[index], $0) }
            if case .editable = classified, isProtected {
                classifications.append(.skipped)
            } else {
                classifications.append(classified)
            }
        }

        let editable = classifications.indices.filter {
            if case .editable = classifications[$0] { return true }
            return false
        }
        guard !editable.isEmpty else {
            return nil
        }

        // All-or-nothing decides the toggle direction, so a multi-line selection never
        // half-toggles: repeating a level everything already has is what clears it.
        let alreadyAtLevel = editable.allSatisfy {
            guard case let .editable(_, existing, _) = classifications[$0] else { return false }
            return existing == level
        }
        let target: Int? = alreadyAtLevel ? nil : level

        var rebuilt: [String] = []
        var deltas: [Int] = []
        var markerEnds: [Int] = []
        for index in contents.indices {
            guard case let .editable(indent, _, contentOffset) = classifications[index] else {
                rebuilt.append(contents[index] + terminators[index])
                deltas.append(0)
                markerEnds.append(lineStarts[index])
                continue
            }
            let body = (contents[index] as NSString).substring(from: contentOffset)
            let marker = target.map { String(repeating: "#", count: $0) + " " } ?? ""
            let line = indent + marker + body
            deltas.append((line as NSString).length - (contents[index] as NSString).length)
            markerEnds.append(lineStarts[index] + contentOffset)
            rebuilt.append(line + terminators[index])
        }

        guard deltas.contains(where: { $0 != 0 }) else {
            return nil
        }

        var edited = text
        guard let swiftRange = Range(block, in: edited) else {
            return nil
        }
        edited.replaceSubrange(swiftRange, with: rebuilt.joined())

        let start = mappedLocation(
            selectedRange.location,
            lineStarts: lineStarts,
            contents: contents,
            terminators: terminators,
            markerEnds: markerEnds,
            deltas: deltas
        )
        guard selectedRange.length > 0 else {
            return MarkdownEdit(text: edited, selectedRange: NSRange(location: start, length: 0))
        }
        let end = mappedLocation(
            NSMaxRange(selectedRange),
            lineStarts: lineStarts,
            contents: contents,
            terminators: terminators,
            markerEnds: markerEnds,
            deltas: deltas
        )
        return MarkdownEdit(text: edited, selectedRange: NSRange(location: start, length: max(0, end - start)))
    }

    /// Where a location in the original text lands in the rewritten text.
    ///
    /// This is what keeps the user's TEXT selected rather than the rewritten lines: an offset
    /// measured from the start of a line's own content is preserved exactly, so a caret does
    /// not drift when the `#` count changes under it. A caret sitting *inside* markers that are
    /// being rewritten is clamped to the new content start — there is nowhere else honest to
    /// put it.
    private static func mappedLocation(
        _ location: Int,
        lineStarts: [Int],
        contents: [String],
        terminators: [String],
        markerEnds: [Int],
        deltas: [Int]
    ) -> Int {
        var shift = 0
        for index in lineStarts.indices {
            let lineStart = lineStarts[index]
            let lineEnd = lineStart
                + (contents[index] as NSString).length
                + (terminators[index] as NSString).length

            if location >= lineEnd {
                shift += deltas[index]
                continue
            }

            // The location falls on this line.
            if location >= markerEnds[index] {
                return location + shift + deltas[index]
            }
            return markerEnds[index] + shift + deltas[index]
        }
        return location + shift
    }

    /// The length of the line's terminator, so it can be carried through untouched and the
    /// last line of a file keeps having none.
    private static func terminatorLength(of line: NSString) -> Int {
        guard line.length > 0 else { return 0 }
        let newline = UInt16(UnicodeScalar("\n").value)
        let carriageReturn = UInt16(UnicodeScalar("\r").value)
        let last = line.character(at: line.length - 1)
        guard last == newline || last == carriageReturn else { return 0 }
        if line.length >= 2, last == newline, line.character(at: line.length - 2) == carriageReturn {
            return 2
        }
        return 1
    }
}
