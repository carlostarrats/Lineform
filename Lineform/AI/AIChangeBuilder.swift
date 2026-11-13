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
    /// exact. `keepingOriginal` writes each part's original, a separator, then its replacement;
    /// a kept part with an empty replacement writes nothing (no edit).
    func edits(keepingOriginal: Bool = false) -> [AIReviewEdit] {
        let originalNS = original as NSString
        return parts.reversed().compactMap { part in
            let range = NSRange(location: range.location + part.offset, length: part.length)
            guard keepingOriginal else { return AIReviewEdit(range: range, replacement: part.replacement) }
            guard !part.replacement.isEmpty else { return nil }
            let kept = originalNS.substring(with: NSRange(location: part.offset, length: part.length))
            return AIReviewEdit(range: range, replacement: kept
                + AIReviewSession.separator(between: kept, and: part.replacement) + part.replacement)
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
