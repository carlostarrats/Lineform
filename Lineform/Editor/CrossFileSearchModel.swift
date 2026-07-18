import Foundation

/// Which universe the toolbar search field is searching. `.thisFile` is the settled
/// in-document behavior; `.allFiles` drives the cross-file results page.
enum EditorSearchScope: Hashable {
    case thisFile
    case allFiles
}

/// Reads one candidate file's text for cross-file search, or nil to skip it.
/// Abstracted (the UbiquitousItemDownloader pattern) so tests use an in-memory corpus.
protocol CrossFileSearchFileReading: Sendable {
    func readSearchableText(at url: URL) -> String?
}

/// Production reader. Skips: iCloud-evicted (dataless) files — searching them would
/// force-download the container; files over `maximumByteCount` (1 MB — far beyond any
/// real Markdown document) so one giant stray file can't stall a scan; anything
/// unreadable or non-UTF-8.
struct CrossFileSearchFileReader: CrossFileSearchFileReading {
    static let maximumByteCount = 1_048_576

    func readSearchableText(at url: URL) -> String? {
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maximumByteCount else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Debounced, cancellable, latest-wins orchestration for the All Files scope: reads each
/// candidate file off the main thread, matches via CrossFileSearchResolver, and publishes
/// ranked results on the main actor. Owns no watcher and touches no view — constructed by
/// EditorContainerView, reset whenever the scope leaves `.allFiles` or the document swaps.
@MainActor
final class CrossFileSearchModel: ObservableObject {
    @Published private(set) var results: [CrossFileSearchResult] = []
    @Published private(set) var isSearching = false

    private let reader: CrossFileSearchFileReading
    private let debounceInterval: TimeInterval
    private var generation = 0
    private var pendingTask: Task<Void, Never>?

    init(reader: CrossFileSearchFileReading = CrossFileSearchFileReader(), debounceInterval: TimeInterval = 0.3) {
        self.reader = reader
        self.debounceInterval = debounceInterval
    }

    /// Latest-wins (the ICloudSettingViewModel generation-guard pattern): each call bumps
    /// the generation and cancels the prior task; a stale task re-checks before publishing.
    /// Returns the search task so tests can await it; nil when the query is empty.
    @discardableResult
    func search(query: String, entries: [QuickOpenEntry]) -> Task<Void, Never>? {
        generation += 1
        let expected = generation
        pendingTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
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
            let found = await Task.detached(priority: .userInitiated) { () -> [CrossFileSearchResult] in
                var collected: [CrossFileSearchResult] = []
                for entry in entries {
                    guard !Task.isCancelled else { return collected }
                    guard let text = reader.readSearchableText(at: entry.url) else { continue }
                    if let result = CrossFileSearchResolver.result(for: entry, text: text, query: trimmed) {
                        collected.append(result)
                    }
                }
                return CrossFileSearchResolver.ranked(collected)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard self.generation == expected else { return }
            self.results = found
            self.isSearching = false
        }
        pendingTask = task
        return task
    }

    func reset() {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        results = []
        isSearching = false
    }
}
