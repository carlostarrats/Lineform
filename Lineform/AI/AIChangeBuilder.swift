import Foundation

/// One suggested change, in DOCUMENT UTF-16 coordinates. `range` always sits on
/// composed-character boundaries.
///
/// One AI action is ONE change (spec "AI review: option A"): whatever the writer selected comes
/// back as a single Accept / Reject decision. `range` spans from the first changed prose segment
/// to the last; `original` is that text and `replacement` is the same text with each changed
/// segment rewritten — the document's own text between segments (markers, line endings) kept
/// byte-for-byte.
///
/// `parts` are the changed segments inside it. A decision is APPLIED as one edit per part
/// (`edits`), never as the whole span: the span can cross line endings, and the text view
/// refuses any AI edit that touches one (structure). A part never contains a line terminator.
struct AIChange: Equatable, Identifiable {
    /// One changed segment. `offset` is from `range.location`, in UTF-16 units of `original`.
    struct Part: Equatable {
        let offset: Int
        let length: Int
        let replacement: String
    }

    let id: Int
    var range: NSRange
    let original: String
    let replacement: String
    let parts: [Part]

    /// Without `parts`, the change is one part covering its whole range.
    init(id: Int, range: NSRange, original: String, replacement: String, parts: [Part]? = nil) {
        self.id = id
        self.range = range
        self.original = original
        self.replacement = replacement
        self.parts = parts ?? [Part(offset: 0, length: range.length, replacement: replacement)]
    }

    /// The edits that apply this change at its CURRENT `range`, in DESCENDING location order,
    /// each in the coordinates of the text before any of them — so applying them in order is
    /// exact.
    func edits() -> [AIReviewEdit] {
        parts.reversed().map { part in
            AIReviewEdit(range: NSRange(location: range.location + part.offset, length: part.length),
                         replacement: part.replacement)
        }
    }
}

/// Turns admitted segment revisions into the action's one change.
///
/// A segment is unchanged when its revision is nil (dropped by the guard, or not returned) or
/// canonically equal to its text (`String ==`): an AI that answers in NFC for an NFD document
/// changes nothing the writer can see, and the writer's own bytes are kept. Unchanged segments at
/// either edge are outside the change; one between changed segments is kept verbatim.
enum AIChangeBuilder {
    static func change(segments: [ProseSegment], revisions: [String?], in text: String) -> AIChange? {
        let ns = text as NSString
        var changed: [(range: NSRange, revision: String)] = []
        for (index, segment) in segments.enumerated() where index < revisions.count {
            guard let revision = revisions[index],
                  segment.range.location >= 0, NSMaxRange(segment.range) <= ns.length,
                  // EXACT UTF-16: `==` is canonical equivalence, so a renormalized region would
                  // pass and a change would splice over bytes the AI never saw.
                  ns.substring(with: segment.range).utf16.elementsEqual(segment.text.utf16),
                  revision != segment.text else { continue }
            changed.append((segment.range, revision))
        }
        changed.sort { $0.range.location < $1.range.location }
        // Overlapping segments are never expected; one that overlaps the previous is dropped.
        var disjoint: [(range: NSRange, revision: String)] = []
        for piece in changed where piece.range.location >= (disjoint.last.map { NSMaxRange($0.range) } ?? 0) {
            disjoint.append(piece)
        }
        guard let first = disjoint.first, let last = disjoint.last else { return nil }

        let start = first.range.location
        let span = NSRange(location: start, length: NSMaxRange(last.range) - start)
        let original = ns.substring(with: span)
        let replacement = NSMutableString(string: original)
        for piece in disjoint.reversed() {
            replacement.replaceCharacters(in: NSRange(location: piece.range.location - start, length: piece.range.length),
                                          with: piece.revision)
        }
        let parts = disjoint.map {
            AIChange.Part(offset: $0.range.location - start, length: $0.range.length, replacement: $0.revision)
        }
        return AIChange(id: 0, range: span, original: original, replacement: replacement as String, parts: parts)
    }
}

