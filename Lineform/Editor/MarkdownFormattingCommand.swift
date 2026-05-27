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
        var text = markdown
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    return nil
                }
                return stripLinePrefix(from: line)
            }
            .joined(separator: "\n")

        text = replace(pattern: #"!\[([^\]]*)\]\([^)]+\)"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"(\*\*|__)(.*?)\1"#, in: text, withTemplate: "$2")
        text = replace(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: text, withTemplate: "$1")
        text = replace(pattern: #"(?<!_)_([^_\n]+)_(?!_)"#, in: text, withTemplate: "$1")
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

enum MarkdownFormattingCommand {
    case title
    case section
    case bold
    case italic
    case inlineCode
    case unorderedList
    case link

    func apply(to text: String, selectedRange: NSRange) -> MarkdownEdit {
        switch self {
        case .title:
            return prefixSelection("# ", in: text, selectedRange: selectedRange)
        case .section:
            return prefixSelection("## ", in: text, selectedRange: selectedRange)
        case .bold:
            return toggleMarkers("**", in: text, selectedRange: selectedRange)
        case .italic:
            return toggleMarkers("_", in: text, selectedRange: selectedRange)
        case .inlineCode:
            return toggleMarkers("`", in: text, selectedRange: selectedRange)
        case .unorderedList:
            return prefixSelectedLines("- ", in: text, selectedRange: selectedRange)
        case .link:
            return wrapLink(in: text, selectedRange: selectedRange)
        }
    }

    private func prefixSelection(_ prefix: String, in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let selectedText = nsText.substring(with: selectedRange)
        let replacement = selectedText
            .components(separatedBy: "\n")
            .map { line in
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : prefix + line
            }
            .joined(separator: "\n")

        var edited = text
        replace(range: selectedRange, in: &edited, with: replacement)

        let isRemovingPrefix = selectedText.hasPrefix(prefix)
        let selectionShift = isRemovingPrefix ? -prefix.count : prefix.count
        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(
                location: max(0, selectedRange.location + selectionShift),
                length: selectedRange.length
            )
        )
    }

    private func toggleMarkers(_ marker: String, in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let markerLength = (marker as NSString).length
        let prefixRange = NSRange(location: selectedRange.location - markerLength, length: markerLength)
        let suffixRange = NSRange(location: NSMaxRange(selectedRange), length: markerLength)

        if selectedRange.location >= markerLength,
           NSMaxRange(suffixRange) <= nsText.length,
           nsText.substring(with: prefixRange) == marker,
           nsText.substring(with: suffixRange) == marker {
            var edited = text
            replace(range: suffixRange, in: &edited, with: "")
            replace(range: prefixRange, in: &edited, with: "")
            return MarkdownEdit(
                text: edited,
                selectedRange: NSRange(location: selectedRange.location - markerLength, length: selectedRange.length)
            )
        }

        var edited = text
        replace(range: selectedRange, in: &edited, with: marker + nsText.substring(with: selectedRange) + marker)
        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(location: selectedRange.location + markerLength, length: selectedRange.length)
        )
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
