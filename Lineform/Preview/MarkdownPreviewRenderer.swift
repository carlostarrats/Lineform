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

    /// Back-compat convenience (used by tests and any caller that doesn't render mermaid): uses
    /// a disabled mermaid provider so ```mermaid blocks fall back to a captioned source block.
    func render(_ text: String, profile: ReadingProfile) -> NSAttributedString {
        render(
            text,
            profile: profile,
            columnWidth: CGFloat(profile.columnWidth),
            mermaidProvider: DisabledMermaidImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "0"
        )
    }

    func render(
        _ text: String,
        profile: ReadingProfile,
        columnWidth: CGFloat,
        mermaidProvider: MermaidImageProviding,
        diagramLog: DiagramFailureLogging,
        reportRegistry: DiagramReportRegistry,
        appVersion: String
    ) -> NSAttributedString {
        reportRegistry.reset()
        let output = NSMutableAttributedString(string: "")
        let bodyAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        let bodyBlockSpacingAttributes = blockSpacingAttributes(bodyAttributes, profile: profile)
        let codeAttributes = codeAttributes(profile: profile)
        let codeBlockSpacingAttributes = blockSpacingAttributes(codeAttributes, profile: profile)
        let blockSpacingLineIndexes = Set(MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes(in: text))
        let theme = Theme.theme(for: profile)
        var inFence = false
        let lines = text.components(separatedBy: "\n")

        // Mermaid block accumulation: when a ```mermaid fence opens we buffer its body and, on
        // the closing fence, emit a rendered diagram (or a captioned-source fallback) as one unit.
        var mermaidBody: [String]?

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if mermaidBody != nil {
                if MermaidFence.isFenceDelimiter(trimmed) {
                    // Closing fence: emit the accumulated block, then stop buffering.
                    let source = mermaidBody!.joined(separator: "\n")
                    appendMermaidBlock(
                        source: source,
                        to: output,
                        profile: profile,
                        theme: theme,
                        columnWidth: columnWidth,
                        codeAttributes: codeAttributes,
                        mermaidProvider: mermaidProvider,
                        diagramLog: diagramLog,
                        reportRegistry: reportRegistry,
                        appVersion: appVersion
                    )
                    mermaidBody = nil
                    if index < lines.count - 1 {
                        output.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
                    }
                } else {
                    mermaidBody!.append(line)
                }
                index += 1
                continue
            }

            let usesBlockSpacing = blockSpacingLineIndexes.contains(index)
            let activeBodyAttributes = usesBlockSpacing ? bodyBlockSpacingAttributes : bodyAttributes
            let activeCodeAttributes = usesBlockSpacing ? codeBlockSpacingAttributes : codeAttributes
            var lineTerminatorAttributes = activeBodyAttributes
            if !inFence, MermaidFence.isMermaidOpening(trimmed) {
                // Opening mermaid fence: start buffering the body (the fence line is not emitted).
                mermaidBody = []
                index += 1
                continue
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                output.append(NSAttributedString(string: line, attributes: activeCodeAttributes))
                lineTerminatorAttributes = activeCodeAttributes
            } else if inFence {
                output.append(NSAttributedString(string: line, attributes: activeCodeAttributes))
                lineTerminatorAttributes = activeCodeAttributes
            } else if let heading = heading(in: line) {
                let activeHeadingAttributes = headingAttributes(
                    level: heading.level,
                    profile: profile,
                    usesBlockSpacing: usesBlockSpacing
                )
                output.append(NSAttributedString(
                    string: heading.title,
                    attributes: activeHeadingAttributes
                ))
                lineTerminatorAttributes = activeHeadingAttributes
            } else {
                output.append(inlineMarkdown(in: line, baseAttributes: activeBodyAttributes, profile: profile))
            }

            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: lineTerminatorAttributes))
            }
            index += 1
        }

        // Flush an unclosed mermaid block (no closing fence) so its content is never dropped.
        if let mermaidBody {
            appendMermaidBlock(
                source: mermaidBody.joined(separator: "\n"),
                to: output,
                profile: profile,
                theme: theme,
                columnWidth: columnWidth,
                codeAttributes: codeAttributes,
                mermaidProvider: mermaidProvider,
                diagramLog: diagramLog,
                reportRegistry: reportRegistry,
                appVersion: appVersion
            )
        }

        return output
    }

    /// Emit a mermaid block: a rendered diagram image (constrained to the column width, with a
    /// VoiceOver description) or the captioned-source fallback, logging failures.
    private func appendMermaidBlock(
        source: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        theme: Theme,
        columnWidth: CGFloat,
        codeAttributes: [NSAttributedString.Key: Any],
        mermaidProvider: MermaidImageProviding,
        diagramLog: DiagramFailureLogging,
        reportRegistry: DiagramReportRegistry,
        appVersion: String
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let outcome = mermaidProvider.outcome(
            source: source,
            background: theme.backgroundColor,
            foreground: theme.textColor,
            scale: scale
        )

        switch outcome {
        case .image(let image):
            image.accessibilityDescription = "Mermaid diagram. \(source)"
            let attachment = NSTextAttachment()
            attachment.image = image
            let natural = image.size
            let width = min(natural.width, max(columnWidth, 1))
            let height = natural.width > 0 ? natural.height * (width / natural.width) : natural.height
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            output.append(NSAttributedString(attachment: attachment))
        case .skipped:
            // Size-guard skip: not a render failure, so no report affordance.
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes, reportHash: nil)
        case .failed(let error):
            diagramLog.record(source: source, error: error, appVersion: appVersion)
            let hash = DiagramLog.sourceHash(source)
            reportRegistry.register(hash: hash, source: source, error: error)
            appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes, reportHash: hash)
        }
    }

    private func appendMermaidFallback(
        source: String,
        to output: NSMutableAttributedString,
        profile: ReadingProfile,
        codeAttributes: [NSAttributedString.Key: Any],
        reportHash: String?
    ) {
        var captionAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        captionAttributes[.foregroundColor] = Theme.theme(for: profile).textColor.withAlphaComponent(0.6)
        if let font = captionAttributes[.font] as? NSFont {
            captionAttributes[.font] = NSFont.systemFont(ofSize: max(10, font.pointSize - 2))
        }
        output.append(NSAttributedString(string: "Mermaid diagram (source)", attributes: captionAttributes))
        if let reportHash, let url = DiagramReportLink.url(hash: reportHash) {
            var linkAttributes = captionAttributes
            linkAttributes[.link] = url
            linkAttributes[.foregroundColor] = NSColor.linkColor
            output.append(NSAttributedString(string: "  ", attributes: captionAttributes))
            output.append(NSAttributedString(string: "Report this", attributes: linkAttributes))
        }
        output.append(NSAttributedString(string: "\n", attributes: captionAttributes))
        output.append(NSAttributedString(string: source, attributes: codeAttributes))
    }

    private func heading(in line: String) -> (level: Int, title: String)? {
        MarkdownHeadingParser.heading(in: line)
    }

    private func headingAttributes(level: Int, profile: ReadingProfile, usesBlockSpacing: Bool) -> [NSAttributedString.Key: Any] {
        let theme = Theme.theme(for: profile)
        let bodyFont = FontOption.option(for: profile.fontID)?.resolvedFont(size: CGFloat(profile.fontSize)) ?? .systemFont(ofSize: CGFloat(profile.fontSize))
        let sizeBoost = Self.headingSizeBoosts[level] ?? 0
        let headingFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let resolvedHeadingFont = NSFont(descriptor: headingFont.fontDescriptor, size: bodyFont.pointSize + sizeBoost) ?? headingFont
        let paragraphStyle = usesBlockSpacing
            ? MarkdownSyntaxHighlighter.blockSpacingParagraphStyle(for: profile, font: resolvedHeadingFont, additionalSpacing: 4)
            : MarkdownSyntaxHighlighter.paragraphStyle(for: profile, font: resolvedHeadingFont)

        return [
            NSAttributedString.Key.font: resolvedHeadingFont,
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

    private func blockSpacingAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        profile: ReadingProfile
    ) -> [NSAttributedString.Key: Any] {
        guard profile.paragraphSpacing > 0, let font = attributes[.font] as? NSFont else {
            return attributes
        }

        var spacedAttributes = attributes
        spacedAttributes[.paragraphStyle] = MarkdownSyntaxHighlighter.blockSpacingParagraphStyle(for: profile, font: font)
        return spacedAttributes
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
