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
/// Decisions are applied only when the review ends (`AIReviewSession`), so an ACCEPTED change is
/// drawn as its replacement in place of the document's text, plain; a rejected one is simply the
/// document. Text outside the changes is copied verbatim, so everything before the first change is
/// byte-identical to the document and its lines line up with the editor underneath.
///
/// Proofread (2026-11-14) draws every correction IN PLACE: the original word(s) struck, the fix
/// right after on the same line — never on a line of its own. A Rewrite-family change is drawn at
/// the smallest unit that changed: when the original and the replacement have the same number of
/// sentences and some are unchanged, each changed sentence is struck with its replacement inline
/// right after it; a whole replaced or restructured (merged / split) span keeps the whole-span
/// display, a whole line stacked on a line of its own. Pure value logic; the overlay draws it.
struct AIReviewComposition: Equatable {
    let string: String
    /// Change id → the struck originals, in `string` coordinates, in order. Absent for a pure
    /// insertion.
    let removedRanges: [Int: [NSRange]]
    /// Change id → the highlighted replacements, in `string` coordinates, in order. Absent for a
    /// pure deletion.
    let replacementRanges: [Int: [NSRange]]
    /// Change id → an ACCEPTED (not yet applied) change's replacement as drawn, plain.
    var acceptedRanges: [Int: [NSRange]] = [:]
    /// Change id → the whole change as drawn, from its first part to its last.
    let changeRanges: [Int: NSRange]
    /// Change id → the change's range in the DOCUMENT the composition was built from.
    let documentRanges: [Int: NSRange]
    /// Text the overlay shows that the document does not have (separators, line breaks,
    /// replacements), in order: where it sits in `string`, how long it is, the document index it
    /// stands at, and how much document text it stands IN PLACE of (an accepted change hides its
    /// original; 0 otherwise). Everything else in `string` is document text, one to one.
    let insertions: [Insertion]

    struct Insertion: Equatable {
        let overlayLocation: Int
        let length: Int
        let documentLocation: Int
        var documentLength: Int = 0
    }

