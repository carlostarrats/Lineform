import AppKit

final class MarkdownSyntaxHighlighter {
    static let lightThemeInlineCodeColor = NSColor(srgbRed: 0.0, green: 0.32, blue: 0.68, alpha: 1)
    static let darkThemeInlineCodeColor = NSColor(srgbRed: 0.60, green: 0.76, blue: 1.0, alpha: 1)
    static let lightThemeMarkdownMarkerColor = NSColor(srgbRed: 0.24, green: 0.29, blue: 0.35, alpha: 1)
    static let darkThemeMarkdownMarkerColor = NSColor(srgbRed: 0.82, green: 0.86, blue: 0.92, alpha: 1)
    static let lightThemeReducedMarkdownMarkerColor = NSColor(srgbRed: 0.36, green: 0.39, blue: 0.44, alpha: 1)
    static let darkThemeReducedMarkdownMarkerColor = NSColor(srgbRed: 0.76, green: 0.80, blue: 0.86, alpha: 1)

    static func inlineCodeColor(for profile: ReadingProfile) -> NSColor {
        inlineCodeColor(for: Theme.theme(for: profile))
    }

    static func inlineCodeColor(for theme: Theme) -> NSColor {
        theme.usesDarkChrome ? darkThemeInlineCodeColor : lightThemeInlineCodeColor
    }

    static func markdownMarkerColor(for profile: ReadingProfile) -> NSColor {
        markdownMarkerColor(for: Theme.theme(for: profile), reduceMarkdownNoise: profile.reduceMarkdownNoise)
    }

    static func markdownMarkerColor(for theme: Theme) -> NSColor {
        markdownMarkerColor(for: theme, reduceMarkdownNoise: false)
    }

    static func markdownMarkerColor(for theme: Theme, reduceMarkdownNoise: Bool) -> NSColor {
        if theme.usesDarkChrome {
            return reduceMarkdownNoise ? darkThemeReducedMarkdownMarkerColor : darkThemeMarkdownMarkerColor
        }

        return reduceMarkdownNoise ? lightThemeReducedMarkdownMarkerColor : lightThemeMarkdownMarkerColor
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        baseAttributes(for: .original)
    }

    static func baseAttributes(for profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        let font = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
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
        let lines = text.components(separatedBy: "\n")
        var inFence = false

        return lines.indices.compactMap { index in
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFenceDelimiter = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            let isClosingFence = inFence && isFenceDelimiter
            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            let nextLineIsBlank = nextLine?.trimmingCharacters(in: .whitespaces).isEmpty == true
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

            if isFenceDelimiter {
                inFence.toggle()
            }

            return usesBlockSpacing ? index : nil
        }
    }

    private static func hasNonEmptyLine(after index: Int, in lines: [String]) -> Bool {
        guard index + 1 < lines.count else {
            return false
        }

        return lines[(index + 1)...].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private let analyzer = MarkdownRangeAnalyzer()

    @MainActor
    func highlight(textView: NSTextView, profile: ReadingProfile = .original) {
        guard let storage = textView.textStorage else {
            return
        }

        let selectedRange = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes(for: profile), range: fullRange)

        for token in analyzer.ranges(in: textView.string) where NSMaxRange(token.range) <= storage.length {
            storage.addAttributes(attributes(for: token.kind, profile: profile), range: token.range)
        }

        storage.endEditing()
        textView.setSelectedRange(selectedRange)
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
            return [.foregroundColor: NSColor.linkColor]
        case .linkDestination:
            return [.foregroundColor: markerColor]
        }
    }
}
