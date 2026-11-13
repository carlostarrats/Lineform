import AppKit
import Combine
import Foundation

/// The smallest edit that turns `entry` into `exit`: the common UTF-16 prefix and suffix are left
/// out, then the changed span is widened to Character boundaries in BOTH strings, so it
/// never splits a CRLF pair, a surrogate pair, or a combining mark from its base. A leading BOM
/// and any line endings outside the change are therefore never rewritten. `nil` when equal.
enum HistoryUndoCollapse {
    static func minimalEdit(from entry: String, to exit: String) -> HistoryEdit? {
        trimmedEdit(from: entry, to: exit, prefixFirst: true)
    }

    /// Like `minimalEdit`, but never GUESSES where the change sits. When inserted or deleted
    /// text repeats next to itself ("Keep this. Keep this." minus one copy), the change has
    /// several valid placements: the prefix-first trim puts it at the last one, the suffix-first
    /// trim at the first. A position that reads correctly under one placement reads a different,
    /// IDENTICAL occurrence under the other — and nothing that compares text can tell. When the
    /// two placements differ this returns their UNION (earliest start to latest end, replacement
    /// built so the result text is the same), so every passage overlapping the ambiguous region
    /// straddles the edit and is dropped. Ordinary typing has one placement and is unchanged.
    static func unambiguousEdit(from entry: String, to exit: String) -> HistoryEdit? {
        guard let forward = trimmedEdit(from: entry, to: exit, prefixFirst: true),
              let backward = trimmedEdit(from: entry, to: exit, prefixFirst: false) else { return nil }
        guard forward != backward else { return forward }
        let a = entry as NSString
        let b = exit as NSString
        let start = min(forward.range.location, backward.range.location)
        let endA = max(NSMaxRange(forward.range), NSMaxRange(backward.range))
        // Outside [start, endA) the entry is a shared prefix and suffix of both strings.
        let endB = b.length - (a.length - endA)
        return HistoryEdit(
            range: NSRange(location: start, length: endA - start),
            replacement: b.substring(with: NSRange(location: start, length: endB - start))
        )
    }

    private static func trimmedEdit(from entry: String, to exit: String, prefixFirst: Bool) -> HistoryEdit? {
        let a = entry as NSString
        let b = exit as NSString
        guard !a.isEqual(to: exit) else { return nil }
        let shorter = min(a.length, b.length)

        func commonPrefix(limit: Int) -> Int {
            var count = 0
            while count < limit, a.character(at: count) == b.character(at: count) { count += 1 }
            return count
        }
        func commonSuffix(limit: Int) -> Int {
            var count = 0
            while count < limit,
                  a.character(at: a.length - 1 - count) == b.character(at: b.length - 1 - count) {
                count += 1
            }
            return count
        }
        let prefix: Int
        let suffix: Int
        if prefixFirst {
            prefix = commonPrefix(limit: shorter)
            suffix = commonSuffix(limit: shorter - prefix)
        } else {
            suffix = commonSuffix(limit: shorter)
            prefix = commonPrefix(limit: shorter - suffix)
        }

        // Widen until the start and both ends sit on composed-character boundaries. Each pass
        // only moves outward, and the shared prefix/suffix are identical in both strings, so the
        // loop ends.
        var start = prefix
        var endA = a.length - suffix
        var endB = b.length - suffix
        while true {
            let newStart = min(clusterStart(a, at: start), clusterStart(b, at: start))
            let growA = clusterEnd(a, at: endA) - endA
            let growB = clusterEnd(b, at: endB) - endB
            let grow = max(growA, growB)
            if newStart == start, grow == 0 { break }
            start = newStart
            endA += grow
            endB += grow
        }
        return HistoryEdit(
            range: NSRange(location: start, length: endA - start),
            replacement: b.substring(with: NSRange(location: start, length: endB - start))
        )
    }

    /// The start of the Character (extended grapheme cluster) `index` falls inside — `index`
    /// itself on a boundary. Swift's Characters, not NSString's composed sequences: only the
    /// former keep a CRLF pair together.
    private static func clusterStart(_ s: NSString, at index: Int) -> Int {
        guard index > 0, index < s.length else { return index }
        let string = s as String
        let end = string.index(after: String.Index(utf16Offset: index, in: string))
        return string.index(before: end).utf16Offset(in: string)
    }

