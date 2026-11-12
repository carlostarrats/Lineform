import Foundation

/// A passage found in the live text by `DocumentHistoryEngine.locateAll(in:)`. `range` is a UTF-16
/// range into the text that call was given, and is only valid for that exact text.
struct LocatedPassage: Equatable {
    let id: UUID
    let level: HistoryLevel
    let range: NSRange
    let rootID: UUID
}

/// One replacement the editor applies to show another version. `range` is the passage's live range
/// in the text the engine was handed. The caller applies it verbatim and does not report it back
/// through `applyEdit`.
struct HistoryEdit: Equatable {
    let range: NSRange
    let replacement: String
}

/// Pure History logic over plain strings: no UI, no AppKit, no persistence.
///
/// The current version of every passage IS the live text (spec §5.0). During a session the engine
/// tracks where each located passage sits through `liveRanges`, moved by `applyEdit` as the writer
/// types; it never re-finds a passage by resemblance. A passage an edit cannot be mapped through
/// (it straddles the passage's edge or deletes it) is dropped together with its descendants
/// (spec §5.1 rule 2) — history quietly disappears rather than replacing the wrong text.
///
/// Caller contract:
/// - Report EVERY user text change through `applyEdit(_:replacementLength:)`, in the coordinates of
///   the text before that change. That includes the replacement made when an AI rewrite is
///   accepted (before `recordAccepted`).
/// - Do NOT call `applyEdit` for a `HistoryEdit` the engine itself returned from `step`, `select`
///   or `deleteVersion`: the engine has already moved its live ranges for it. Apply it verbatim.
/// - Never call `locateAll` per keystroke. `applyEdit` is the per-keystroke path: O(passages),
///   and it never reads the text.
///
/// Without live ranges (the first locate after loading stored history) a passage is found only by
/// a LITERAL match of its stored current text plus context; anything else drops it.
struct DocumentHistoryEngine {
    var history: DocumentHistory
    let now: () -> Date

    /// Where each located, visible passage sits in the live text (UTF-16).
    private(set) var liveRanges: [UUID: NSRange] = [:]

    /// The UTF-16 length the live ranges were last synced against, moved by every edit. A text of
    /// any other length means a change was not reported, so the live ranges are discarded and every
    /// passage falls back to the literal search.
    private var syncedLength: Int?

    init(history: DocumentHistory, now: @escaping () -> Date) {
        self.history = history
        self.now = now
    }

    // MARK: - Live ranges

    /// Maps one user text change through every live range. `edited` is the range replaced, in the
    /// text before the change; `replacementLength` is the UTF-16 length inserted. O(passages).
    mutating func applyEdit(_ edited: NSRange, replacementLength: Int) {
        var lost = Set<UUID>()
        for (id, range) in liveRanges {
            if let moved = Self.map(range, through: edited, replacementLength: replacementLength) {
                liveRanges[id] = moved
            } else {
                lost.insert(id)
            }
        }
        removeWithDescendants(lost)
        if let length = syncedLength { syncedLength = length + replacementLength - edited.length }
    }

    /// Before (an insertion AT the start counts as before) shifts; after (an insertion AT the end
    /// counts as after) is unchanged; inside resizes; anything that straddles an edge or leaves the
    /// passage empty is nil.
    static func map(_ passage: NSRange, through edited: NSRange, replacementLength: Int) -> NSRange? {
        let delta = replacementLength - edited.length
        if edited.location + edited.length <= passage.location {
            return NSRange(location: passage.location + delta, length: passage.length)
        }
        if edited.location >= passage.location + passage.length { return passage }
        guard edited.location >= passage.location,
              edited.location + edited.length <= passage.location + passage.length,
              passage.length + delta > 0 else { return nil }
        return NSRange(location: passage.location, length: passage.length + delta)
    }