/// Proofread's corrections (2026-11-14): the provider still returns one revised string per prose
/// segment, and each segment is diffed against it at WORD level, so a paragraph with four fixed
/// words becomes four suggestions rather than one rewritten paragraph.
enum AIWordDiff {
    /// `text` as tokens tiling it, in UTF-16 ranges: a run of word characters (letters, digits,
    /// combining marks — whole `Character`s, so an accented letter or an emoji is never split —
    /// with an apostrophe between two word characters kept inside the word: "don't"), a run of
    /// whitespace, or one other character (punctuation, a symbol, an emoji).
    static func tokens(_ text: String) -> [NSRange] {
        enum Kind { case word, space, other }
        func kind(_ c: Character) -> Kind {
            if c.isLetter || c.isNumber { return .word }
            if c.isWhitespace { return .space }
            return .other
        }
        let characters = Array(text)
        var result: [NSRange] = []
        var location = 0
        var index = 0
        while index < characters.count {
            let start = location
            let k = kind(characters[index])
            location += characters[index].utf16.count
            index += 1
            if k == .other {
                result.append(NSRange(location: start, length: location - start))
                continue
            }
            while index < characters.count {
                let c = characters[index]
                var joins = kind(c) == k
                // An apostrophe between word characters stays in the word.
                if !joins, k == .word, c == "'" || c == "’", index + 1 < characters.count,
                   kind(characters[index + 1]) == .word {
                    joins = true
                }
                guard joins else { break }
                location += c.utf16.count
                index += 1
            }
            result.append(NSRange(location: start, length: location - start))
        }
        return result
    }

    /// Token pairs past which a diff is not attempted: the corrections fall back to one span (the
    /// differing middle after the shared prefix and suffix).
    static let maximumCells = 4_000_000

    /// The corrections turning `original` into `revised`: each maximal run of CONTIGUOUS changed
    /// tokens is one correction — its range in `original` (empty for a pure insertion, at the
    /// insertion point) and the text replacing it — in order. Empty when the two are equal.
    /// Identity is exact UTF-16 per token.
    static func corrections(original: String, revised: String) -> [(range: NSRange, replacement: String)] {
        let a = original as NSString, b = revised as NSString
        let ta = tokens(original), tb = tokens(revised)
        func same(_ i: Int, _ j: Int) -> Bool {
            ta[i].length == tb[j].length && a.substring(with: ta[i]).utf16.elementsEqual(b.substring(with: tb[j]).utf16)
        }
        // Shared prefix and suffix first: most of a proofread segment is unchanged.
        var lo = 0
        while lo < ta.count, lo < tb.count, same(lo, lo) { lo += 1 }
        var hiA = ta.count, hiB = tb.count
        while hiA > lo, hiB > lo, same(hiA - 1, hiB - 1) { hiA -= 1; hiB -= 1 }
        let n = hiA - lo, m = hiB - lo
        guard n > 0 || m > 0 else { return [] }

        // The edit script over the middle: true = kept token (an LCS match).
        var keptA = [Bool](repeating: false, count: n)
        var keptB = [Bool](repeating: false, count: m)
        if n > 0, m > 0, n * m <= maximumCells {
            var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            let width = m + 1
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * width + j] = same(lo + i, lo + j)
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if same(lo + i, lo + j), table[i * width + j] == table[(i + 1) * width + j + 1] + 1 {
                    keptA[i] = true; keptB[j] = true; i += 1; j += 1
                } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        // Walk both sides together; every run between kept tokens is one correction.
        var result: [(range: NSRange, replacement: String)] = []
        var i = 0, j = 0
        func startA(_ i: Int) -> Int { lo + i < ta.count ? ta[lo + i].location : a.length }
        while i < n || j < m {
            if i < n, j < m, keptA[i], keptB[j] {
                i += 1; j += 1
                continue
            }
            let fromA = startA(i)
            var replacement = ""
            while i < n, !keptA[i] { i += 1 }
            while j < m, !keptB[j] { replacement += b.substring(with: tb[lo + j]); j += 1 }
            let toA = startA(i)
            result.append((NSRange(location: fromA, length: toA - fromA), replacement))
        }
        return result
    }

    /// Proofread's changes for `segments` and their admitted revisions: one `AIChange` per
    /// correction, in document coordinates, ids from 0 in document order. A segment whose
    /// revision was refused, or that no longer matches `text`, contributes none.
    static func corrections(segments: [ProseSegment], revisions: [String?], in text: String) -> [AIChange] {
        let ns = text as NSString
        var changes: [AIChange] = []
        for (index, segment) in segments.enumerated() where index < revisions.count {
            guard let revision = revisions[index],
                  segment.range.location >= 0, NSMaxRange(segment.range) <= ns.length,
                  ns.substring(with: segment.range).utf16.elementsEqual(segment.text.utf16) else { continue }
            for correction in corrections(original: segment.text, revised: revision) {
                let range = NSRange(location: segment.range.location + correction.range.location, length: correction.range.length)
                changes.append(AIChange(id: 0, range: range, original: ns.substring(with: range),
                                        replacement: correction.replacement))
            }
        }
        return changes.sorted { $0.range.location < $1.range.location }.enumerated().map { index, change in
            AIChange(id: index, range: change.range, original: change.original, replacement: change.replacement)
        }
    }
}
