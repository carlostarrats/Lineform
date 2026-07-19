import Foundation

enum MarkdownTokenKind: String, Hashable {
    case headingMarker
    case listMarker
    case checkbox
    case blockquoteMarker
    case codeSpan
    case codeFence
    case linkText
    case linkDestination
    /// An image link's alt text / path (`![alt](path)`). Colored like a link so image references
    /// stand out from body text even when the alt is empty (`![](path)`) — the common case.
    case imageText
    case imageDestination
}

struct MarkdownTokenRange: Equatable, Hashable {
    var kind: MarkdownTokenKind
    var range: NSRange
}

struct MarkdownRangeAnalyzer {
    private static let headingRegex = try? NSRegularExpression(pattern: #"^#{1,6}(?=\s)"#)
    private static let listRegex = try? NSRegularExpression(pattern: #"^\s*(?:[-+*]|\d+[.)])\s"#)
    private static let checkboxRegex = try? NSRegularExpression(pattern: #"\[[ xX]\]"#)
    private static let blockquoteRegex = try? NSRegularExpression(pattern: #"^\s*>\s?"#)
    private static let codeSpanRegex = try? NSRegularExpression(pattern: "`[^`\\n]+`")
    // Newline-excluded so links are strictly single-line: keeps the analyzer fully line-local,
    // which is what lets scoped (visible-window) highlighting stay byte-identical to a whole-doc
    // pass (see MarkdownSyntaxHighlighter.tokens(in:scope:)). The `(?<!!)` lookbehind makes this
    // match ordinary links only — an `![...]` image link is handled by `imageRegex` instead, so
    // the two never double-match the same span.
    private static let linkRegex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
    // Image links `![alt](path)`. Alt is `*` (may be empty — `![](path)` is common), so this
    // colors image references that `linkRegex` (which requires a non-empty label) never matched.
    // Also line-local (no `\n` in any class).
    private static let imageRegex = try? NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)

    func ranges(in text: String) -> [MarkdownTokenRange] {
        var tokens: [MarkdownTokenRange] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        nsText.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            tokens.append(contentsOf: lineTokens(in: nsText, lineRange: lineRange))
        }

        tokens.append(contentsOf: regexTokens(regex: Self.codeSpanRegex, kind: .codeSpan, text: text))
        tokens.append(contentsOf: linkTokens(in: text))
        tokens.append(contentsOf: imageTokens(in: text))

        return tokens.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
    }

    private func lineTokens(in text: NSString, lineRange: NSRange) -> [MarkdownTokenRange] {
        let line = text.substring(with: lineRange) as NSString
        var tokens: [MarkdownTokenRange] = []

        if line.hasPrefix("```") {
            tokens.append(MarkdownTokenRange(kind: .codeFence, range: NSRange(location: lineRange.location, length: 3)))
        }

        if let headingRange = firstMatch(regex: Self.headingRegex, in: line as String) {
            tokens.append(offsetToken(kind: .headingMarker, localRange: headingRange, lineRange: lineRange))
        }

        if let listRange = firstMatch(regex: Self.listRegex, in: line as String) {
            tokens.append(offsetToken(kind: .listMarker, localRange: listRange, lineRange: lineRange))
        }

        if let checkboxRange = firstMatch(regex: Self.checkboxRegex, in: line as String) {
            tokens.append(offsetToken(kind: .checkbox, localRange: checkboxRange, lineRange: lineRange))
        }

        if let quoteRange = firstMatch(regex: Self.blockquoteRegex, in: line as String) {
            tokens.append(offsetToken(kind: .blockquoteMarker, localRange: quoteRange, lineRange: lineRange))
        }

        return tokens
    }

    private func linkTokens(in text: String) -> [MarkdownTokenRange] {
        let nsText = text as NSString
        let matches = Self.linkRegex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []

        return matches.flatMap { match -> [MarkdownTokenRange] in
            [
                MarkdownTokenRange(kind: .linkText, range: match.range(at: 1)),
                MarkdownTokenRange(kind: .linkDestination, range: match.range(at: 2))
            ]
        }
    }

    private func imageTokens(in text: String) -> [MarkdownTokenRange] {
        let nsText = text as NSString
        let matches = Self.imageRegex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []

        return matches.flatMap { match -> [MarkdownTokenRange] in
            var tokens: [MarkdownTokenRange] = []
            let altRange = match.range(at: 1)
            if altRange.length > 0 {
                tokens.append(MarkdownTokenRange(kind: .imageText, range: altRange))
            }
            tokens.append(MarkdownTokenRange(kind: .imageDestination, range: match.range(at: 2)))
            return tokens
        }
    }

    private func regexTokens(regex: NSRegularExpression?, kind: MarkdownTokenKind, text: String) -> [MarkdownTokenRange] {
        let nsText = text as NSString
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        return matches.map { MarkdownTokenRange(kind: kind, range: $0.range) }
    }

    private func firstMatch(regex: NSRegularExpression?, in text: String) -> NSRange? {
        let nsText = text as NSString
        return regex?.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))?.range
    }

    private func offsetToken(kind: MarkdownTokenKind, localRange: NSRange, lineRange: NSRange) -> MarkdownTokenRange {
        MarkdownTokenRange(
            kind: kind,
            range: NSRange(location: lineRange.location + localRange.location, length: localRange.length)
        )
    }
}