    /// Keeps live ranges consistent with an edit the engine produced for passage `id`: the passage
    /// takes the replacement's range, its descendants are hidden (re-found literally if their
    /// version is shown again), and every other passage moves by the ordinary rules.
    private mutating func didProduce(_ edit: HistoryEdit, for id: UUID) {
        let replacementLength = (edit.replacement as NSString).length
        let hidden = descendants(of: id)
        for child in hidden { liveRanges[child] = nil }
        var lost = Set<UUID>()
        for (other, range) in liveRanges where other != id {
            if let moved = Self.map(range, through: edit.range, replacementLength: replacementLength) {
                liveRanges[other] = moved
            } else {
                lost.insert(other)
            }
        }
        liveRanges[id] = NSRange(location: edit.range.location, length: replacementLength)
        removeWithDescendants(lost)
        if let length = syncedLength { syncedLength = length + replacementLength - edit.range.length }
    }

    // MARK: - Locating

    mutating func locateAll(in text: String) -> [LocatedPassage] {
        let ns = text as NSString
        if syncedLength != ns.length { liveRanges.removeAll() }
        dropUnreachable()

        var located: [LocatedPassage] = []
        var lost: [UUID] = []
        var found: [UUID: NSRange] = [:]
        // Breadth-first from the roots; children are searched only inside a located parent whose
        // CURRENT version is the one they were made in.
        var queue: [(id: UUID, scope: NSRange, rootID: UUID?)] =
            history.passages.filter { $0.parentID == nil }.map { ($0.id, NSRange(location: 0, length: ns.length), nil) }
        var head = 0
        while head < queue.count {
            let (id, scope, rootID) = queue[head]
            head += 1
            guard let index = history.passages.firstIndex(where: { $0.id == id }) else { continue }
            let passage = history.passages[index]
            guard let range = find(passage, in: text, within: scope) else {
                lost.append(id)
                continue
            }
            found[id] = range
            let context = PassageHistoryText.context(around: range, in: text)
            history.passages[index].versions[passage.currentIndex].text = ns.substring(with: range)
            history.passages[index].contextBefore = context.before
            history.passages[index].contextAfter = context.after
            let root = rootID ?? id
            located.append(LocatedPassage(id: id, level: passage.level, range: range, rootID: root))
            for child in history.passages where child.parentID == id && child.parentVersionIndex == passage.currentIndex {
                queue.append((child.id, range, root))
            }
        }
        liveRanges = found
        syncedLength = ns.length
        removeWithDescendants(Set(lost))
        return located.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
    }

    /// The live range when there is one (it must still lie inside `scope`); otherwise a LITERAL
    /// match of the stored current text, scored by context. Never a resemblance search.
    private func find(_ passage: HistoryPassage, in text: String, within scope: NSRange) -> NSRange? {
        if let live = liveRanges[passage.id] {
            guard live.length > 0, live.location >= scope.location,
                  live.location + live.length <= scope.location + scope.length else { return nil }
            return live
        }
        return PassageHistoryText.locate(passage.versions[passage.currentIndex].text,
                                         before: passage.contextBefore, after: passage.contextAfter,
                                         in: text, within: scope)
    }

    // MARK: - Adding

    func canAdd(_ range: NSRange, in text: String) -> Bool {
        var copy = self
        return copy.placement(for: range, in: text) != nil
    }

    /// Where an added range goes: an existing passage with the same range, or a new passage of
    /// `level` under `parent`. Nil when it is not allowed.
    private enum Placement {
        case existing(UUID)
        case new(level: HistoryLevel, range: NSRange, parent: LocatedPassage?, contained: [LocatedPassage])
    }

    private mutating func placement(for range: NSRange, in text: String) -> Placement? {
        guard let level = PassageHistoryText.classify(range, in: text) else { return nil }
        let r = PassageHistoryText.aligned(range, in: text)
        let located = locateAll(in: text)
        if let same = located.first(where: { $0.range == r }) { return .existing(same.id) }

        let parent = located.filter { NSIntersectionRange($0.range, r) == r }.last  // sorted outer → inner
        if let parent, !(parent.level < level) { return nil }  // nothing nests inside a word
        var contained: [LocatedPassage] = []
        for passage in located where passage.id != parent?.id {
            let overlap = NSIntersectionRange(passage.range, r)
            if overlap.length == 0 { continue }
            if NSIntersectionRange(passage.range, r) == r { continue }  // an outer ancestor of the parent
            guard overlap == passage.range, level < passage.level else { return nil }  // partial overlap or not smaller
            contained.append(passage)
        }
        return .new(level: level, range: r, parent: parent, contained: contained)
    }

