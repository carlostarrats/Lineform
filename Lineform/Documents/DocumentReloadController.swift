import AppKit
import Foundation

/// The text + modification date to apply when a live reload fires.
struct ReloadResult: Equatable {
    let text: String
    let modificationDate: Date?
}

/// Abstracts the coordinated disk read so the controller is testable without real files.
/// `Sendable` so the reader can be handed to the background read queue.
protocol DocumentDiskReading: Sendable {
    func readText(at url: URL) -> String?
    func modificationDate(at url: URL) -> Date?
}

/// Real disk reader: sandbox-safe coordinated read + UTF-8 decode.
struct FileSystemDiskReader: DocumentDiskReading {
    func readText(at url: URL) -> String? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var text: String?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                // Same decode pair as `LineformDocument.init(markdownData:)`: validate with the
                // failable initializer, decode with `String(decoding:as:)` so a leading U+FEFF
                // survives. If the two disagreed, a BOM'd file would compare unequal to its own
                // in-memory text and reload on every save.
                text = String(data: data, encoding: .utf8) == nil
                    ? nil
                    : String(decoding: data, as: UTF8.self)
            }
        }
        return text
    }

    func modificationDate(at url: URL) -> Date? {
        LineformDocument.modificationDate(at: url)
    }
}

/// Owns the file watcher + debounce, decides via `DocumentReloadPolicy`, and publishes a
/// `ReloadResult` the view applies. Never mutates the document itself.
@MainActor
final class DocumentReloadController: ObservableObject {
    @Published private(set) var lastReload: ReloadResult?

    /// The current in-memory text, kept up to date by the view; used for the disk-vs-memory
    /// comparison that suppresses reloads from the app's own saves.
    var currentText: String = ""

    /// The in-memory text as of the last moment memory equalled disk (open / our own save /
    /// prior reload). The reload gate compares against this baseline rather than the
    /// framework's asynchronously-updated dirty flag.
    var lastSyncedText: String = ""

    /// A `FileDocument` write callback only proves that AppKit obtained a serialized wrapper;
    /// the later safe write can still fail. Keep the serialized bytes as a candidate and count
    /// review engagement only when the file presenter reads those exact bytes back from disk.
    var onConfirmedSourceWrite: (() -> Void)?
    private var pendingSourceWrite: (text: String, expiresAt: Date)?

    /// True while a native Writing Tools session is rewriting the text view. Binding writes
    /// are deferred during a session, so the dirty gate can't see the in-progress edits; any
    /// external change is deferred until the session ends (then reconciled once).
    var isWritingToolsSessionActive = false {
        didSet {
            if oldValue && !isWritingToolsSessionActive { fileDidChange() }
        }
    }

    private let diskReader: DocumentDiskReading
    private let debounceInterval: TimeInterval
    private let readQueue = DispatchQueue(label: "com.lineform.document-reload-read", qos: .userInitiated)
    private var url: URL?
    private var watcher: DocumentFileWatcher?
    private var debounceWorkItem: DispatchWorkItem?
    /// Modification date as of the last applied disk snapshot: duplicate presenter
    /// notifications for an already-applied write (and the no-change reconciles fired by
    /// `register`/Writing-Tools-end) are dismissed with a stat instead of a full read.
    private var lastSeenModificationDate: Date?

    init(
        diskReader: DocumentDiskReading = FileSystemDiskReader(),
        debounceInterval: TimeInterval = DocumentReloadPolicy.debounceInterval
    ) {
        self.diskReader = diskReader
        self.debounceInterval = debounceInterval
    }

    /// Point the controller at the current document's URL and reset the synced baseline
    /// (callers invoke this only at moments where memory equals disk: open, swap, reload).
    /// Re-registers the file watcher when the URL changes. A nil URL stops watching
    /// (untitled doc).
    func update(url newURL: URL?, syncedText: String) {
        currentText = syncedText
        lastSyncedText = syncedText
        startWatching(newURL)
    }

    /// Idempotent registration for view (re)appearance. A new URL is treated like `update`
    /// (open/swap are memory==disk moments). The same URL after a `stop()` re-adds the
    /// presenter with baselines preserved — re-appearing mid-session must not bless unsaved
    /// edits as synced — and reconciles once in case the file changed while unwatched.
    func register(url newURL: URL?, syncedText: String) {
        if newURL != url {
            update(url: newURL, syncedText: syncedText)
        } else if newURL != nil, watcher == nil {
            startWatching(newURL, force: true)
            fileDidChange()
        }
    }

    /// Re-point the watcher after an in-app rename/move of the watched file. Baselines are
    /// deliberately preserved — a rename is not a memory==disk moment, and unsaved edits
    /// must never be blessed as synced (the same rule the presenter's own move handling
    /// follows). `register` would reset the baseline for a new URL; this must not.
    func noteMoved(to newURL: URL?) {
        startWatching(newURL)
    }

    /// Record a completed save: the baseline becomes exactly the text that was written to
    /// disk — NOT the live text, which may already contain keystrokes typed after the save
    /// snapshot — and the watcher re-points if the save created or changed the file URL
    /// (first save of an untitled document, Save As).
    func noteSaved(url newURL: URL?, savedText: String) {
        // A serialization that reproduces the existing baseline is not meaningful engagement,
        // and accepting it would let a failed no-op save "confirm" against unchanged disk bytes.
        pendingSourceWrite = savedText == lastSyncedText
            ? nil
            : (text: savedText, expiresAt: Date().addingTimeInterval(30))
        lastSyncedText = savedText
        startWatching(newURL)
        // A first Save can finish before its presenter is installed. Read back only for
        // confirmation here — routing this through the reload policy could apply the OLD disk
        // snapshot while AppKit's atomic safe write is still in flight.
        confirmPendingSourceWriteFromDisk()
    }

