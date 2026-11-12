import Foundation

/// Pure text helpers for passage History. Every NSRange here is a UTF-16 offset into the ORIGINAL
/// text (CRLF and a leading BOM included), never into a stripped copy.
enum PassageHistoryText {
    static let contextLength = 32

    private static let trimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static func isTrimUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return trimSet.contains(scalar)
    }

    /// Snaps to composed-character boundaries, then trims surrounding whitespace and line endings.
    static func aligned(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let length = ns.length
        let location = (range.location == NSNotFound || range.location < 0) ? length : min(range.location, length)
        let end = location + min(max(range.length, 0), length - location)
        guard end > location else { return NSRange(location: location, length: 0) }

        let widened = ns.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: end - location))
        var start = widened.location
        var stop = widened.location + widened.length
        while start < stop, isTrimUnit(ns.character(at: start)) { start += 1 }
        while stop > start, isTrimUnit(ns.character(at: stop - 1)) { stop -= 1 }
        return NSRange(location: start, length: stop - start)
    }

    /// Paragraphs = runs of non-blank lines, as `markdownSourceLines` reports them, trimmed.
    private static func paragraphRanges(in text: String) -> [NSRange] {
        let split = markdownSourceLines(in: text)
        var result: [NSRange] = []
        var runStart: Int?
        var runEnd = 0
        func flush() {
            if let s = runStart {
                result.append(aligned(NSRange(location: s, length: runEnd - s), in: text))
                runStart = nil
            }
        }
        for (line, range) in zip(split.lines, split.ranges) {
            if line.trimmingCharacters(in: markdownLineTrimCharacters).isEmpty {
                flush()
            } else {
                if runStart == nil { runStart = range.location }
                runEnd = range.location + range.length
            }
        }
        flush()
        return result
    }

    static func classify(_ range: NSRange, in text: String) -> HistoryLevel? {
        let r = aligned(range, in: text)
        guard r.length > 0 else { return nil }
        let ns = text as NSString
        let first = r.location
        let last = r.location + r.length - 1

        let paragraphs = paragraphRanges(in: text)
        let startPara = paragraphs.first { NSLocationInRange(first, $0) }
        let endPara = paragraphs.first { NSLocationInRange(last, $0) }
        guard let startPara, let endPara, startPara == endPara else { return .paragraph }
        if r == startPara { return .paragraph }

        let startSentence = ReadingAssistRangeResolver.sentenceRange(in: text, containing: first)
        let endSentence = ReadingAssistRangeResolver.sentenceRange(in: text, containing: last)
        guard startSentence == endSentence else { return .sentence }

        var words = 0
        ns.enumerateSubstrings(in: r, options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        return words <= 3 ? .word : .sentence
    }

    static func context(around range: NSRange, in text: String) -> (before: String, after: String) {
        let ns = text as NSString
        let length = ns.length
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)

        var beforeStart = max(0, location - contextLength)
        if beforeStart > 0, beforeStart < length {
            let seq = ns.rangeOfComposedCharacterSequence(at: beforeStart)
            if seq.location < beforeStart { beforeStart = seq.location + seq.length }
        }
        var afterEnd = min(length, end + contextLength)
        if afterEnd < length, afterEnd > end {
            let seq = ns.rangeOfComposedCharacterSequence(at: afterEnd - 1)
            if seq.location + seq.length > afterEnd { afterEnd = seq.location }
        }
        let before = ns.substring(with: NSRange(location: beforeStart, length: max(0, location - beforeStart)))
        let after = ns.substring(with: NSRange(location: end, length: max(0, afterEnd - end)))
        return (before, after)
    }

    /// Finds `needle` inside `scope`, choosing the occurrence whose surrounding text best matches
    /// `before`/`after` (longest common suffix plus prefix). Returns nil rather than guess: no
    /// occurrence, a best score of 0 (even for a single occurrence), or only occurrences that split
    /// a composed character or start/end mid-word. Ties above 0 resolve to the first.
    static func locate(_ needle: String, before: String, after: String, in text: String, within scope: NSRange) -> NSRange? {
        let ns = text as NSString
        let needleLength = (needle as NSString).length
        guard needleLength > 0 else { return nil }
        let scopeStart = (scope.location == NSNotFound || scope.location < 0) ? ns.length : min(scope.location, ns.length)
        let scopeEnd = scopeStart + min(max(scope.length, 0), ns.length - scopeStart)
        let alnum = CharacterSet.alphanumerics
        func isWordUnit(_ unit: unichar) -> Bool {
            Unicode.Scalar(unit).map { alnum.contains($0) } ?? false
        }
        let needleNS = needle as NSString
        let startsWord = isWordUnit(needleNS.character(at: 0))
        let endsWord = isWordUnit(needleNS.character(at: needleNS.length - 1))

        let beforeNS = before as NSString
        let afterNS = after as NSString

        var candidates: [(range: NSRange, score: Int)] = []
        var cursor = scopeStart
        while cursor < scopeEnd {
            let found = ns.range(of: needle, options: .literal,
                                 range: NSRange(location: cursor, length: scopeEnd - cursor))
            if found.location == NSNotFound { break }
            cursor = found.location + 1
            // A code-unit match can land inside a composed character ("cafe" in "cafe\u{301}",
            // "👍" in "👍🏽") or mid-word ("he" in "the"). Replacing there corrupts text; skip it.
            if ns.rangeOfComposedCharacterSequences(for: found) != found { continue }
            if startsWord, found.location > 0, isWordUnit(ns.character(at: found.location - 1)) { continue }
            if endsWord, found.location + found.length < ns.length,
               isWordUnit(ns.character(at: found.location + found.length)) { continue }

            var suffix = 0
            while suffix < beforeNS.length, found.location - 1 - suffix >= 0,
                  ns.character(at: found.location - 1 - suffix) == beforeNS.character(at: beforeNS.length - 1 - suffix) {
                suffix += 1
            }
            let foundEnd = found.location + found.length
            var prefix = 0
            while prefix < afterNS.length, foundEnd + prefix < ns.length,
                  ns.character(at: foundEnd + prefix) == afterNS.character(at: prefix) {
                prefix += 1
            }
            candidates.append((found, suffix + prefix))
        }

        // Never guess: no context agreement at all means the passage is treated as gone.
        guard let best = candidates.map(\.score).max(), best > 0 else { return nil }
        return candidates.first { $0.score == best }?.range
    }
}
