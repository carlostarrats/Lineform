import Foundation

/// Which part of the document the editor tokenizes on each pass. Pure, and shared by the Mac and
/// iPhone editors. Moved from the Mac app's `MarkdownSyntaxHighlighter` (whose `scopedTokenRange`,
/// `tokens(in:scope:)` and `range(_:covers:)` are now one-line forwarders to these).
public enum MarkdownTokenScope {
    /// Expands `visibleRange` by `margin` characters on each side, snaps the result out to
    /// line boundaries, and clamps to `[0, text.length]`. Empty text → empty range. Pure; the
    /// text view feeds it its on-screen character range so only that window (plus a smoothing
    /// margin) gets re-tokenized on each typing pause / scroll.
    public static func scopedTokenRange(in text: NSString, around visibleRange: NSRange, margin: Int) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let lowerBound = max(0, visibleRange.location - margin)
        let upperBound = min(length, NSMaxRange(visibleRange) + margin)

        let start = text.lineRange(for: NSRange(location: min(lowerBound, length - 1), length: 0)).location
        let end: Int
        if upperBound >= length {
            end = length
        } else {
            end = NSMaxRange(text.lineRange(for: NSRange(location: upperBound, length: 0)))
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Tokenizes only the substring in `scope`, offset back to absolute positions. The range
    /// analyzer is line-local (no cross-line token state), so when `scope` is snapped to line
    /// boundaries these are byte-identical to the whole-document tokens intersected with `scope`.
    public static func tokens(in text: NSString, scope: NSRange) -> [MarkdownTokenRange] {
        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: text.length))
        guard clamped.length > 0 else { return [] }
        let substring = text.substring(with: clamped)
        return MarkdownRangeAnalyzer().ranges(in: substring).map { token in
            MarkdownTokenRange(
                kind: token.kind,
                range: NSRange(location: token.range.location + clamped.location, length: token.range.length)
            )
        }
    }

    /// `true` when `inner` is fully contained in `outer` — the "already highlighted" guard the
    /// text view uses to skip re-tokenizing on ordinary in-margin scrolls.
    public static func range(_ outer: NSRange, covers inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }
}
