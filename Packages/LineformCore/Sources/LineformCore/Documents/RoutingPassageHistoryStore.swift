import Foundation

/// This device's name in shared History: `"<platform>-<UUID>"` (`mac-…`, `iphone-…`), made once
/// and kept in `defaults`. It is also the file name of this device's records, so a Mac's and an
/// iPhone's names never match.
public struct HistoryDeviceIdentity {
    static let defaultsKey = "LineformHistoryDeviceID.v1"

    public static func current(platform: String, defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: defaultsKey), stored.hasPrefix(platform + "-") { return stored }
        let made = "\(platform)-\(UUID().uuidString)"
        defaults.set(made, forKey: defaultsKey)
        return made
    }
}

/// Where a document's History lives (plan decision D9).
public enum HistoryLocation: Equatable, Sendable {
    /// This device only: `FilePassageHistoryStore`, unchanged.
    case local
    /// The Lineform iCloud container: `container` holds `Documents/` and `History/`;
    /// `relativePath` is the document's path inside `Documents/`.
    case shared(container: URL, relativePath: String)

    /// Recognised from the URL alone (no container lookup): the first ancestor named
    /// `containerFolderName` whose child is `Documents`, with the document below it. The
    /// `Documents` folder itself, and every other iCloud Drive folder, is `.local`.
    public static func classify(_ url: URL, containerFolderName: String = "iCloud~com~lineform~app") -> HistoryLocation {
        guard url.isFileURL else { return .local }
        let components = url.standardizedFileURL.pathComponents
        for i in components.indices where components[i] == containerFolderName {
            guard i + 1 < components.count, components[i + 1] == "Documents" else { continue }
            let rest = components[(i + 2)...]
            guard !rest.isEmpty else { return .local }
            let container = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...i])), isDirectory: true)
            return .shared(container: container, relativePath: rest.joined(separator: "/"))
        }
        return .local
    }
}

/// The app's History store: each document goes to the shared iCloud store when it is inside the
/// Lineform container's `Documents` folder, and to the unchanged local store otherwise (D5, D6,
/// D9). Existing local History of a shared document moves into iCloud the first time it is loaded,
/// or at the session's prune. Moves across the boundary carry History with the document.
///
/// Only `prune` and `clearAll` (which have no document to classify) look the container up, through
/// `containerProvider`, and only on a background queue: `load` and `save` never do.
///
/// `@unchecked Sendable`: its own state is guarded by `lock`; both stores are thread-safe.
public final class RoutingPassageHistoryStore: PassageHistoryPersisting, @unchecked Sendable {
    let local: FilePassageHistoryStore
    private let device: String
    private let classify: @Sendable (URL) -> HistoryLocation
    private let containerProvider: @Sendable () -> URL?
    private let bookmarkDirectory: URL
    private let makeShared: @Sendable (URL) -> SharedPassageHistoryStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var sharedStores: [String: SharedPassageHistoryStore] = [:]
    /// Set by `clearAll`: every shared store this router vends drops what was touched before it.
    private var clearedFloor: Date?
    private let queue = DispatchQueue(label: "com.lineform.history.shared", qos: .utility)

    private struct BookmarkEntry: Codable, Equatable {
        var path: String
        var bookmark: Data
    }

    public init(local: FilePassageHistoryStore, device: String,
                classify: @escaping @Sendable (URL) -> HistoryLocation = { u in HistoryLocation.classify(u) },
                containerProvider: @escaping @Sendable () -> URL?, bookmarkDirectory: URL,
                makeShared: @escaping @Sendable (URL) -> SharedPassageHistoryStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.local = local
        self.device = device
        self.classify = classify
        self.containerProvider = containerProvider
        self.bookmarkDirectory = bookmarkDirectory
        self.makeShared = makeShared
        self.now = now
        // A closed document moved into the container in Finder: its local History follows it.
        local.onPruneMoved = { [weak self] _, to in self?.migrateLocalEntry(at: to) }
    }