    @discardableResult
    mutating func add(_ range: NSRange, author: HistoryAuthor, in text: String) -> UUID? {
        guard let placement = placement(for: range, in: text) else { return nil }
        let date = now()
        switch placement {
        case .existing(let id):
            guard let index = index(of: id) else { return nil }
            let live = history.passages[index].versions[history.passages[index].currentIndex].text
            appendLive(HistoryVersion(text: live, author: author, createdAt: date), toPassageAt: index)
            return id
        case let .new(level, r, parent, contained):
            let live = (text as NSString).substring(with: r)
            return insertPassage(level: level, range: r, versions: [
                HistoryVersion(text: live, author: .you, createdAt: date),
                HistoryVersion(text: live, author: author, createdAt: date),
            ], parent: parent, contained: contained, in: text)
        }
    }

    /// One accepted AI action = one passage: `[original(you), accepted(ai)]`. `text` is the text
    /// after the accept (already reported through `applyEdit`) and `range` is where the accepted
    /// text sits in it. A passage whose live range equals `range` gains a version — matched by
    /// position, never by comparing the accepted text with stored text, so a dissimilar rewrite
    /// keeps its history. The replaced version is the writer's only when `original` differs from
    /// the stored text of that version; otherwise (accepting AI text twice) it keeps its author.
    @discardableResult
    mutating func recordAccepted(range: NSRange, original: String, accepted: String, in text: String) -> UUID? {
        let stored = history  // before locateAll refreshes the current version to the accepted text
        guard let placement = placement(for: range, in: text) else { return nil }
        let date = now()
        switch placement {
        case .existing(let id):
            guard let index = index(of: id) else { return nil }
            let current = history.passages[index].currentIndex
            // The version being replaced keeps its author when it IS the original (accepting AI
            // text twice in a row); text that differs from what was stored is the writer's.
            let previous = stored.passages.first { $0.id == id }.map { $0.versions[$0.currentIndex].text }
            if previous != original { history.passages[index].versions[current].author = .you }
            history.passages[index].versions[current].text = original
            appendLive(HistoryVersion(text: accepted, author: .ai, createdAt: date), toPassageAt: index)
            return id
        case let .new(level, r, parent, contained):
            return insertPassage(level: level, range: r, versions: [
                HistoryVersion(text: original, author: .you, createdAt: date),
                HistoryVersion(text: accepted, author: .ai, createdAt: date),
            ], parent: parent, contained: contained, in: text)
        }
    }

    private mutating func insertPassage(level: HistoryLevel, range: NSRange, versions: [HistoryVersion],
                                        parent: LocatedPassage?, contained: [LocatedPassage], in text: String) -> UUID {
        let context = PassageHistoryText.context(around: range, in: text)
        let id = UUID()
        let parentVersion = parent.flatMap { p in history.passages.first { $0.id == p.id }?.currentIndex }
        history.passages.append(HistoryPassage(
            id: id, level: level, versions: versions, currentIndex: versions.count - 1,
            parentID: parent?.id, parentVersionIndex: parentVersion,
            contextBefore: context.before, contextAfter: context.after, lastTouched: now()))
        liveRanges[id] = range
        // Passages already inside the new one now live in its live version, so stepping the new
        // passage hides and restores them instead of overwriting them.
        let containedIDs = Set(contained.map(\.id))
        for i in history.passages.indices where containedIDs.contains(history.passages[i].id)
            && history.passages[i].parentID == parent?.id {
            history.passages[i].parentID = id
            history.passages[i].parentVersionIndex = versions.count - 1
        }
        return id
    }

