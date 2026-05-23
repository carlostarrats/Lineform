import Foundation

struct MarkdownEdit: Equatable {
    var text: String
    var selectedRange: NSRange
}

enum MarkdownFormattingCommand {
    case bold
    case italic
    case inlineCode
    case unorderedList

    func apply(to text: String, selectedRange: NSRange) -> MarkdownEdit {
        switch self {
        case .bold:
            return toggleMarkers("**", in: text, selectedRange: selectedRange)
        case .italic:
            return toggleMarkers("_", in: text, selectedRange: selectedRange)
        case .inlineCode:
            return toggleMarkers("`", in: text, selectedRange: selectedRange)
        case .unorderedList:
            return prefixSelectedLines("- ", in: text, selectedRange: selectedRange)
        }
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

    private func replace(range: NSRange, in text: inout String, with replacement: String) {
        guard let swiftRange = Range(range, in: text) else {
            return
        }
        text.replaceSubrange(swiftRange, with: replacement)
    }
}
