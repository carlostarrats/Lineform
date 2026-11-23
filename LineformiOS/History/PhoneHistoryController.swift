import Combine
import Foundation
import LineformCore
import Observation

/// What leaving History mode does to the text: `collapse` turns the text History mode was entered
/// on (`entryText`) into the text it leaves (`exitText`), in entry coordinates, and is applied as
/// the session's ONE undoable edit (`LineformTextView.applyHistoryExit`). Undoing it makes
/// `restoreVersions` current again (the versions on entry; empty when the session deleted a
/// version, whose indices no longer line up), redoing it `exitVersions`. Nil `collapse`: the text
/// did not change, nothing is registered.
struct HistoryExit {
    let collapse: HistoryEdit?
    let restoreVersions: [UUID: Int]
    let exitVersions: [UUID: Int]
    let entryText: String
    let exitText: String
}

/// History for the iPhone's one open document: the Mac's `DocumentHistoryController`, ported
/// without AppKit. It owns the engine and the store access, publishes what History mode shows,
/// and is the ONLY thing that applies History's edits to the text (through the attached
/// `editor`). Callers never apply a returned `HistoryEdit` or `HistoryExit` themselves; the
/// returns exist so the logic can be tested without a text view.
///
/// Lifecycle (driven by `OpenDocument`): `open(url:text:)` for every document shown — the first
/// store access, and the session's one prune, on `pruneQueue` (nothing is read or pruned at
/// launch); `close(text:)` before a swap; `persist(text:)` after every save; `fileMoved` for a
/// rename, a move or Save As; `documentGotFile` when an Untitled document is first saved;
/// `documentReloaded` for live reload. Untitled documents keep their history in memory only.
///
/// Edits reach it from the text view's storage hook (`noteUserEdit`, `noteWholeTextReplacement`);
/// History's own edits are flagged there and never reported back.
@MainActor
@Observable
final class PhoneHistoryController {
    // MARK: - Published state

    private(set) var hasHistory = false
    private(set) var isHistoryModeActive = false
    /// The passages History mode shows, in text order (empty outside History mode, or stale).
    private(set) var located: [LocatedPassage] = []
    private(set) var selectedPassageID: UUID?
    /// Replace With… asked for the replacement field on this passage; spent when the field opens
    /// (`replacementFieldDidOpen`), when History mode ends, and on a document swap.
    private(set) var pendingReplacementFieldID: UUID?
    /// The passage an AI accept recorded while History was off: the next plain entry
    /// (`enterHistoryModeFromMenu`) selects it.
    private(set) var rememberedPassageID: UUID?
    /// Bumped whenever what History mode shows changes (a step, a delete, a level), so a view
    /// reading `selectedPassage` re-renders. The engine itself is not observed: typing mutates it.
    private(set) var revision = 0

    // MARK: - Unobserved state

    /// The text view History edits. Weak: `MarkdownEditor` attaches the live one.
    @ObservationIgnored private(set) weak var editor: LineformTextView?
    @ObservationIgnored private(set) var url: URL?
    @ObservationIgnored private let store: PassageHistoryPersisting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pruneQueue: DispatchQueue
    @ObservationIgnored private var engine: DocumentHistoryEngine
    /// Changes on every open and close: an undo registered for one document never acts on another.
    @ObservationIgnored private var documentToken = UUID()
    /// Whether the store holds (or may hold) an entry for `url`. Without one, an empty history is
    /// never written — nothing is stored until a version is kept.
    @ObservationIgnored private var hasStoreEntry = false
    /// The text when History mode was entered, and the text as History mode has left it.
    @ObservationIgnored private var entryText: String?
    @ObservationIgnored private var modeText: String?
    /// Each passage's current version when History mode was entered, for the session's undo.
    @ObservationIgnored private var entryVersions: [UUID: Int] = [:]
    /// A version was deleted this session: indices no longer line up with `entryVersions`.
    @ObservationIgnored private var sessionDeletedVersions = false
    /// History mode was on when an AI action started: the passage selected then.
    @ObservationIgnored private var aiResume: AIResume?
    private struct AIResume { let selectedID: UUID? }
    @ObservationIgnored private var clearAllObservation: AnyCancellable?