    /// The app's store. Local History stays where 1.8/1.9 keep it; the bookmark sidecar is in its
    /// own folder beside it, so the local format and `clearAll` are unchanged.
    public static func live(platform: String, home: URL, defaults: UserDefaults = .standard) -> RoutingPassageHistoryStore {
        let directory = FilePassageHistoryStore.defaultDirectory(home: home)
        let device = HistoryDeviceIdentity.current(platform: platform, defaults: defaults)
        return RoutingPassageHistoryStore(
            local: FilePassageHistoryStore(directory: directory),
            device: device,
            containerProvider: { FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.lineform.app") },
            bookmarkDirectory: directory.deletingLastPathComponent().appendingPathComponent("HistoryShared", isDirectory: true),
            makeShared: { container in SharedPassageHistoryStore(containerURL: container, device: device) })
    }

    // MARK: - PassageHistoryPersisting

    public func load(for url: URL) -> DocumentHistory {
        guard case let .shared(container, path) = classify(url) else { return local.load(for: url) }
        let store = shared(container)
        // D5a: History this Mac kept locally before the document was shared.
        migrate(localURL: url, into: store, path: path)
        return store.load(relativePath: path)
    }

    public func save(_ history: DocumentHistory, for url: URL) {
        guard case let .shared(container, path) = classify(url) else { return local.save(history, for: url) }
        if shared(container).save(history, relativePath: path), !history.isEmpty { rememberBookmark(for: url) }
    }

    public func noteVersionDeleted(passage: UUID, at index: Int, in history: DocumentHistory, for url: URL) {
        guard case let .shared(container, path) = classify(url) else { return }
        shared(container).noteVersionDeleted(passage: passage, at: index, in: history, relativePath: path)
    }

    /// D6: inside → inside merges at the new key; local → inside carries the local History in;
    /// inside → local saves the merged History locally and deletes the shared folder.
    public func retarget(from old: URL, to new: URL) {
        switch (classify(old), classify(new)) {
        case (.local, .local):
            local.retarget(from: old, to: new)
        case let (.local, .shared(container, path)):
            migrate(localURL: old, into: shared(container), path: path)
            rememberBookmark(for: new)
        case let (.shared(container, path), .local):
            let store = shared(container)
            let history = store.load(relativePath: path)
            if !history.isEmpty { local.save(history, for: new) }
            store.remove(relativePath: path)
            forgetBookmark(for: old)
        case let (.shared(oldContainer, oldPath), .shared(newContainer, newPath)):
            if oldContainer.standardizedFileURL == newContainer.standardizedFileURL {
                shared(oldContainer).move(from: oldPath, to: newPath)
            } else {
                let from = shared(oldContainer)
                if shared(newContainer).merge(from.load(relativePath: oldPath), into: newPath) {
                    from.remove(relativePath: oldPath)
                }
            }
            forgetBookmark(for: old)
            rememberBookmark(for: new)
        }
    }

    public func retargetDirectory(from oldDir: URL, to newDir: URL) {
        switch (classify(oldDir), classify(newDir)) {
        case (.local, .local):
            local.retargetDirectory(from: oldDir, to: newDir)
        case let (.shared(oldContainer, oldPath), .shared(newContainer, newPath))
            where oldContainer.standardizedFileURL == newContainer.standardizedFileURL:
            let store = shared(oldContainer)
            let moving = store.storedRelativePaths().filter { SharedPassageHistoryStore.remainder(of: $0, under: oldPath) != nil }
            store.moveDirectory(from: oldPath, to: newPath)
            for path in moving {
                guard let rest = SharedPassageHistoryStore.remainder(of: path, under: oldPath) else { continue }
                forgetBookmark(for: oldDir.appendingPathComponents(rest))
                rememberBookmark(for: newDir.appendingPathComponents(rest))
            }
        case let (.shared(container, oldPath), _):
            // Out of (or across) the container: each document follows on its own.
            for path in shared(container).storedRelativePaths() {
                guard let rest = SharedPassageHistoryStore.remainder(of: path, under: oldPath) else { continue }
                retarget(from: oldDir.appendingPathComponents(rest), to: newDir.appendingPathComponents(rest))
            }
        case (.local, .shared):
            let oldKey = FileIdentity.key(for: oldDir)
            for stored in local.storedDocumentURLs() {
                let components = stored.standardizedFileURL.pathComponents
                let prefix = URL(fileURLWithPath: oldKey).standardizedFileURL.pathComponents
                guard components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix else { continue }
                retarget(from: stored, to: newDir.appendingPathComponents(Array(components.dropFirst(prefix.count))))
            }
        }
    }

    /// Runs on the controller's background queue, once per session. The local prune (whose bookmark
    /// moves into the container migrate), then every local entry already inside a container (D5b),
    /// then the shared documents' bookmarks (moves made while the app was closed, D6), then the
    /// shared prune (D8).
    public func prune(now date: Date) {
        local.prune(now: date)
        for url in local.storedDocumentURLs() { migrateLocalEntry(at: url) }
        followBookmarks()
        if let container = containerProvider() { shared(container).prune(now: date) }
    }

    /// D7. Local History is removed at once and every shared load from now on drops what was
    /// touched before this moment; the marker and the shared folders are written and deleted on a
    /// background queue, where the container is looked up.
    public func clearAll() {
        local.clearAll()
        let date = now()
        lock.lock()
        clearedFloor = max(clearedFloor ?? date, date)
        let stores = Array(sharedStores.values)
        lock.unlock()
        for store in stores { store.excludeHistory(touchedAtOrBefore: date) }
        CoordinatedFileAccess.remove(bookmarksURL)
        queue.async { [self] in
            guard let container = containerProvider() else { return }
            shared(container).clearAll(at: date)
        }
    }

    /// Waits for `clearAll`'s background work (tests).
    func waitForBackgroundWork() { queue.sync {} }

    // MARK: - Routing

    private func shared(_ container: URL) -> SharedPassageHistoryStore {
        let key = container.standardizedFileURL.path
        lock.lock()
        if let store = sharedStores[key] { lock.unlock(); return store }
        let store = makeShared(container)
        sharedStores[key] = store
        let floor = clearedFloor
        lock.unlock()
        if let floor { store.excludeHistory(touchedAtOrBefore: floor) }
        return store
    }

    /// Moves the local History stored for `localURL` (if any) into the shared document `path`; the
    /// local entry is removed only after the shared write succeeded.
    private func migrate(localURL: URL, into store: SharedPassageHistoryStore, path: String) {
        let key = FileIdentity.key(for: localURL)
        guard local.storedDocumentURLs().contains(where: { $0.path == key }) else { return }
        let history = local.load(for: localURL)
        if history.isEmpty || store.merge(history, into: path) {
            local.remove(for: localURL)
            if !history.isEmpty { rememberBookmark(for: localURL) }
        }
    }

    private func migrateLocalEntry(at url: URL) {
        guard case let .shared(container, path) = classify(url) else { return }
        migrate(localURL: url, into: shared(container), path: path)
    }

    // MARK: - Bookmark sidecar (D6)

    private var bookmarksURL: URL { bookmarkDirectory.appendingPathComponent("bookmarks.json") }

    private func readBookmarks() -> [BookmarkEntry] {
        guard let data = CoordinatedFileAccess.read(bookmarksURL),
              let entries = try? JSONDecoder().decode([BookmarkEntry].self, from: data) else { return [] }
        return entries
    }

    private func writeBookmarks(_ entries: [BookmarkEntry]) {
        if entries.isEmpty { CoordinatedFileAccess.remove(bookmarksURL); return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        CoordinatedFileAccess.write(data, to: bookmarksURL)
    }

    private func rememberBookmark(for url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        var entries = readBookmarks()
        if let i = entries.firstIndex(where: { $0.path == path }) {
            guard entries[i].bookmark != bookmark else { return }
            entries[i].bookmark = bookmark
        } else {
            entries.append(BookmarkEntry(path: path, bookmark: bookmark))
        }
        writeBookmarks(entries)
    }

    private func forgetBookmark(for url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        let entries = readBookmarks()
        let kept = entries.filter { $0.path != path }
        if kept != entries { writeBookmarks(kept) }
    }

    /// A shared document moved while the app was closed: its History follows to wherever the
    /// bookmark now resolves (inside the container, or out of it). A trashed or unresolvable
    /// document is left to the shared prune's positive-evidence rule.
    private func followBookmarks() {
        lock.lock()
        let entries = readBookmarks()
        lock.unlock()
        for entry in entries {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let old = URL(fileURLWithPath: entry.path)
            guard resolved.standardizedFileURL.path != entry.path, !resolved.pathComponents.contains(".Trash") else { continue }
            if FileIdentity.key(for: resolved) == FileIdentity.key(for: old) { continue }
            retarget(from: old, to: resolved)
        }
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { $0.appendingPathComponent($1) }
    }
}
