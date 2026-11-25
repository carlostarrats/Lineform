import Foundation

/// Which universe the toolbar search field is searching. `.thisFile` is the settled
/// in-document behavior; `.allFiles` drives the cross-file results page.
public enum EditorSearchScope: Hashable {
    case thisFile
    case allFiles
}

/// One candidate file's text for cross-file search, or why there is none.
public enum CrossFileSearchRead: Equatable, Sendable {
    case text(String)
    /// An iCloud file with no local copy (a `.Name.icloud` stub, or dataless): not read, so its
    /// text was not searched. The results say so (`skippedNotDownloaded`).
    case notDownloaded
    /// Too big, unreadable, or not UTF-8: skipped quietly.
    case unreadable
}

/// Reads one candidate file's text for cross-file search, or nil to skip it.
/// Abstracted (the UbiquitousItemDownloader pattern) so tests use an in-memory corpus.
public protocol CrossFileSearchFileReading: Sendable {
    func readSearchableText(at url: URL) -> String?
    /// The text, or why there is none. The default wraps `readSearchableText` (never
    /// `.notDownloaded`).
    func searchableRead(at url: URL) -> CrossFileSearchRead
}

public extension CrossFileSearchFileReading {
    func searchableRead(at url: URL) -> CrossFileSearchRead {
        readSearchableText(at: url).map(CrossFileSearchRead.text) ?? .unreadable
    }
}

/// Production reader. Skips: iCloud files with no local copy (a `.Name.icloud` stub, or
/// dataless) — searching them would force-download the container; files over
/// `maximumByteCount` (1 MB — far beyond any real Markdown document) so one giant stray file
/// can't stall a scan; anything unreadable or non-UTF-8. A `.downloaded` file (a local copy that
/// is not the latest version) IS read: its local copy is on disk and reading it downloads nothing.
public struct CrossFileSearchFileReader: CrossFileSearchFileReading {
    static let maximumByteCount = 1_048_576

    public init() {}

    public func readSearchableText(at url: URL) -> String? {
        if case let .text(text) = searchableRead(at: url) { return text }
        return nil
    }

    public func searchableRead(at url: URL) -> CrossFileSearchRead {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            return fileManager.fileExists(atPath: stub.path) ? .notDownloaded : .unreadable
        }
        // A fresh URL value: `URL` caches resource values per instance.
        let fresh = URL(fileURLWithPath: url.path)
        if let values = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return .notDownloaded
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maximumByteCount,
              let text = String(data: data, encoding: .utf8) else {
            return .unreadable
        }
        return .text(text)
    }
}

/// Debounced, cancellable, latest-wins orchestration for the All Files scope: reads each
/// candidate file off the main thread, matches via CrossFileSearchResolver, and publishes
/// ranked results on the main actor. Owns no watcher and touches no view — constructed by
/// EditorContainerView, reset whenever the scope leaves `.allFiles` or the document swaps.
@MainActor
public final class CrossFileSearchModel: ObservableObject {
    @Published public private(set) var results: [CrossFileSearchResult] = []
    @Published public private(set) var isSearching = false
    /// True when the last search skipped at least one iCloud file that is not downloaded, so its
    /// text was not searched (its name still was).
    @Published public private(set) var skippedNotDownloaded = false

    private let reader: CrossFileSearchFileReading
    private let debounceInterval: TimeInterval
    private var generation = 0
    private var pendingTask: Task<Void, Never>?

    public init(reader: CrossFileSearchFileReading = CrossFileSearchFileReader(), debounceInterval: TimeInterval = 0.3) {
        self.reader = reader
        self.debounceInterval = debounceInterval
    }

    /// Latest-wins (the ICloudSettingViewModel generation-guard pattern): each call bumps
    /// the generation and cancels the prior task; a stale task re-checks before publishing.
    /// Returns the search task so tests can await it; nil when the query is empty.
    @discardableResult
    public func search(query: String, entries: [QuickOpenEntry]) -> Task<Void, Never>? {
        generation += 1
        let expected = generation
        pendingTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            if skippedNotDownloaded { skippedNotDownloaded = false }
            return nil
        }

        isSearching = true
        let reader = reader
        let interval = debounceInterval
        let task = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            let (found, skipped) = await Self.scan(entries: entries, query: trimmed, reader: reader)
            guard let self, !Task.isCancelled else { return }
            guard self.generation == expected else { return }
            self.results = found
            if self.skippedNotDownloaded != skipped { self.skippedNotDownloaded = skipped }
            self.isSearching = false
        }
        pendingTask = task
        return task
    }

    public func reset() {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        results = []
        isSearching = false
        if skippedNotDownloaded { skippedNotDownloaded = false }
    }

    /// Reads and matches each candidate file. `nonisolated` (not `Task.detached`) so this
    /// still runs off the @MainActor — file reads stay off the main thread — but, unlike
    /// `Task.detached`, a `nonisolated` async function DOES inherit the calling task's
    /// cancellation, so `Task.isCancelled` here actually trips when `pendingTask?.cancel()`
    /// fires (a newer search, or `reset()`), stopping the read loop instead of only letting
    /// the generation guard discard an already-completed scan.
    private nonisolated static func scan(
        entries: [QuickOpenEntry],
        query: String,
        reader: CrossFileSearchFileReading
    ) async -> (results: [CrossFileSearchResult], skippedNotDownloaded: Bool) {
        var collected: [CrossFileSearchResult] = []
        var skipped = false
        for entry in entries {
            guard !Task.isCancelled else { return (collected, skipped) }
            // A filename match must remain useful even when an iCloud file is evicted or
            // its contents cannot be read. Content search remains best-effort as before.
            var text: String?
            switch reader.searchableRead(at: entry.url) {
            case let .text(read): text = read
            case .notDownloaded: skipped = true
            case .unreadable: break
            }
            if let result = CrossFileSearchResolver.result(for: entry, text: text, query: query) {
                collected.append(result)
            }
        }
        return (CrossFileSearchResolver.ranked(collected), skipped)
    }
}
