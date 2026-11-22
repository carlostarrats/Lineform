import Foundation
import LineformCore
import Observation
import SwiftUI
import UIKit
import os

/// The one document the iPhone app has open: its file (nil for a new document that has no text
/// yet), its text, and the live-reload watcher on that file.
///
/// Reads go through `NSFileCoordinator` and `MarkdownFileCodec`, so a file keeps its bytes (a
/// leading BOM, CRLF line endings). Live reload follows `DocumentReloadPolicy`: an external change
/// replaces the text only while the text still equals `lastSyncedText`, so in-memory edits that
/// disk does not have yet are never overwritten.
///
/// Saving is automatic and never asks. `AutosavePlanner` decides each save: a new document gets
/// a file in the save folder once it has text, named from its first line, and is renamed while
/// that name still follows the first line; an opened file is written in place. Saves run 1 s
/// after the last keystroke, at once when the app goes to the background, and before another
/// file replaces this one. Writes and renames are coordinated with this document's own file
/// presenter, so they never come back as a reload.
///
/// When the open file is deleted elsewhere (Files, another device), or moved into a Trash folder,
/// the text stays on screen but the document lets go of that path: it becomes a new document
/// again, so the next change saves it under a new name from its first line, and nothing writes
/// the deleted file back.
///
/// Text is never thrown away to make room for something else. Opening a file or starting a new
/// document first saves the current one; if that save fails, the current document stays and the
/// screen shows `saveFailed`'s quiet notice. Every read of a file happens off the main thread, and
/// a file iCloud has not downloaded yet is downloaded first while the screen shows `downloadingName`.
@MainActor
@Observable
final class OpenDocument: ImageInsertionHost {
    enum OpenError: Error, Equatable {
        /// The file could not be read, or it is not valid UTF-8 text.
        case unreadable(URL)
        /// The current document could not be saved, so it stays open instead of being replaced.
        case currentDocumentNotSaved
        /// A later open or New Document took over before this open finished.
        case superseded
    }

    /// The open file, or nil for a new document that has not been saved yet.
    private(set) var url: URL?
    /// The text the editor shows.
    private(set) var text = ""
    /// The text as of the last moment memory equalled disk: open, our own save, or a reload.
    private(set) var lastSyncedText = ""
    /// True while the file name follows the document's first line. A new document starts named
    /// from its first line; an opened file never is.
    var isNamedFromFirstLine: Bool { planner.isNamedFromFirstLine }

    /// True after a save failed, until a save succeeds. The screen shows a small, calm notice;
    /// the text is still in memory and the next save tries again.
    private(set) var saveFailed = false
    /// The name of a file iCloud is downloading so it can be opened, or nil. While it is set the
    /// screen shows a quiet downloading state in place of the text.
    private(set) var downloadingName: String?
    /// True for a few seconds after a pasted or dropped image could not be written beside the
    /// document (its folder is not writable, as for a file opened from another provider where
    /// only the file is in scope). The screen shows a short notice; nothing was inserted.
    private(set) var imageSaveFailed = false
    /// How long the image notice stays.
    static let imageNoticeDuration: Duration = .seconds(4)

    /// How long after the last keystroke an autosave runs.
    static let autosaveDelay: Duration = .seconds(1)
    /// How often a file iCloud is downloading is checked again.
    static let downloadPollInterval: Duration = .milliseconds(250)

    /// Where new documents save. Resolved off the main thread by `prepare`, because the live
    /// folder asks for the iCloud container.
    private(set) var saveFolder: URL?

