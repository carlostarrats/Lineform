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
    // Short enough that the elided window (centered on the match) fits a result-card
    // pill's single visible line — with the old 120 cap, a match past ~45 characters sat
    // beyond the pill's own trailing truncation, so its bold emphasis was never visible.
    static let snippetMaximumLength = 60

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

    /// How many characters of leading context an elided snippet keeps before the match.
    /// Small on purpose: the match must land near the START of the pill so it is visible
    /// at any card width — a centered window pushed it past narrow pills' truncation.
    static let snippetLeadingContextLength = 12

    /// The first match's line, whitespace-trimmed, elided to `snippetMaximumLength`
    /// characters when longer, with the window LEFT-BIASED to the match (at most
    /// `snippetLeadingContextLength` characters before it). The returned range re-locates
    /// the match within the (possibly elided) snippet text.
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

        // Left-bias the window: at most `snippetLeadingContextLength` characters before
        // the match, the rest of the cap spent on the match and what follows — so the
        // match always sits near the pill's visible start regardless of card width.
        var start = max(0, matchInLine.location - snippetLeadingContextLength)
        if start + snippetMaximumLength > line.length {
            start = max(0, line.length - snippetMaximumLength)
        }
        start = min(start, matchInLine.location)
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
