import Foundation

struct MarkdownOutlineItem: Equatable, Identifiable {
    var id: String { "\(lineNumber)-\(title)" }
    var level: Int
    var title: String
    var lineNumber: Int
    var characterRange: NSRange
}

struct MarkdownOutlineParser {
    func items(in text: String) -> [MarkdownOutlineItem] {
        var items: [MarkdownOutlineItem] = []
        var inFence = false
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var lineNumber = 0

        nsText.enumerateSubstrings(in: fullRange, options: [.byLines]) { substring, substringRange, _, _ in
            lineNumber += 1
            let line = substring ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence, let heading = MarkdownHeadingParser.heading(in: line) {
                items.append(MarkdownOutlineItem(
                    level: heading.level,
                    title: heading.title,
                    lineNumber: lineNumber,
                    characterRange: substringRange
                ))
            }
        }

        return items
    }
}
