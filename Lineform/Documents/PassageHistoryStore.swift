import Foundation

/// Persistence for per-document passage history. Failure-tolerant by contract: a missing or
/// corrupt file loads as empty and no method throws to the caller. Thread-safe by contract:
/// `prune` runs on a background queue while the main thread loads and saves.
protocol PassageHistoryPersisting: AnyObject {
    func load(for url: URL) -> DocumentHistory
    func save(_ history: DocumentHistory, for url: URL)
    func retarget(from old: URL, to new: URL)
    /// A folder was renamed or moved: every stored document under `oldDir` (at any depth) follows,
    /// to the same relative path under `newDir`.
    func retargetDirectory(from oldDir: URL, to newDir: URL)
    func prune(now: Date)
    func clearAll()
}

/// Keeps nothing. Used by tests and by untitled documents (no file to key history to).
final class NullPassageHistoryStore: PassageHistoryPersisting {
    func load(for url: URL) -> DocumentHistory { DocumentHistory(passages: []) }
    func save(_ history: DocumentHistory, for url: URL) {}
    func retarget(from old: URL, to new: URL) {}
    func retargetDirectory(from oldDir: URL, to newDir: URL) {}
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
    private let isConfirmedMissing: (URL) -> Bool
    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// `isConfirmedMissing` must return true ONLY on positive evidence the file is gone; the
    /// default is `confirmedMissing(_:)`.
    init(directory: URL, isConfirmedMissing: @escaping (URL) -> Bool = FilePassageHistoryStore.confirmedMissing) {
        self.directory = directory
        self.isConfirmedMissing = isConfirmedMissing
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
        // 1.8.0 stored every Add to History twice (a frozen copy plus an identical live version),
        // and a one-version passage on disk is a History session that never ended.
        return DocumentHistoryEngine.preparedForLoad(readHistory(entry.id))
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

    func retargetDirectory(from oldDir: URL, to newDir: URL) {
        lock.lock(); defer { lock.unlock() }
        let oldPrefix = FileIdentity.key(for: oldDir) + "/"
        guard FileIdentity.key(for: newDir) + "/" != oldPrefix else { return }
        var index = readIndex()
        // Path-COMPONENT prefix: "/a/b/" never matches "/a/bc/x.md".
        let moving = index.indices.filter { index[$0].pathKey.hasPrefix(oldPrefix) }
        guard !moving.isEmpty else { return }
        var doomed = Set<UUID>()
        for i in moving {
            let relative = String(index[i].pathKey.dropFirst(oldPrefix.count))
            let newURL = newDir.appendingPathComponent(relative)
            let newKey = FileIdentity.key(for: newURL)
            // The destination's own history (if any) is replaced by the moved file's.
            for j in index.indices where j != i && index[j].pathKey == newKey && !moving.contains(j) {
                doomed.insert(index[j].id)
            }
            index[i].pathKey = newKey
            index[i].bookmark = Self.bookmark(for: newURL)
        }
        for id in doomed { removeHistoryFile(id) }
        index.removeAll { doomed.contains($0.id) }
        writeIndex(index)
    }

    /// Drops history for files KNOWN to be deleted and passages untouched for 30 days.
    ///
    /// Deletion needs positive evidence: the bookmark resolves into the Trash, or the file's
    /// folder can be listed and the file is not in it (`isConfirmedMissing`). An unplugged drive,
    /// an unmounted network volume or a folder the sandbox cannot read is not evidence — that
    /// history stays and the 30-day rule cleans it up. Bookmarks resolve without mounting or UI.
    ///
    /// The slow part (resolving each bookmark, checking each folder) runs WITHOUT the lock, so a
    /// `load` or `save` on the main thread never waits behind it; the decisions are then applied
    /// under the lock to the index as it is at that moment, skipping entries changed meanwhile.
    func prune(now: Date) {
        lock.lock()
        // Nothing stored yet: write nothing either (not even an empty index).
        guard fileManager.fileExists(atPath: indexURL.path) else { lock.unlock(); return }
        let snapshot = readIndex()
        lock.unlock()

        enum Fate { case deleted, moved(pathKey: String, bookmark: Data?), unchanged }
        var fates: [UUID: (pathKey: String, fate: Fate)] = [:]
        for entry in snapshot {
            let fate: Fate
            if let resolved = Self.resolve(entry.bookmark) {
                if Self.isTrashed(resolved) {
                    // A bookmark follows a file into the Trash; a trashed file is a deleted file.
                    fate = .deleted
                } else {
                    let key = FileIdentity.key(for: resolved)
                    fate = key == entry.pathKey ? .unchanged : .moved(pathKey: key, bookmark: Self.bookmark(for: resolved))
                }
            } else if isConfirmedMissing(URL(fileURLWithPath: entry.pathKey)) {
                fate = .deleted
            } else {
                fate = .unchanged
            }
            fates[entry.id] = (entry.pathKey, fate)
        }

        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: indexURL.path) else { return }  // cleared meanwhile
        let cutoff = now.addingTimeInterval(-Self.staleInterval)
        var kept: [IndexEntry] = []
        for var entry in readIndex() {
            // Only an entry still exactly as it was checked takes the decision.
            if let decided = fates[entry.id], decided.pathKey == entry.pathKey {
                switch decided.fate {
                case .deleted:
                    removeHistoryFile(entry.id)
                    continue
                case let .moved(pathKey, bookmark):
                    entry.pathKey = pathKey
                    entry.bookmark = bookmark
                case .unchanged:
                    break
                }
            }
            var history = readHistory(entry.id)
            let fresh = history.passages.filter { $0.lastTouched >= cutoff }
            if fresh.isEmpty {
                removeHistoryFile(entry.id)
                continue
            }
            if let clash = kept.firstIndex(where: { $0.pathKey == entry.pathKey }) {
                // Two entries now resolve to one file (a move followed by a save at the new path):
                // keep whichever was touched more recently, never the stale one.
                let keptNewest = Self.newestTouch(readHistory(kept[clash].id))
                if Self.newestTouch(DocumentHistory(passages: fresh)) > keptNewest {
                    removeHistoryFile(kept[clash].id)
                    kept.remove(at: clash)
                } else {
                    removeHistoryFile(entry.id)
                    continue
                }
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

    private static func newestTouch(_ history: DocumentHistory) -> Date {
        history.passages.map(\.lastTouched).max() ?? .distantPast
    }

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

    private static func isTrashed(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        if (try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: .allDomainsMask, toItemAt: url)) != nil,
           relationship == .contains {
            return true
        }
        return url.pathComponents.contains(".Trash")
    }

    /// Never mounts a volume or shows UI: an unreachable drive simply fails to resolve.
    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Positive evidence that `url` is gone: its folder can be LISTED (so its volume is mounted
    /// and readable) and the file is neither in that listing nor present. A folder that cannot be
    /// listed — unplugged drive, unmounted network volume, outside the sandbox — proves nothing.
    static func confirmedMissing(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
        let name = url.lastPathComponent
        if names.contains(where: { $0.compare(name, options: [.caseInsensitive]) == .orderedSame }) { return false }
        return !fileManager.fileExists(atPath: url.path)
    }
}
