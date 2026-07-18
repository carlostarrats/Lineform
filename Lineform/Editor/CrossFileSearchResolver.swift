import Foundation

/// One line of context around a cross-file match. `matchRange` locates the query hit
/// WITHIN `lineText` (post-elision), so the UI can emphasize it.
struct CrossFileSearchSnippet: Equatable {
    let lineText: String
    let matchRange: NSRange
}

/// One file's cross-file search result.
struct CrossFileSearchResult: Identifiable, Equatable {
    let id: String            // full URL path — the OutlineFileTreeItem.id rule
    let url: URL
    let name: String
    let relativePath: String
    let rootTitle: String
    let matchCount: Int
    let snippets: [CrossFileSearchSnippet]
}

/// Pure per-file matching + ranking behind the All Files search scope. Matching reuses
/// `EditorSearchResolver.matches` (literal, case- and diacritic-insensitive, trimmed
/// query) so cross-file search agrees with in-file search by construction. No I/O —
/// callers supply the file text. The `EditorSearchResolver` pattern: fully unit-testable.
enum CrossFileSearchResolver {
    /// Longest snippet line shown before eliding around the match.
    static let snippetMaximumLength = 120

    /// Cap on how many per-line snippets a single file contributes to the results page.
    static let maximumSnippetsPerFile = 8

    static func result(for entry: QuickOpenEntry, text: String, query: String) -> CrossFileSearchResult? {
        let matches = EditorSearchResolver.matches(in: text, query: query)
        guard !matches.isEmpty else { return nil }
        return CrossFileSearchResult(
            id: entry.id,
            url: entry.url,
            name: entry.name,
            relativePath: entry.relativePath,
            rootTitle: entry.rootTitle,
            matchCount: matches.count,
            snippets: snippets(in: text, matches: matches)
        )
    }

    /// Builds at most one snippet per distinct source line, in document order, up to
    /// `limit`. A later match sharing an already-represented line is skipped so the
    /// same line's text never appears twice.
    static func snippets(in text: String, matches: [NSRange], limit: Int = maximumSnippetsPerFile) -> [CrossFileSearchSnippet] {
        let nsText = text as NSString
        var result: [CrossFileSearchSnippet] = []
        var seenLineRanges: [NSRange] = []
        for match in matches {
            if result.count >= limit { break }
            let lineRange = nsText.lineRange(for: match)
            if seenLineRanges.contains(where: { NSEqualRanges($0, lineRange) }) { continue }
            seenLineRanges.append(lineRange)
            result.append(snippet(in: text, around: match))
        }
        return result
    }

    /// Display order: most matches first, then name, then relative path — the
    /// QuickOpenIndex stable/deterministic tie-break style.
    static func ranked(_ results: [CrossFileSearchResult]) -> [CrossFileSearchResult] {
        results.sorted { lhs, rhs in
            if lhs.matchCount != rhs.matchCount { return lhs.matchCount > rhs.matchCount }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.relativePath < rhs.relativePath
        }
    }

    /// The first match's line, whitespace-trimmed, elided to `snippetMaximumLength`
    /// characters centered on the match when the line is longer. The returned range
    /// re-locates the match within the (possibly elided) snippet text.
    static func snippet(in text: String, around match: NSRange) -> CrossFileSearchSnippet {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: match)
        var line = nsText.substring(with: lineRange) as NSString
        var matchInLine = NSRange(location: match.location - lineRange.location, length: match.length)

        // Strip the trailing newline (and any trailing whitespace) without disturbing
        // the match offset, then strip leading whitespace and shift the offset.
        let trimmedTrailing = (line as String).replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression
        ) as NSString
        line = trimmedTrailing
        let leadingTrimmed = (line as String).replacingOccurrences(
            of: "^\\s+", with: "", options: .regularExpression
        ) as NSString
        let leadingRemoved = line.length - leadingTrimmed.length
        line = leadingTrimmed
        matchInLine.location = max(0, matchInLine.location - leadingRemoved)
        matchInLine.length = min(matchInLine.length, max(0, line.length - matchInLine.location))

        guard line.length > snippetMaximumLength else {
            return CrossFileSearchSnippet(lineText: line as String, matchRange: matchInLine)
        }

        // Center a window of snippetMaximumLength characters on the match. When the match
        // itself is longer than the cap, `half` would go negative — clamp it so `start`
        // never lands past the match's own start.
        let half = max(0, (snippetMaximumLength - matchInLine.length) / 2)
        var start = max(0, matchInLine.location - half)
        if start + snippetMaximumLength > line.length {
            start = max(0, line.length - snippetMaximumLength)
        }
        let window = NSRange(location: start, length: min(snippetMaximumLength, line.length - start))
        var display = line.substring(with: window)

        // Overlap the match with the window in original-line coordinates first — when the
        // match is longer than the window (the match-longer-than-cap case), only the part
        // of the match that actually falls inside the window should be reported, so this
        // must not simply reuse `matchInLine.length` un-clamped.
        let windowEnd = window.location + window.length
        let matchEnd = matchInLine.location + matchInLine.length
        let overlapStart = max(matchInLine.location, window.location)
        let overlapEnd = min(matchEnd, windowEnd)
        let overlapLength = max(0, overlapEnd - overlapStart)
        var shifted = NSRange(location: overlapStart - start, length: overlapLength)

        if start > 0 {
            display = "…" + display
            shifted.location += 1
        }
        if windowEnd < line.length {
            display += "…"
        }
        shifted.location = max(0, shifted.location)
        shifted.length = min(shifted.length, max(0, (display as NSString).length - shifted.location))
        return CrossFileSearchSnippet(lineText: display, matchRange: shifted)
    }
}
