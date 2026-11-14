import Foundation

/// One edit the editor applies for a decision, in the CURRENT document's UTF-16 coordinates.
struct AIReviewEdit: Equatable {
    let range: NSRange
    let replacement: String
}

enum AIDecision: Equatable {
    case accepted, rejected
}

/// The state of reviewing one AI action's changes (spec §4.1). Pure value logic: nothing here
/// touches the document.
///
/// Decisions are RECORDED here and applied together when the review ends (2026-11-14): every
/// accepted change of one action is then ONE `applyAIEdits` call — one undo step — and one
/// History record. So the document under the review never changes while it is up, and every
/// change's `range` stays in the coordinates of the document the review was built from. A
/// Rewrite-family action has one change (one decision); Proofread has one per correction.
struct AIReviewSession: Equatable {
    let action: AIAction
    let originalSelection: String
    private(set) var changes: [AIChange]
    private(set) var decisions: [Int: AIDecision] = [:]
    private(set) var currentID: Int?
    /// The reviewed selection, in the document the review was built from until the accepted
    /// changes are applied (`shiftSelection`).
    private(set) var selectionRange: NSRange

    init(action: AIAction, changes: [AIChange], selectionRange: NSRange, originalSelection: String) {
        self.action = action
        self.changes = changes.sorted { ($0.range.location, $0.id) < ($1.range.location, $1.id) }
        self.selectionRange = selectionRange
        self.originalSelection = originalSelection
        currentID = self.changes.first?.id
    }

    var pending: [AIChange] { changes.filter { decisions[$0.id] == nil } }
    var accepted: [AIChange] { changes.filter { decisions[$0.id] == .accepted } }
    var isFinished: Bool { pending.isEmpty }
    var acceptedAny: Bool { decisions.values.contains(.accepted) }

    /// "2 of 4": the current change's 1-based position among all of them, and how many there are.
    var position: (index: Int, count: Int)? {
        guard let currentID, let index = changes.firstIndex(where: { $0.id == currentID }) else { return nil }
        return (index + 1, changes.count)
    }

    // MARK: - Decisions

    /// Records `id` as accepted. False when it was already decided (or unknown).
    @discardableResult
    mutating func accept(_ id: Int) -> Bool {
        guard changes.contains(where: { $0.id == id }), decisions[id] == nil else { return false }
        decisions[id] = .accepted
        advance(after: id)
        return true
    }

    mutating func reject(_ id: Int) {
        guard changes.contains(where: { $0.id == id }), decisions[id] == nil else { return }
        decisions[id] = .rejected
        advance(after: id)
    }

    /// Accept All: every change still pending.
    mutating func acceptAllPending() {
        for change in pending { decisions[change.id] = .accepted }
        currentID = nil
    }

    /// ← / →: the previous or next PENDING change, wrapping. No-op with fewer than two pending.
    mutating func move(by delta: Int) {
        let open = pending
        guard open.count > 1, delta != 0 else { return }
        let index = currentID.flatMap { id in open.firstIndex { $0.id == id } } ?? 0
        let next = ((index + delta) % open.count + open.count) % open.count
        currentID = open[next].id
    }

    /// A click on a pending change makes it current.
    mutating func select(_ id: Int) {
        guard decisions[id] == nil, changes.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    // MARK: - Applying

    /// Every accepted change's edits, DESCENDING by location, each in the coordinates of the
    /// document the review was built from — so applying them in order is exact (changes never
    /// overlap).
    var acceptedEdits: [AIReviewEdit] {
        accepted.flatMap { $0.edits() }.sorted { $0.range.location > $1.range.location }
    }

    /// The selection moved by `delta` (what landed when the accepted edits were applied; they all
    /// lie inside it).
    mutating func shiftSelection(by delta: Int) {
        selectionRange.length = max(0, selectionRange.length + delta)
    }

    static func lengthDelta(of edits: [AIReviewEdit]) -> Int {
        edits.reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
    }

    /// `" "` when both sides are non-empty and neither touching character is whitespace.
    static func separator(between original: String, and replacement: String) -> String {
        guard let last = original.last, let first = replacement.first,
              !last.isWhitespace, !first.isWhitespace else { return "" }
        return " "
    }

    // MARK: - Private

    /// After a decision on `id`: the current change stays if it is still pending; otherwise the
    /// next pending change after `id`, wrapping to the first.
    private mutating func advance(after id: Int) {
        if let current = currentID, decisions[current] == nil { return }
        guard let first = pending.first else {
            currentID = nil
            return
        }
        let decidedIndex = changes.firstIndex { $0.id == id } ?? -1
        let next = changes.indices.first { $0 > decidedIndex && decisions[changes[$0].id] == nil }
        currentID = next.map { changes[$0].id } ?? first.id
    }
}
