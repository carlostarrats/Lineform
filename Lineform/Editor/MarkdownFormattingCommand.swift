import Foundation

struct MarkdownEdit: Equatable {
    var text: String
    var selectedRange: NSRange
}

enum LineformTextFormat: String, Equatable {
    case markdown
    case plainText
}

struct MarkdownPlainTextConversion: Equatable {
    var originalMarkdown: String
    var plainText: String
    var range: NSRange

    func restoredMarkdown(in text: String) -> MarkdownEdit? {
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else {
            return nil
        }

        guard nsText.substring(with: range) == plainText else {
            return nil
        }

        var edited = text
        guard let swiftRange = Range(range, in: text) else {
            return nil
        }
        edited.replaceSubrange(swiftRange, with: originalMarkdown)
        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(location: range.location, length: (originalMarkdown as NSString).length)
        )
    }
}

enum MarkdownPlainTextConverter {
    static func plainText(from markdown: String) -> String {
        // Split on "\n", NOT `.newlines`: that set splits `\r` and `\n` separately, so every
        // `\r\n` in a Windows-authored file produced an EMPTY component between them and the
        // conversion inserted a blank line after every line — in a command that rewrites the
        // user's document. The `\r` is set aside for detection and put back on the way out, so
        // the file's line endings survive the conversion unchanged.
        var text = markdown
            .components(separatedBy: "\n")
            .compactMap { raw -> String? in
                let carriageReturn = raw.hasSuffix("\r") ? "\r" : ""
                let line = carriageReturn.isEmpty ? raw : String(raw.dropLast())
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    return nil
                }
                return stripLinePrefix(from: line) + carriageReturn
            }
            .joined(separator: "\n")