    /// The current version becomes frozen at its index and `version` is appended as the new live
    /// one. Children visible in the live text move with it. Consecutive duplicate FROZEN versions
    /// collapse (the live version always stays, even when it equals the last frozen one).
    private mutating func appendLive(_ version: HistoryVersion, toPassageAt index: Int) {
        let id = history.passages[index].id
        let oldCurrent = history.passages[index].currentIndex
        history.passages[index].versions.append(version)
        let newCurrent = history.passages[index].versions.count - 1
        history.passages[index].currentIndex = newCurrent
        history.passages[index].lastTouched = now()
        for i in history.passages.indices
        where history.passages[i].parentID == id && history.passages[i].parentVersionIndex == oldCurrent {
            history.passages[i].parentVersionIndex = newCurrent
        }
        var v = 1
        while v < history.passages[index].versions.count - 1 {
            let versions = history.passages[index].versions
            if versions[v].text == versions[v - 1].text {
                // Children of the duplicate saw identical text; they belong to its twin.
                removeVersion(at: v, ofPassageAt: index, reparentingTo: v - 1)
            } else {
                v += 1
            }
        }
    }

    // MARK: - Switching versions
    //
    // The returned `HistoryEdit` is applied by the caller verbatim and NOT reported back through
    // `applyEdit`: the engine has already moved its live ranges for it.

    mutating func step(_ id: UUID, by delta: Int, in text: String) -> HistoryEdit? {
        guard let passage = history.passages.first(where: { $0.id == id }) else { return nil }
        let count = passage.versions.count
        guard count > 1 else { return nil }
        let target = ((passage.currentIndex + delta) % count + count) % count
        return select(id, version: target, in: text)
    }

    /// Nil when the passage cannot be located, has one version, or `index` is already current.
    mutating func select(_ id: UUID, version index: Int, in text: String) -> HistoryEdit? {
        guard let located = locateAll(in: text).first(where: { $0.id == id }),
              let p = self.index(of: id) else { return nil }
        let passage = history.passages[p]
        guard passage.versions.count > 1, passage.versions.indices.contains(index),
              index != passage.currentIndex else { return nil }
        history.passages[p].currentIndex = index
        history.passages[p].lastTouched = now()
        let edit = HistoryEdit(range: located.range, replacement: passage.versions[index].text)
        didProduce(edit, for: id)
        return edit
    }

    /// Deleting the current version first switches to its neighbour and returns that edit. A
    /// passage left with one version is removed together with its descendants.
    mutating func deleteVersion(_ id: UUID, at index: Int, in text: String) -> HistoryEdit? {
        guard let located = locateAll(in: text).first(where: { $0.id == id }),
              let p = self.index(of: id),
              history.passages[p].versions.indices.contains(index),
              history.passages[p].versions.count > 1 else { return nil }
        var edit: HistoryEdit?
        if index == history.passages[p].currentIndex {
            let neighbour = index > 0 ? index - 1 : index + 1
            let switched = HistoryEdit(range: located.range, replacement: history.passages[p].versions[neighbour].text)
            history.passages[p].currentIndex = neighbour
            didProduce(switched, for: id)
            edit = switched
        }
        removeVersion(at: index, ofPassageAt: p, reparentingTo: nil)
        if let q = self.index(of: id) {
            if history.passages[q].versions.count < 2 {
                removeWithDescendants([id])
            } else {
                history.passages[q].lastTouched = now()
            }
        }
        return edit
    }

    // MARK: - Groups

    /// Every level present in the nested group: the root plus descendants made in each parent's
    /// current version, in `HistoryLevel.allCases` order.
    func group(containing id: UUID) -> [HistoryLevel] {
        guard let rootID = chain(to: id).first else { return [] }
        var levels = Set<HistoryLevel>()
        var stack = [rootID]
        while let next = stack.popLast() {
            guard let passage = history.passages.first(where: { $0.id == next }) else { continue }
            levels.insert(passage.level)
            stack += visibleChildren(of: passage).map(\.id)
        }
        return HistoryLevel.allCases.filter(levels.contains)
    }

