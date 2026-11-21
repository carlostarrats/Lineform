import Foundation

/// The static half of the editor's Markdown styling: the token inks, the base attributes and the
/// paragraph / block-spacing styles. Moved out of the Mac app's `MarkdownSyntaxHighlighter`
/// (which keeps one-line forwarders of the same names) so the iPhone app styles text the same way.
public enum MarkdownTextStyle {
    public static let lightThemeInlineCodeColor = PlatformColor.lineformSRGB(red: 0.0, green: 0.32, blue: 0.68, alpha: 1)
    public static let darkThemeInlineCodeColor = PlatformColor.lineformSRGB(red: 0.60, green: 0.76, blue: 1.0, alpha: 1)
    public static let lightThemeMarkdownMarkerColor = PlatformColor.lineformSRGB(red: 0.24, green: 0.29, blue: 0.35, alpha: 1)
    public static let darkThemeMarkdownMarkerColor = PlatformColor.lineformSRGB(red: 0.82, green: 0.86, blue: 0.92, alpha: 1)

    public static func inlineCodeColor(for profile: ReadingProfile) -> PlatformColor {
        inlineCodeColor(for: Theme.theme(for: profile))
    }

    public static func inlineCodeColor(for theme: Theme) -> PlatformColor {
        theme.usesDarkChrome ? darkThemeInlineCodeColor : lightThemeInlineCodeColor
    }

    public static func markdownMarkerColor(for profile: ReadingProfile) -> PlatformColor {
        markdownMarkerColor(for: Theme.theme(for: profile))
    }

    public static func markdownMarkerColor(for theme: Theme) -> PlatformColor {
        if theme.usesDarkChrome {
            return darkThemeMarkdownMarkerColor
        }

        return lightThemeMarkdownMarkerColor
    }

    public static var baseAttributes: [NSAttributedString.Key: Any] {
        baseAttributes(for: .original)
    }

    public static func baseAttributes(for profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        // `resolved(for:)`, not `option(for:)?` + a bare `?? .systemFont(…)` tail: a RETIRED
        // FontID resolves to nil here. The tail renders the SAME face today (the default option
        // is SF Pro), so this is forward insurance against the next retirement — not a fix for a
        // visible defect. See `FontOption.resolved(for:)`.
        let font = FontOption.resolved(for: profile.fontID).resolvedFont(size: CGFloat(profile.fontSize))
        let paragraphStyle = paragraphStyle(for: profile, font: font)

        return [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: theme.textColor,
            NSAttributedString.Key.paragraphStyle: paragraphStyle,
            NSAttributedString.Key.kern: profile.letterSpacing
        ]
    }

    public static func paragraphStyle(
        for profile: ReadingProfile,
        font: PlatformFont,
        blockSpacing: CGFloat = 0
    ) -> PlatformMutableParagraphStyle {
        let paragraphStyle = PlatformMutableParagraphStyle()
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

    public static func blockSpacingParagraphStyle(
        for profile: ReadingProfile,
        font: PlatformFont,
        additionalSpacing: CGFloat = 0
    ) -> PlatformMutableParagraphStyle {
        paragraphStyle(
            for: profile,
            font: font,
            blockSpacing: CGFloat(profile.paragraphSpacing) + additionalSpacing
        )
    }

    public static func markdownBlockSpacingLineRanges(
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

    public static func markdownBlockSpacingLineIndexes(
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
    public static func markdownBlockSpacingLineIndexes(
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

    private static func hasNonEmptyLine(after index: Int, in lines: [String]) -> Bool {
        guard index + 1 < lines.count else {
            return false
        }

        return lines[(index + 1)...].contains { !$0.trimmingCharacters(in: markdownLineTrimCharacters).isEmpty }
    }
}
