import Foundation

struct MarkdownOutlineItem: Equatable, Identifiable {
    var id: String { "\(lineNumber)-\(title)" }
    var level: Int
    var title: String
    var lineNumber: Int
    var characterRange: NSRange
}

struct MarkdownOutlineParser {
    /// Headings the renderer treats as prose, in document order.
    ///
    /// Fence state is tracked with `MermaidFence`, the same CommonMark matching
    /// `markdownBlocks(in:)` uses — same delimiter character, a closing run at least as long as the
    /// opener's, nothing but whitespace after it. This is a second definition of "inside fenced
    /// code" only in the sense that it is a second *caller*; the rule itself is shared, which is
    /// the point.
    ///
    /// It used to toggle a flag on any line starting with ` ``` ` or `~~~`, and that disagreed with
    /// the renderer on documents that are entirely ordinary — any note *about* Markdown, where a
    /// longer fence wraps a shorter one, or a ``` block quotes a `~~~` line. The toggle closed on
    /// the inner delimiter, so the rest of the block's `#` lines were listed as headings that do
    /// not exist, and every real heading after it was swallowed as "code" and vanished from the
    /// sidebar. Guarded by `OutlineAndInsertionProbeTests`, which asserts the agreement in both
    /// directions.
    ///
    /// Lines come from `markdownSourceLines(in:)` — the one splitter every renderer uses — so a
    /// CRLF file's fences close here exactly as they do on screen. `characterRange` still excludes
    /// the `\r` (it spans the line's own text, as the scroll restore expects).
    func items(in text: String) -> [MarkdownOutlineItem] {
        var items: [MarkdownOutlineItem] = []
        let source = markdownSourceLines(in: text)
        var openMarker: (character: Character, length: Int)?

        for (index, line) in source.lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: markdownLineTrimCharacters)

            if let marker = openMarker {
                if MermaidFence.isClosingFence(trimmed, matching: marker) {
                    openMarker = nil
                }
                continue
            }
            if let marker = MermaidFence.openingMarker(trimmed) {
                openMarker = marker
                continue
            }

            guard let heading = MarkdownHeadingParser.heading(in: line) else {
                continue
            }
            items.append(MarkdownOutlineItem(
                level: heading.level,
                title: heading.title,
                lineNumber: index + 1,
                characterRange: NSRange(
                    location: source.ranges[index].location,
                    length: (line as NSString).length
                )
            ))
        }

        return items
    }
}