    static func build(text: String, session: AIReviewSession) -> AIReviewComposition {
        let source = text as NSString
        let result = NSMutableString()
        var removed: [Int: [NSRange]] = [:]
        var replaced: [Int: [NSRange]] = [:]
        var acceptedDrawn: [Int: [NSRange]] = [:]
        var whole: [Int: NSRange] = [:]
        var documentRanges: [Int: NSRange] = [:]
        var insertions: [Insertion] = []
        var cursor = 0
        let inline = session.action.reviewsPerCorrection

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
        /// The struck original at `removedRange` (document coordinates), then the replacement.
        func strike(_ removedRange: NSRange, with added: String, id: Int, stacksWholeLine: Bool) {
            copyDocument(upTo: removedRange.location)
            if removedRange.length > 0 {
                removed[id, default: []].append(NSRange(location: result.length, length: removedRange.length))
                copyDocument(upTo: NSMaxRange(removedRange))
            }
            let removedText = source.substring(with: removedRange)
            if stacksWholeLine, removedRange.length > 0, !added.isEmpty, let marker = wholeLineMarker(removedRange, in: source) {
                // The item's own marker repeats, so the replacement reads as the same item.
                insert(MarkdownLineEnding.inForce(at: removedRange.location, in: source).text + marker,
                       isReplacement: false, id: id)
            } else {
                insert(AIReviewSession.separator(between: removedText, and: added), isReplacement: false, id: id)
            }
            insert(added, isReplacement: true, id: id)
        }

        let shown = session.changes.filter { session.decisions[$0.id] != .rejected }
        for change in shown.sorted(by: { ($0.range.location, $0.id) < ($1.range.location, $1.id) }) {
            let range = change.range
            // A stale or overlapping range (never expected: the session keeps them current) is
            // skipped rather than drawn wrong.
            guard range.location >= cursor, NSMaxRange(range) <= source.length,
                  change.parts.allSatisfy({ $0.offset >= 0 && $0.length >= 0 && $0.offset + $0.length <= range.length }) else { continue }
            let isAccepted = session.decisions[change.id] == .accepted
            var start: Int?
            let sortedParts = change.parts.sorted(by: { $0.offset < $1.offset })
            // A line whose prose is split by links, code spans or other inline structure into
            // several CHANGED segments is shown whole: struck, then its whole new text stacked on a
            // line of its own (2026-11-14 — interleaved pieces around a link were unreadable).
            let stackedLines: [NSRange: [AIChange.Part]] = inline || isAccepted ? [:] : {
                var byLine: [NSRange: [AIChange.Part]] = [:]
                for part in sortedParts {
                    guard let line = lineContent(at: range.location + part.offset, in: source) else { continue }
                    byLine[line.content, default: []].append(part)
                }
                return byLine.filter { $0.value.count > 1 }
            }()
            var drawnLines = Set<NSRange>()
            for part in sortedParts {
                let partRange = NSRange(location: range.location + part.offset, length: part.length)
                guard partRange.location >= cursor else { continue }
                if let entry = stackedLines.first(where: { NSLocationInRange(partRange.location, $0.key) || $0.key.location == partRange.location }) {
                    let content = entry.key
                    guard !drawnLines.contains(content) else { continue }
                    drawnLines.insert(content)
                    guard content.location >= cursor else { continue }
                    copyDocument(upTo: content.location)
                    if start == nil { start = result.length }
                    // The line's new text: its own text with every changed segment replaced.
                    let newLine = NSMutableString(string: source.substring(with: content))
                    for linePart in entry.value.sorted(by: { $0.offset > $1.offset }) {
                        let local = NSRange(location: range.location + linePart.offset - content.location, length: linePart.length)
                        newLine.replaceCharacters(in: local, with: linePart.replacement)
                    }
                    removed[change.id, default: []].append(NSRange(location: result.length, length: content.length))
                    copyDocument(upTo: NSMaxRange(content))
                    let marker = lineContent(at: content.location, in: source)?.marker ?? ""
                    insert(MarkdownLineEnding.inForce(at: content.location, in: source).text + marker, isReplacement: false, id: change.id)
                    insert(newLine as String, isReplacement: true, id: change.id)
                    continue
                }
                copyDocument(upTo: partRange.location)
                if start == nil { start = result.length }
                if isAccepted {
                    // Accepted, not yet applied: the replacement stands in place of the original.
                    let length = (part.replacement as NSString).length
                    if length > 0 {
                        acceptedDrawn[change.id, default: []].append(NSRange(location: result.length, length: length))
                    }
                    insertions.append(Insertion(overlayLocation: result.length, length: length,
                                                documentLocation: cursor, documentLength: partRange.length))
                    result.append(part.replacement)
                    cursor = NSMaxRange(partRange)
                    continue
                }
                // The document's own text, never `change.original`: what is struck is what is there.
                let original = source.substring(with: partRange)
                if inline {
                    strike(partRange, with: part.replacement, id: change.id, stacksWholeLine: false)
                } else if let pairs = changedSentencePairs(original: original, replacement: part.replacement) {
                    for pair in pairs {
                        strike(NSRange(location: partRange.location + pair.original.location, length: pair.original.length),
                               with: (part.replacement as NSString).substring(with: pair.replacement),
                               id: change.id, stacksWholeLine: false)
                    }
                } else {
                    let differing = differingSpan(original: original, replacement: part.replacement)
                    strike(NSRange(location: partRange.location + differing.original.location, length: differing.original.length),
                           with: (part.replacement as NSString).substring(with: differing.replacement),
                           id: change.id, stacksWholeLine: true)
                }
                copyDocument(upTo: NSMaxRange(partRange))
            }
            copyDocument(upTo: NSMaxRange(range))
            let first = start ?? result.length
            if !isAccepted {
                whole[change.id] = NSRange(location: first, length: result.length - first)
            }
            documentRanges[change.id] = range
        }
        copyDocument(upTo: source.length)
        var composition = AIReviewComposition(string: result as String, removedRanges: removed, replacementRanges: replaced,
                                              changeRanges: whole, documentRanges: documentRanges, insertions: insertions)
        composition.acceptedRanges = acceptedDrawn
        return composition
    }

