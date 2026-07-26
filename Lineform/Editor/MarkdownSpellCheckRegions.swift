import Foundation

/// The sub-ranges of a document that should be spell-checked: everything except the Markdown
/// regions where a "misspelling" is not a misspelling.
///
/// Pure and AppKit-free so it tests in the default plan, and — load-bearing — so the checking
/// path never touches a whole-document pass. `MarkdownWritingToolsProtection.ignoredRanges` and
/// `MarkdownRangeAnalyzer.ranges(in:)` are both whole-document (18 ms at 730 KB) and are BANNED
/// from this path; use the scoped entry points instead, as below.
///
/// See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md`.
enum MarkdownSpellCheckRegions {
    /// Inline token kinds that are not prose. Link and image TEXT are deliberately absent:
    /// `[teh docs](/path)` should flag `teh` and ignore `/path`.
    static let suppressedInlineKinds: Set<MarkdownTokenKind> = [
        .codeSpan,
        .linkDestination,
        .imageDestination,
    ]

    static func checkableRanges(
        in text: NSString,
        enclosing range: NSRange,
        highlighter: MarkdownSyntaxHighlighter = MarkdownSyntaxHighlighter()
    ) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        let clamped = NSIntersectionRange(range, full)
        guard clamped.length > 0 else { return [] }

        // Snap out to line boundaries before tokenizing. The range analyzer is line-local, so
        // this is exactly what makes the scoped tokens byte-identical to a whole-document pass;
        // a raw AppKit range would mis-tokenize a construct straddling the edge.
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(visibleRange: clamped, margin: 0, in: text)

        var suppressed = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        suppressed += highlighter
            .tokens(in: text, scope: scope)
            .filter { suppressedInlineKinds.contains($0.kind) }
            .map(\.range)

        return subtracting(suppressed, from: clamped)
    }

    /// `range` minus `ranges`, clipped, sorted, coalesced. Never returns zero-length or
    /// overlapping ranges — each result is handed straight to AppKit.
    static func subtracting(_ ranges: [NSRange], from range: NSRange) -> [NSRange] {
        let clipped = ranges
            .map { NSIntersectionRange($0, range) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

        var result: [NSRange] = []
        var cursor = range.location
        for suppressed in clipped {
            if suppressed.location > cursor {
                result.append(NSRange(location: cursor, length: suppressed.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(suppressed))
        }
        if cursor < NSMaxRange(range) {
            result.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return result
    }
}
