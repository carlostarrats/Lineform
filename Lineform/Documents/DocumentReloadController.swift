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
                text = String(data: data, encoding: .utf8)
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

    private let diskReader: DocumentDiskReading
    private let debounceInterval: TimeInterval
    private let readQueue = DispatchQueue(label: "com.lineform.document-reload-read", qos: .userInitiated)
    private var url: URL?
    private var watcher: DocumentFileWatcher?
    private var debounceWorkItem: DispatchWorkItem?

    init(
        diskReader: DocumentDiskReading = FileSystemDiskReader(),
        debounceInterval: TimeInterval = DocumentReloadPolicy.debounceInterval
    ) {
        self.diskReader = diskReader
        self.debounceInterval = debounceInterval
    }

    /// Point the controller at the current document's URL and reset the synced baseline
    /// (callers invoke this only at moments where memory equals disk: open, save, swap,
    /// reload). Re-registers the file watcher when the URL changes. A nil URL stops watching
    /// (untitled doc).
    func update(url newURL: URL?, syncedText: String) {
        currentText = syncedText
        lastSyncedText = syncedText
        guard newURL != url else { return }
        stop()
        url = newURL
        guard let newURL else { return }
        let watcher = DocumentFileWatcher(url: newURL) { [weak self] in
            Task { @MainActor in self?.fileDidChange() }
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
    func reloadFromDisk() {
        guard let url else { return }
        let reader = diskReader
        readQueue.async { [weak self] in
            let diskText = reader.readText(at: url)
            let modificationDate = reader.modificationDate(at: url)
            DispatchQueue.main.async {
                self?.applyDiskSnapshot(url: url, diskText: diskText, modificationDate: modificationDate)
            }
        }
    }

    /// Decide against the current baseline and publish a `ReloadResult` on `.reload`.
    /// Main-actor and side-effect-scoped so it is unit-testable synchronously.
    func applyDiskSnapshot(url snapshotURL: URL, diskText: String?, modificationDate: Date?) {
        guard snapshotURL == url, let diskText else { return }
        switch DocumentReloadPolicy.decide(diskText: diskText, currentText: currentText, lastSyncedText: lastSyncedText) {
        case .reload:
            lastSyncedText = diskText
            lastReload = ReloadResult(text: diskText, modificationDate: modificationDate)
        case .ignoreDirty, .ignoreUnchanged:
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
    }
}

/// A minimal NSFilePresenter that forwards content changes to the controller. Moves/deletes
/// are left to the framework NSDocument; the controller re-points via `update` when the URL
/// changes, so we only need to signal a change here.
final class DocumentFileWatcher: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.onChange = onChange
    }

    func presentedItemDidChange() { onChange() }
}
