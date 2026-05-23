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
}

struct MarkdownTokenRange: Equatable, Hashable {
    var kind: MarkdownTokenKind
    var range: NSRange
}

struct MarkdownRangeAnalyzer {
    func ranges(in text: String) -> [MarkdownTokenRange] {
        var tokens: [MarkdownTokenRange] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        nsText.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            tokens.append(contentsOf: lineTokens(in: nsText, lineRange: lineRange))
        }

        tokens.append(contentsOf: regexTokens(pattern: "`[^`\\n]+`", kind: .codeSpan, text: text))
        tokens.append(contentsOf: linkTokens(in: text))

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

        if let headingRange = firstMatch(pattern: #"^#{1,6}(?=\s)"#, in: line as String) {
            tokens.append(offsetToken(kind: .headingMarker, localRange: headingRange, lineRange: lineRange))
        }

        if let listRange = firstMatch(pattern: #"^\s*(?:[-+*]|\d+\.)\s"#, in: line as String) {
            tokens.append(offsetToken(kind: .listMarker, localRange: listRange, lineRange: lineRange))
        }

        if let checkboxRange = firstMatch(pattern: #"\[[ xX]\]"#, in: line as String) {
            tokens.append(offsetToken(kind: .checkbox, localRange: checkboxRange, lineRange: lineRange))
        }

        if let quoteRange = firstMatch(pattern: #"^\s*>\s?"#, in: line as String) {
            tokens.append(offsetToken(kind: .blockquoteMarker, localRange: quoteRange, lineRange: lineRange))
        }

        return tokens
    }

    private func linkTokens(in text: String) -> [MarkdownTokenRange] {
        let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]+)\)"#)
        let nsText = text as NSString
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []

        return matches.flatMap { match -> [MarkdownTokenRange] in
            [
                MarkdownTokenRange(kind: .linkText, range: match.range(at: 1)),
                MarkdownTokenRange(kind: .linkDestination, range: match.range(at: 2))
            ]
        }
    }

    private func regexTokens(pattern: String, kind: MarkdownTokenKind, text: String) -> [MarkdownTokenRange] {
        let regex = try? NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        return matches.map { MarkdownTokenRange(kind: kind, range: $0.range) }
    }

    private func firstMatch(pattern: String, in text: String) -> NSRange? {
        let regex = try? NSRegularExpression(pattern: pattern)
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