    #if DEBUG
    /// How many edits and whole-text replacements the text view reported (tests).
    @ObservationIgnored private(set) var reportedEditCountForTesting = 0
    @ObservationIgnored private(set) var wholeTextReplacementCountForTesting = 0
    #endif

    // MARK: - The app's store

    /// The app's one store: the local store under the app container's Application Support, and
    /// for documents in the Lineform iCloud folder the shared store in the container's `History/`
    /// folder (`RoutingPassageHistoryStore`). LAZY (`LazyHistoryStore`): the app's
    /// `OpenDocument.live()` is built at launch, and nothing History-related runs then — the router
    /// is made at the store's first use (the first document opened with a file, or Settings ▸
    /// Clear History), and this iPhone's device name (Keychain, this device only) is read only when
    /// a document in the Lineform iCloud folder first uses History.
    static let sharedStore: LazyHistoryStore = makeLiveStore()

    /// The live store, made on first use. `home`, `defaults` and `deviceIDStorage` are injected by
    /// tests.
    static func makeLiveStore(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        defaults: UserDefaults = .standard,
        deviceIDStorage: HistoryDeviceIDStoring = SystemHistoryDeviceIDKeychain()
    ) -> LazyHistoryStore {
        let box = UncheckedLiveInputs(defaults: defaults, storage: deviceIDStorage)
        return LazyHistoryStore {
            RoutingPassageHistoryStore.live(platform: "iphone", home: home, defaults: box.defaults,
                                            deviceIDStorage: box.storage)
        }
    }

    private struct UncheckedLiveInputs: @unchecked Sendable {
        let defaults: UserDefaults
        let storage: HistoryDeviceIDStoring
    }

    /// Stores already pruned this app session (one in production). Held weakly: a freed store's
    /// `ObjectIdentifier` can be reused by a new one, which would then never be pruned.
    private static var prunedStores: [WeakStore] = []
    private struct WeakStore { weak var store: PassageHistoryPersisting? }
    /// Pruning resolves a bookmark per stored document: never on the main thread, and opening a
    /// document never waits for it.
    static let defaultPruneQueue = DispatchQueue(label: "com.lineform.history.prune", qos: .utility)

    /// Posted (object: the store) after `clearAllHistory(in:)` emptied a store. Every controller on
    /// that store re-reads it, so nothing open keeps — or later writes back — cleared history.
    static let didClearAllNotification = Notification.Name("LineformiOS.historyDidClearAll")

