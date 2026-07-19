import Foundation

/// Pure conversion from document markdown into a clean spoken string for `SpeechController`.
/// Reuses `markdownBlocks(in:)` and a focused inline-marker-stripping pass so bold/italic/
/// code/link/image punctuation is removed but the words remain, and code / math / mermaid /
/// thematic-rule blocks are skipped entirely (not readable long-form prose). No AV dependency.
enum SpeechTextExtractor {
    // Patterns are COPIED from `MarkdownPreviewRenderer` (the source of truth). If those change,
    // mirror them here so spoken text matches the rendered text.
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)

    static func spokenText(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        let blocks = markdownBlocks(in: lines)
        var units: [String] = []

        for block in blocks {
            switch block {
            case .lines(let range):
                appendLineRun(lines, range, into: &units)
            case .blockquote(let quoteLines, _):
                // Only recognized callouts become `.callout` blocks; a plain blockquote reaching here
                // has no callout token, and an UNRECOGNIZED `[!type]` renders literally, so speak the
                // text verbatim to match what's on screen.
                for quote in quoteLines {
                    append(quote.text, into: &units)
                }
            case .callout(_, let title, let body, _):
                if let title {
                    append(title, into: &units)
                }
                for quote in body {
                    append(quote.text, into: &units)
                }
            case .list(let items, _):
                for item in items {
                    append(item.text, into: &units)
                }
            case .table(let table, _):
                appendRow(table.headers, into: &units)
                for row in table.rows { appendRow(row, into: &units) }
            case .image(let alt, let path, _, _):
                appendRaw(imageSpokenText(alt: alt, path: path), into: &units)
            case .singleLineMath, .fencedMath, .mermaid, .horizontalRule, .fencedCode:
                break // skipped: not readable long-form prose (or, for fencedCode, source code)
            }
        }

        return units.joined(separator: "\n")
    }

    static func stripInlineMarkers(_ line: String) -> String {
        let nsLine = line as NSString
        guard nsLine.length > 0 else { return "" }
        var result = ""
        var location = 0
        while location < nsLine.length {
            guard let token = nextToken(in: line, nsLine: nsLine, from: location) else {
                result += nsLine.substring(from: location)
                break
            }
            if token.range.location > location {
                result += nsLine.substring(with: NSRange(location: location, length: token.range.location - location))
            }
            result += token.replacement
            location = token.range.location + token.range.length
        }
        return result
    }

    // MARK: - Block helpers

    private static func appendLineRun(_ lines: [String], _ range: Range<Int>, into units: inout [String]) {
        // A plain ``` / ~~~ code fence is now routed to its own `.fencedCode` block by
        // `markdownBlocks(in:)` before a `.lines` run is ever formed, so this should never see a
        // fence delimiter in practice. The guard is kept defensively (cheap, and matches the
        // brief's original design) in case a future grouping change reintroduces mixed content.
        var inFence = false
        for index in range {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if MermaidFence.isFenceDelimiter(trimmed) {
                inFence.toggle()
                continue // the ``` / ~~~ delimiter itself is never spoken
            }
            if inFence { continue } // fenced code contents are skipped
            if let heading = MarkdownHeadingParser.heading(in: line) {
                append(heading.title, into: &units)
            } else {
                append(line, into: &units)
            }
        }
    }

    private static func appendRow(_ cells: [String], into units: inout [String]) {
        let spoken = cells
            .map { stripInlineMarkers($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        appendRaw(spoken, into: &units)
    }

    /// Strip inline markers from `text`, then append if non-empty after trimming.
    private static func append(_ text: String, into units: inout [String]) {
        appendRaw(stripInlineMarkers(text), into: &units)
    }

    private static func appendRaw(_ text: String, into units: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { units.append(trimmed) }
    }

    /// A standalone `.image` block's spoken text: the alt text, stripped of inline markers, or —
    /// when there is no alt — the URL's filename so a lone image still reads as something. Mirrors
    /// `imageToken`'s inline fallback. Never resolves or touches the file.
    private static func imageSpokenText(alt: String, path: String) -> String {
        let trimmedAlt = alt.trimmingCharacters(in: .whitespaces)
        if !trimmedAlt.isEmpty {
            return stripInlineMarkers(trimmedAlt)
        }
        let filename = imageFilename(from: path)
        return filename.isEmpty ? "Image" : filename
    }

    // MARK: - Inline token scan

    private struct Token {
        var range: NSRange
        var replacement: String
    }

    private static func nextToken(in line: String, nsLine: NSString, from location: Int) -> Token? {
        var earliest: Token?

        func consider(_ candidate: Token?) {
            guard let candidate else { return }
            if let current = earliest, current.range.location <= candidate.range.location { return }
            earliest = candidate
        }

        func captured(_ regex: NSRegularExpression) -> Token? {
            let searchRange = NSRange(location: location, length: nsLine.length - location)
            guard let match = regex.firstMatch(in: line, range: searchRange) else { return nil }
            let inner = nsLine.substring(with: match.range(at: 1))
            return Token(range: match.range, replacement: stripInlineMarkers(inner))
        }

        consider(captured(boldRegex))
        consider(captured(italicRegex))
        consider(captured(codeRegex))
        consider(captured(strikethroughRegex))
        consider(imageToken(in: line, nsLine: nsLine, from: location))
        consider(captured(linkRegex))
        return earliest
    }

    /// `![alt](url)` → the alt text, or the URL's filename when there is no alt (so a lone image
    /// still reads as something). Never resolves or touches the file — pure string work.
    private static func imageToken(in line: String, nsLine: NSString, from location: Int) -> Token? {
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = imageRegex.firstMatch(in: line, range: searchRange) else { return nil }
        let alt = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let replacement: String
        if !alt.isEmpty {
            replacement = stripInlineMarkers(alt)
        } else {
            let filename = imageFilename(from: nsLine.substring(with: match.range(at: 2)))
            replacement = filename.isEmpty ? "Image" : filename
        }
        return Token(range: match.range, replacement: replacement)
    }

    private static func imageFilename(from url: String) -> String {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let withoutFragment = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
        let last = withoutFragment.split(separator: "/").last.map(String.init) ?? withoutFragment
        return last.trimmingCharacters(in: .whitespaces)
    }
}
