import Foundation

extension MarkdownSyntaxHighlighter {
    /// Expands `visibleRange` by `margin` characters on each side, snaps the result out to
    /// line boundaries, and clamps to `[0, text.length]`. Empty text → empty range. Pure; the
    /// text view feeds it its on-screen character range so only that window (plus a smoothing
    /// margin) gets re-tokenized on each typing pause / scroll.
    static func scopedTokenRange(visibleRange: NSRange, margin: Int, in text: NSString) -> NSRange {
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
    func tokens(in text: NSString, scope: NSRange) -> [MarkdownTokenRange] {
        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: text.length))
        guard clamped.length > 0 else { return [] }
        let substring = text.substring(with: clamped)
        return analyzer.ranges(in: substring).map { token in
            MarkdownTokenRange(
                kind: token.kind,
                range: NSRange(location: token.range.location + clamped.location, length: token.range.length)
            )
        }
    }
}
