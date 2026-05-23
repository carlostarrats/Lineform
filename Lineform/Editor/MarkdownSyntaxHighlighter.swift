import AppKit

final class MarkdownSyntaxHighlighter {
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: CGFloat(ReadingProfile.original.fontSize)),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private let analyzer = MarkdownRangeAnalyzer()

    @MainActor
    func highlight(textView: NSTextView) {
        guard let storage = textView.textStorage else {
            return
        }

        let selectedRange = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes, range: fullRange)

        for token in analyzer.ranges(in: textView.string) where NSMaxRange(token.range) <= storage.length {
            storage.addAttributes(attributes(for: token.kind), range: token.range)
        }

        storage.endEditing()
        textView.setSelectedRange(selectedRange)
    }

    private func attributes(for kind: MarkdownTokenKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .headingMarker:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .listMarker, .checkbox, .blockquoteMarker:
            return [.foregroundColor: NSColor.tertiaryLabelColor]
        case .codeSpan, .codeFence:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: CGFloat(ReadingProfile.original.fontSize), weight: .regular),
                .foregroundColor: NSColor.systemBrown
            ]
        case .linkText:
            return [.foregroundColor: NSColor.linkColor]
        case .linkDestination:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        }
    }
}
