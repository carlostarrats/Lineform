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
    /// Changes whose dimmed (removed) text the writer clicked to keep.
    private(set) var keptOriginals: Set<Int> = []
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
    var hasDecided: Bool { !decisions.isEmpty }
    var isFinished: Bool { pending.isEmpty }
    var acceptedAny: Bool { decisions.values.contains(.accepted) }

    /// 1-based position of the current change among ALL changes; 0 when none is current.
    var position: (current: Int, total: Int) {
        let index = currentID.flatMap { id in changes.firstIndex { $0.id == id } }
        return (index.map { $0 + 1 } ?? 0, changes.count)
    }

    // MARK: - Decisions

    /// Accepts `id`: the edits to apply, in DESCENDING location order in the current text (one
    /// per changed segment of the change). Empty when it was already decided, or when it is a
    /// kept pure deletion (decided, nothing to write).
    mutating func accept(_ id: Int) -> [AIReviewEdit] {
        guard let index = changes.firstIndex(where: { $0.id == id }), decisions[id] == nil else { return [] }
        decisions[id] = .accepted
        defer { advance(after: id) }
        let edits = changes[index].edits(keepingOriginal: keptOriginals.contains(id))
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

    /// Keep (or stop keeping) a pending change's removed text. A pure insertion has none.
    mutating func toggleKeep(_ id: Int) {
        guard let change = changes.first(where: { $0.id == id }), decisions[id] == nil,
              !change.original.isEmpty else { return }
        if keptOriginals.contains(id) {
            keptOriginals.remove(id)
        } else {
            keptOriginals.insert(id)
        }
    }

    /// Accepts every pending change. The edits are in DESCENDING location order, each in the
    /// coordinates of the document before any of them, so applying them in order is exact.
    mutating func acceptRemaining() -> [AIReviewEdit] {
        var edits: [AIReviewEdit] = []
        var shift = 0
        for index in changes.indices {
            let before = changes[index]
            changes[index].range.location += shift
            let id = changes[index].id
            guard decisions[id] == nil else { continue }
            decisions[id] = .accepted
            // In pre-batch coordinates: the change as it was before this batch shifted it.
            let changeEdits = before.edits(keepingOriginal: keptOriginals.contains(id))
            edits += changeEdits
            let delta = Self.lengthDelta(of: changeEdits)
            shift += delta
            changes[index].range.length += delta
        }
        selectionRange.length += shift
        currentID = nil
        return edits.sorted { $0.range.location > $1.range.location }
    }

    mutating func rejectRemaining() {
        for change in changes where decisions[change.id] == nil {
            decisions[change.id] = .rejected
        }
        currentID = nil
    }

    /// Moves the current change among PENDING changes, wrapping at either end.
    mutating func move(by delta: Int) {
        let ids = pending.map(\.id)
        guard !ids.isEmpty else {
            currentID = nil
            return
        }
        guard let current = currentID, let position = ids.firstIndex(of: current) else {
            currentID = delta >= 0 ? ids.first : ids.last
            return
        }
        let count = ids.count
        currentID = ids[((position + delta) % count + count) % count]
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
