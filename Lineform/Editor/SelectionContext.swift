import Foundation

struct SelectionContext: Equatable {
    var text: String
    var selectedRange: NSRange

    var selectedText: String {
        substring(in: selectedRange)
    }

    var currentLineText: String {
        substring(in: currentLineRange)
    }

    var currentLineRange: NSRange {
        let nsText = text as NSString
        guard selectedRange.location <= nsText.length else {
            return NSRange(location: nsText.length, length: 0)
        }
        return nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
    }

    private func substring(in range: NSRange) -> String {
        let nsText = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= nsText.length else {
            return ""
        }
        return nsText.substring(with: range)
            .trimmingCharacters(in: .newlines)
    }
}
