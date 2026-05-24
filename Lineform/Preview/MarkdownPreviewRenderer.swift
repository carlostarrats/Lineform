import AppKit

struct MarkdownPreviewRenderer {
    func render(_ text: String, profile: ReadingProfile) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let bodyAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        var inFence = false
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                output.append(NSAttributedString(string: line, attributes: codeAttributes(profile: profile)))
            } else if inFence {
                output.append(NSAttributedString(string: line, attributes: codeAttributes(profile: profile)))
            } else if let heading = heading(in: line) {
                output.append(NSAttributedString(string: heading.title, attributes: headingAttributes(level: heading.level, profile: profile)))
            } else {
                output.append(inlineMarkdown(in: line, baseAttributes: bodyAttributes, profile: profile))
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
        let theme = Theme.theme(for: profile)
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

    private func codeAttributes(profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        var attributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
        return attributes
    }

    private func inlineMarkdown(in line: String, baseAttributes: [NSAttributedString.Key: Any], profile: ReadingProfile) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let nsLine = line as NSString
        var location = 0

        while location < nsLine.length {
            if let token = nextInlineToken(in: line, from: location) {
                if token.range.location > location {
                    output.append(NSAttributedString(
                        string: nsLine.substring(with: NSRange(location: location, length: token.range.location - location)),
                        attributes: baseAttributes
                    ))
                }
                output.append(NSAttributedString(string: token.text, attributes: token.attributes(baseAttributes, profile)))
                location = NSMaxRange(token.range)
            } else {
                output.append(NSAttributedString(
                    string: nsLine.substring(from: location),
                    attributes: baseAttributes
                ))
                location = nsLine.length
            }
        }

        return output
    }

    private func nextInlineToken(in line: String, from location: Int) -> InlineToken? {
        let candidates = [
            inlineToken(pattern: #"\*\*([^*\n]+)\*\*"#, kind: .bold, in: line, from: location),
            inlineToken(pattern: #"_([^_\n]+)_"#, kind: .italic, in: line, from: location),
            inlineToken(pattern: #"`([^`\n]+)`"#, kind: .code, in: line, from: location),
            inlineToken(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#, kind: .link, in: line, from: location)
        ].compactMap { $0 }

        return candidates.min { $0.range.location < $1.range.location }
    }

    private func inlineToken(pattern: String, kind: InlineToken.Kind, in line: String, from location: Int) -> InlineToken? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsLine = line as NSString
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = regex.firstMatch(in: line, range: searchRange) else {
            return nil
        }

        return InlineToken(kind: kind, text: nsLine.substring(with: match.range(at: 1)), range: match.range)
    }
}

private struct InlineToken {
    enum Kind {
        case bold
        case italic
        case code
        case link
    }

    var kind: Kind
    var text: String
    var range: NSRange

    func attributes(_ base: [NSAttributedString.Key: Any], _ profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        var attributes = base
        switch kind {
        case .bold:
            if let font = base[.font] as? NSFont {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        case .italic:
            if let font = base[.font] as? NSFont {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
        case .code:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular)
        case .link:
            attributes[.foregroundColor] = NSColor.linkColor
        }
        return attributes
    }
}
