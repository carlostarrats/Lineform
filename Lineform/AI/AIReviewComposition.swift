import Foundation

/// What the review overlay shows (spec "AI review: option A"): the document's text with every
/// PENDING change spliced in — the original struck through and dimmed, then the replacement on a
/// highlight. No pill, no U+FFFC: the decision is made on the card, with Return or Esc.
///
/// A change is drawn PART by part (`AIChange.parts`, one per changed prose segment). The text
/// between parts — list markers, line endings — is the document's own and is drawn once, never
/// struck and repeated. Inside a part only the SENTENCES that differ are struck and highlighted:
/// identical leading and trailing sentences are drawn once, as document text. When what differs
/// is a whole line, the replacement starts on a line of its own (the document's own line ending,
/// overlay only); otherwise it follows inline after `AIReviewSession.separator`.
///
/// Decided changes contribute nothing: an accepted one is already in the document, a rejected
/// one is simply the document. Text outside the pending changes is copied verbatim, so everything
/// before the first change is byte-identical to the document and its lines line up with the
/// editor underneath. Pure value logic; the overlay text view draws it.
struct AIReviewComposition: Equatable {
    let string: String
    /// Change id → the struck originals, in `string` coordinates, in order. Absent for a pure
    /// insertion and for an original the writer kept.
    let removedRanges: [Int: [NSRange]]
    /// Change id → the highlighted replacements, in `string` coordinates, in order. Absent for a
    /// pure deletion.
    let replacementRanges: [Int: [NSRange]]
    /// Change id → the whole change as drawn, from its first part to its last.
    let changeRanges: [Int: NSRange]
    /// Change id → the change's range in the DOCUMENT the composition was built from.
    let documentRanges: [Int: NSRange]
    /// Text the overlay shows that the document does not have (separators, line breaks,
    /// replacements), in order: where it sits in `string`, how long it is, and the document index
    /// it stands at. Everything else in `string` is document text, one to one.
    let insertions: [Insertion]

    struct Insertion: Equatable {
        let overlayLocation: Int
        let length: Int
        let documentLocation: Int
    }

    static func build(text: String, session: AIReviewSession) -> AIReviewComposition {
        let source = text as NSString
        let result = NSMutableString()
        var removed: [Int: [NSRange]] = [:]
        var replaced: [Int: [NSRange]] = [:]
        var whole: [Int: NSRange] = [:]
        var documentRanges: [Int: NSRange] = [:]
        var insertions: [Insertion] = []
        var cursor = 0

        func copyDocument(upTo location: Int) {
            guard location > cursor else { return }
            result.append(source.substring(with: NSRange(location: cursor, length: location - cursor)))
            cursor = location
        }
        func insert(_ string: String, isReplacement: Bool, id: Int) {
            let length = (string as NSString).length
            guard length > 0 else { return }
            if isReplacement { replaced[id, default: []].append(NSRange(location: result.length, length: length)) }
            insertions.append(Insertion(overlayLocation: result.length, length: length, documentLocation: cursor))
            result.append(string)
        }

        for change in session.pending.sorted(by: { ($0.range.location, $0.id) < ($1.range.location, $1.id) }) {
            let range = change.range
            // A stale or overlapping range (never expected: the session keeps them current) is
            // skipped rather than drawn wrong.
            guard range.location >= cursor, NSMaxRange(range) <= source.length,
                  change.parts.allSatisfy({ $0.offset >= 0 && $0.length >= 0 && $0.offset + $0.length <= range.length }) else { continue }
            let kept = session.keptOriginals.contains(change.id)
            var start: Int?
            for part in change.parts.sorted(by: { $0.offset < $1.offset }) {
                let partRange = NSRange(location: range.location + part.offset, length: part.length)
                guard partRange.location >= cursor else { continue }
                copyDocument(upTo: partRange.location)
                if start == nil { start = result.length }
                // The document's own text, never `change.original`: what is struck is what is there.
                let original = source.substring(with: partRange)
                if kept {
                    // What a kept accept writes: the whole original, a separator, the replacement.
                    copyDocument(upTo: NSMaxRange(partRange))
                    insert(AIReviewSession.separator(between: original, and: part.replacement), isReplacement: false, id: change.id)
                    insert(part.replacement, isReplacement: true, id: change.id)
                    continue
                }
                let differing = differingSpan(original: original, replacement: part.replacement)
                let removedRange = NSRange(location: partRange.location + differing.original.location, length: differing.original.length)
                let added = (part.replacement as NSString).substring(with: differing.replacement)
                copyDocument(upTo: removedRange.location)
                if removedRange.length > 0 {
                    removed[change.id, default: []].append(NSRange(location: result.length, length: removedRange.length))
                    copyDocument(upTo: NSMaxRange(removedRange))
                }
                let removedText = source.substring(with: removedRange)
                if removedRange.length > 0, !added.isEmpty, isWholeLine(removedRange, in: source) {
                    insert(MarkdownLineEnding.inForce(at: removedRange.location, in: source).text, isReplacement: false, id: change.id)
                } else {
                    insert(AIReviewSession.separator(between: removedText, and: added), isReplacement: false, id: change.id)
                }
                insert(added, isReplacement: true, id: change.id)
                copyDocument(upTo: NSMaxRange(partRange))
            }
            copyDocument(upTo: NSMaxRange(range))
            let first = start ?? result.length
            whole[change.id] = NSRange(location: first, length: result.length - first)
            documentRanges[change.id] = range
        }
        copyDocument(upTo: source.length)
        return AIReviewComposition(string: result as String, removedRanges: removed, replacementRanges: replaced,
                                   changeRanges: whole, documentRanges: documentRanges, insertions: insertions)
    }

