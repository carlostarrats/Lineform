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

    // MARK: Blocks

    /// The `<body>` inner HTML for a whole document. No shell — `html(for:title:generatedImage:)`
    /// wraps this.
    static func body(for text: String, generatedImage: GeneratedImageProvider) -> String {
        let lines = text.components(separatedBy: "\n")
        var out = ""
        for block in markdownBlocks(in: lines) {
            out += html(for: block, lines: lines, generatedImage: generatedImage)
        }
        return out
    }

    private static func html(
        for block: MarkdownBlock,
        lines: [String],
        generatedImage: GeneratedImageProvider
    ) -> String {
        switch block {
        case let .lines(range):
            return linesHTML(Array(lines[range]))
        case let .singleLineMath(latex, _):
            return generatedHTML(.math(latex: latex), fallback: latex, generatedImage: generatedImage)
        case let .fencedMath(latex, _):
            return generatedHTML(.math(latex: latex), fallback: latex, generatedImage: generatedImage)
        case let .mermaid(source, _):
            return generatedHTML(.mermaid(source: source), fallback: source, generatedImage: generatedImage)
        case .horizontalRule:
            return "<hr>"
        case let .blockquote(quoteLines, _):
            return quoteHTML(quoteLines)
        case let .callout(kind, title, body, _):
            return calloutHTML(kind: kind, title: title, body: body)
        case let .list(items, _):
            return listHTML(items)
        case let .table(table, _):
            return tableHTML(table)
        case let .fencedCode(language, body, _, _):
            let openTag = language.isEmpty ? "<pre><code>" : "<pre><code class=\"language-\(escape(language))\">"
            return "\(openTag)\(escape(body))</code></pre>"
        case let .image(alt, path, _, _):
            return "<p><img src=\"\(escape(path))\" alt=\"\(escape(alt))\"></p>"
        }
    }

    /// A run of ordinary lines: headings become heading tags, and maximal runs of non-blank
    /// lines become one paragraph whose source line breaks are preserved as `<br>` (matching how
    /// Read mode lays the same lines out).
    private static func linesHTML(_ lines: [String]) -> String {
        var out = ""
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out += "<p>\(paragraph.joined(separator: "<br>"))</p>"
            paragraph.removeAll()
        }

        for line in lines {
            if let heading = MarkdownHeadingParser.heading(in: line) {
                flush()
                let level = min(max(heading.level, 1), 6)
                out += "<h\(level)>\(inlineHTML(heading.title))</h\(level)>"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(inlineHTML(line))
            }
        }
        flush()
        return out
    }

    private static func listHTML(_ items: [MarkdownListItem]) -> String {
        var out = ""
        /// One entry per currently-open list, innermost last: its tag and its indent level.
        var open: [(tag: String, level: Int)] = []

        for item in items {
            let tag = item.ordinal == nil ? "ul" : "ol"

            while let last = open.last, last.level > item.indentLevel {
                out += "</\(last.tag)></li>"
                open.removeLast()
            }

            if let last = open.last, last.level == item.indentLevel {
                if last.tag == tag {
                    out += "</li>"
                } else {
                    // A bullet run turning into a numbered run at the same depth closes one list
                    // and opens the other, rather than emitting mismatched tags.
                    out += "</li></\(last.tag)>"
                    open.removeLast()
                    out += "<\(tag)>"
                    open.append((tag, item.indentLevel))
                }
            } else {
                // Deeper than anything open (or nothing open): nest inside the current item.
                out += "<\(tag)>"
                open.append((tag, item.indentLevel))
            }

            out += "<li>\(itemHTML(item))"
        }

        while let last = open.popLast() {
            out += "</li></\(last.tag)>"
        }
        return out
    }

    private static func itemHTML(_ item: MarkdownListItem) -> String {
        guard let checkbox = item.checkbox else { return inlineHTML(item.text) }
        let checked = checkbox.isChecked ? " checked" : ""
        return "<input type=\"checkbox\" disabled\(checked)> \(inlineHTML(item.text))"
    }

    private static func quoteHTML(_ quoteLines: [MarkdownQuoteLine]) -> String {
        var out = ""
        var depth = 0
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out += "<p>\(paragraph.joined(separator: "<br>"))</p>"
            paragraph.removeAll()
        }

        for line in quoteLines {
            if line.depth != depth {
                flush()
                while depth < line.depth { out += "<blockquote>"; depth += 1 }
                while depth > line.depth { out += "</blockquote>"; depth -= 1 }
            }
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(inlineHTML(line.text))
            }
        }
        flush()
        while depth > 0 { out += "</blockquote>"; depth -= 1 }
        return out
    }

    private static func calloutHTML(kind: CalloutKind, title: String?, body: [MarkdownQuoteLine]) -> String {
        let heading = (title?.isEmpty == false) ? title! : kind.displayName
        var out = "<blockquote class=\"callout callout-\(kind.rawValue)\">"
        out += "<p class=\"callout-title\">\(escape(heading))</p>"
        // Body lines are already marker-stripped; render them at depth 0 inside this blockquote.
        out += quoteHTML(body.map { MarkdownQuoteLine(depth: 0, text: $0.text) })
        out += "</blockquote>"
        return out
    }

    private static func tableHTML(_ table: MarkdownTable) -> String {
        func style(_ index: Int) -> String {
            let alignment = table.alignments.indices.contains(index) ? table.alignments[index] : .left
            switch alignment {
            case .left: return "left"
            case .center: return "center"
            case .right: return "right"
            }
        }

        var out = "<table><thead><tr>"
        for (index, header) in table.headers.enumerated() {
            out += "<th style=\"text-align:\(style(index))\">\(inlineHTML(header))</th>"
        }
        out += "</tr></thead><tbody>"
        for row in table.rows {
            out += "<tr>"
            for (index, cell) in row.enumerated() {
                out += "<td style=\"text-align:\(style(index))\">\(inlineHTML(cell))</td>"
            }
            out += "</tr>"
        }
        out += "</tbody></table>"
        return out
    }

    /// Math and mermaid: the only embedded bytes, because there is no user path to preserve.
    /// A provider that declines falls back to the source as preformatted text, so a broken
    /// formula or diagram never loses content.
    private static func generatedHTML(
        _ image: GeneratedImage,
        fallback: String,
        generatedImage: GeneratedImageProvider
    ) -> String {
        guard let data = generatedImage(image) else {
            return "<pre><code>\(escape(fallback))</code></pre>"
        }
        let base64 = data.base64EncodedString()
        return "<p><img src=\"data:image/png;base64,\(base64)\" alt=\"\(escape(fallback))\"></p>"
    }
}
