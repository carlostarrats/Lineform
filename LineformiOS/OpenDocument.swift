import Foundation
import LineformCore
import Observation
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
/// When the open file is deleted elsewhere (Files, another device), the text stays on screen but
/// the document lets go of that path: it becomes a new document again, so the next change saves
/// it under a new name from its first line, and nothing writes the deleted file back.
@MainActor
@Observable
final class OpenDocument {
    enum OpenError: Error, Equatable {
        /// The file could not be read, or it is not valid UTF-8 text.
        case unreadable(URL)
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

    /// How long after the last keystroke an autosave runs.
    static let autosaveDelay: Duration = .seconds(1)

    /// Where new documents save. Resolved off the main thread by `prepare`, because the live
    /// folder asks for the iCloud container.
    private(set) var saveFolder: URL?

    @ObservationIgnored private let folderProvider: @Sendable () -> URL
    @ObservationIgnored private let reader: any DocumentDiskReading
    @ObservationIgnored private var watcher: DocumentFileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The URL whose security scope this document holds (a file from outside the app).
    @ObservationIgnored private var securityScopedURL: URL?
    @ObservationIgnored private var isPrepared = false
    private var planner = AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.lineform.app", category: "autosave")

    /// - Parameters:
    ///   - folderProvider: returns the folder new documents save into. It is called off the main
    ///     thread (the live one asks for the iCloud container). Tests pass a temporary folder.
    ///   - reader: the coordinated disk reader live reload uses.
    init(
        folderProvider: @escaping @Sendable () -> URL,
        reader: any DocumentDiskReading = FileSystemDiskReader()
    ) {
        self.folderProvider = folderProvider
        self.reader = reader
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
        let provider = folderProvider
        let folder = await Task.detached {
            let folder = provider()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }.value
        saveFolder = folder

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
            try? open(stored)
        }
        // Text typed before the folder was known has been waiting for it.
        if text != lastSyncedText { scheduleAutosave() }
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
    /// Throws `OpenError.unreadable` when the file cannot be read or is not valid UTF-8; the
    /// current document then stays as it was.
    func open(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        guard let diskText = Self.coordinatedRead(url) else {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw OpenError.unreadable(url)
        }

        // The document being replaced keeps what was typed into it.
        flush()
        stopWatching()
        releaseSecurityScope()
        if didAccess { securityScopedURL = url }

        self.url = url
        text = diskText
        lastSyncedText = diskText
        planner = AutosavePlanner(existingFileName: url.lastPathComponent, isNamedFromFirstLine: false)
        startWatching(url)
    }

    /// Starts a blank Untitled document, after saving whatever the current one has not saved yet.
    /// Like any new document, it creates no file until it has text.
    func newDocument() {
        flush()
        stopWatching()
        releaseSecurityScope()
        url = nil
        text = ""
        lastSyncedText = ""
        planner = AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
    }

    /// Set when `openReportingFailure` could not open a file; the screen shows an alert for it.
    var failedOpenURL: URL?

    /// `open`, for the UI: a file that cannot be opened sets `failedOpenURL` instead of throwing.
    func openReportingFailure(_ url: URL) {
        do {
            try open(url)
        } catch {
            failedOpenURL = url
        }
    }

    // MARK: - Editing

    /// The writer changed the text.
    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        scheduleAutosave()
    }

    // MARK: - Autosave

    /// Saves `autosaveDelay` after the last keystroke.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves now whatever disk does not have yet: creates, writes or renames the file as
    /// `AutosavePlanner` decides. Does nothing when there is nothing to save.
    func flush() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard text != lastSyncedText else { return }
        guard let folder = url?.deletingLastPathComponent() ?? saveFolder else {
            // The save folder is still being resolved; `prepare` saves once it is known.
            return
        }

        let textToSave = text
        let previousPlanner = planner
        switch planner.textChanged(textToSave, existingNames: Self.existingNames(in: folder)) {
        case .none:
            return
        case .create(let fileName):
            let newURL = folder.appendingPathComponent(fileName)
            guard coordinatedWrite(textToSave, to: newURL) else {
                planner = previousPlanner
                return
            }
            url = newURL
            startWatching(newURL)
        case .write:
            guard let url, coordinatedWrite(textToSave, to: url) else { return }
        case .rename(let fileName):
            guard let oldURL = url else { return }
            let newURL = folder.appendingPathComponent(fileName)
            if coordinatedMove(from: oldURL, to: newURL) {
                stopWatching()
                url = newURL
                startWatching(newURL)
            } else {
                // Keep the old name; the text still saves.
                planner = previousPlanner
            }
            guard let url, coordinatedWrite(textToSave, to: url) else { return }
        }
        lastSyncedText = textToSave
    }

    /// `flush`, inside a background-task assertion, for the scene going to the background: the
    /// text must be on disk before iOS may suspend the app.
    func flushForBackground(using tasks: any BackgroundTaskAsserting = UIApplication.shared) {
        let assertion = BackgroundAssertion()
        assertion.identifier = tasks.beginAssertion(name: "Save document") {
            assertion.end(using: tasks)
        }
        flush()
        assertion.end(using: tasks)
    }

    // MARK: - Live reload

    /// Reads the file again and applies `DocumentReloadPolicy.decide`. Returns the outcome, or nil
    /// when there is no file or it could not be read.
    @discardableResult
    func applyExternalChange() async -> ReloadOutcome? {
        guard let url else { return nil }
        let reader = self.reader
        let diskText = await Task.detached { reader.readText(at: url) }.value
        // The document may have changed while the read was in flight.
        guard self.url == url, let diskText else { return nil }

        let outcome = DocumentReloadPolicy.decide(
            diskText: diskText, currentText: text, lastSyncedText: lastSyncedText
        )
        if outcome == .reload {
            text = diskText
            lastSyncedText = diskText
        }
        return outcome
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

    /// The file was moved or renamed by someone else (Files, iCloud): keep editing it there.
    private func followMove(to newURL: URL) {
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
        lastSyncedText = text
        planner = AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
    }

    private func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Disk

    /// A coordinated write of `text`'s exact bytes to `url`. This document's own presenter is
    /// passed to the coordinator, so the write is not reported back to it as an external change.
    private func coordinatedWrite(_ text: String, to url: URL) -> Bool {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: watcher)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
                do {
                    try MarkdownFileCodec.encode(text).write(to: writeURL, options: .atomic)
                } catch {
                    writeError = error
                }
            }
        if let error = coordinationError ?? writeError {
            log.error("Autosave could not write \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
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

    /// A coordinated read of `url`, decoded with `MarkdownFileCodec`; nil when the read fails or
    /// the bytes are not UTF-8.
    private static func coordinatedRead(_ url: URL) -> String? {
        var coordinationError: NSError?
        var text: String?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                if let data = try? Data(contentsOf: readURL) {
                    text = MarkdownFileCodec.decode(data)
                }
            }
        return text
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