    static let empty = AIReviewComposition(string: "", removedRanges: [:], replacementRanges: [:],
                                           changeRanges: [:], documentRanges: [:], insertions: [])

    // MARK: - Sentences that differ

    /// The part of `original` and of `replacement` that differs, in whole SENTENCES: identical
    /// leading and trailing sentences (`NSString.enumerateSubstrings(.bySentences)`, as
    /// `AISentenceSplitter` finds them) are left out, and so is whitespace the two share at
    /// either edge of what remains — so "A. B. C." → "A. Bee. C." strikes "B." alone.
    /// Identity is exact UTF-16: drawn once, the text must be the document's own bytes.
    static func differingSpan(original: String, replacement: String) -> (original: NSRange, replacement: NSRange) {
        let a = original as NSString, b = replacement as NSString
        let tilesA = sentenceTiles(a), tilesB = sentenceTiles(b)
        func same(_ x: NSRange, _ y: NSRange) -> Bool {
            x.length == y.length && a.substring(with: x).utf16.elementsEqual(b.substring(with: y).utf16)
        }
        var lead = 0
        while lead < tilesA.count, lead < tilesB.count, same(tilesA[lead], tilesB[lead]) { lead += 1 }
        var trail = 0
        while trail < tilesA.count - lead, trail < tilesB.count - lead,
              same(tilesA[tilesA.count - 1 - trail], tilesB[tilesB.count - 1 - trail]) { trail += 1 }
        var startA = lead > 0 ? NSMaxRange(tilesA[lead - 1]) : 0
        var startB = lead > 0 ? NSMaxRange(tilesB[lead - 1]) : 0
        var endA = trail > 0 ? tilesA[tilesA.count - trail].location : a.length
        var endB = trail > 0 ? tilesB[tilesB.count - trail].location : b.length
        func isSpace(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.whitespaces.contains(scalar)
        }
        while startA < endA, startB < endB, a.character(at: startA) == b.character(at: startB), isSpace(a.character(at: startA)) {
            startA += 1
            startB += 1
        }
        while endA > startA, endB > startB, a.character(at: endA - 1) == b.character(at: endB - 1), isSpace(a.character(at: endA - 1)) {
            endA -= 1
            endB -= 1
        }
        return (NSRange(location: startA, length: endA - startA), NSRange(location: startB, length: endB - startB))
    }

    /// Sentence ranges that tile `text` from 0 to its end.
    private static func sentenceTiles(_ text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }
        var starts: [Int] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            starts.append(enclosing.location)
        }
        let bounds = Array(Set(starts.filter { $0 > 0 && $0 < text.length } + [0])).sorted() + [text.length]
        return zip(bounds, bounds.dropFirst()).map { NSRange(location: $0, length: $1 - $0) }
    }

    /// Whether `range` is a whole line of `text`: it starts where a line starts and ends where
    /// that line's text ends (before its terminator, or at the end of the document).
    private static func isWholeLine(_ range: NSRange, in text: NSString) -> Bool {
        let newline = unichar(10), carriageReturn = unichar(13)
        let startsLine = range.location == 0 || text.character(at: range.location - 1) == newline
        let end = NSMaxRange(range)
        let endsLine = end == text.length || text.character(at: end) == newline
            || (text.character(at: end) == carriageReturn && end + 1 < text.length && text.character(at: end + 1) == newline)
        return startsLine && endsLine
    }

    // MARK: - Index mapping (scroll hand-over between the editor and the overlay)

    /// The document index shown at overlay index `index`. Document text maps one to one; text
    /// the document does not have (a separator, a line break, a replacement) maps to the document
    /// index it stands at — the end of the struck original before it.
    func documentIndex(forOverlayIndex index: Int) -> Int {
        var shift = 0
        for insertion in insertions {
            if index < insertion.overlayLocation { break }
            if index < insertion.overlayLocation + insertion.length { return insertion.documentLocation }
            shift += insertion.length
        }
        return index - shift
    }

    /// The overlay index showing document index `index` (the inverse of `documentIndex`).
    func overlayIndex(forDocumentIndex index: Int) -> Int {
        var shift = 0
        for insertion in insertions {
            if insertion.documentLocation > index { break }
            shift += insertion.length
        }
        return index + shift
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
