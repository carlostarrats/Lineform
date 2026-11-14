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
/// touches the document. The controller applies the edits this returns.
///
/// Every change's `range` is kept in CURRENT document coordinates: an accepted change shifts the
/// changes after it (and grows or shrinks `selectionRange`) by its length delta, so a later
/// decision always aims at the text now on screen. An accepted change's range then covers the
/// text that replaced it.
struct AIReviewSession: Equatable {
    let action: AIAction
    let originalSelection: String
    private(set) var changes: [AIChange]
    private(set) var decisions: [Int: AIDecision] = [:]
    private(set) var currentID: Int?
    private(set) var selectionRange: NSRange

    init(action: AIAction, changes: [AIChange], selectionRange: NSRange, originalSelection: String) {
        self.action = action
        self.changes = changes.sorted { ($0.range.location, $0.id) < ($1.range.location, $1.id) }
        self.selectionRange = selectionRange
        self.originalSelection = originalSelection
        currentID = self.changes.first?.id
    }

    var pending: [AIChange] { changes.filter { decisions[$0.id] == nil } }
    var isFinished: Bool { pending.isEmpty }
    var acceptedAny: Bool { decisions.values.contains(.accepted) }

    // MARK: - Decisions

    /// Accepts `id`: the edits to apply, in DESCENDING location order in the current text (one
    /// per changed segment of the change). Empty when it was already decided.
    mutating func accept(_ id: Int) -> [AIReviewEdit] {
        guard let index = changes.firstIndex(where: { $0.id == id }), decisions[id] == nil else { return [] }
        decisions[id] = .accepted
        defer { advance(after: id) }
        let edits = changes[index].edits()
        let delta = Self.lengthDelta(of: edits)
        for later in changes.indices where later > index {
            changes[later].range.location += delta
        }
        changes[index].range.length += delta
        selectionRange.length += delta
        return edits
    }

    mutating func reject(_ id: Int) {
        guard changes.contains(where: { $0.id == id }), decisions[id] == nil else { return }
        decisions[id] = .rejected
        advance(after: id)
    }

    // MARK: - Private

    private static func lengthDelta(of edits: [AIReviewEdit]) -> Int {
        edits.reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
    }

    /// `" "` when both sides are non-empty and neither touching character is whitespace.
    static func separator(between original: String, and replacement: String) -> String {
        guard let last = original.last, let first = replacement.first,
              !last.isWhitespace, !first.isWhitespace else { return "" }
        return " "
    }

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
