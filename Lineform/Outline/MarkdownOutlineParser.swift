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
        var inDisplayMath = false

        for (index, line) in source.lines.enumerated() {
            // `.whitespaces`, matching `markdownBlocks` — NOT `markdownLineTrimCharacters`.
            // `markdownSourceLines` has already stripped a CRLF's `\r` and a line-0 BOM, so the
            // wider set only differs on a residual `\r` or a BOM in the MIDDLE of a document
            // (what `cat a.md b.md` produces). There the renderer sees prose and the outline saw a
            // fence: it opened a block early, closed it early, and listed a heading that Read mode
            // draws inside code. The two must agree on what a line IS, not only on the fence rule.
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Display math is consumed by `markdownBlocks` BEFORE it looks for a code fence, so a
            // fence-shaped line inside `$$…$$` is math body to the renderer. Without this state the
            // outline opened a fence on it, never found a closer, and swallowed every heading in
            // the rest of the document.
            if inDisplayMath {
                if MathBlockFence.blockDelimiterOnly(trimmed) { inDisplayMath = false }
                continue
            }

            if let marker = openMarker {
                if MermaidFence.isClosingFence(trimmed, matching: marker) {
                    openMarker = nil
                }
                continue
            }
            if MathBlockFence.singleLineBlock(trimmed) != nil {
                continue
            }
            if MathBlockFence.blockDelimiterOnly(trimmed) {
                inDisplayMath = true
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
