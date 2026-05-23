import AppKit

struct MarkdownPreviewRenderer {
    func render(_ text: String, profile: ReadingProfile) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: "\n")
        let bodyAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)

        for (index, line) in lines.enumerated() {
            if let heading = heading(in: line) {
                output.append(NSAttributedString(string: heading.title, attributes: headingAttributes(level: heading.level, profile: profile)))
            } else {
                output.append(NSAttributedString(string: line, attributes: bodyAttributes))
            }

            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }
        }

        return output
    }

    private func heading(in line: String) -> (level: Int, title: String)? {
        MarkdownOutlineParser().items(in: line).first.map { ($0.level, $0.title) }
    }

    private func headingAttributes(level: Int, profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile.themeID)
        let bodyFont = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        let sizeBoost = CGFloat(max(1, 7 - level)) * 1.6
        let headingFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = CGFloat(profile.lineHeightMultiple)
        paragraphStyle.paragraphSpacing = CGFloat(profile.paragraphSpacing + 4)

        return [
            NSAttributedString.Key.font: NSFont(descriptor: headingFont.fontDescriptor, size: bodyFont.pointSize + sizeBoost) ?? headingFont,
            NSAttributedString.Key.foregroundColor: theme.textColor,
            NSAttributedString.Key.paragraphStyle: paragraphStyle,
            NSAttributedString.Key.kern: profile.letterSpacing
        ]
    }
}