    init(
        store: PassageHistoryPersisting,
        now: @escaping () -> Date = Date.init,
        pruneQueue: DispatchQueue = PhoneHistoryController.defaultPruneQueue,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.now = now
        self.pruneQueue = pruneQueue
        engine = DocumentHistoryEngine(history: DocumentHistory(passages: []), now: now)
        clearAllObservation = notificationCenter
            .publisher(for: Self.didClearAllNotification, object: store)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reloadFromStore(text: self.editor?.textStorage.string ?? self.modeText ?? "")
                }
            }
    }

    /// Settings ▸ Clear History: removes every document's history from `store` and refreshes
    /// every controller on it.
    static func clearAllHistory(in store: PassageHistoryPersisting, center: NotificationCenter = .default) {
        store.clearAll()
        center.post(name: didClearAllNotification, object: store)
    }

    // MARK: - Editor

    /// Idempotent: `MarkdownEditor` calls it from every update.
    func attach(_ textView: LineformTextView) {
        if editor !== textView {
            if let old = editor, old.historyController === self { old.historyController = nil }
            editor = textView
        }
        if textView.historyController !== self { textView.historyController = self }
        textView.historyDisplayDidChange()
    }

    func detach(_ textView: LineformTextView) {
        guard editor === textView else { return }
        editor = nil
        if textView.historyController === self { textView.historyController = nil }
    }

    // MARK: - Documents

    /// Loads history for the document now shown. The first open with a file prunes the store
    /// once, in the background.
    func open(url: URL?, text: String) {
        endHistoryModeWithoutEdit()
        self.url = url
        documentToken = UUID()
        selectedPassageID = nil
        rememberedPassageID = nil
        pendingReplacementFieldID = nil
        aiResume = nil
        var history = DocumentHistory(passages: [])
        if let url {
            pruneOnce()
            history = store.load(for: url)
            // Prune may not have reached this document yet: apply its 30-day rule here too, or
            // the next save would write the stale passages back.
            let cutoff = now().addingTimeInterval(-FilePassageHistoryStore.staleInterval)
            history.passages.removeAll { $0.lastTouched < cutoff }
        }
        hasStoreEntry = !history.isEmpty
        engine = DocumentHistoryEngine(history: history, now: now)
        located = history.isEmpty ? [] : engine.locateAll(in: text)
        refreshHasHistory()
        bump()
    }

    /// Before a document swap (and when the open file was deleted or trashed): leaves History mode
    /// (the collapse lands on the outgoing text, which the editor still shows), persists, and
    /// forgets the document.
    func close(text: String) {
        if isHistoryModeActive { exitHistoryMode(text: text) }
        persistNow(text: text)
        url = nil
        documentToken = UUID()
        rememberedPassageID = nil
        pendingReplacementFieldID = nil
        aiResume = nil
        hasStoreEntry = false
        engine = DocumentHistoryEngine(history: DocumentHistory(passages: []), now: now)
        located = []
        refreshHasHistory()
        bump()
    }

    /// The document was written. Typing inside a passage edits its current version in place, so
    /// that version is stored now — otherwise the next open searches for stale text and drops it.
    /// In History mode every step already saved.
    func persist(text: String) {
        guard !isHistoryModeActive else { return }
        persistNow(text: text)
    }

    /// Writes the store's queued History writes now (shared History is written on a queue): called
    /// inside the background-task assertion, before iOS may suspend or end the app.
    func flushPendingWrites() {
        store.flushPendingWrites()
    }

    /// Live reload from disk: reload wins. History mode closes WITHOUT the collapse (the disk text
    /// replaces everything) and passages are re-found literally.
    func documentReloaded(text: String) {
        endHistoryModeWithoutEdit()
        engine.invalidateLiveRanges()
        located = engine.history.isEmpty ? [] : engine.locateAll(in: text)
        refreshHasHistory()
        bump()
    }

    /// A rename (the first-line rule, Files, another device), a move, or Save As: the history
    /// follows the file.
    func fileMoved(from old: URL, to new: URL) {
        store.retarget(from: old, to: new)
        if Self.sameFile(url, old) { url = new }
    }

    /// An Untitled document was saved for the first time: its in-memory history is stored now.
    func documentGotFile(_ newURL: URL, text: String) {
        guard url == nil else { return }
        url = newURL
        persist(text: text)
    }

    /// Re-reads the store for the current document (Clear History). An Untitled document's
    /// in-memory history is dropped too. The engine is replaced BEFORE History mode leaves:
    /// leaving saves, and saving the old engine would write the cleared history straight back.
    func reloadFromStore(text: String) {
        let history = url.map { store.load(for: $0) } ?? DocumentHistory(passages: [])
        hasStoreEntry = !history.isEmpty
        engine = DocumentHistoryEngine(history: history, now: now)
        located = []
        if isHistoryModeActive { exitHistoryMode(text: text) }
        refreshHasHistory()
        bump()
    }

    // MARK: - User edits

    /// Every user text change, in pre-change coordinates. O(passages); never reads the text.
    func noteUserEdit(_ range: NSRange, replacement: String) {
        #if DEBUG
        reportedEditCountForTesting += 1
        #endif
        guard !engine.history.isEmpty else { return }
        let before = engine.history.passages.count
        engine.applyEdit(range, replacement: replacement)
        if engine.history.passages.count != before {
            // An edit across a passage's edge dropped it.
            save()
            refreshHasHistory()
        }
    }

    /// The text was replaced in a way that is not reported edit by edit: the next locate re-finds
    /// every passage literally.
    func noteWholeTextReplacement() {
        #if DEBUG
        wholeTextReplacementCountForTesting += 1
        #endif
        engine.invalidateLiveRanges()
    }

    // MARK: - Reading

    /// The stored passage `id`, or nil.
    func passage(_ id: UUID) -> HistoryPassage? {
        engine.history.passages.first { $0.id == id }
    }

    /// The selected passage, or nil.
    var selectedPassage: HistoryPassage? {
        _ = revision
        return selectedPassageID.flatMap { passage($0) }
    }

    /// The levels of the nested group holding `id` (the level switcher shows only when > 1).
    func levels(containing id: UUID) -> [HistoryLevel] {
        engine.group(containing: id)
    }

    // MARK: - History mode

    /// Whether Replace With… is offered for `range` (the Mac rule): the edge-trimmed selection
    /// stays within one line and touches no front matter, fenced code or math, and History can
    /// place it.
    func canAdd(_ range: NSRange, text: String) -> Bool {
        let ns = text as NSString
        let aligned = PassageHistoryText.aligned(range, in: text)
        guard aligned.length > 0, NSMaxRange(aligned) <= ns.length,
              ns.substring(with: aligned).rangeOfCharacter(from: .newlines) == nil,
              MarkdownWritingToolsProtection.protectedRanges(in: ns, intersecting: aligned).isEmpty else { return false }
        return engine.canAdd(range, in: text)
    }

    /// Replace With…: stores the original (one version), asks for the replacement field on it,
    /// and shows it in History mode (entering it when it is not on). Leaving History without a
    /// replacement discards the passage again.
    @discardableResult
    func add(_ range: NSRange, text: String) -> UUID? {
        guard let id = engine.add(range, author: .you, in: text) else { return nil }
        pendingReplacementFieldID = id
        save()
        if isHistoryModeActive {
            located = engine.locateAll(in: text)
            // Add never changes the text, so this version is what the session's undo restores.
            if entryVersions[id] == nil, let added = passage(id) {
                entryVersions[id] = added.currentIndex
            }
            if located.contains(where: { $0.id == id }) { selectedPassageID = id }
            refreshHasHistory()
            bump()
        } else {
            refreshHasHistory()
            showPassage(id, text: text)
        }
        return id
    }

    /// The card opened the replacement field: the request is spent.
    func replacementFieldDidOpen() {
        guard pendingReplacementFieldID != nil else { return }
        pendingReplacementFieldID = nil
        bump()
    }

    /// Returns whether History mode is active afterwards: false when nothing could be shown.
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
        selectedPassageID = nil
        isHistoryModeActive = true
        bump()
        return true
    }

    /// Menu ▸ History: History mode with nothing selected — or, when an AI accept left a
    /// remembered passage that still locates, that one selected. The memory is spent either way.
    @discardableResult
    func enterHistoryModeFromMenu(text: String) -> Bool {
        let remembered = rememberedPassageID
        rememberedPassageID = nil
        pendingReplacementFieldID = nil
        guard enterHistoryMode(text: text) else { return false }
        if let remembered, located.contains(where: { $0.id == remembered }) {
            selectedPassageID = remembered
            bump()
        }
        return true
    }

    /// Enters History mode (when it is not on already) focused on passage `id`. False when History
    /// mode could not start or the passage is not in the text.
    @discardableResult
    func showPassage(_ id: UUID, text: String) -> Bool {
        rememberedPassageID = nil
        if !isHistoryModeActive {
            guard passage(id) != nil else { return false }
            located = engine.locateAll(in: text)
        }
        guard located.contains(where: { $0.id == id }), enterHistoryMode(text: text) else { return false }
        selectedPassageID = id
        bump()
        return true
    }

    /// Selects a located passage, or deselects with nil (back to the overview; History stays on).
    func select(_ id: UUID?) {
        guard isHistoryModeActive else { return }
        if let id {
            guard located.contains(where: { $0.id == id }), selectedPassageID != id else { return }
        } else {
            guard selectedPassageID != nil else { return }
        }
        selectedPassageID = id
        bump()
    }

    @discardableResult
    func step(by delta: Int, text: String) -> HistoryEdit? {
        guard isHistoryModeActive, let id = selectedPassageID else { return nil }
        return didProduce(engine.step(id, by: delta, in: text), in: text)
    }

    @discardableResult
    func selectVersion(_ index: Int, text: String) -> HistoryEdit? {
        guard isHistoryModeActive, let id = selectedPassageID else { return nil }
        return didProduce(engine.select(id, version: index, in: text), in: text)
    }

    @discardableResult
    func deleteVersion(_ index: Int, text: String) -> HistoryEdit? {
        guard isHistoryModeActive, let id = selectedPassageID else { return nil }
        let before = engine.history
        let edit = engine.deleteVersion(id, at: index, in: text)
        guard edit != nil || engine.history != before else { return nil }
        // With the history from BEFORE the delete, and only once the engine really deleted: a
        // shared store records it, so the version (or the passage removed with it) is not brought
        // back from another device's copy.
        if let url { store.noteVersionDeleted(passage: id, at: index, in: before, for: url) }
        sessionDeletedVersions = true
        return didProduce(edit, in: text, alwaysRefresh: true)
    }

    /// The writer's own replacement for the selected passage: a new version, made current, put in
    /// the document through the undo-disabled path as a step. Nil outside History mode, with
    /// nothing selected, when the trimmed text is empty or equals the current version, or when
    /// `passageID` (the passage the field was opened for) is no longer the selected one.
    @discardableResult
    func addReplacement(_ replacement: String, text current: String, for passageID: UUID? = nil) -> HistoryEdit? {
        guard isHistoryModeActive, let id = selectedPassageID else { return nil }
        if let passageID, passageID != id { return nil }
        return didProduce(engine.addReplacement(replacement, to: id, in: current), in: current)
    }

    func selectLevel(_ level: HistoryLevel) {
        guard isHistoryModeActive, let id = selectedPassageID else { return }
        let visible = Set(located.map(\.id))
        let levels = Dictionary(engine.history.passages.map { ($0.id, $0.level) }, uniquingKeysWith: { first, _ in first })
        if let up = engine.chain(to: id).first(where: { levels[$0] == level && visible.contains($0) }) {
            selectedPassageID = up
        } else if let down = engine.descend(from: id, to: level), visible.contains(down) {
            selectedPassageID = down
        }
        bump()
    }

    /// Leaves History mode and applies the session to the attached editor as ONE undoable edit
    /// (`LineformTextView.applyHistoryExit`). Returns what was applied; nil outside History mode.
    @discardableResult
    func exitHistoryMode(text: String) -> HistoryExit? {
        guard isHistoryModeActive, let entry = entryText else { return nil }
        let current = modeText ?? text
        // Never a guessed placement: the collapse's own undo and redo are reported against live
        // ranges, so an ambiguous one must straddle the region it could sit in.
        let collapse = HistoryUndoCollapse.unambiguousEdit(from: entry, to: current)
        let exit = HistoryExit(
            collapse: collapse,
            restoreVersions: sessionDeletedVersions ? [:] : entryVersions,
            exitVersions: currentVersions(),
            entryText: entry,
            exitText: current
        )
        resetModeState()
        discardUnrevisedPassages()
        save()
        editor?.applyHistoryExit(exit, controller: self)
        return exit
    }

    // MARK: - Exit undo (called by `LineformTextView.applyHistoryExit`, inside its undo group)

    /// Registered BEFORE the collapse, so it is undone last and REDONE FIRST. With a version undo
    /// to come: undo does nothing, redo makes the exit versions current before the text redo runs.
    /// Without one (the session deleted a version): undo and redo forget the live ranges, so the
    /// next locate re-finds passages literally instead of trusting ranges mapped through a
    /// text-only edit.
    func registerUndoBeforeExitCollapse(_ exit: HistoryExit, on manager: UndoManager) {
        if exit.restoreVersions.isEmpty {
            registerInvalidationBracket(on: manager, token: documentToken)
        } else {
            registerRedoBracket(on: manager, making: exit.exitVersions, token: documentToken)
        }
    }

    /// Registered AFTER the collapse, in the same group: undoing it makes the entry versions
    /// current (and redo the exit ones). It runs before the text is reverted (LIFO) and clears the
    /// live ranges, so the revert cannot drop a passage it straddles.
    func registerUndoAfterExitCollapse(_ exit: HistoryExit, on manager: UndoManager) {
        guard !exit.restoreVersions.isEmpty else { return }
        registerVersionUndo(on: manager, making: exit.restoreVersions, redoMaking: exit.exitVersions, token: documentToken)
    }

    // MARK: - AI (the Mac's `AIHistoryRecording` side, for step 8)

    /// AI actions are offered on any selection in normal writing; History mode refuses them.
    func allowsAIAction(on range: NSRange) -> Bool {
        !isHistoryModeActive
    }

    /// The range an AI action on `range` works on: grown over any passage it partly overlaps.
    func aiActionRange(for range: NSRange) -> NSRange {
        engine.aiActionRange(for: range)
    }

    /// An AI request is about to start. When History mode is on, the passage selected now is
    /// remembered and History mode ends; `aiActionDidEnd` returns to it.
    func aiActionWillStart() {
        guard isHistoryModeActive else { return }
        aiResume = AIResume(selectedID: selectedPassageID)
        exitHistoryMode(text: editor?.textStorage.string ?? modeText ?? "")
    }

    /// An AI action ended. History was on when it started → History mode comes back focused on
    /// `recorded`, else the passage containing `changedRange`, else the one selected before — the
    /// first that still locates. History was off → an accept's passage is remembered for the next
    /// plain entry.
    func aiActionDidEnd(recorded: UUID?, changedRange: NSRange? = nil, text: String) {
        guard let resume = aiResume else {
            if let recorded { rememberedPassageID = recorded }
            return
        }
        aiResume = nil
        let candidates = engine.history.isEmpty ? [] : engine.locateAll(in: text)
        let containing = changedRange.flatMap { range in
            candidates.filter { NSIntersectionRange($0.range, range).length > 0 || $0.range.location == range.location }
                .min { $0.range.length < $1.range.length }?.id
        }
        for id in [recorded, containing, resume.selectedID].compactMap({ $0 })
        where candidates.contains(where: { $0.id == id }) {
            showPassage(id, text: text)
            return
        }
    }

    /// The AI action ended in a way that must not bring History back: the context is dropped.
    func aiActionAbandoned() {
        aiResume = nil
    }

    /// An accepted AI change is applied between these: a passage its edits would drop is set
    /// aside (versions kept) for `recordAccepted`.
    func aiAcceptWillApply() { engine.beginSettingAside() }
    func aiAcceptDidApply() { engine.endSettingAside() }

    /// An accepted AI change. `text` is the text after the accept, already reported as edits.
    @discardableResult
    func recordAccepted(range: NSRange, original: String, accepted: String, text: String) -> UUID? {
        guard let id = engine.recordAccepted(range: range, original: original, accepted: accepted, in: text) else { return nil }
        save()
        refreshHasHistory()
        return id
    }

    /// The accept's recording is over: set-aside passages nothing could hold are dropped.
    func aiAcceptRecordingDidFinish() {
        engine.finishSetAside()
        save()
        refreshHasHistory()
    }

    // MARK: - Private

    /// Applies an engine edit to the editor (undo-disabled, not reported), then re-locates and
    /// saves. Leaves History mode when the last passage went away.
    private func didProduce(_ edit: HistoryEdit?, in text: String, alwaysRefresh: Bool = false) -> HistoryEdit? {
        guard edit != nil || alwaysRefresh else { return nil }
        var newText = text
        if let edit {
            newText = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            modeText = newText
            editor?.applyHistoryEdit(edit)
        }
        located = engine.locateAll(in: newText)
        if let id = selectedPassageID, !located.contains(where: { $0.id == id }) {
            selectedPassageID = nil
        }
        save()
        refreshHasHistory()
        if located.isEmpty {
            exitHistoryMode(text: newText)
        } else {
            bump()
        }
        return edit
    }

    private func endHistoryModeWithoutEdit() {
        guard isHistoryModeActive else { return }
        resetModeState()
        discardUnrevisedPassages()
        save()
    }

    private func resetModeState() {
        isHistoryModeActive = false
        pendingReplacementFieldID = nil
        entryText = nil
        modeText = nil
        entryVersions = [:]
        selectedPassageID = nil
        bump()
    }

    /// Leaving History: a passage added and never given a replacement is discarded.
    private func discardUnrevisedPassages() {
        let discarded = Set(engine.discardUnrevisedPassages())
        guard !discarded.isEmpty else { return }
        located.removeAll { discarded.contains($0.id) }
        refreshHasHistory()
    }

    private func currentVersions() -> [UUID: Int] {
        Dictionary(engine.history.passages.map { ($0.id, $0.currentIndex) }, uniquingKeysWith: { first, _ in first })
    }

    private func registerVersionUndo(on manager: UndoManager, making indices: [UUID: Int],
                                     redoMaking other: [UUID: Int], token: UUID) {
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                // Act only on the document this session belonged to.
                guard controller.documentToken == token else { return }
                controller.engine.restoreCurrentVersions(indices)
                controller.located = []
                controller.save()
                controller.bump()
                controller.registerVersionUndo(on: manager, making: other, redoMaking: indices, token: token)
            }
        }
    }

    private func registerInvalidationBracket(on manager: UndoManager, token: UUID) {
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                if controller.documentToken == token {
                    controller.engine.invalidateLiveRanges()
                    controller.located = []
                }
                controller.registerInvalidationBracket(on: manager, token: token)
            }
        }
    }

    private func registerRedoBracket(on manager: UndoManager, making exitIndices: [UUID: Int], token: UUID) {
        manager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                // Undoing: nothing to change; arm the redo half.
                manager.registerUndo(withTarget: controller) { controller in
                    MainActor.assumeIsolated {
                        if controller.documentToken == token {
                            controller.engine.restoreCurrentVersions(exitIndices)
                            controller.located = []
                            controller.save()
                            controller.bump()
                        }
                        controller.registerRedoBracket(on: manager, making: exitIndices, token: token)
                    }
                }
            }
        }
    }

    private func persistNow(text: String) {
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
        pruneQueue.async { box.store.prune(now: date) }
    }

    private struct UncheckedStore: @unchecked Sendable { let store: PassageHistoryPersisting }

    private func refreshHasHistory() {
        let value = !engine.history.isEmpty
        if hasHistory != value { hasHistory = value }
    }

    /// Every change to what History mode shows goes through here: views reading `revision`
    /// re-render, and the attached editor redraws its wash and follows the mode (read-only, taps
    /// and keys select and step).
    private func bump() {
        revision &+= 1
        editor?.historyDisplayDidChange()
    }

    private static func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return FileIdentity.key(for: l) == FileIdentity.key(for: r)
        default: return false
        }
    }
}

/// The AI controller's History on iPhone, as `DocumentHistoryController` is on the Mac: the
/// nine methods in the "AI" section above, unchanged. `DocumentScreen` assigns it to
/// `SelectionController.aiHistory`, the one assignment.
extension PhoneHistoryController: AIHistoryRecording {}
