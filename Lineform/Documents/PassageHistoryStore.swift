import Foundation

/// Persistence for per-document passage history. Failure-tolerant by contract: a missing or
/// corrupt file loads as empty and no method throws to the caller.
protocol PassageHistoryPersisting: AnyObject {
    func load(for url: URL) -> DocumentHistory
    func save(_ history: DocumentHistory, for url: URL)
    func retarget(from old: URL, to new: URL)
    func prune(now: Date)
    func clearAll()
}

/// Keeps nothing. Used by tests and by untitled documents (no file to key history to).
final class NullPassageHistoryStore: PassageHistoryPersisting {
    func load(for url: URL) -> DocumentHistory { DocumentHistory(passages: []) }
    func save(_ history: DocumentHistory, for url: URL) {}
    func retarget(from old: URL, to new: URL) {}
    func prune(now: Date) {}
    func clearAll() {}
}

/// Stores history as JSON under Application Support: `index.json` maps each document
/// (`FileIdentity.key`, plus a bookmark so a Finder move made while Lineform was closed can be
/// followed) to a `<id>.json` holding its `DocumentHistory`. Nothing is stored for a document
/// with no history.
final class FilePassageHistoryStore: PassageHistoryPersisting {
    /// Passages untouched for this long are dropped by `prune`.
    static let staleInterval: TimeInterval = 30 * 24 * 60 * 60

    private struct IndexEntry: Codable, Equatable {
        var id: UUID
        var pathKey: String
        var bookmark: Data?
    }

    private let directory: URL
    private let fileExists: (URL) -> Bool
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL, fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.directory = directory
        self.fileExists = fileExists
    }

    static func defaultDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Lineform/History", isDirectory: true)
    }

    // MARK: - PassageHistoryPersisting

    func load(for url: URL) -> DocumentHistory {
        lock.lock(); defer { lock.unlock() }
        let key = FileIdentity.key(for: url)
        guard let entry = readIndex().first(where: { $0.pathKey == key }) else { return Self.empty }
        return readHistory(entry.id)
    }

    func save(_ history: DocumentHistory, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        let key = FileIdentity.key(for: url)
        var index = readIndex()
        let existing = index.firstIndex(where: { $0.pathKey == key })
        if history.isEmpty {
            guard let existing else { return }
            removeHistoryFile(index[existing].id)
            index.remove(at: existing)
            writeIndex(index)
            return
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let id: UUID
        if let existing {
            id = index[existing].id
            // Refresh the bookmark: it is how a move made while the app is closed is followed.
            if let fresh = Self.bookmark(for: url) { index[existing].bookmark = fresh }
        } else {
            id = UUID()
            index.append(IndexEntry(id: id, pathKey: key, bookmark: Self.bookmark(for: url)))
        }
        guard let data = try? Self.encoder.encode(history) else { return }
        do { try data.write(to: historyURL(id), options: .atomic) } catch { return }
        writeIndex(index)
    }

    func retarget(from old: URL, to new: URL) {
        lock.lock(); defer { lock.unlock() }
        let oldKey = FileIdentity.key(for: old)
        let newKey = FileIdentity.key(for: new)
        guard oldKey != newKey else { return }
        var index = readIndex()
        guard index.contains(where: { $0.pathKey == oldKey }) else { return }
        // The destination's own history (if any) is replaced by the moved file's.
        if let clash = index.firstIndex(where: { $0.pathKey == newKey }) {
            removeHistoryFile(index[clash].id)
            index.remove(at: clash)
        }
        guard let moving = index.firstIndex(where: { $0.pathKey == oldKey }) else { return }
        index[moving].pathKey = newKey
        index[moving].bookmark = Self.bookmark(for: new)
        writeIndex(index)
    }

    func prune(now: Date) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Self.staleInterval)
        var kept: [IndexEntry] = []
        for var entry in readIndex() {
            if let resolved = Self.resolve(entry.bookmark) {
                let key = FileIdentity.key(for: resolved)
                if key != entry.pathKey {
                    entry.pathKey = key
                    entry.bookmark = Self.bookmark(for: resolved)
                }
            } else if !fileExists(URL(fileURLWithPath: entry.pathKey)) {
                removeHistoryFile(entry.id)
                continue
            }
            if kept.contains(where: { $0.pathKey == entry.pathKey }) {
                // A move landed on a path that already has history: keep the first, drop this.
                removeHistoryFile(entry.id)
                continue
            }
            var history = readHistory(entry.id)
            let fresh = history.passages.filter { $0.lastTouched >= cutoff }
            if fresh.isEmpty {
                removeHistoryFile(entry.id)
                continue
            }
            if fresh.count != history.passages.count {
                history.passages = fresh
                if let data = try? Self.encoder.encode(history) {
                    try? data.write(to: historyURL(entry.id), options: .atomic)
                }
            }
            kept.append(entry)
        }
        writeIndex(kept)
    }

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Disk

    private static let empty = DocumentHistory(passages: [])

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func historyURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func readIndex() -> [IndexEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? Self.decoder.decode([IndexEntry].self, from: data) else { return [] }
        return index
    }

    private func writeIndex(_ index: [IndexEntry]) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func readHistory(_ id: UUID) -> DocumentHistory {
        guard let data = try? Data(contentsOf: historyURL(id)),
              let history = try? Self.decoder.decode(DocumentHistory.self, from: data) else { return Self.empty }
        return history
    }

    private func removeHistoryFile(_ id: UUID) {
        try? fileManager.removeItem(at: historyURL(id))
    }

    // MARK: - Bookmarks

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