        text = replace(pattern: #"!\[([^\]]*)\]\([^)]+\)"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: text, withTemplate: "$1")
        // These mirror `MarkdownInlineSyntax` — conversion must strip exactly what the app draws
        // as emphasis, no more. Bold is `**` only (the renderer has never read `__bold__`, so
        // stripping it here would eat a Python `__init__`), underscore italics can't start or end
        // inside a word (`make_test_file`), and asterisk italics can't be flanked by spaces
        // (`2 * 3 * 4`). Unlike the renderer, a wrong answer here rewrites the user's file.
        text = replace(pattern: #"\*\*([^*\n]+)\*\*"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"(?<![\*\\])\*([^*\s\n](?:[^*\n]*[^*\s\n])?)\*(?!\*)"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"(?<![\w\\])_([^_\n]+)_(?![\w])"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"`([^`\n]+)`"#, in: text, withTemplate: "$1")

        return text
    }

    private static func stripLinePrefix(from line: String) -> String {
        var stripped = replace(pattern: #"^\s{0,3}#{1,6}\s+"#, in: line, withTemplate: "")
        stripped = replace(pattern: #"^\s{0,3}>\s?"#, in: stripped, withTemplate: "")
        stripped = replace(pattern: #"^\s{0,3}[-*+]\s+"#, in: stripped, withTemplate: "")
        stripped = replace(pattern: #"^\s{0,3}\d+[.)]\s+"#, in: stripped, withTemplate: "")
        return stripped
    }

    private static func replace(pattern: String, in text: String, withTemplate template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Heading levels are deliberately absent: `apply` returns a non-optional edit, so a heading
/// no-op would have to become an identity edit, and routing that through
/// `applyFormattingCommand` pushes an empty step onto the undo stack.
/// `MarkdownHeadingEditing.setLevel` returns `nil` instead, and `applyHeadingLevel` bails.
enum MarkdownFormattingCommand {
    case bold
    case italic
    case inlineCode
    case strikethrough
    case blockquote
    case unorderedList
    case orderedList
    case link

    func apply(to text: String, selectedRange: NSRange) -> MarkdownEdit {
        let selectedRange = Self.composedCharacterAligned(selectedRange, in: text)
        switch self {
        case .bold:
            return toggleMarkers("**", in: text, selectedRange: selectedRange)
        case .italic:
            return toggleItalic(in: text, selectedRange: selectedRange)
        case .inlineCode:
            return toggleMarkers("`", in: text, selectedRange: selectedRange)
        case .strikethrough:
            return toggleMarkers("~~", in: text, selectedRange: selectedRange)
        case .blockquote:
            return prefixSelectedLines("> ", in: text, selectedRange: selectedRange)
        case .unorderedList:
            return prefixSelectedLines("- ", in: text, selectedRange: selectedRange)
        case .orderedList:
            return prefixSelectedLines("1. ", in: text, selectedRange: selectedRange)
        case .link:
            return wrapLink(in: text, selectedRange: selectedRange)
        }
    }

    /// Snaps a selection to composed-character boundaries.
    ///
    /// Every command's arithmetic is UTF-16 while the edit itself goes through
    /// `Range(_:in:)`, which returns `nil` for a range that splits a surrogate pair or lands
    /// between a base character and its combining mark. `replace` then silently did nothing
    /// while the command still reported the selection the edit WOULD have produced — a range
    /// past the end of the unchanged document, and `setSelectedRange` raises on that rather
    /// than merely putting the caret somewhere odd.
    ///
    /// Aligning once here fixes every command at the entry point instead of each edit site,
    /// and it is also the behaviour a person expects: a selection that clips half an emoji
    /// grows to cover the whole one rather than being refused.
    static func composedCharacterAligned(_ range: NSRange, in text: String) -> NSRange {
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else {
            return NSRange(location: min(range.location, nsText.length), length: 0)
        }
        // A caret only needs its own location moved off the middle of a sequence; growing it the
        // way a real selection grows would silently turn the caret into a selection.
        guard range.length > 0 else {
            guard range.location > 0, range.location < nsText.length else { return range }
            return NSRange(location: nsText.rangeOfComposedCharacterSequence(at: range.location).location, length: 0)
        }
        return nsText.rangeOfComposedCharacterSequences(for: range)
    }

    /// Italic is the one command whose marker depends on where the caret is.
    ///
    /// `MarkdownInlineSyntax.italic` refuses intraword `_` — the rule that keeps `make_test_file`
    /// intact — so wrapping a mid-word selection in underscores would emit markup the app then
    /// renders as literal underscores. Asterisks have no such restriction, so a partial word gets
    /// `*`, everything else keeps the familiar `_`. Un-toggling accepts whichever marker is there.
    private func toggleItalic(in text: String, selectedRange: NSRange) -> MarkdownEdit {
        if let removal = removingMarkers("_", in: text, selectedRange: selectedRange) {
            return removal
        }
        // Only a LONE asterisk is ours to remove. Peeling one off `**word**` would leave `*word*`,
        // quietly turning bold into italic.
        if !isInsideDoubleAsterisk(text, selectedRange: selectedRange),
           let removal = removingMarkers("*", in: text, selectedRange: selectedRange) {
            return removal
        }

        let marker = touchesWordCharacter(text, selectedRange: selectedRange) ? "*" : "_"
        return addingMarkers(marker, in: text, selectedRange: selectedRange)
    }

    /// Whether a word character sits immediately before or after the selection — i.e. wrapping it
    /// would put a marker inside a word.
    private func touchesWordCharacter(_ text: String, selectedRange: NSRange) -> Bool {
        let nsText = text as NSString
        let isWord: (unichar) -> Bool = { char in
            guard let scalar = Unicode.Scalar(char) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }

        if selectedRange.location > 0, isWord(nsText.character(at: selectedRange.location - 1)) {
            return true
        }
        let after = NSMaxRange(selectedRange)
        if after < nsText.length, isWord(nsText.character(at: after)) {
            return true
        }
        return false
    }

    private func isInsideDoubleAsterisk(_ text: String, selectedRange: NSRange) -> Bool {
        let nsText = text as NSString
        let before = selectedRange.location - 2
        let after = NSMaxRange(selectedRange) + 1
        guard before >= 0, after < nsText.length else { return false }
        return nsText.character(at: before) == unichar(UInt8(ascii: "*"))
            && nsText.character(at: after) == unichar(UInt8(ascii: "*"))
    }

    private func removingMarkers(_ marker: String, in text: String, selectedRange: NSRange) -> MarkdownEdit? {
        let nsText = text as NSString
        let markerLength = (marker as NSString).length
        let prefixRange = NSRange(location: selectedRange.location - markerLength, length: markerLength)
        let suffixRange = NSRange(location: NSMaxRange(selectedRange), length: markerLength)

        guard selectedRange.location >= markerLength,
              NSMaxRange(suffixRange) <= nsText.length,
              nsText.substring(with: prefixRange) == marker,
              nsText.substring(with: suffixRange) == marker else { return nil }

        var edited = text
        replace(range: suffixRange, in: &edited, with: "")
        replace(range: prefixRange, in: &edited, with: "")
        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(location: selectedRange.location - markerLength, length: selectedRange.length)
        )
    }

    private func addingMarkers(_ marker: String, in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let markerLength = (marker as NSString).length
        var edited = text
        replace(range: selectedRange, in: &edited, with: marker + nsText.substring(with: selectedRange) + marker)
        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(location: selectedRange.location + markerLength, length: selectedRange.length)
        )
    }

    private func toggleMarkers(_ marker: String, in text: String, selectedRange: NSRange) -> MarkdownEdit {
        removingMarkers(marker, in: text, selectedRange: selectedRange)
            ?? addingMarkers(marker, in: text, selectedRange: selectedRange)
    }

    private func prefixSelectedLines(_ prefix: String, in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let selectedText = nsText.substring(with: selectedRange)
        let lines = selectedText.components(separatedBy: "\n")
        let replacement = lines.map { line in
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : prefix + line
        }.joined(separator: "\n")

        var edited = text
        replace(range: selectedRange, in: &edited, with: replacement)
        return MarkdownEdit(text: edited, selectedRange: NSRange(location: selectedRange.location, length: (replacement as NSString).length))
    }

    private func wrapLink(in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let selectedText = nsText.substring(with: selectedRange)
        let urlPlaceholder = "https://example.com"
        let replacement = "[\(selectedText)](\(urlPlaceholder))"

        var edited = text
        replace(range: selectedRange, in: &edited, with: replacement)

        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(
                location: selectedRange.location + 1 + selectedRange.length + 2,
                length: (urlPlaceholder as NSString).length
            )
        )
    }

    private func replace(range: NSRange, in text: inout String, with replacement: String) {
        guard let swiftRange = Range(range, in: text) else {
            return
        }
        text.replaceSubrange(swiftRange, with: replacement)
    }
}
