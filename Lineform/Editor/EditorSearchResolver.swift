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

    static func previousIndex(before index: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let index else {
            return matchCount - 1
        }

        return (index - 1 + matchCount) % matchCount
    }

    static func accessibilitySummary(query: String, matchCount: Int, activeIndex: Int?) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        guard matchCount > 0 else {
            return "Search for \(trimmedQuery). No matches."
        }

        let safeActiveIndex = min(max(activeIndex ?? 0, 0), matchCount - 1)
        let matchWord = matchCount == 1 ? "match" : "matches"
        return "Search for \(trimmedQuery). \(matchCount) \(matchWord). Result \(safeActiveIndex + 1) of \(matchCount)."
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