    /// The changed sentences of a part, paired, when it can be shown sentence by sentence: the
    /// original and the replacement tile into the SAME number of sentences and at least one is
    /// unchanged. Each pair is the differing span of one changed sentence (shared edge whitespace
    /// left out), in `original` and `replacement` coordinates. Nil when every sentence changed (a
    /// whole replacement) or the counts differ (sentences merged or split — pairing them could
    /// strike one sentence against another's replacement).
    static func changedSentencePairs(original: String, replacement: String) -> [(original: NSRange, replacement: NSRange)]? {
        let a = original as NSString, b = replacement as NSString
        let tilesA = sentenceTiles(a), tilesB = sentenceTiles(b)
        guard tilesA.count == tilesB.count, tilesA.count > 1 else { return nil }
        var pairs: [(original: NSRange, replacement: NSRange)] = []
        for (x, y) in zip(tilesA, tilesB) {
            let sa = a.substring(with: x), sb = b.substring(with: y)
            if sa.utf16.elementsEqual(sb.utf16) { continue }
            let span = differingSpan(original: sa, replacement: sb)
            pairs.append((NSRange(location: x.location + span.original.location, length: span.original.length),
                          NSRange(location: y.location + span.replacement.location, length: span.replacement.length)))
        }
        guard !pairs.isEmpty, pairs.count < tilesA.count else { return nil }
        return pairs
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

    /// The prose of the line holding `location`: from just after its Markdown marker prefix (and a
    /// leading BOM on the first line) to where its text ends, before the terminator; and that
    /// prefix. Lines split on "\n" only (CLAUDE.md: never `getLineStart`).
    static func lineContent(at location: Int, in text: NSString) -> (content: NSRange, marker: String)? {
        guard location >= 0, location <= text.length else { return nil }
        let newline = unichar(10), carriageReturn = unichar(13)
        var lineStart = location
        while lineStart > 0, text.character(at: lineStart - 1) != newline { lineStart -= 1 }
        var lineEnd = location
        while lineEnd < text.length, text.character(at: lineEnd) != newline { lineEnd += 1 }
        if lineEnd > lineStart, text.character(at: lineEnd - 1) == carriageReturn { lineEnd -= 1 }
        if lineStart == 0, text.length > 0, text.character(at: 0) == 0xFEFF { lineStart = 1 }
        guard lineEnd >= lineStart else { return nil }
        let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        let markerLength = markerPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length ?? 0
        let marker = (line as NSString).substring(to: markerLength)
        return (NSRange(location: lineStart + markerLength, length: lineEnd - lineStart - markerLength), marker)
    }

    /// When `range` is ALL of a line's prose — from the line start (past a leading BOM on the
    /// document's first line), or from just after the line's
    /// Markdown marker prefix (`- `, `1. `, `> `, `- [ ] `, nested `> - `, with indentation), to
    /// where the line's text ends (before its terminator, or at the end of the document) — that
    /// prefix ("" for a plain line). Nil when the range is only part of the line.
    static func wholeLineMarker(_ range: NSRange, in text: NSString) -> String? {
        let newline = unichar(10), carriageReturn = unichar(13)
        let end = NSMaxRange(range)
        let endsLine = end == text.length || text.character(at: end) == newline
            || (text.character(at: end) == carriageReturn && end + 1 < text.length && text.character(at: end + 1) == newline)
        guard endsLine else { return nil }
        var lineStart = range.location
        while lineStart > 0, text.character(at: lineStart - 1) != newline { lineStart -= 1 }
        // A leading BOM belongs to the file, not to the first line's marker: skipped for matching
        // and never copied into the repeated marker (`markdownSourceLines` skips it the same way).
        if lineStart == 0, text.length > 0, text.character(at: 0) == 0xFEFF, range.location > 0 { lineStart = 1 }
        let prefix = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let whole = NSRange(location: 0, length: (prefix as NSString).length)
        guard markerPrefix.firstMatch(in: prefix, range: whole)?.range == whole else { return nil }
        return prefix
    }

    /// Zero or more list (`-`, `*`, `+`, 1–9 digits with `.` or `)`, optional task box) or quote
    /// markers, each optionally indented. Digits are capped at nine, as `MarkdownBlockGrouping`.
    private static let markerPrefix = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*(?:(?:[-*+]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?|>[ \t]?))*"#)

    /// The pending change drawn at overlay index `index`, if any (a click makes it current).
    func changeID(at index: Int) -> Int? {
        changeRanges.first { NSLocationInRange(index, $0.value) }?.key
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
            shift += insertion.length - insertion.documentLength
        }
        return index - shift
    }

    /// The overlay index showing document index `index` (the inverse of `documentIndex`).
    func overlayIndex(forDocumentIndex index: Int) -> Int {
        var shift = 0
        for insertion in insertions {
            if insertion.documentLocation > index { break }
            if index < insertion.documentLocation + insertion.documentLength { return insertion.overlayLocation }
            shift += insertion.length - insertion.documentLength
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
