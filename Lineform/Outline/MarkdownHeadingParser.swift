import Foundation

/// The one definition of "this line is an ATX heading" for everything that READS headings —
/// the outline sidebar, Read/Preview, HTML export, read-aloud, and write-mode highlighting.
///
/// It must agree with `MarkdownHeadingEditing.classify`, which decides what the ⌘1–⌘6 commands
/// treat as an existing heading. Where they disagree, the command rewrites a line the reader
/// never saw as a heading — or leaves one the outline cannot see. Both now accept the same
/// shape: up to three columns of leading space, one to six `#`, then a space, a tab, or the end
/// of the line.
enum MarkdownHeadingParser {
    /// CommonMark allows an ATX heading to be indented by up to three spaces; a fourth column
    /// makes it an indented code block, which `MarkdownHeadingEditing.classify` also refuses.
    private static let maximumIndentColumns = 3

    static func heading(in line: String) -> (level: Int, title: String)? {
        let nsLine = line as NSString
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let hash = UInt16(UnicodeScalar("#").value)

        var cursor = 0
        while cursor < nsLine.length, cursor < maximumIndentColumns, nsLine.character(at: cursor) == space {
            cursor += 1
        }

        var level = 0
        while level < 6, cursor + level < nsLine.length, nsLine.character(at: cursor + level) == hash {
            level += 1
        }

        guard level > 0, nsLine.length > cursor + level else {
            return nil
        }

        // A tab counts as a separator in CommonMark, so `#\tTitle` is a heading. Rejecting it
        // made ⌘4 on `##\tSection` emit `#### ##\tSection` — the stacking bug, reached by a
        // different key.
        let separator = nsLine.character(at: cursor + level)
        guard separator == space || separator == tab else {
            return nil
        }

        let rawTitle = nsLine.substring(from: cursor + level + 1)
        let title = rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        guard !title.isEmpty else {
            return nil
        }

        return (level, title)
    }
}
