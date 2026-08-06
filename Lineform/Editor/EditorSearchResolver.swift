import Foundation

enum EditorSearchResolver {
    struct RefreshState: Equatable {
        let activeIndex: Int?
        let requestedSelection: NSRange?
    }

    static func matches(in text: String, query: String) -> [NSRange] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var searchRange = fullRange
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = nsText.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )

            guard match.location != NSNotFound, match.length > 0 else {
                break
            }

            matches.append(match)
            let nextLocation = match.location + match.length
            searchRange = NSRange(
                location: nextLocation,
                length: max(0, NSMaxRange(fullRange) - nextLocation)
            )
        }

        return matches
    }

    struct ReplacementResult: Equatable {
        let text: String
        let selectedRange: NSRange
        let replacedCount: Int
    }

    /// Replace ALL occurrences of `query` in `text` with `replacement`, in one pass.
    /// Uses the same `matches(in:query:)` as search (case- & diacritic-insensitive, trimmed
    /// query) so replace matches exactly what search finds. Rewrites back-to-front so earlier
    /// ranges stay valid when the replacement length differs, and never re-scans freshly
    /// written text, so a replacement containing the query cannot cascade. Returns nil when
    /// there is nothing to replace (empty/whitespace query or no matches) so callers can no-op.
    static func replaceAll(in text: String, query: String, replacement: String) -> ReplacementResult? {
        let ranges = matches(in: text, query: query)
        guard let firstRange = ranges.first else {
            return nil
        }

        let mutable = NSMutableString(string: text)
        for range in ranges.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }

        // Caret lands at the end of the top-most (first, in document order) replacement.
        let caretLocation = firstRange.location + (replacement as NSString).length
        return ReplacementResult(
            text: mutable as String,
            selectedRange: NSRange(location: caretLocation, length: 0),
            replacedCount: ranges.count
        )
    }

    /// Replace the single match occupying `matchRange` with `replacement`. The returned
    /// selection spans the inserted replacement (so it reads as selected). Returns nil if
    /// `matchRange` no longer fits the text (a stale range after an edit).
    static func replaceMatch(in text: String, matchRange: NSRange, replacement: String) -> ReplacementResult? {
        let nsText = text as NSString
        guard
            matchRange.location != NSNotFound,
            NSMaxRange(matchRange) <= nsText.length
        else {
            return nil
        }

        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: matchRange, with: replacement)
        let insertionRange = NSRange(location: matchRange.location, length: (replacement as NSString).length)
        return ReplacementResult(
            text: mutable as String,
            selectedRange: insertionRange,
            replacedCount: 1
        )
    }

    /// Pick the match to make active for "Replace & find next" after a single replacement.
    ///
    /// `matches` are recomputed against the post-replace text; the next match is the first one
    /// starting at or **after the end of the inserted replacement**, so a replacement that itself
    /// contains the query is skipped rather than re-selected (otherwise Replace would loop on its
    /// own output, e.g. cat→cats→catss). When none follow it wraps to the top.
    ///
    /// `priorInsertions` carries every span inserted earlier in this replace run (see
    /// `insertionsAfterReplacement`), and matches inside ANY of them are skipped on both the
    /// forward and the wrap path. Excluding only the CURRENT insertion was not enough: after the
    /// last occurrence was replaced, the wrap landed on a match sitting inside an EARLIER
    /// replacement, so `the log and the log` → Replace ×4 gave `the logss and the logss` — the
    /// app rewriting its own output, autosaved to the user's file at every step.
    static func nextActiveIndexAfterReplacement(
        matches: [NSRange],
        replacedLocation: Int,
        replacementLength: Int,
        priorInsertions: [NSRange] = []
    ) -> Int? {
        let afterInsertion = replacedLocation + replacementLength
        let current = NSRange(location: replacedLocation, length: replacementLength)
        let inserted = priorInsertions + [current]
        func isInsideAnInsertion(_ match: NSRange) -> Bool {
            inserted.contains { NSIntersectionRange($0, match).length > 0 }
        }

        if let forward = matches.firstIndex(where: {
            $0.location >= afterInsertion && !isInsideAnInsertion($0)
        }) {
            return forward
        }
        return matches.firstIndex {
            $0.location < replacedLocation && !isInsideAnInsertion($0)
        }
    }

    /// Roll the recorded insertion spans forward across a new replacement.
    ///
    /// A replacement changes the text length at one point, so every span that started after the
    /// replaced range shifts by the delta. The new insertion is appended. The result is the set of
    /// "text this replace run wrote" in post-replace coordinates, which is what
    /// `nextActiveIndexAfterReplacement` needs on the next click.
    static func insertionsAfterReplacement(
        priorInsertions: [NSRange],
        matchRange: NSRange,
        replacementLength: Int
    ) -> [NSRange] {
        let delta = replacementLength - matchRange.length
        let shifted = priorInsertions.map { span -> NSRange in
            span.location >= NSMaxRange(matchRange)
                ? NSRange(location: span.location + delta, length: span.length)
                : span
        }
        return shifted + [NSRange(location: matchRange.location, length: replacementLength)]
    }

    static func refreshState(
        currentActiveIndex: Int?,
        matches: [NSRange],
        selectFirstWhenNeeded: Bool,
        navigatesToActiveMatch: Bool
    ) -> RefreshState {
        guard !matches.isEmpty else {
            return RefreshState(activeIndex: nil, requestedSelection: nil)
        }

        let activeIndex: Int?
        if let currentActiveIndex, matches.indices.contains(currentActiveIndex) {
            activeIndex = currentActiveIndex
        } else if selectFirstWhenNeeded {
            activeIndex = 0
        } else {
            activeIndex = nil
        }

        guard
            navigatesToActiveMatch,
            let activeIndex,
            matches.indices.contains(activeIndex)
        else {
            return RefreshState(activeIndex: activeIndex, requestedSelection: nil)
        }

        return RefreshState(activeIndex: activeIndex, requestedSelection: matches[activeIndex])
    }

    static func visibleMatches(_ ranges: [NSRange], activeRange: NSRange?, visibleCharacterRange: NSRange?) -> [NSRange] {
        guard let visibleCharacterRange else {
            return ranges
        }

        var visibleRanges: [NSRange] = []
        for range in ranges {
            let intersectsVisibleRange = NSIntersectionRange(range, visibleCharacterRange).length > 0
            if intersectsVisibleRange || range == activeRange {
                visibleRanges.append(range)
            }
        }
        return visibleRanges
    }

    static func nextIndex(after index: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let index else {
            return 0
        }

        return (index + 1) % matchCount
    }

    static func accessibilitySummary(query: String, matchCount: Int, activeIndex: Int?) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        guard matchCount > 0 else {
            return String(localized: "Search for \(trimmedQuery). No matches.")
        }

        let safeActiveIndex = min(max(activeIndex ?? 0, 0), matchCount - 1)
        // The count goes through catalog plural variations, not an English `== 1` ternary
        // spliced into the sentence.
        let matches = String(localized: "\(matchCount) matches")
        return String(localized: "Search for \(trimmedQuery). \(matches). Result \(safeActiveIndex + 1) of \(matchCount).")
    }
}

enum EditorSearchToolbarPresentation {
    static let usesNativeSearchableToolbarItem = true
    static let preservesSystemToolbarButtonGroup = true
    static let usesSeparateVisualCapsule = true
    static let embedsNavigationControlsInSearchField = false
    static let usesNativeSearchClearButton = true
    static let showsNavigationControlsWhenQueryIsEmpty = false
    static let usesSystemSearchFieldSizing = true
}
