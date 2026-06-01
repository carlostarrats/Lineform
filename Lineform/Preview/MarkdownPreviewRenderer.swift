import AppKit

struct MarkdownPreviewRenderer {
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
    private static let headingSizeBoosts: [Int: CGFloat] = [
        1: 11,
        2: 3,
        3: 2,
        4: 1,
        5: 0,
        6: 0
    ]

    func render(_ text: String, profile: ReadingProfile) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let bodyAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        let codeAttributes = codeAttributes(profile: profile)
        var inFence = false
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                output.append(NSAttributedString(string: line, attributes: codeAttributes))
            } else if inFence {
                output.append(NSAttributedString(string: line, attributes: codeAttributes))
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
        MarkdownHeadingParser.heading(in: line)
    }

    private func headingAttributes(level: Int, profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        let bodyFont = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        let sizeBoost = Self.headingSizeBoosts[level] ?? 0
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
            if let token = nextInlineToken(in: line, nsLine: nsLine, from: location) {
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

    private func nextInlineToken(in line: String, nsLine: NSString, from location: Int) -> InlineToken? {
        var earliest: InlineToken?

        consider(
            inlineToken(regex: Self.boldRegex, kind: .bold, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.italicRegex, kind: .italic, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.codeRegex, kind: .code, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )
        consider(
            inlineToken(regex: Self.linkRegex, kind: .link, in: line, nsLine: nsLine, from: location),
            earliest: &earliest
        )

        return earliest
    }

    private func consider(_ candidate: InlineToken?, earliest: inout InlineToken?) {
        guard let candidate else { return }

        if let current = earliest, current.range.location <= candidate.range.location {
            return
        }

        earliest = candidate
    }

    private func inlineToken(regex: NSRegularExpression, kind: InlineToken.Kind, in line: String, nsLine: NSString, from location: Int) -> InlineToken? {
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
