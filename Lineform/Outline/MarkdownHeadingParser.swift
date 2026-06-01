import Foundation

enum MarkdownHeadingParser {
    static func heading(in line: String) -> (level: Int, title: String)? {
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
