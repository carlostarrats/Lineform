import AppKit

final class MarkdownSyntaxHighlighter {
    static let lightThemeInlineCodeColor = NSColor(srgbRed: 0.0, green: 0.32, blue: 0.68, alpha: 1)
    static let darkThemeInlineCodeColor = NSColor(srgbRed: 0.60, green: 0.76, blue: 1.0, alpha: 1)
    static let lightThemeMarkdownMarkerColor = NSColor(srgbRed: 0.24, green: 0.29, blue: 0.35, alpha: 1)
    static let darkThemeMarkdownMarkerColor = NSColor(srgbRed: 0.82, green: 0.86, blue: 0.92, alpha: 1)

    static func inlineCodeColor(for profile: ReadingProfile) -> NSColor {
        inlineCodeColor(for: Theme.theme(for: profile))
    }

    static func inlineCodeColor(for theme: Theme) -> NSColor {
        theme.usesDarkChrome ? darkThemeInlineCodeColor : lightThemeInlineCodeColor
    }

    static func markdownMarkerColor(for profile: ReadingProfile) -> NSColor {
        markdownMarkerColor(for: Theme.theme(for: profile))
    }

    static func markdownMarkerColor(for theme: Theme) -> NSColor {
        if theme.usesDarkChrome {
            return darkThemeMarkdownMarkerColor
        }

        return lightThemeMarkdownMarkerColor
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        baseAttributes(for: .original)
    }

    static func baseAttributes(for profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        // `resolved(for:)`, not `option(for:)?` + a bare-font tail: a RETIRED FontID resolves to
        // nil, and the tail then drew a bare system face while the picker showed the default.
        let font = FontOption.resolved(for: profile.fontID).resolvedFont(size: CGFloat(profile.fontSize))
        let paragraphStyle = paragraphStyle(for: profile, font: font)

        return [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: theme.textColor,
            NSAttributedString.Key.paragraphStyle: paragraphStyle,
            NSAttributedString.Key.kern: profile.letterSpacing
        ]
    }

    static func paragraphStyle(
        for profile: ReadingProfile,
        font: NSFont,
        blockSpacing: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        let lineHeightMultiple = CGFloat(profile.lineHeightMultiple)
        if lineHeightMultiple < 1 {
            paragraphStyle.lineHeightMultiple = 1
            let naturalLineHeight = max(font.ascender - font.descender + font.leading, font.pointSize)
            paragraphStyle.lineSpacing = naturalLineHeight * (lineHeightMultiple - 1)
        } else {
            paragraphStyle.lineHeightMultiple = lineHeightMultiple
        }
        paragraphStyle.paragraphSpacing = blockSpacing
        return paragraphStyle
    }

    static func blockSpacingParagraphStyle(
        for profile: ReadingProfile,
        font: NSFont,
        additionalSpacing: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        paragraphStyle(
            for: profile,
            font: font,
            blockSpacing: CGFloat(profile.paragraphSpacing) + additionalSpacing
        )
    }

    static func markdownBlockSpacingLineRanges(
        in text: String,
        includeLineTerminators: Bool = true,
        includeTrailingBlankBoundary: Bool = true
    ) -> [NSRange] {
        let lines = text.components(separatedBy: "\n")
        let blockSpacingLineIndexes = Set(markdownBlockSpacingLineIndexes(
            in: text,
            includeTrailingBlankBoundary: includeTrailingBlankBoundary
        ))
        var ranges: [NSRange] = []
        var currentLocation = 0

        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length

            if blockSpacingLineIndexes.contains(index) {
                let includesLineTerminator = includeLineTerminators && index < lines.count - 1
                ranges.append(NSRange(location: currentLocation, length: max(length + (includesLineTerminator ? 1 : 0), 1)))
            }

            currentLocation += length
            if index < lines.count - 1 {
                currentLocation += 1
            }
        }

