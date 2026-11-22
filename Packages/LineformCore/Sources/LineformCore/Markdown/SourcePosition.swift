import Foundation

/// The two lookups between a rendered Read/Preview string and its Markdown source, read from the
/// `.sourceSpan` attribute `MarkdownPreviewRenderer` puts on every rendered run. Moved from the
/// Mac's `MarkdownPreviewTextView` (its visible-top report and its scroll-to-source restore) so
/// the iPhone Read view maps positions with the same rules. Pure: no layout, no UI.
///
/// Never recompute line offsets from the text instead: the renderer's spans come from
/// `markdownSourceLines(in:)`, the one splitter, which keeps a CRLF file's `\r` and a leading BOM
/// counted correctly.
public enum SourcePosition {
    /// The exact source offset for the rendered character at `renderedIndex`: the start of the
    /// `.sourceSpan` of the run holding it (or, if that run has none, the nearest tagged run before
    /// it), plus how far into the run's RENDERED range the index sits. That offset is clamped to
    /// the span's SOURCE length, so a position deep inside a multi-line block (blockquote, list,
    /// table) stays inside that block instead of overshooting past it. Exact for plain prose.
    ///
    /// `renderedIndex` is clamped into the string. Nil for an empty string, or when no tagged run
    /// is at or before the index.
    public static func sourceLocation(atRenderedIndex renderedIndex: Int, in rendered: NSAttributedString) -> Int? {
        guard rendered.length > 0 else { return nil }
        let index = min(max(0, renderedIndex), rendered.length - 1)
        guard let info = sourceSpan(at: index, in: rendered) else { return nil }
        let renderedOffset = max(0, index - info.renderedRange.location)
        let clampedOffset = min(renderedOffset, max(0, info.sourceSpan.length - 1))
        return info.sourceSpan.location + clampedOffset
    }

    /// The rendered character for source offset `sourceLocation`: in the run whose source span
    /// starts nearest at or before the target (the largest span location ≤ target), as far into
    /// that run as the target sits past the span's start, clamped to the run's last character.
    ///
    /// Nil when the string is empty or no span starts at or before the target (for example
    /// offset 0 of a file that starts with a byte-order mark, whose first span starts at 1). The
    /// caller then shows the very top.
    public static func renderedIndex(forSourceLocation sourceLocation: Int, in rendered: NSAttributedString) -> Int? {
        guard rendered.length > 0 else { return nil }
        var bestRenderedRange: NSRange?
        var bestSourceLocation = -1
        rendered.enumerateAttribute(
            .sourceSpan,
            in: NSRange(location: 0, length: rendered.length),
            options: []
        ) { value, renderedRange, _ in
            guard let value = value as? NSValue else { return }
            let location = value.rangeValue.location
            if location <= sourceLocation, location > bestSourceLocation {
                bestSourceLocation = location
                bestRenderedRange = renderedRange
            }
        }
        guard let bestRenderedRange else { return nil }
        let offsetIntoSource = max(0, sourceLocation - bestSourceLocation)
        return min(bestRenderedRange.location + offsetIntoSource, NSMaxRange(bestRenderedRange) - 1)
    }

    /// The `.sourceSpan` value at `index` and the rendered run it belongs to, or, if that exact run
    /// lacks one (rare), the nearest tagged run before it. Walks backward by attribute run, never
    /// character by character.
    private static func sourceSpan(at index: Int, in rendered: NSAttributedString) -> (sourceSpan: NSRange, renderedRange: NSRange)? {
        var index = min(max(0, index), rendered.length - 1)
        while index >= 0 {
            var effectiveRange = NSRange(location: 0, length: 0)
            if let value = rendered.attribute(.sourceSpan, at: index, effectiveRange: &effectiveRange) as? NSValue {
                return (value.rangeValue, effectiveRange)
            }
            index = effectiveRange.location - 1
        }
        return nil
    }
}
