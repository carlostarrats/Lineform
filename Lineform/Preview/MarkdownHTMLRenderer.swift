import Foundation

/// Pure Markdown → HTML emitter over the same `[MarkdownBlock]` grouping the preview renderer
/// uses (`markdownBlocks(in:)`), so a new block construct becomes one new case here and nothing
/// else.
///
/// **Output is ONE-TO-ONE with the source.** Image paths, link URLs, and remote URLs are emitted
/// exactly as the user wrote them — never resolved, rewritten, or inlined. Someone exporting HTML
/// is technical and their intent is what they typed: if they keep the `.html` beside the `.md`,
/// their relative paths keep working. Self-contained output is what PDF export is for. Do not
/// "improve" this by embedding local files or degrading unresolvable paths to alt text.
///
/// Math and mermaid are the only embedded bytes, because they have no user-authored path — the
/// picture is generated from the `$$…$$` / ```mermaid source at export time. They come from an
/// injected provider, which is also what keeps this file free of AppKit so its tests stay in the
/// default test plan.
enum MarkdownHTMLRenderer {

    /// A picture the app generates rather than one the user pointed at.
    enum GeneratedImage: Equatable {
        case math(latex: String)
        case mermaid(source: String)
    }

    /// PNG bytes for a generated image, or `nil` to fall back to emitting the source as text.
    typealias GeneratedImageProvider = (GeneratedImage) -> Data?

    // MARK: Escaping

    /// Escapes the four characters that can break out of text or an attribute value.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: Inline

    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)

    private struct Token {
        enum Kind { case bold, italic, code, strikethrough, image, link }
        var kind: Kind
        var text: String
        /// Destination for image/link; empty otherwise.
        var destination: String
        var range: NSRange
    }

    /// Emits one source line's inline markup. Token text is escaped but NOT re-scanned, matching
    /// the preview renderer's single-pass behavior.
    static func inlineHTML(_ line: String) -> String {
        let nsLine = line as NSString
        var out = ""
        var location = 0

        while location < nsLine.length {
            guard let token = nextToken(in: line, nsLine: nsLine, from: location) else {
                out += escape(nsLine.substring(from: location))
                break
            }
            if token.range.location > location {
                out += escape(nsLine.substring(
                    with: NSRange(location: location, length: token.range.location - location)
                ))
            }
            out += emit(token)
            location = NSMaxRange(token.range)
        }

        return out
    }

    private static func emit(_ token: Token) -> String {
        let text = escape(token.text)
        switch token.kind {
        case .bold: return "<strong>\(text)</strong>"
        case .italic: return "<em>\(text)</em>"
        case .code: return "<code>\(text)</code>"
        case .strikethrough: return "<del>\(text)</del>"
        case .image: return "<img src=\"\(escape(token.destination))\" alt=\"\(text)\">"
        case .link: return "<a href=\"\(escape(token.destination))\">\(text)</a>"
        }
    }

    private static func nextToken(in line: String, nsLine: NSString, from location: Int) -> Token? {
        var earliest: Token?
        consider(token(boldRegex, .bold, line, nsLine, location), &earliest)
        consider(token(italicRegex, .italic, line, nsLine, location), &earliest)
        consider(token(codeRegex, .code, line, nsLine, location), &earliest)
        consider(token(strikethroughRegex, .strikethrough, line, nsLine, location), &earliest)
        consider(token(imageRegex, .image, line, nsLine, location), &earliest)
        consider(token(linkRegex, .link, line, nsLine, location), &earliest)
        return earliest
    }

    /// Earliest match wins. `<=` keeps the FIRST considered token at a tie, which is why `.image`
    /// is considered before `.link`: for `![a](b)` the link regex also matches, one character
    /// later, so position alone already resolves it — but a tie must not flip the result.
    private static func consider(_ candidate: Token?, _ earliest: inout Token?) {
        guard let candidate else { return }
        if let current = earliest, current.range.location <= candidate.range.location { return }
        earliest = candidate
    }

    private static func token(
        _ regex: NSRegularExpression,
        _ kind: Token.Kind,
        _ line: String,
        _ nsLine: NSString,
        _ location: Int
    ) -> Token? {
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = regex.firstMatch(in: line, range: searchRange) else { return nil }
        let destination = match.numberOfRanges > 2 ? nsLine.substring(with: match.range(at: 2)) : ""
        return Token(
            kind: kind,
            text: nsLine.substring(with: match.range(at: 1)),
            destination: destination,
            range: match.range
        )
    }
}
