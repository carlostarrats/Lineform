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
    /// Query hits in the filename. These are kept separate from document hits so the
    /// card can emphasize its title without pretending a filename is source text.
    let filenameMatches: [NSRange]
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
    // Generous on purpose: the result card scrolls, so a heavily-matched file should
    // list (nearly) every matching line — a cap of 8 left cards feeling truncated. This
    // is a runaway guard, not a display budget.
    static let maximumSnippetsPerFile = 100

    static func result(for entry: QuickOpenEntry, text: String?, query: String) -> CrossFileSearchResult? {
        let filenameMatches = EditorSearchResolver.matches(in: entry.name, query: query)
        let contentMatches = text.map { EditorSearchResolver.matches(in: $0, query: query) } ?? []
        guard !filenameMatches.isEmpty || !contentMatches.isEmpty else { return nil }
        return CrossFileSearchResult(
            id: entry.id,
            url: entry.url,
            name: entry.name,
            relativePath: entry.relativePath,
            rootTitle: entry.rootTitle,
            filenameMatches: filenameMatches,
            matchCount: filenameMatches.count + contentMatches.count,
            snippets: text.map { snippets(in: $0, matches: contentMatches) } ?? []
        )
    }

    /// Builds ONE snippet per match, in document order, up to `limit` — the card lists
    /// exactly as many pills as the header's match count (QA: "8 matches" showing 5
    /// per-line pills read as missing items). A line with several hits appears once per
    /// hit, each snippet elided around its own match.
    static func snippets(in text: String, matches: [NSRange], limit: Int = maximumSnippetsPerFile) -> [CrossFileSearchSnippet] {
        matches.prefix(limit).map { snippet(in: text, around: $0) }
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
        // Deliberately NO backward fill when the match is near the line's end (a shorter
        // window is fine): pulling `start` back to fill the cap re-hid end-of-line
        // matches past the pill's visible width — the exact bug this bias exists to fix.
        // Both window edges are snapped to composed-character boundaries before slicing. The
        // lengths above are documented in characters but measured in UTF-16 units, so an unsnapped
        // edge could land between the surrogates of an emoji: `substring(with:)` does not raise,
        // it returns a lone surrogate, and the pill then showed a U+FFFD that is not in the file.
        // Same class as the Table Reformat padding rule — UTF-16 arithmetic against text measured
        // in Characters.
        let rawStart = max(0, matchInLine.location - snippetLeadingContextLength)
        let start = rawStart < line.length
            ? line.rangeOfComposedCharacterSequence(at: rawStart).location
            : rawStart
        let rawEnd = min(line.length, start + snippetMaximumLength)
        let end = rawEnd > start && rawEnd < line.length
            ? NSMaxRange(line.rangeOfComposedCharacterSequence(at: rawEnd - 1))
            : rawEnd
        let window = NSRange(location: start, length: max(0, min(end, line.length) - start))
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