    /// Root … id. Empty when `id` is unknown or its ancestry is broken.
    func chain(to id: UUID) -> [UUID] {
        var result: [UUID] = []
        var cursor: UUID? = id
        while let current = cursor {
            guard !result.contains(current),
                  let passage = history.passages.first(where: { $0.id == current }) else { return [] }
            result.append(current)
            cursor = passage.parentID
        }
        return result.reversed()
    }

    /// First passage of `level` nested under `id`, through current versions only.
    func descend(from id: UUID, to level: HistoryLevel) -> UUID? {
        guard let start = history.passages.first(where: { $0.id == id }) else { return nil }
        var queue = visibleChildren(of: start)
        var head = 0
        while head < queue.count {
            let passage = queue[head]
            head += 1
            if passage.level == level { return passage.id }
            queue += visibleChildren(of: passage)
        }
        return nil
    }

    // MARK: - Bookkeeping

    private func index(of id: UUID) -> Int? {
        history.passages.firstIndex { $0.id == id }
    }

    private func visibleChildren(of passage: HistoryPassage) -> [HistoryPassage] {
        history.passages.filter { $0.parentID == passage.id && $0.parentVersionIndex == passage.currentIndex }
    }

    /// Removes version `v`. Its children move to `reparentingTo` when given, otherwise they are
    /// removed with their descendants; later indices shift down.
    private mutating func removeVersion(at v: Int, ofPassageAt index: Int, reparentingTo twin: Int?) {
        let id = history.passages[index].id
        var doomed = Set<UUID>()
        for i in history.passages.indices where history.passages[i].parentID == id {
            guard let pv = history.passages[i].parentVersionIndex else { continue }
            if pv == v {
                if let twin { history.passages[i].parentVersionIndex = twin } else { doomed.insert(history.passages[i].id) }
            } else if pv > v {
                history.passages[i].parentVersionIndex = pv - 1
            }
        }
        history.passages[index].versions.remove(at: v)
        if history.passages[index].currentIndex > v { history.passages[index].currentIndex -= 1 }
        removeWithDescendants(doomed)
    }

    private mutating func removeWithDescendants(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var doomed = ids
        var grew = true
        while grew {
            grew = false
            for passage in history.passages where !doomed.contains(passage.id) {
                if let parent = passage.parentID, doomed.contains(parent) {
                    doomed.insert(passage.id)
                    grew = true
                }
            }
        }
        history.passages.removeAll { doomed.contains($0.id) }
        for id in doomed { liveRanges[id] = nil }
    }

    /// Every passage below `id`, through all versions.
    private func descendants(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var frontier: Set<UUID> = [id]
        while !frontier.isEmpty {
            let next = Set(history.passages.filter { $0.parentID.map(frontier.contains) ?? false }.map(\.id))
                .subtracting(result).subtracting([id])
            result.formUnion(next)
            frontier = next
        }
        return result
    }

    /// Drops passages that cannot belong to any tree: corrupt version indices, a parent that no
    /// longer exists or lacks the version they were made in, and parent cycles.
    private mutating func dropUnreachable() {
        let byID = Dictionary(history.passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reachable = Set<UUID>()
        var frontier = history.passages.filter { $0.parentID == nil && Self.isWellFormed($0) }.map(\.id)
        reachable.formUnion(frontier)
        while !frontier.isEmpty {
            var next: [UUID] = []
            for passage in history.passages where !reachable.contains(passage.id) && Self.isWellFormed(passage) {
                guard let parentID = passage.parentID, frontier.contains(parentID),
                      let parent = byID[parentID], let pv = passage.parentVersionIndex,
                      parent.versions.indices.contains(pv) else { continue }
                reachable.insert(passage.id)
                next.append(passage.id)
            }
            frontier = next
        }
        history.passages.removeAll { !reachable.contains($0.id) }
        for id in liveRanges.keys where !reachable.contains(id) { liveRanges[id] = nil }
    }

    private static func isWellFormed(_ passage: HistoryPassage) -> Bool {
        passage.versions.indices.contains(passage.currentIndex)
    }
}