    /// Explicit NSDocument completion callbacks already know the safe write succeeded. Cancel the
    /// presenter fallback so one write does not advance the quiet-period token twice.
    func discardPendingSourceWriteConfirmation() {
        pendingSourceWrite = nil
    }

    private func confirmPendingSourceWriteFromDisk() {
        guard pendingSourceWrite != nil, let url, watcher != nil else { return }
        let reader = diskReader
        readQueue.async { [weak self] in
            let diskText = reader.readText(at: url)
            DispatchQueue.main.async {
                guard let self,
                      self.url == url,
                      let diskText,
                      let pending = self.pendingSourceWrite,
                      Date() <= pending.expiresAt,
                      diskText == pending.text
                else { return }
                self.pendingSourceWrite = nil
                self.onConfirmedSourceWrite?()
            }
        }
    }

    /// Ensure the presenter watches `newURL`. Baselines are left untouched; `force` re-adds
    /// a presenter for the same URL after `stop()`.
    private func startWatching(_ newURL: URL?, force: Bool = false) {
        guard force || newURL != url else { return }
        stop()
        url = newURL
        lastSeenModificationDate = nil
        guard let newURL else { return }
        let watcher = DocumentFileWatcher(url: newURL)
        // Both callbacks verify the firing watcher is still the installed one, so events from
        // a replaced or stopped presenter (stop() / URL change racing an in-flight event)
        // can't act on the controller.
        watcher.onChange = { [weak self, weak watcher] in
            Task { @MainActor in
                guard let self, let watcher, self.watcher === watcher else { return }
                self.fileDidChange()
            }
        }
        watcher.onMove = { [weak self, weak watcher] movedURL in
            // Finder rename: the presenter's URL is immutable, so re-create it at the
            // new location (baselines preserved). Without this the controller would keep
            // watching the old path and could reload an unrelated file created there.
            Task { @MainActor in
                guard let self, let watcher, self.watcher === watcher else { return }
                self.startWatching(movedURL)
            }
        }
        self.watcher = watcher
        NSFileCoordinator.addFilePresenter(watcher)
    }

    /// Presenter entry point: schedule a trailing-debounced reload.
    func fileDidChange() {
        debounceWorkItem?.cancel()
        guard debounceInterval > 0 else { reloadFromDisk(); return }
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Read the changed file OFF the main thread, then evaluate + publish back on the main
    /// thread. The read must not block the main runloop (large or dataless-iCloud files).
    /// A stat-only pre-check skips the full read when the modification date hasn't moved
    /// since the last applied snapshot (duplicate notifications, no-change reconciles).
    func reloadFromDisk() {
        guard let url, watcher != nil, !isWritingToolsSessionActive else { return }
        let reader = diskReader
        let lastSeen = lastSeenModificationDate
        readQueue.async { [weak self] in
            let modificationDate = reader.modificationDate(at: url)
            if let modificationDate, let lastSeen, modificationDate == lastSeen { return }
            let diskText = reader.readText(at: url)
            DispatchQueue.main.async {
                self?.applyDiskSnapshot(url: url, diskText: diskText, modificationDate: modificationDate)
            }
        }
    }

    /// Decide against the current baseline and publish a `ReloadResult` on `.reload`.
    /// Main-actor and side-effect-scoped so it is unit-testable synchronously.
    func applyDiskSnapshot(url snapshotURL: URL, diskText: String?, modificationDate: Date?) {
        guard !isWritingToolsSessionActive, snapshotURL == url, let diskText else { return }
        if let pendingSourceWrite {
            if Date() > pendingSourceWrite.expiresAt {
                self.pendingSourceWrite = nil
            } else if diskText == pendingSourceWrite.text {
                self.pendingSourceWrite = nil
                onConfirmedSourceWrite?()
            }
        }
        switch DocumentReloadPolicy.decide(diskText: diskText, currentText: currentText, lastSyncedText: lastSyncedText) {
        case .reload:
            lastSeenModificationDate = modificationDate
            lastSyncedText = diskText
            lastReload = ReloadResult(text: diskText, modificationDate: modificationDate)
        case .ignoreUnchanged:
            lastSeenModificationDate = modificationDate
        case .ignoreDirty:
            // Deliberately NOT recorded: if the user later undoes back to the baseline, a
            // subsequent event for this same modification date must still take the full read.
            break
        }
    }

    /// Reset the published value after the view has applied a reload.
    func clearLastReload() {
        lastReload = nil
    }

    /// Deregister the presenter and cancel any pending reload. Called from the view's
    /// `onDisappear` and whenever the watched URL changes. (A nonisolated `deinit` cannot
    /// safely touch the non-Sendable watcher under Swift 6, so removal is driven explicitly
    /// through this method; the window-close `onDisappear` covers the normal lifetime.)
    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let watcher { NSFileCoordinator.removeFilePresenter(watcher) }
        watcher = nil
        // A Writing Tools session cannot outlive its text view; if the view goes away
        // mid-session the end callback may never fire, so don't stay suspended forever.
        // (Setting the flag with no watcher installed makes the didSet re-kick a no-op.)
        isWritingToolsSessionActive = false
    }
}

/// A minimal NSFilePresenter that forwards content changes and moves to the controller.
/// Deletes are left to the framework NSDocument. Callbacks are assigned after init so they
/// can capture the watcher itself for identity checks.
final class DocumentFileWatcher: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    var onChange: (() -> Void)?
    var onMove: ((URL) -> Void)?

    init(url: URL) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
    }

    func presentedItemDidChange() { onChange?() }

    func presentedItemDidMove(to newURL: URL) { onMove?(newURL) }
}
