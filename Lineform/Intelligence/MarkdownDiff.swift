import Foundation

struct MarkdownDiff: Equatable {
    struct Change: Equatable, Identifiable {
        var id: Int {
            lineNumber
        }

        let lineNumber: Int
        let originalLine: String
        let replacementLine: String
        let replacementRange: NSRange

        var accessibilityLabel: String {
            "Changed line \(lineNumber)"
        }
    }

    let changes: [Change]

    var summary: String {
        switch changes.count {
        case 0:
            return "No text changes"
        case 1:
            return "1 changed line"
        default:
            return "\(changes.count) changed lines"
        }
    }

    static func make(original: String, replacement: String) -> MarkdownDiff {
        let originalLines = original.components(separatedBy: .newlines)
        let replacementLines = replacement.components(separatedBy: .newlines)
        let replacementOffsets = lineOffsets(in: replacement)
        let count = max(originalLines.count, replacementLines.count)

        let changes = (0..<count).compactMap { index -> Change? in
            let originalLine = index < originalLines.count ? originalLines[index] : ""
            let replacementLine = index < replacementLines.count ? replacementLines[index] : ""
            guard originalLine != replacementLine else {
                return nil
            }

            let location = index < replacementOffsets.count ? replacementOffsets[index] : (replacement as NSString).length
            return Change(
                lineNumber: index + 1,
                originalLine: originalLine,
                replacementLine: replacementLine,
                replacementRange: NSRange(location: location, length: (replacementLine as NSString).length)
            )
        }

        return MarkdownDiff(changes: changes)
    }

    private static func lineOffsets(in text: String) -> [Int] {
        var offsets = [0]
        let nsText = text as NSString
        var searchLocation = 0

        while searchLocation < nsText.length {
            let range = nsText.range(of: "\n", options: [], range: NSRange(location: searchLocation, length: nsText.length - searchLocation))
            guard range.location != NSNotFound else {
                break
            }
            offsets.append(range.location + range.length)
            searchLocation = range.location + range.length
        }

        return offsets
    }
}
