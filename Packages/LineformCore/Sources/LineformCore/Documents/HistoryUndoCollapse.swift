import Foundation

/// The smallest edit that turns `entry` into `exit`: the common UTF-16 prefix and suffix are left
/// out, then the changed span is widened to Character boundaries in BOTH strings, so it
/// never splits a CRLF pair, a surrogate pair, or a combining mark from its base. A leading BOM
/// and any line endings outside the change are therefore never rewritten. `nil` when equal.
public enum HistoryUndoCollapse {
    public static func minimalEdit(from entry: String, to exit: String) -> HistoryEdit? {
        trimmedEdit(from: entry, to: exit, prefixFirst: true)
    }

    /// Like `minimalEdit`, but never GUESSES where the change sits. When inserted or deleted
    /// text repeats next to itself ("Keep this. Keep this." minus one copy), the change has
    /// several valid placements: the prefix-first trim puts it at the last one, the suffix-first
    /// trim at the first. A position that reads correctly under one placement reads a different,
    /// IDENTICAL occurrence under the other — and nothing that compares text can tell. When the
    /// two placements differ this returns their UNION (earliest start to latest end, replacement
    /// built so the result text is the same), so every passage overlapping the ambiguous region
    /// straddles the edit and is dropped. Ordinary typing has one placement and is unchanged.
    public static func unambiguousEdit(from entry: String, to exit: String) -> HistoryEdit? {
        guard let forward = trimmedEdit(from: entry, to: exit, prefixFirst: true),
              let backward = trimmedEdit(from: entry, to: exit, prefixFirst: false) else { return nil }
        guard forward != backward else { return forward }
        let a = entry as NSString
        let b = exit as NSString
        let start = min(forward.range.location, backward.range.location)
        let endA = max(NSMaxRange(forward.range), NSMaxRange(backward.range))
        // Outside [start, endA) the entry is a shared prefix and suffix of both strings.
        let endB = b.length - (a.length - endA)
        return HistoryEdit(
            range: NSRange(location: start, length: endA - start),
            replacement: b.substring(with: NSRange(location: start, length: endB - start))
        )
    }

    private static func trimmedEdit(from entry: String, to exit: String, prefixFirst: Bool) -> HistoryEdit? {
        let a = entry as NSString
        let b = exit as NSString
        guard !a.isEqual(to: exit) else { return nil }
        let shorter = min(a.length, b.length)

        func commonPrefix(limit: Int) -> Int {
            var count = 0
            while count < limit, a.character(at: count) == b.character(at: count) { count += 1 }
            return count
        }
        func commonSuffix(limit: Int) -> Int {
            var count = 0
            while count < limit,
                  a.character(at: a.length - 1 - count) == b.character(at: b.length - 1 - count) {
                count += 1
            }
            return count
        }
        let prefix: Int
        let suffix: Int
        if prefixFirst {
            prefix = commonPrefix(limit: shorter)
            suffix = commonSuffix(limit: shorter - prefix)
        } else {
            suffix = commonSuffix(limit: shorter)
            prefix = commonPrefix(limit: shorter - suffix)
        }

        // Widen until the start and both ends sit on composed-character boundaries. Each pass
        // only moves outward, and the shared prefix/suffix are identical in both strings, so the
        // loop ends.
        var start = prefix
        var endA = a.length - suffix
        var endB = b.length - suffix
        while true {
            let newStart = min(clusterStart(a, at: start), clusterStart(b, at: start))
            let growA = clusterEnd(a, at: endA) - endA
            let growB = clusterEnd(b, at: endB) - endB
            let grow = max(growA, growB)
            if newStart == start, grow == 0 { break }
            start = newStart
            endA += grow
            endB += grow
        }
        return HistoryEdit(
            range: NSRange(location: start, length: endA - start),
            replacement: b.substring(with: NSRange(location: start, length: endB - start))
        )
    }

    /// The start of the Character (extended grapheme cluster) `index` falls inside — `index`
    /// itself on a boundary. Swift's Characters, not NSString's composed sequences: only the
    /// former keep a CRLF pair together.
    private static func clusterStart(_ s: NSString, at index: Int) -> Int {
        guard index > 0, index < s.length else { return index }
        let string = s as String
        let end = string.index(after: String.Index(utf16Offset: index, in: string))
        return string.index(before: end).utf16Offset(in: string)
    }

    /// The end of the Character `index` cuts through — `index` itself on a boundary.
    private static func clusterEnd(_ s: NSString, at index: Int) -> Int {
        guard index > 0, index < s.length else { return index }
        let string = s as String
        let end = string.index(after: String.Index(utf16Offset: index, in: string))
        let start = string.index(before: end).utf16Offset(in: string)
        return start < index ? end.utf16Offset(in: string) : index
    }
}