    /// The end of the Character `index` cuts through — `index` itself on a boundary.
    private static func clusterEnd(_ s: NSString, at index: Int) -> Int {
        guard index > 0, index < s.length else { return index }
        let string = s as String
        let end = string.index(after: String.Index(utf16Offset: index, in: string))
        let start = string.index(before: end).utf16Offset(in: string)
        return start < index ? end.utf16Offset(in: string) : index
    }
}

/// History for the document shown in one editor: owns the engine and the store access, publishes
/// what the sidebar and the text view draw, and is the ONLY thing that applies History's edits to
/// the text (through `editor`). Callers never apply a returned `HistoryEdit` themselves; the
/// returns exist so the logic can be tested without a text view.
///
/// Lifecycle: `open(url:text:)` on every document the editor shows (the first store access —
/// nothing is read or pruned at launch), `close(text:)` before a document swap. Untitled documents
/// keep their history in memory only, until `documentGotFile`.
@MainActor
final class DocumentHistoryController: ObservableObject {
    @Published private(set) var hasHistory = false
    @Published private(set) var isHistoryModeActive = false
    @Published private(set) var display: HistoryModeDisplay?
    @Published private(set) var sidebarModel = HistorySidebarModel()

    /// The text view History edits. Weak: the editor's representable attaches the live one.
    private(set) weak var editor: HistoryEditorSurface?
    private(set) var url: URL?

    private let store: PassageHistoryPersisting
    private let now: () -> Date
    private var engine: DocumentHistoryEngine
    private var documentID: UUID?
    /// Whether the store holds (or may hold) an entry for `url`. Without one, an empty history is
    /// never written — nothing is stored until a version is kept.
    private var hasStoreEntry = false
    private var located: [LocatedPassage] = []
    private var selectedID: UUID?
    /// The text when History mode was entered, and the text as History mode has left it.
    private var entryText: String?
    private var modeText: String?
    /// Each passage's current version when History mode was entered, for the session's undo.
    private var entryVersions: [UUID: Int] = [:]
    /// A version was deleted this session: indices no longer line up with `entryVersions`.
    private var sessionDeletedVersions = false

    /// Stores already pruned this app session (one entry in production: the shared store). Held
    /// weakly: an `ObjectIdentifier` of a freed store can be reused by a new one, which would then
    /// never be pruned.
    private static var prunedStores: [WeakStore] = []
    private struct WeakStore { weak var store: PassageHistoryPersisting? }
    /// Pruning resolves a bookmark per stored document (network volumes, unplugged drives): never
    /// on the main thread, and opening a document never waits for it.
    private static let pruneQueue = DispatchQueue(label: "com.lineform.history.prune", qos: .utility)

