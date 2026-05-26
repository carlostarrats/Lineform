import AppKit

final class MarkdownSyntaxHighlighter {
    static let lightThemeInlineCodeColor = NSColor(srgbRed: 0.0, green: 0.32, blue: 0.68, alpha: 1)
    static let darkThemeInlineCodeColor = NSColor(srgbRed: 0.60, green: 0.76, blue: 1.0, alpha: 1)

    static func inlineCodeColor(for profile: ReadingProfile) -> NSColor {
        inlineCodeColor(for: Theme.theme(for: profile))
    }

    static func inlineCodeColor(for theme: Theme) -> NSColor {
        theme.usesDarkChrome ? darkThemeInlineCodeColor : lightThemeInlineCodeColor
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        baseAttributes(for: .original)
    }

    static func baseAttributes(for profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        let font = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = CGFloat(profile.lineHeightMultiple)
        paragraphStyle.paragraphSpacing = CGFloat(profile.paragraphSpacing)

        return [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: theme.textColor,
            NSAttributedString.Key.paragraphStyle: paragraphStyle,
            NSAttributedString.Key.kern: profile.letterSpacing
        ]
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
        let textColor = Theme.theme(for: profile).textColor
        let markerColor = textColor.withAlphaComponent(profile.reduceMarkdownNoise ? 0.45 : 0.72)
        let mutedColor = textColor.withAlphaComponent(profile.reduceMarkdownNoise ? 0.55 : 0.62)

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
