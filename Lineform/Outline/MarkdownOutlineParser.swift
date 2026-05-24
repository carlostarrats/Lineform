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
            } else if !inFence, let heading = heading(in: line) {
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

    private func heading(in line: String) -> (level: Int, title: String)? {
        let nsLine = line as NSString
        var level = 0

        while level < min(nsLine.length, 6), nsLine.substring(with: NSRange(location: level, length: 1)) == "#" {
            level += 1
        }

        guard level > 0, nsLine.length > level else {
            return nil
        }

        guard nsLine.substring(with: NSRange(location: level, length: 1)) == " " else {
            return nil
        }

        let rawTitle = nsLine.substring(from: level + 1)
        let title = rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        guard !title.isEmpty else {
            return nil
        }

        return (level, title)
    }
}
