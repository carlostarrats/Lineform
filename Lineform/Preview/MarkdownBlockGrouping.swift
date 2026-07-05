import Foundation

/// A structural grouping of the document's lines, produced in a single pass so the preview
/// renderer can render block-by-block instead of re-deriving block boundaries inline. This is the
/// seam new block constructs (horizontal rule, blockquote, list, table) hang off — each becomes a
/// new case here plus a matching emitter in `MarkdownPreviewRenderer`.
///
/// The existing constructs are preserved **exactly**: `.lines` runs are rendered by the renderer's
/// unchanged per-line logic (heading / inline-with-math / fenced-code), and mermaid / display-math
/// blocks carry only what the renderer needs to reproduce its current output (the inner source and
/// the closing line index, `nil` when the block was never closed and is flushed at end-of-document).
enum MarkdownBlock: Equatable {
    /// A maximal run of ordinary lines (body, headings, and fenced code), rendered per line exactly
    /// as before. The range is over the original line indices so block-spacing lookups and the
    /// "newline after every line except the last" rule are reproduced unchanged.
    case lines(Range<Int>)
    /// A whole-line display block `$$…$$`, rendered as one centered equation at `lineIndex`.
    case singleLineMath(latex: String, lineIndex: Int)
    /// A fenced display-math block delimited by lines that are exactly `$$`. `closingIndex` is the
    /// index of the closing `$$` line, or `nil` when the block ran to end-of-document unclosed.
    case fencedMath(latex: String, closingIndex: Int?)
    /// A ```mermaid fenced block. `closingIndex` is the index of the closing fence, or `nil` when it
    /// ran to end-of-document unclosed.
    case mermaid(source: String, closingIndex: Int?)
}

/// Group already-split lines into blocks. Mirrors the detection order and fence-state tracking of
/// the original renderer loop (single-line `$$…$$`, then a `$$` fence, then a ```mermaid fence,
/// each only when **not** inside a regular code fence; regular ``` / ~~~ fences toggle the fence
/// state and stay within a `.lines` run). Pure — no AppKit, no rendering.
func markdownBlocks(in lines: [String]) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var inFence = false
    var linesStart: Int?
    var index = 0

    func flushLines(upTo end: Int) {
        if let start = linesStart, start < end {
            blocks.append(.lines(start..<end))
        }
        linesStart = nil
    }

    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

        if !inFence, let inner = MathBlockFence.singleLineBlock(trimmed) {
            flushLines(upTo: index)
            blocks.append(.singleLineMath(latex: inner, lineIndex: index))
            index += 1
            continue
        }

        if !inFence, MathBlockFence.blockDelimiterOnly(trimmed) {
            flushLines(upTo: index)
            var body: [String] = []
            var cursor = index + 1
            var closing: Int?
            while cursor < lines.count {
                if MathBlockFence.blockDelimiterOnly(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    closing = cursor
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            blocks.append(.fencedMath(latex: body.joined(separator: "\n"), closingIndex: closing))
            index = (closing ?? lines.count - 1) + 1
            continue
        }

        if !inFence, MermaidFence.isMermaidOpening(trimmed) {
            flushLines(upTo: index)
            var body: [String] = []
            var cursor = index + 1
            var closing: Int?
            while cursor < lines.count {
                if MermaidFence.isFenceDelimiter(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    closing = cursor
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            blocks.append(.mermaid(source: body.joined(separator: "\n"), closingIndex: closing))
            index = (closing ?? lines.count - 1) + 1
            continue
        }

        // A regular code fence stays inside the current `.lines` run; track the state so the
        // special blocks above are correctly ignored while inside it.
        if MermaidFence.isFenceDelimiter(trimmed) {
            inFence.toggle()
        }
        if linesStart == nil {
            linesStart = index
        }
        index += 1
    }

    flushLines(upTo: lines.count)
    return blocks
}