    /// The app's one store, under the (sandboxed) home's Application Support. Creating it touches
    /// nothing on disk.
    static let sharedStore: PassageHistoryPersisting = FilePassageHistoryStore(
        directory: FilePassageHistoryStore.defaultDirectory(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    )

    /// Posted (object: the store) after `clearAllHistory(in:)` emptied a store. Every controller
    /// on that store re-reads it, so no open editor keeps — or later writes back — cleared history.
    static let didClearAllNotification = Notification.Name("Lineform.historyDidClearAll")
    private var clearAllObservation: AnyCancellable?
    /// Quit and window close persist what was typed into passages since the last save. Observed
    /// here — never wired in `applicationDidFinishLaunching` (the test host is the app).
    private var lifecycleObservations: [AnyCancellable] = []

    init(store: PassageHistoryPersisting, now: @escaping () -> Date = Date.init,
         notificationCenter: NotificationCenter = .default) {
        self.store = store
        self.now = now
        engine = DocumentHistoryEngine(history: DocumentHistory(passages: []), now: now)
        clearAllObservation = notificationCenter
            .publisher(for: Self.didClearAllNotification, object: store)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadFromStore() }
            }
        lifecycleObservations = [
            notificationCenter.publisher(for: NSApplication.willTerminateNotification)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.persistEditorText() }
                },
            notificationCenter.publisher(for: NSWindow.willCloseNotification)
                .sink { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = notification.object as? NSWindow,
                              let editorWindow = (self.editor as? NSView)?.window, window === editorWindow else { return }
                        self.persistEditorText()
                    }
                },
        ]
    }

    /// Quit / window close: store the current versions as the editor shows them. In History mode
    /// every step already saved; only typing (which leaves History mode) is unsaved.
    func persistEditorText() {
        guard let text = editor?.string else { return }
        documentSaved(text: text)
    }

    /// Settings ▸ Clear History: removes every document's history from `store` and refreshes
    /// every open controller on it (each window's, active tab or not; background tabs re-read
    /// the store when they are next shown).
    static func clearAllHistory(in store: PassageHistoryPersisting, center: NotificationCenter = .default) {
        store.clearAll()
        center.post(name: didClearAllNotification, object: store)
    }

    // MARK: - Editor

    /// Idempotent: called from every `updateNSView`, so it does nothing for the attached view.
    func attach(_ textView: LineformTextView) {
        guard editor !== textView else { return }
        editor = textView
        textView.historyCommandHandler = { [weak self, weak textView] command in
            guard let self, let textView else { return }
            _ = self.handle(command, text: textView.string)
        }
        textView.historyCanAddHandler = { [weak self, weak textView] range in
            guard let self, let textView else { return false }
            return self.canAdd(range, text: textView.string)
        }
        textView.historyUserEditHandler = { [weak self] range, replacement in
            self?.noteUserEdit(range, replacement: replacement)
        }
    }

    func detach(_ textView: LineformTextView) {
        guard editor === textView else { return }
        editor = nil
        textView.historyCommandHandler = nil
        textView.historyCanAddHandler = nil
        textView.historyUserEditHandler = nil
        textView.historyDisplay = nil
    }

    // MARK: - Documents

    /// Loads history for the document now shown. A no-op when it is the document already open
    /// (same `documentID` and file), so re-registration on appear or window bind keeps live state.
    func open(url: URL?, text: String, documentID: UUID? = nil) {
        if let documentID, documentID == self.documentID, Self.sameFile(url, self.url) {
            return
        }
        endHistoryModeWithoutEdit()
        self.url = url
        self.documentID = documentID
        selectedID = nil
        var history = DocumentHistory(passages: [])
        if let url {
            pruneOnce()
            history = store.load(for: url)
            // Prune runs in the background and may not have reached this document yet: apply its
            // 30-day rule here too, or the next save would write the stale passages back.
            let cutoff = now().addingTimeInterval(-FilePassageHistoryStore.staleInterval)
            history.passages.removeAll { $0.lastTouched < cutoff }
        }
        hasStoreEntry = !history.isEmpty
        engine = DocumentHistoryEngine(history: history, now: now)
        located = history.isEmpty ? [] : engine.locateAll(in: text)
        refreshHasHistory()
    }

    /// Before a document swap: leaves History mode (the collapse lands on the outgoing text, which
    /// the editor still shows), persists, and forgets the document.
    func close(text: String) {
        if isHistoryModeActive { _ = exitHistoryMode() }
        persist(text: text)
        url = nil
        documentID = nil
        hasStoreEntry = false
        engine = DocumentHistoryEngine(history: DocumentHistory(passages: []), now: now)
        located = []
        refreshHasHistory()
    }

    /// The document was written. Typing inside a passage edits its current version in place, so
    /// store that version now — otherwise the next launch searches for stale text and drops it.
    func documentSaved(text: String) {
        guard !isHistoryModeActive else { return }
        persist(text: text)
    }

    /// Live reload from disk: reload wins. History mode closes WITHOUT the collapse (the disk text
    /// replaces everything) and passages are re-found literally.
    func documentReloaded(text: String) {
        endHistoryModeWithoutEdit()
        engine.invalidateLiveRanges()
        located = engine.history.isEmpty ? [] : engine.locateAll(in: text)
        refreshHasHistory()
    }

    /// Rename, Finder/iCloud move, or Save As: the history follows the file.
    func fileMoved(from old: URL, to new: URL) {
        store.retarget(from: old, to: new)
        if Self.sameFile(url, old) {
            url = new
        }
    }

    /// A folder was renamed or moved: every stored document under it follows, and so does this
    /// one when it lives there.
    func directoryMoved(from oldDir: URL, to newDir: URL) {
        store.retargetDirectory(from: oldDir, to: newDir)
        guard let current = url else { return }
        let oldPrefix = FileIdentity.key(for: oldDir) + "/"
        let key = FileIdentity.key(for: current)
        if key.hasPrefix(oldPrefix) {
            url = newDir.appendingPathComponent(String(key.dropFirst(oldPrefix.count)))
        }
    }

    /// An untitled document was saved for the first time: its in-memory history is stored now.
    func documentGotFile(_ newURL: URL, text: String) {
        guard url == nil else { return }
        url = newURL
        persist(text: text)
    }

    /// Re-reads the store for the current document (Settings ▸ Clear History). An untitled
    /// document's in-memory history is dropped too: it has no store entry to re-read.
    ///
    /// The engine is replaced BEFORE History mode leaves: leaving saves, and saving the old engine
    /// would write the cleared history straight back. The text History mode left stays (it is the
    /// writer's document) and still collapses into one undoable edit.
    func reloadFromStore() {
        let history = url.map(store.load(for:)) ?? DocumentHistory(passages: [])
        hasStoreEntry = !history.isEmpty
        engine = DocumentHistoryEngine(history: history, now: now)
        located = []
        if isHistoryModeActive { _ = exitHistoryMode() }
        refreshHasHistory()
    }

    // MARK: - User edits

    /// Every user text change, in pre-change coordinates (the text view's `shouldChangeText`).
    /// O(passages); never reads the text.
    func noteUserEdit(_ range: NSRange, replacement: String) {
        guard !engine.history.isEmpty else { return }
        let before = engine.history.passages.count
        engine.applyEdit(range, replacement: replacement)
        if engine.history.passages.count != before {
            // An edit across a passage's edge dropped it (spec §5.1 rule 2).
            save()
            refreshHasHistory()
        }
    }

    func noteWholeTextReplacement() {
        engine.invalidateLiveRanges()
    }

    // MARK: - History mode

    /// Returns whether History mode is active afterwards: false when nothing could be shown, so
    /// the sidebar never sits on an inert History tab.
    @discardableResult
    func enterHistoryMode(text: String) -> Bool {
        guard !isHistoryModeActive else { return true }
        guard !engine.history.isEmpty else {
            refreshHasHistory()
            return false
        }
        located = engine.locateAll(in: text)
        refreshHasHistory()
        guard !located.isEmpty else { return false }
        entryText = text
        modeText = text
        entryVersions = currentVersions()
        sessionDeletedVersions = false
        selectedID = nil
        isHistoryModeActive = true
        publishMode()
        return true
    }

    /// Leaves History mode and returns the collapsed edit (entry text → exit text, in entry
    /// coordinates), which the editor applies as the session's single undo step.
    @discardableResult
    func exitHistoryMode() -> HistoryEdit? {
        guard isHistoryModeActive, let entry = entryText, let current = modeText else { return nil }
        // Never a guessed placement: the collapse's own undo and redo are reported against live
        // ranges, so an ambiguous one must straddle the region it could sit in.
        let collapse = HistoryUndoCollapse.unambiguousEdit(from: entry, to: current)
        let restoring = sessionDeletedVersions ? nil : entryVersions
        let exitVersions = currentVersions()
        resetModeState()
        save()
        guard let editor else { return collapse }
        // The text view's manager is the tab's real stack again once the display is cleared.
        var bracketed: UndoManager?
        let applied = editor.applyHistoryExit(restoring: entry, collapse: collapse, expecting: current) { [self] in
            guard let manager = editor.undoManager else { return }
            guard restoring != nil else {
                // No version undo is registered (the session deleted a version), so nothing
                // else clears the live ranges around the collapse's undo and redo.
                registerInvalidationBracket(on: manager, documentID: documentID, url: url)
                return
            }
            registerRedoBracket(on: manager, making: exitVersions, documentID: documentID, url: url)
            bracketed = manager
        }
        if applied, let restoring, let manager = bracketed {
            registerVersionUndo(on: manager, making: restoring, redoMaking: exitVersions,
                                documentID: documentID, url: url)
        }
        return collapse
    }

    /// History lives in Write mode; Read or Split leaves it.
    func displayModeDidChange(to mode: EditorDisplayMode) {
        guard mode != .write, isHistoryModeActive else { return }
        exitHistoryMode()
    }

    @discardableResult
    func handle(_ command: HistoryTextCommand, text: String) -> HistoryEdit? {
        switch command {
        case .add(let range):
            guard engine.add(range, author: .you, in: text) != nil else { return nil }
            save()
            if isHistoryModeActive {
                located = engine.locateAll(in: text)
                publishMode()
            }
            refreshHasHistory()
            return nil
        case .select(let id):
            guard isHistoryModeActive, located.contains(where: { $0.id == id }) else { return nil }
            selectedID = id
            publishMode()
            return nil
        case .step(let delta):
            guard isHistoryModeActive, let id = selectedID else { return nil }
            return didProduce(engine.step(id, by: delta, in: text), in: text)
        case .moveSelection(let delta):
            moveSelection(by: delta)
            return nil
        case .exit, .typedWhileInHistoryMode:
            return exitHistoryMode()
        }
    }

    func selectLevel(_ level: HistoryLevel) {
        guard isHistoryModeActive, let id = selectedID else { return }
        let visible = Set(located.map(\.id))
        let levels = Dictionary(engine.history.passages.map { ($0.id, $0.level) }, uniquingKeysWith: { first, _ in first })
        if let up = engine.chain(to: id).first(where: { levels[$0] == level && visible.contains($0) }) {
            selectedID = up
        } else if let down = engine.descend(from: id, to: level), visible.contains(down) {
            selectedID = down
        }
        publishMode()
    }

    @discardableResult
    func selectVersion(_ index: Int, text: String) -> HistoryEdit? {
        guard isHistoryModeActive, let id = selectedID else { return nil }
        return didProduce(engine.select(id, version: index, in: text), in: text)
    }

    @discardableResult
    func deleteVersion(_ index: Int, text: String) -> HistoryEdit? {
        guard isHistoryModeActive, let id = selectedID else { return nil }
        let before = engine.history
        let edit = engine.deleteVersion(id, at: index, in: text)
        guard edit != nil || engine.history != before else { return nil }
        sessionDeletedVersions = true
        return didProduce(edit, in: text, alwaysRefresh: true)
    }

    func canAdd(_ range: NSRange, text: String) -> Bool {
        engine.canAdd(range, in: text)
    }

    /// AI actions are unavailable while History mode is on and inside a word-level passage (spec §5).
    func allowsAIAction(on range: NSRange) -> Bool {
        !isHistoryModeActive && !engine.isInsideWordPassage(range)
    }

    /// An accepted AI change (plan 3). `text` is the text after the accept, already reported
    /// through `noteUserEdit`.
    func recordAccepted(range: NSRange, original: String, accepted: String, text: String) {
        guard engine.recordAccepted(range: range, original: original, accepted: accepted, in: text) != nil else { return }
        save()
        refreshHasHistory()
    }

    // MARK: - Private

    /// Applies an engine edit to the editor (undo-disabled), then re-locates and saves. Leaves
    /// History mode when the last passage went away.
    private func didProduce(_ edit: HistoryEdit?, in text: String, alwaysRefresh: Bool = false) -> HistoryEdit? {
        guard edit != nil || alwaysRefresh else { return nil }
        var newText = text
        if let edit {
            newText = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            modeText = newText
            editor?.applyHistoryEdit(edit)
        }
        located = engine.locateAll(in: newText)
        if let id = selectedID, !located.contains(where: { $0.id == id }) {
            selectedID = nil
        }
        save()
        refreshHasHistory()
        if located.isEmpty {
            exitHistoryMode()
        } else {
            publishMode()
        }
        return edit
    }

    private func moveSelection(by delta: Int) {
        guard isHistoryModeActive, !located.isEmpty, delta != 0 else { return }
        let target: Int
        if let id = selectedID, let index = located.firstIndex(where: { $0.id == id }) {
            target = min(max(index + delta, 0), located.count - 1)
        } else {
            target = delta > 0 ? 0 : located.count - 1
        }
        selectedID = located[target].id
        publishMode()
    }

    private func endHistoryModeWithoutEdit() {
        guard isHistoryModeActive else { return }
        resetModeState()
        save()
        editor?.historyDisplay = nil
    }

    private func resetModeState() {
        isHistoryModeActive = false
        entryText = nil
        modeText = nil
        entryVersions = [:]
        selectedID = nil
        publishMode()
    }

    private func currentVersions() -> [UUID: Int] {
        Dictionary(engine.history.passages.map { ($0.id, $0.currentIndex) }, uniquingKeysWith: { first, _ in first })
    }

    /// Registered in the SAME undo group as the exit collapse, so undoing it puts the entry
    /// versions back as current (and redo the exit ones). It runs before the text is reverted
    /// (LIFO) and clears the live ranges, so the revert cannot drop a passage it straddles.
    /// Skipped after a version deletion this session (indices shifted): the passages are then
    /// re-found by their stored text or quietly dropped — never overwritten.
    private func registerVersionUndo(on manager: UndoManager, making indices: [UUID: Int],
                                     redoMaking other: [UUID: Int], documentID: UUID?, url: URL?) {
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                // Undo stacks are per tab; act only on the document this session belonged to.
                guard controller.documentID == documentID, Self.sameFile(controller.url, url) else { return }
                controller.engine.restoreCurrentVersions(indices)
                controller.located = []
                controller.save()
                controller.registerVersionUndo(on: manager, making: other, redoMaking: indices,
                                               documentID: documentID, url: url)
            }
        }
    }

    /// Registered in the exit's undo group BEFORE the collapse, so it is undone last and REDONE
    /// FIRST. Undo does nothing here; redo makes the exit versions current and clears the live
    /// ranges before the collapse's text redo runs. Without it the text redo ran first, reported
    /// against live ranges a save had re-found for the entry text — a collapse spanning several
    /// passages straddled them all and dropped them.
    /// Registered in the exit's undo group BEFORE the collapse when no version undo is (the
    /// session deleted a version): undo forgets the live ranges right AFTER the collapse's text
    /// undo, redo right BEFORE its text redo, so the next locate re-finds passages literally
    /// instead of trusting ranges mapped through a text-only edit.
    private func registerInvalidationBracket(on manager: UndoManager, documentID: UUID?, url: URL?) {
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                if controller.documentID == documentID, Self.sameFile(controller.url, url) {
                    controller.engine.invalidateLiveRanges()
                    controller.located = []
                }
                controller.registerInvalidationBracket(on: manager, documentID: documentID, url: url)
            }
        }
    }

    private func registerRedoBracket(on manager: UndoManager, making exitIndices: [UUID: Int],
                                     documentID: UUID?, url: URL?) {
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                // Undoing: nothing to change; arm the redo half.
                manager.registerUndo(withTarget: controller) { controller in
                    MainActor.assumeIsolated {
                        if controller.documentID == documentID, Self.sameFile(controller.url, url) {
                            controller.engine.restoreCurrentVersions(exitIndices)
                            controller.located = []
                            controller.save()
                        }
                        controller.registerRedoBracket(on: manager, making: exitIndices,
                                                       documentID: documentID, url: url)
                    }
                }
            }
        }
    }

    private func persist(text: String) {
        guard url != nil, !engine.history.isEmpty || hasStoreEntry else { return }
        if !engine.history.isEmpty {
            located = engine.locateAll(in: text)
        }
        save()
        refreshHasHistory()
    }

    private func save() {
        guard let url, !engine.history.isEmpty || hasStoreEntry else { return }
        store.save(engine.history, for: url)
        hasStoreEntry = !engine.history.isEmpty
    }

    private func pruneOnce() {
        Self.prunedStores.removeAll { $0.store == nil }
        guard !Self.prunedStores.contains(where: { $0.store === store }) else { return }
        Self.prunedStores.append(WeakStore(store: store))
        // Stores are thread-safe by contract (the file store serializes on its lock).
        let box = UncheckedStore(store: store)
        let date = now()
        Self.pruneQueue.async { box.store.prune(now: date) }
    }

    private struct UncheckedStore: @unchecked Sendable { let store: PassageHistoryPersisting }

    private func refreshHasHistory() {
        let value = !engine.history.isEmpty
        if hasHistory != value { hasHistory = value }
    }

    /// Publishes the display and the sidebar model; pushes the display straight to the editor so
    /// the ink and the next keystroke see it before SwiftUI's next update.
    private func publishMode() {
        let newDisplay: HistoryModeDisplay?
        let newModel: HistorySidebarModel
        if isHistoryModeActive {
            let passage = selectedID.flatMap { id in engine.history.passages.first { $0.id == id } }
            let counter = passage.map { HistoryCounter(count: $0.versions.count, current: $0.currentIndex) }
            newDisplay = HistoryModeDisplay(passages: located, selectedID: selectedID, hoveredID: nil, counter: counter)
            if let passage {
                let levels = engine.group(containing: passage.id)
                newModel = HistorySidebarModel(
                    levels: levels,
                    currentLevel: passage.level,
                    versions: passage.versions.enumerated().map { index, version in
                        HistorySidebarRow(
                            id: index,
                            text: HistorySidebarRow.displayText(for: version.text),
                            author: version.author,
                            isCurrent: index == passage.currentIndex
                        )
                    },
                    hasSelection: true
                )
            } else {
                newModel = HistorySidebarModel()
            }
        } else {
            newDisplay = nil
            newModel = HistorySidebarModel()
        }
        if display != newDisplay { display = newDisplay }
        if sidebarModel != newModel { sidebarModel = newModel }
        editor?.historyDisplay = newDisplay
    }

    private static func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return FileIdentity.key(for: l) == FileIdentity.key(for: r)
        default: return false
        }
    }
}
