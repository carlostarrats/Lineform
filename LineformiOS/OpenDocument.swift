import Foundation
import LineformCore
import Observation

/// The one document the iPhone app has open: its file (nil for a new document that has no text
/// yet), its text, and the live-reload watcher on that file.
///
/// Reads go through `NSFileCoordinator` and `MarkdownFileCodec`, so a file keeps its bytes (a
/// leading BOM, CRLF line endings). Live reload follows `DocumentReloadPolicy`: an external change
/// replaces the text only while the text still equals `lastSyncedText`, so in-memory edits that
/// disk does not have yet are never overwritten.
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
    private(set) var isNamedFromFirstLine = true

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

    /// Resolves the save folder off the main thread and makes sure it exists. Only the first call
    /// does anything.
    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true
        let provider = folderProvider
        saveFolder = await Task.detached {
            let folder = provider()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }.value
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

        stopWatching()
        releaseSecurityScope()
        if didAccess { securityScopedURL = url }

        self.url = url
        text = diskText
        lastSyncedText = diskText
        isNamedFromFirstLine = false
        startWatching(url)
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
        startWatching(newURL)
    }

    private func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Disk

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