        return ranges
    }

    static func markdownBlockSpacingLineIndexes(
        in text: String,
        includeTrailingBlankBoundary: Bool = true
    ) -> [Int] {
        markdownBlockSpacingLineIndexes(
            inLines: text.components(separatedBy: "\n"),
            includeTrailingBlankBoundary: includeTrailingBlankBoundary
        )
    }

    /// Same as `markdownBlockSpacingLineIndexes(in:)` but takes lines already split by the caller,
    /// so a caller that also needs the split (the preview renderer) does it once, not twice.
    static func markdownBlockSpacingLineIndexes(
        inLines lines: [String],
        includeTrailingBlankBoundary: Bool = true
    ) -> [Int] {
        // Fence state uses `MermaidFence`, the renderer's CommonMark matching, so block spacing
        // agrees with what is actually drawn as one code block. A flag toggled on any ``` / ~~~
        // line ended a ```` block at its first inner ``` and respaced the rest of the document.
        var openFenceMarker: (character: Character, length: Int)?

        return lines.indices.compactMap { index in
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: markdownLineTrimCharacters)
            let inFence = openFenceMarker != nil
            let isClosingFence = openFenceMarker.map { MermaidFence.isClosingFence(trimmed, matching: $0) } ?? false
            let opensFence = !inFence && MermaidFence.openingMarker(trimmed) != nil
            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            let nextLineIsBlank = nextLine?.trimmingCharacters(in: markdownLineTrimCharacters).isEmpty == true
            let nextLineIsHeading = nextLine.map { !inFence && MarkdownHeadingParser.heading(in: $0) != nil } ?? false
            let blankBoundaryIsStable = includeTrailingBlankBoundary || hasNonEmptyLine(after: index + 1, in: lines)
            let isHeading = !inFence && MarkdownHeadingParser.heading(in: line) != nil
            let usesBlockSpacing = !trimmed.isEmpty
                && (
                    isHeading
                        || nextLineIsHeading
                        || (!inFence && nextLineIsBlank && blankBoundaryIsStable)
                        || (isClosingFence && nextLineIsBlank && blankBoundaryIsStable)
                )

            if isClosingFence {
                openFenceMarker = nil
            } else if opensFence {
                openFenceMarker = MermaidFence.openingMarker(trimmed)
            }

            return usesBlockSpacing ? index : nil
        }
    }

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

    private static func hasNonEmptyLine(after index: Int, in lines: [String]) -> Bool {
        guard index + 1 < lines.count else {
            return false
        }

        return lines[(index + 1)...].contains { !$0.trimmingCharacters(in: markdownLineTrimCharacters).isEmpty }
    }

    private let analyzer = MarkdownRangeAnalyzer()

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

    /// `true` when `inner` is fully contained in `outer` — the "already highlighted" guard the
    /// text view uses to skip re-tokenizing on ordinary in-margin scrolls.
    static func range(_ outer: NSRange, covers inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Full refresh: resets the WHOLE document to base attributes (uniform font / paragraph
    /// style / kern / color → stable layout everywhere) and colorizes tokens only within
    /// `tokenScope`. `tokenScope == nil` colorizes the whole document — the original behavior,
    /// used by tests and by any text view with no enclosing scroll view.
    @MainActor
    func highlight(textView: NSTextView, profile: ReadingProfile = .original, tokenScope: NSRange? = nil) {
        guard let storage = textView.textStorage else {
            return
        }

        let selectedRange = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: storage.length)
        let scope = NSIntersectionRange(tokenScope ?? fullRange, fullRange)

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes(for: profile), range: fullRange)
        applyTokenAttributes(in: storage, profile: profile, scope: scope)
        storage.endEditing()
        textView.setSelectedRange(selectedRange)
    }

    /// Incremental token pass: resets ONLY `scope` to base (clearing stale token colors there)
    /// and re-applies tokens within it. Does not touch the rest of the document — base is already
    /// whole-document from the last `highlight`, and edits preserve attributes. Used on the
    /// typing pause and on scroll-settle so the per-pass cost is bounded to the visible window.
    @MainActor
    func refreshTokens(textView: NSTextView, profile: ReadingProfile, scope: NSRange) {
        guard let storage = textView.textStorage else {
            return
        }

        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else {
            return
        }

        let selectedRange = textView.selectedRange()

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes(for: profile), range: clamped)
        applyTokenAttributes(in: storage, profile: profile, scope: clamped)
        storage.endEditing()
        textView.setSelectedRange(selectedRange)
    }

    private func applyTokenAttributes(in storage: NSTextStorage, profile: ReadingProfile, scope: NSRange) {
        guard scope.length > 0 else { return }
        for token in tokens(in: storage.string as NSString, scope: scope) where NSMaxRange(token.range) <= storage.length {
            storage.addAttributes(attributes(for: token.kind, profile: profile), range: token.range)
        }
    }

    private func attributes(for kind: MarkdownTokenKind, profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let markerColor = Self.markdownMarkerColor(for: profile)
        let mutedColor = markerColor

        switch kind {
        case .headingMarker:
            return [.foregroundColor: markerColor]
        case .listMarker, .checkbox, .blockquoteMarker:
            return [.foregroundColor: mutedColor]
        case .codeSpan, .codeFence:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular),
                .foregroundColor: Self.inlineCodeColor(for: profile)
            ]
        case .linkText:
            // Through the theme's contrast floor: `NSColor.linkColor` is the system blue and was
            // the one reader ink not derived from the theme, so nothing put it under the contrast
            // gate — it reads 3.70:1 on Quiet, below AA.
            return [.foregroundColor: Theme.theme(for: profile).readableInk(NSColor.linkColor)]
        case .linkDestination:
            return [.foregroundColor: markerColor]
        case .imageText, .imageDestination:
            // Image links read in link blue (both alt and path) so they're easy to spot as
            // references — unlike ordinary links, the path is colored too, since image links
            // often have an empty alt (`![](path)`) and the path is the only visible content.
            return [.foregroundColor: Theme.theme(for: profile).readableInk(NSColor.linkColor)]
        }
    }
}
