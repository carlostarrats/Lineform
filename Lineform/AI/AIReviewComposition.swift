import Foundation

/// What the review overlay shows (spec §4.1): the document's text with every PENDING change
/// spliced in — the original (dimmed, unless the writer kept it), then the replacement in normal
/// ink, then one U+FFFC for that change's ✓|✕ pill.
///
/// Decided changes contribute nothing: an accepted one is already in the document, a rejected
/// one is simply the document. Text outside the pending changes is copied verbatim, so everything
/// before the first change is byte-identical to the document and its lines line up with the
/// editor underneath. Pure value logic; the overlay text view draws it.
struct AIReviewComposition: Equatable {
    static let pillCharacter = "\u{FFFC}"

    let string: String
    /// Change id → the dimmed original, in `string` coordinates. Absent for an insertion and for
    /// an original the writer kept.
    let removedRanges: [Int: NSRange]
    /// Change id → the U+FFFC carrying that change's pill, in `string` coordinates.
    let pillIndices: [Int: Int]
    /// Change id → a kept original (shown in normal ink; clicking it again stops keeping it).
    let keptRanges: [Int: NSRange]
    /// Change id → the whole change as drawn: original, replacement and pill.
    let changeRanges: [Int: NSRange]

    static func build(text: String, session: AIReviewSession) -> AIReviewComposition {
        let source = text as NSString
        let result = NSMutableString()
        var removed: [Int: NSRange] = [:]
        var kept: [Int: NSRange] = [:]
        var pills: [Int: Int] = [:]
        var whole: [Int: NSRange] = [:]
        var cursor = 0

        for change in session.pending.sorted(by: { ($0.range.location, $0.id) < ($1.range.location, $1.id) }) {
            let range = change.range
            // A stale or overlapping range (never expected: the session keeps them current) is
            // skipped rather than drawn wrong.
            guard range.location >= cursor, NSMaxRange(range) <= source.length else { continue }
            result.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            let start = result.length
            // The document's own text, never `change.original`: what is dimmed is what is there.
            let original = source.substring(with: range)
            if !original.isEmpty {
                let originalRange = NSRange(location: result.length, length: range.length)
                result.append(original)
                if session.keptOriginals.contains(change.id) {
                    kept[change.id] = originalRange
                    result.append(AIReviewSession.separator(between: original, and: change.replacement))
                } else {
                    removed[change.id] = originalRange
                }
            }
            result.append(change.replacement)
            pills[change.id] = result.length
            result.append(pillCharacter)
            whole[change.id] = NSRange(location: start, length: result.length - start)
            cursor = NSMaxRange(range)
        }
        result.append(source.substring(from: cursor))
        return AIReviewComposition(string: result as String, removedRanges: removed, pillIndices: pills,
                                   keptRanges: kept, changeRanges: whole)
    }

    /// The change whose pill sits at `index`.
    func changeID(atPill index: Int) -> Int? {
        pillIndices.first { $0.value == index }?.key
    }

    /// The change whose dimmed or kept original contains `index`.
    func changeID(atRemovedOrKept index: Int) -> Int? {
        if let id = removedRanges.first(where: { NSLocationInRange(index, $0.value) })?.key { return id }
        return keptRanges.first { NSLocationInRange(index, $0.value) }?.key
    }
}