    @ObservationIgnored private let folderProvider: @Sendable () -> URL
    @ObservationIgnored private let reader: any DocumentDiskReading
    @ObservationIgnored private let writer: any DocumentFileWriting
    @ObservationIgnored private let ubiquitousItems: any UbiquitousItemAccessing
    /// The one resolution of the save folder that `prepare`, `flush` and the file list share.
    @ObservationIgnored private var folderTask: Task<URL, Never>?
    /// Bumped by every open and New Document, so an open still reading or downloading can tell
    /// that something newer took over.
    @ObservationIgnored private var openGeneration = 0
    /// Bumped whenever the document is put away for another (`closeCurrentDocument`): an image on
    /// its way to the old one must not land in the new one.
    @ObservationIgnored private var documentGeneration = 0
    @ObservationIgnored private var imageNoticeTask: Task<Void, Never>?
    /// How many opens are between their start and their end. The launch restore gives way to any.
    @ObservationIgnored private var opensInFlight = 0
    /// Bumped whenever `lastSyncedText` is set (open, our own save, a reload, a detach), so a
    /// reload read that was in flight meanwhile can tell its snapshot is stale.
    @ObservationIgnored private var syncGeneration = 0
    @ObservationIgnored private var watcher: DocumentFileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The URL whose security scope this document holds (a file from outside the app).
    @ObservationIgnored private var securityScopedURL: URL?
    /// Images picked with Read's Reconnect whose security scope this document holds while it is
    /// open, so the next render (and every one after) can load them.
    @ObservationIgnored private var reconnectedImageURLs: [URL] = []
    /// Undo for the edits Read makes (a checkbox toggle, a Reconnect): one step each. Write mode's
    /// editor keeps its own; a Write edit clears this stack, because undoing an older whole-text
    /// step would throw that edit away.
    /// Each step is grouped by hand (`groupsByEvent` off), so one toggle is one step whether or not
    /// a run-loop event is open.
    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    /// Set while a Read edit (or its undo) goes through `edit`, so it keeps the undo stack.
    @ObservationIgnored private var isApplyingReadEdit = false
    @ObservationIgnored private var isPrepared = false
    private var planner = AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.lineform.app", category: "autosave")

    /// - Parameters:
    ///   - folderProvider: returns the folder new documents save into. It is called off the main
    ///     thread (the live one asks for the iCloud container). Tests pass a temporary folder.
    ///   - reader: the coordinated disk reader that opening and live reload use, off the main thread.
    ///   - writer: writes the bytes inside the coordinated save. Tests inject failures.
    ///   - ubiquitousItems: tells whether iCloud still has to download a file, and starts that
    ///     download. Tests inject a fake; real iCloud is never touched in tests.
    init(
        folderProvider: @escaping @Sendable () -> URL,
        reader: any DocumentDiskReading = FileSystemDiskReader(),
        writer: any DocumentFileWriting = FileSystemDocumentWriter(),
        ubiquitousItems: any UbiquitousItemAccessing = LiveUbiquitousItems()
    ) {
        self.folderProvider = folderProvider
        self.reader = reader
        self.writer = writer
        self.ubiquitousItems = ubiquitousItems
    }

    /// The document the app uses: new documents save into iCloud Drive's Lineform folder when it
    /// is available, otherwise into the app's on-device Documents folder.
    static func live() -> OpenDocument {
        OpenDocument(folderProvider: { DocumentFolderResolver.live().saveFolder() })
    }

    // MARK: - Preparing

    /// Resolves the save folder off the main thread and makes sure it exists, then reopens the
    /// document the scene had open, if there was one and it can still be read. A stored file that
    /// is gone or unreadable leaves the blank document. Only the first call does anything.
    ///
    /// - Parameters:
    ///   - bookmark: `storedBookmark` as `@SceneStorage` kept it (base64 bookmark data).
    ///   - storedPath: the older path form (`storedPath`), read when there is no bookmark, for a
    ///     scene stored before bookmarks.
    func prepare(restoringBookmark bookmark: String = "", restoringStoredPath storedPath: String = "") async {
        guard !isPrepared else { return }
        isPrepared = true
        let folder = await resolveSaveFolder()

        // Restore only into an untouched document: never replace something already typed or opened.
        var stored: URL?
        if !bookmark.isEmpty {
            stored = await Task.detached { Self.resolveBookmark(bookmark) }.value
        } else if !storedPath.isEmpty {
            stored = storedPath.hasPrefix("/")
                ? URL(fileURLWithPath: storedPath)
                : folder.appendingPathComponent(storedPath)
        }
        if let stored, url == nil, text.isEmpty {
            try? await open(stored, onlyIntoUntouchedDocument: true)
        }
        // Text typed before the folder was known has been waiting for it.
        if text != lastSyncedText { scheduleAutosave() }
    }

