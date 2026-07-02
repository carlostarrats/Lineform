import AppKit
import Foundation

/// The text + modification date to apply when a live reload fires.
struct ReloadResult: Equatable {
    let text: String
    let modificationDate: Date?
}

/// Abstracts "does the open document have unsaved edits?" so the controller is testable
/// without a real window/NSDocument. Main-actor isolated because the real implementation
/// reads main-actor NSWindow/NSDocument state.
@MainActor
protocol DocumentDirtyProviding: AnyObject {
    var isDocumentEdited: Bool { get }
}

/// Real dirty-state provider: reads the framework NSDocument reachable from the window.
@MainActor
final class WindowDocumentDirtyProvider: DocumentDirtyProviding {
    private weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }
    var isDocumentEdited: Bool { window?.windowController?.document?.isDocumentEdited ?? false }
}

/// Abstracts the coordinated disk read so the controller is testable without real files.
protocol DocumentDiskReading {
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

    private let diskReader: DocumentDiskReading
    private let debounceInterval: TimeInterval
    private var url: URL?
    // Held strongly: the provider is created inline by the caller and nothing else retains it.
    // No cycle — the real provider holds its NSWindow weakly.
    private var dirtyProvider: DocumentDirtyProviding?
    private var watcher: DocumentFileWatcher?
    private var debounceWorkItem: DispatchWorkItem?

    init(
        diskReader: DocumentDiskReading = FileSystemDiskReader(),
        debounceInterval: TimeInterval = DocumentReloadPolicy.debounceInterval
    ) {
        self.diskReader = diskReader
        self.debounceInterval = debounceInterval
    }

    /// Point the controller at the current document's URL + dirty provider. Re-registers the
    /// file watcher when the URL changes. Passing a nil URL stops watching (untitled doc).
    func update(url newURL: URL?, dirtyProvider: DocumentDirtyProviding?) {
        self.dirtyProvider = dirtyProvider
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

    /// Presenter entry point: schedule a trailing-debounced evaluation.
    func fileDidChange() {
        debounceWorkItem?.cancel()
        guard debounceInterval > 0 else { evaluate(); return }
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Run the reload decision and publish a result on `.reload`.
    func evaluate() {
        guard let url else { return }
        guard let diskText = diskReader.readText(at: url) else { return }
        let isDirty = dirtyProvider?.isDocumentEdited ?? false
        switch DocumentReloadPolicy.decide(isDocumentEdited: isDirty, diskText: diskText, currentText: currentText) {
        case .reload:
            lastReload = ReloadResult(text: diskText, modificationDate: diskReader.modificationDate(at: url))
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
