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
        additionalParagraphSpacing: CGFloat = 0
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
        paragraphStyle.paragraphSpacing = CGFloat(profile.paragraphSpacing) + additionalParagraphSpacing
        return paragraphStyle
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
