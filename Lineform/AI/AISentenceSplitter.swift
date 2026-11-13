import Foundation

/// One sentence for Mark, in DOCUMENT UTF-16 coordinates. `prose` is what the model sees: the
/// sentence's prose segments joined with one space, its Markdown structure left out. `range`
/// runs from the sentence's first prose character to its last, so leading markers (`- `, `> `,
/// `- [ ] `) and trailing structure are outside it.
struct AISentence: Equatable {
    let range: NSRange
    let prose: String
}

enum AISentenceSplitter {
    /// The sentences of every non-blank block the selection touches, over each block's FULL
    /// lines inside the selection. Sentences with no prose (a rule, a code fence) are skipped.
    static func sentences(in text: String, selection: NSRange) -> [AISentence] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let clamped = NSIntersectionRange(selection, NSRange(location: 0, length: ns.length))
        guard clamped.length > 0 else { return [] }
        let model = MarkdownStructureMap.SourceModel(ns)
        let first = model.lineIndex(containing: clamped.location)
        let last = model.lineIndex(containing: NSMaxRange(clamped) - 1)

        var result: [AISentence] = []
        var line = first
        while line <= last {
            guard !model.isBlank(line) else {
                line += 1
                continue
            }
            var end = line
            while end + 1 <= last, !model.isBlank(end + 1) { end += 1 }
            let start = model.content[line].location
            let block = NSRange(location: start, length: NSMaxRange(model.content[end]) - start)
            result += sentences(inBlock: block, of: text, ns: ns)
            line = end + 1
        }
        return result
    }

    private static func sentences(inBlock block: NSRange, of text: String, ns: NSString) -> [AISentence] {
        guard block.length > 0 else { return [] }
        // Structure is analysed once per block, so a sentence boundary never cuts a construct.
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: block)
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: block, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        var result: [AISentence] = []
        for range in ranges {
            let trimmed = MarkdownStructureMap.edgeTrimmed(range, in: ns)
            guard trimmed.length > 0 else { continue }
            var pieces: [String] = []
            var proseStart: Int?
            var proseEnd = 0
            for segment in segments {
                let overlap = NSIntersectionRange(segment.range, trimmed)
                guard overlap.length > 0 else { continue }
                let piece = MarkdownStructureMap.edgeTrimmed(ns.rangeOfComposedCharacterSequences(for: overlap), in: ns)
                guard piece.length > 0 else { continue }
                pieces.append(ns.substring(with: piece))
                proseStart = proseStart ?? piece.location
                proseEnd = NSMaxRange(piece)
            }
            guard let proseStart, !pieces.isEmpty else { continue }
            // The range a mark covers runs from the first prose to the last: a list, quote or
            // task marker before the sentence is structure and is never marked.
            result.append(AISentence(range: NSRange(location: proseStart, length: proseEnd - proseStart),
                                     prose: pieces.joined(separator: " ")))
        }
        return result
    }
}