    /// The folder new documents save into. The first caller starts resolving it off the main
    /// thread (the live folder asks for the iCloud container) and creates it if needed; every
    /// caller, including ones that arrive while that is still running, gets the same folder.
    @discardableResult
    func resolveSaveFolder() async -> URL {
        if let saveFolder { return saveFolder }
        let task: Task<URL, Never>
        if let folderTask {
            task = folderTask
        } else {
            let provider = folderProvider
            task = Task.detached {
                let folder = provider()
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder
            }
            folderTask = task
        }
        let folder = await task.value
        if saveFolder == nil { saveFolder = folder }
        return folder
    }

    /// What `@SceneStorage` keeps to reopen this document: "" for a document with no file, the
    /// path relative to the save folder for a file in it (the app container's path can change
    /// between launches), and the absolute path otherwise.
    var storedPath: String {
        guard let url else { return "" }
        if let folder = saveFolder {
            let folderPath = folder.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path.hasPrefix(folderPath + "/") {
                return String(path.dropFirst(folderPath.count + 1))
            }
        }
        return url.path
    }

    /// What `@SceneStorage` keeps to reopen this document: "" for a document with no file,
    /// otherwise the file's bookmark data, base64-encoded. A bookmark, unlike a path, also reopens
    /// a file from outside the app (Files, "Open in Lineform") with its security scope, and follows
    /// the file if it was renamed meanwhile.
    var storedBookmark: String {
        guard let url,
              let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return "" }
        return data.base64EncodedString()
    }

    /// The file a `storedBookmark` points at, or nil when it no longer resolves.
    nonisolated private static func resolveBookmark(_ bookmark: String) -> URL? {
        guard let data = Data(base64Encoded: bookmark) else { return nil }
        var isStale = false
        // A stale bookmark still resolves; the screen stores a fresh one once the file is open.
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    // MARK: - Opening

    /// Opens `url`, replacing the current document. A file from outside the app (Files, "Open in
    /// Lineform") is opened through its security scope, which the document keeps while it is open.
    ///
    /// The file is read off the main thread. A file with no local copy yet (its `.Name.md.icloud`
    /// placeholder) is downloaded first: the current document is saved and put away,
    /// `downloadingName` is set while iCloud works, and the file opens once a local copy exists.
    /// A full local copy that is not current opens at once while the download runs; live reload
    /// applies the current version when it arrives.
    ///
    /// Throws `OpenError.unreadable` when the file cannot be read or is not valid UTF-8, and
    /// `OpenError.currentDocumentNotSaved` when the current document could not be saved; in both
    /// cases the current document stays as it was. Throws `OpenError.superseded` when a later
    /// open or New Document took over meanwhile.
    func open(_ requestedURL: URL) async throws {
        try await open(requestedURL, onlyIntoUntouchedDocument: false)
    }

    /// `open`; with `onlyIntoUntouchedDocument` (the launch restore), the file opens only if the
    /// writer has not typed or opened anything while it was being read.
    private func open(_ requestedURL: URL, onlyIntoUntouchedDocument: Bool) async throws {
        // The launch restore never takes over from an open the writer started: it gives up
        // without touching `openGeneration`.
        if onlyIntoUntouchedDocument, opensInFlight > 0 || downloadingName != nil {
            throw OpenError.superseded
        }
        let url = Self.realURL(for: requestedURL)
        openGeneration += 1
        let generation = openGeneration
        opensInFlight += 1
        defer { opensInFlight -= 1 }
        /// True when the restore must leave the document alone: the writer typed or opened something.
        func restoreMustYield() -> Bool {
            onlyIntoUntouchedDocument && (self.url != nil || !text.isEmpty)
        }
        var startsDownloadAfterWatching = false
        let didAccess = url.startAccessingSecurityScopedResource()
        var keepsScope = false
        defer { if didAccess, !keepsScope { url.stopAccessingSecurityScopedResource() } }

        let items = ubiquitousItems
        switch await Task.detached(operation: { items.downloadState(url) }).value {
        case .current:
            break
        case .localCopyNotCurrent:
            // A full local copy is here (offline, or a newer version is on its way): open it at
            // once. The download starts once the file is watched, so the current version is
            // brought in by the watcher and `DocumentReloadPolicy` like any external change.
            startsDownloadAfterWatching = true
        case .notDownloaded:
            guard generation == openGeneration else { throw OpenError.superseded }
            // A restore never puts away a document the writer has typed into.
            if restoreMustYield() { throw OpenError.superseded }
            // The download can take a while: save and put away the current document first, so
            // nothing typed meanwhile can be lost, and show the downloading state in its place.
            guard await flush() else { throw OpenError.currentDocumentNotSaved }
            guard generation == openGeneration else { throw OpenError.superseded }
            if restoreMustYield() { throw OpenError.superseded }
            closeCurrentDocument()
            downloadingName = url.lastPathComponent
            do {
                try await Task.detached(operation: { try items.startDownloading(url) }).value
            } catch {
                // A failure after a newer action took over is that action's business.
                guard generation == openGeneration else { throw OpenError.superseded }
                downloadingName = nil
                throw OpenError.unreadable(url)
            }
            // Wait only until a local copy exists; a newer version then arrives as a reload.
            while await Task.detached(operation: { items.downloadState(url) }).value == .notDownloaded {
                guard generation == openGeneration else { throw OpenError.superseded }
                try? await Task.sleep(for: Self.downloadPollInterval)
                guard generation == openGeneration else { throw OpenError.superseded }
            }
        }

        let reader = self.reader
        let diskText = await Task.detached(operation: { reader.readText(at: url) }).value
        guard generation == openGeneration else { throw OpenError.superseded }
        guard let diskText else {
            downloadingName = nil
            throw OpenError.unreadable(url)
        }
        if restoreMustYield() { throw OpenError.superseded }

        // The document being replaced keeps what was typed into it, including while the read ran.
        guard await flush() else { throw OpenError.currentDocumentNotSaved }
        guard generation == openGeneration else { throw OpenError.superseded }
        if restoreMustYield() { throw OpenError.superseded }
        closeCurrentDocument()
        if didAccess {
            securityScopedURL = url
            keepsScope = true
        }

        self.url = url
        text = diskText
        setLastSyncedText(diskText)
        planner = AutosavePlanner(existingFileName: url.lastPathComponent, isNamedFromFirstLine: false)
        startWatching(url)
        if startsDownloadAfterWatching {
            Task.detached { try? items.startDownloading(url) }
            // A version that landed between the read and the watch is not announced to the new
            // watcher: check disk once now that it is watched.
            scheduleReload()
        }
    }

    /// Starts a blank Untitled document, after saving whatever the current one has not saved yet.
    /// Like any new document, it creates no file until it has text. Returns false, and keeps the
    /// current document, when that save failed.
    @discardableResult
    func newDocument() async -> Bool {
        openGeneration += 1
        let generation = openGeneration
        guard await flush() else { return false }
        // An open the writer started after this, which finished during the save, stays.
        guard generation == openGeneration else { return false }
        closeCurrentDocument()
        return true
    }

    /// Puts the current document away (after it was saved): stops watching, releases its scope,
    /// and leaves a blank, untouched new document.
    private func closeCurrentDocument() {
        documentGeneration += 1
        autosaveTask?.cancel()
        autosaveTask = nil
        stopWatching()
        releaseSecurityScope()
        url = nil
        text = ""
        setLastSyncedText("")
        planner = AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
        downloadingName = nil
        undoManager.removeAllActions()
    }

    /// The file a URL stands for: an iCloud placeholder `.Name.md.icloud` stands for `Name.md`
    /// next to it. Downloading and reading always use the real URL.
    nonisolated static func realURL(for url: URL) -> URL {
        let entry = url.lastPathComponent
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud"),
              let name = FileListModel.displayName(of: entry)
        else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Set when `openReportingFailure` could not open a file; the screen shows an alert for it.
    var failedOpenURL: URL?

    /// `open`, for the UI: a file that cannot be opened sets `failedOpenURL` instead of throwing.
    /// A failed save of the current document already shows its own notice, and a superseded open
    /// is not a failure.
    func openReportingFailure(_ url: URL) async {
        do {
            try await open(url)
        } catch OpenError.currentDocumentNotSaved, OpenError.superseded {
            return
        } catch {
            failedOpenURL = url
        }
    }

    // MARK: - Editing

    /// The writer changed the text.
    func edit(_ newText: String) {
        guard newText != text else { return }
        if !isApplyingReadEdit { undoManager.removeAllActions() }
        text = newText
        scheduleAutosave()
    }

    /// The folder relative image links resolve against: the open file's. Nil for a document that
    /// has no file yet.
    var documentDirectory: URL? { url?.deletingLastPathComponent() }

    // MARK: - Edits from Read

    /// A rendered task checkbox was tapped: swaps `[ ]` and `[x]` at `range` as a normal edit
    /// (autosave, one undo step). Nothing happens when `range` no longer holds a marker
    /// (`CheckboxToggle` returns nil), or when `renderedFrom`, the source the Read view rendered
    /// the checkbox from, is no longer the text: a render that has not caught up with an edit
    /// (Preview's 0.12 s debounce) could otherwise aim at another line's marker.
    func toggleCheckbox(at range: NSRange, renderedFrom: String? = nil) {
        if let renderedFrom, renderedFrom != text { return }
        guard let newText = CheckboxToggle.toggledText(in: text, at: range) else { return }
        applyReadEdit(newText)
    }

    /// Read's Reconnect: points the image at `range` at `pickedURL` (from the image picker),
    /// relative to the document's folder when the file is inside it, otherwise absolute
    /// (`ImageLinkRewrite`), as a normal edit with one undo step. The picked file's security scope
    /// is kept while this document is open, so the next render loads it. A stale range (no longer
    /// one image) changes nothing and keeps no scope.
    func reconnectImage(at range: NSRange, with pickedURL: URL) {
        let didAccess = pickedURL.startAccessingSecurityScopedResource()
        let newPath = ImageLinkRewrite.linkPath(for: pickedURL, documentDirectory: documentDirectory)
        guard let newText = ImageLinkRewrite.rewritten(in: text, at: range, newPath: newPath) else {
            if didAccess { pickedURL.stopAccessingSecurityScopedResource() }
            return
        }
        if didAccess { reconnectedImageURLs.append(pickedURL) }
        applyReadEdit(newText)
    }

    /// One Read edit through `edit`, registered as one undo step that redoes the same way.
    private func applyReadEdit(_ newText: String) {
        let oldText = text
        guard newText != oldText else { return }
        isApplyingReadEdit = true
        edit(newText)
        isApplyingReadEdit = false
        // An undo or redo is already inside the manager's own group; a new step needs its own.
        let opensGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            document.applyReadEdit(oldText)
        }
        if opensGroup { undoManager.endUndoGrouping() }
    }

    // MARK: - Autosave

    /// Saves `autosaveDelay` after the last keystroke.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Saves now whatever disk does not have yet: creates, writes or renames the file as
    /// `AutosavePlanner` decides. A new document typed before the save folder is known waits for
    /// it. Returns true when disk has the text (or there was nothing to save), false when the save
    /// failed; the text is then still in memory, and `saveFailed` is set.
    @discardableResult
    func flush() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard text != lastSyncedText else { return true }
        if url == nil, saveFolder == nil {
            await resolveSaveFolder()
        }
        return saveNow()
    }

    /// The synchronous part of `flush`, once the folder is known.
    @discardableResult
    private func saveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard text != lastSyncedText else { return true }
        guard let folder = url?.deletingLastPathComponent() ?? saveFolder else { return false }
        let saved = save(text, in: folder)
        saveFailed = !saved
        return saved
    }

    private func save(_ textToSave: String, in folder: URL) -> Bool {
        let previousPlanner = planner
        var takenNames: Set<String> = []
        // A name can be taken between planning and writing (another device, Files); then plan
        // again with that name counted as taken. A few tries is plenty.
        for _ in 0..<5 {
            let existingNames = Self.existingNames(in: folder).union(takenNames)
            switch planner.textChanged(textToSave, existingNames: existingNames) {
            case .none:
                return true
            case .create(let fileName):
                let newURL = folder.appendingPathComponent(fileName)
                switch coordinatedWrite(textToSave, to: newURL, replaceExisting: false) {
                case .written:
                    url = newURL
                    startWatching(newURL)
                    setLastSyncedText(textToSave)
                    return true
                case .fileExists:
                    planner = previousPlanner
                    takenNames.insert(fileName)
                    continue
                case .failed:
                    planner = previousPlanner
                    return false
                }
            case .write:
                guard let url, coordinatedWrite(textToSave, to: url, replaceExisting: true) == .written else { return false }
                setLastSyncedText(textToSave)
                return true
            case .rename(let fileName):
                guard let oldURL = url else { return false }
                let newURL = folder.appendingPathComponent(fileName)
                if coordinatedMove(from: oldURL, to: newURL) {
                    stopWatching()
                    url = newURL
                    startWatching(newURL)
                } else {
                    // Keep the old name; the text still saves.
                    planner = previousPlanner
                }
                guard let url, coordinatedWrite(textToSave, to: url, replaceExisting: true) == .written else { return false }
                setLastSyncedText(textToSave)
                return true
            }
        }
        planner = previousPlanner
        return false
    }

    // MARK: - Images

    /// The folder a pasted or dropped image goes in (its `images/` subfolder): the open file's own
    /// folder. A document that was never saved is saved first, through `flush` and so the normal
    /// autosave rules, which gives it a file beside that folder. If that save fails, the answer is
    /// nil, `saveFailed` shows the usual notice, and the editor inserts nothing. A document with
    /// nothing to be named from yet (blank: `AutosavePlanner` creates no file for it) gets the save
    /// folder, where `imageLinkInserted` creates its file from the link.
    func folderForInsertedImage() async -> URL? {
        if let url { return url.deletingLastPathComponent() }
        guard await flush() else { return nil }
        if let url { return url.deletingLastPathComponent() }
        return await resolveSaveFolder()
    }

    /// The editor inserted an image link: save now rather than a second later, so a new document's
    /// file is on disk next to its `images/` folder.
    func imageLinkInserted() async {
        await flush()
    }

    /// Which document is open: it changes when another document (an opened file, New Document)
    /// takes this one's place, and stays the same while this one is first saved or renamed.
    var imageInsertionDocumentIdentity: Int { documentGeneration }

    /// An image could not be written beside the document: show the short notice, which goes
    /// away by itself. Nothing is written anywhere else (an absolute path to the app's own
    /// container would not travel with the document).
    func imageCouldNotBeSaved() {
        imageSaveFailed = true
        imageNoticeTask?.cancel()
        imageNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.imageNoticeDuration)
            guard !Task.isCancelled else { return }
            self?.imageSaveFailed = false
        }
    }

    private func setLastSyncedText(_ newValue: String) {
        lastSyncedText = newValue
        syncGeneration += 1
    }

    /// `flush`, inside a background-task assertion, for the scene going inactive or to the
    /// background: the text must be on disk before iOS may suspend the app. The save runs at once
    /// when the folder is known; at launch it finishes once the folder is.
    func flushForBackground(using tasks: any BackgroundTaskAsserting = UIApplication.shared) {
        let assertion = BackgroundAssertion()
        assertion.identifier = tasks.beginAssertion(name: "Save document") {
            assertion.end(using: tasks)
        }
        if text == lastSyncedText || url != nil || saveFolder != nil {
            saveNow()
            assertion.end(using: tasks)
        } else {
            Task {
                await self.flush()
                assertion.end(using: tasks)
            }
        }
    }

    /// The scene phases that save at once: leaving the foreground starts at `.inactive` (the app
    /// switcher, a call, Control Center), and iOS may suspend the app soon after `.background`.
    static func savesImmediately(on phase: ScenePhase) -> Bool {
        phase == .inactive || phase == .background
    }

    // MARK: - Live reload

    /// Reads the file again and applies `DocumentReloadPolicy.decide`. Returns the outcome, or nil
    /// when there is no file or it could not be read.
    ///
    /// The read runs off the main thread. If the document changed while it was in flight (our own
    /// save landed, the writer typed, another file opened), the result is stale: deciding on it
    /// could put older disk text back over a save that just happened. The file is then read again,
    /// a few times at most, and a result that is still stale is dropped.
    @discardableResult
    func applyExternalChange() async -> ReloadOutcome? {
        for _ in 0..<3 {
            guard let url else { return nil }
            let snapshotText = text
            let snapshotSynced = lastSyncedText
            let snapshotGeneration = syncGeneration
            let reader = self.reader
            let diskText = await Task.detached(operation: { reader.readText(at: url) }).value
            guard self.url == url,
                  text == snapshotText,
                  lastSyncedText == snapshotSynced,
                  syncGeneration == snapshotGeneration
            else { continue }
            guard let diskText else { return nil }

            let outcome = DocumentReloadPolicy.decide(
                diskText: diskText, currentText: text, lastSyncedText: lastSyncedText
            )
            if outcome == .reload {
                // Undoing a Read edit made before the reload would put older text over it.
                undoManager.removeAllActions()
                text = diskText
                setLastSyncedText(diskText)
            }
            return outcome
        }
        return nil
    }

    /// Coalesces a burst of presenter callbacks into one reload, `debounceInterval` after the last.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DocumentReloadPolicy.debounceInterval))
            guard !Task.isCancelled else { return }
            await self?.applyExternalChange()
        }
    }

    // MARK: - Watching

    private func startWatching(_ url: URL) {
        let watcher = DocumentFileWatcher(url: url)
        // @Sendable so the closures are not main-actor isolated: the presenter calls them on its
        // own queue, and they hop to the main actor.
        watcher.onChange = { @Sendable [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        let watcherID = ObjectIdentifier(watcher)
        watcher.onDelete = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, let current = self.watcher, ObjectIdentifier(current) == watcherID else { return }
                self.detachFromDeletedFile()
            }
        }
        watcher.onMove = { @Sendable [weak self] newURL in
            Task { @MainActor in
                guard let self, let current = self.watcher, ObjectIdentifier(current) == watcherID else { return }
                self.followMove(to: newURL)
            }
        }
        NSFileCoordinator.addFilePresenter(watcher)
        self.watcher = watcher
    }

    private func stopWatching() {
        reloadTask?.cancel()
        reloadTask = nil
        if let watcher {
            NSFileCoordinator.removeFilePresenter(watcher)
        }
        watcher = nil
    }

    /// The file was moved or renamed by someone else (Files, iCloud): keep editing it there. A move
    /// into a Trash folder (Files' Recently Deleted) is a delete, as on the Mac, where a trashed
    /// file's window keeps its text as unsaved content.
    private func followMove(to newURL: URL) {
        if Self.isTrashLocation(newURL) {
            detachFromDeletedFile()
            return
        }
        stopWatching()
        url = newURL
        planner.fileWasRenamed(to: newURL.lastPathComponent)
        startWatching(newURL)
    }

    /// The file was deleted by someone else. Keep the text on screen, but never write to that path
    /// again: the document becomes new, and nothing is saved until the text changes, when it gets
    /// a file named from its first line.
    private func detachFromDeletedFile() {
        autosaveTask?.cancel()
        autosaveTask = nil
        stopWatching()
        releaseSecurityScope()
        url = nil
        setLastSyncedText(text)
        planner = AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
    }

    /// True for a URL inside a Trash folder: a path component `.Trash` or `Trash`, or a place the
    /// system's trash directory contains.
    nonisolated static func isTrashLocation(_ url: URL) -> Bool {
        if url.pathComponents.contains(where: { $0 == ".Trash" || $0 == "Trash" }) { return true }
        var relationship = FileManager.URLRelationship.other
        if (try? FileManager.default.getRelationship(
            &relationship, of: .trashDirectory, in: .allDomainsMask, toItemAt: url
        )) != nil, relationship == .contains {
            return true
        }
        return false
    }

    private func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        for imageURL in reconnectedImageURLs {
            imageURL.stopAccessingSecurityScopedResource()
        }
        reconnectedImageURLs = []
    }

    // MARK: - Disk

    enum WriteResult: Equatable {
        case written
        /// A new file's name was taken just before the write; nothing was overwritten.
        case fileExists
        case failed
    }

    /// A coordinated write of `text`'s exact bytes to `url`. This document's own presenter is
    /// passed to the coordinator, so the write is not reported back to it as an external change.
    /// With `replaceExisting` false (a new file), a file that appeared at that name meanwhile is
    /// never overwritten: the result is `.fileExists`.
    private func coordinatedWrite(_ text: String, to url: URL, replaceExisting: Bool) -> WriteResult {
        var coordinationError: NSError?
        var writeError: Error?
        let writer = self.writer
        NSFileCoordinator(filePresenter: watcher)
            .coordinate(writingItemAt: url, options: replaceExisting ? .forReplacing : [], error: &coordinationError) { writeURL in
                do {
                    try writer.write(MarkdownFileCodec.encode(text), to: writeURL, replaceExisting: replaceExisting)
                } catch {
                    writeError = error
                }
            }
        if !replaceExisting, let error = writeError as? CocoaError, error.code == .fileWriteFileExists {
            return .fileExists
        }
        if let error = coordinationError ?? writeError {
            log.error("Autosave could not write \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        return .written
    }

    /// A coordinated rename, announced to other presenters with `item(at:willMoveTo:)` and
    /// `item(at:didMoveTo:)`.
    private func coordinatedMove(from source: URL, to destination: URL) -> Bool {
        let coordinator = NSFileCoordinator(filePresenter: watcher)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError {
            log.error("Autosave could not rename \(source.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// The file names in `folder`, with an iCloud placeholder counted under its real name.
    private static func existingNames(in folder: URL) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(entries.compactMap(FileListModel.displayName(of:)))
    }
}

/// Begins and ends the background-task assertion around the background flush. `UIApplication`
/// is the real one; tests record the calls instead.
@MainActor
protocol BackgroundTaskAsserting {
    func beginAssertion(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func endAssertion(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTaskAsserting {
    func beginAssertion(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expiration() } }
    }

    func endAssertion(_ identifier: UIBackgroundTaskIdentifier) {
        endBackgroundTask(identifier)
    }
}

/// Ends a background-task assertion exactly once, whether the flush finishes or time runs out.
@MainActor
private final class BackgroundAssertion {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end(using tasks: any BackgroundTaskAsserting) {
        guard identifier != .invalid else { return }
        tasks.endAssertion(identifier)
        identifier = .invalid
    }
}

/// Writes a document's bytes inside the coordinated save. The real one writes to disk; tests
/// inject failures and last-moment collisions.
protocol DocumentFileWriting: Sendable {
    /// Writes `data` to `url`. With `replaceExisting` false, throws
    /// `CocoaError(.fileWriteFileExists)` instead of overwriting a file already there.
    func write(_ data: Data, to url: URL, replaceExisting: Bool) throws
}

struct FileSystemDocumentWriter: DocumentFileWriting {
    func write(_ data: Data, to url: URL, replaceExisting: Bool) throws {
        // `.withoutOverwriting` cannot be combined with `.atomic`; it creates the file
        // exclusively, so a file that appeared at the last moment is never replaced.
        try data.write(to: url, options: replaceExisting ? .atomic : .withoutOverwriting)
    }
}

/// Where an iCloud file stands locally.
enum UbiquitousDownloadState: Equatable, Sendable {
    /// Not an iCloud item, or downloaded and current: read it.
    case current
    /// A full local copy exists but a newer version is in iCloud (or iCloud can't be reached to
    /// tell): read the local copy; the download brings the current version as a reload.
    case localCopyNotCurrent
    /// No local copy yet (only a `.Name.md.icloud` placeholder): download before reading.
    case notDownloaded
}

/// Where an iCloud file stands, and starting its download. The real one asks the file system;
/// tests inject a fake.
protocol UbiquitousItemAccessing: Sendable {
    func downloadState(_ url: URL) -> UbiquitousDownloadState
    func startDownloading(_ url: URL) throws
}

struct LiveUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path),
           !FileManager.default.fileExists(atPath: url.path) {
            return .notDownloaded
        }
        // A fresh URL value each time: `URL` caches resource values per instance.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus
        else { return .current }
        switch status {
        case .current: return .current
        case .downloaded: return .localCopyNotCurrent
        default:
            return FileManager.default.fileExists(atPath: url.path) ? .localCopyNotCurrent : .notDownloaded
        }
    }

    func startDownloading(_ url: URL) throws {
        let downloader: any UbiquitousItemDownloader = FileManager.default
        try downloader.startDownloadingUbiquitousItem(at: url)
    }
}
