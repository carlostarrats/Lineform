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
    /// Change id → the change's range in the DOCUMENT the composition was built from.
    let documentRanges: [Int: NSRange]

    static func build(text: String, session: AIReviewSession) -> AIReviewComposition {
        let source = text as NSString
        let result = NSMutableString()
        var removed: [Int: NSRange] = [:]
        var kept: [Int: NSRange] = [:]
        var pills: [Int: Int] = [:]
        var whole: [Int: NSRange] = [:]
        var documentRanges: [Int: NSRange] = [:]
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
            documentRanges[change.id] = range
            cursor = NSMaxRange(range)
        }
        result.append(source.substring(from: cursor))
        return AIReviewComposition(string: result as String, removedRanges: removed, pillIndices: pills,
                                   keptRanges: kept, changeRanges: whole, documentRanges: documentRanges)
    }

    static let empty = AIReviewComposition(string: "", removedRanges: [:], pillIndices: [:], keptRanges: [:],
                                           changeRanges: [:], documentRanges: [:])

    // MARK: - Index mapping (scroll hand-over between the editor and the overlay)

    /// Changes as (overlay range, document range), in order.
    private var orderedChanges: [(overlay: NSRange, document: NSRange)] {
        changeRanges.keys.sorted { changeRanges[$0]!.location < changeRanges[$1]!.location }
            .compactMap { id in documentRanges[id].map { (changeRanges[id]!, $0) } }
    }

    /// The document index shown at overlay index `index`. A change's original maps one to one;
    /// its separator, replacement and pill (text the document does not have) map to the change's
    /// end. Text between changes is shifted by what the changes before it added.
    func documentIndex(forOverlayIndex index: Int) -> Int {
        var shift = 0
        for (overlay, document) in orderedChanges {
            if index < overlay.location { break }
            if index < NSMaxRange(overlay) {
                let offset = index - overlay.location
                return offset < document.length ? document.location + offset : NSMaxRange(document)
            }
            shift = NSMaxRange(overlay) - NSMaxRange(document)
        }
        return index - shift
    }

    /// The overlay index showing document index `index` (the inverse of `documentIndex`).
    func overlayIndex(forDocumentIndex index: Int) -> Int {
        var shift = 0
        for (overlay, document) in orderedChanges {
            if index < document.location { break }
            if index < NSMaxRange(document) { return overlay.location + (index - document.location) }
            shift = NSMaxRange(overlay) - NSMaxRange(document)
        }
        return index + shift
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

/// Builds the review composition only when the session or the editor's text changed — the
/// container's body is re-evaluated far more often than either. A reference type, so a lookup
/// from inside `body` mutates no SwiftUI state.
final class AIReviewCompositionCache {
    private var key: (text: String, session: AIReviewSession)?
    private var value: AIReviewComposition?
    private(set) var buildCount = 0

    func composition(text: String, session: AIReviewSession) -> AIReviewComposition {
        if let key, let value, key.session == session, key.text == text { return value }
        let built = AIReviewComposition.build(text: text, session: session)
        key = (text, session)
        value = built
        buildCount += 1
        return built
    }
}
