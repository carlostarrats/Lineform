import Foundation

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
/// Shared writes run on the shared store's queue (`SharedPassageHistoryStore`); the bookmark
/// sidecar is written from there too, never on the save path. Only `prune` and `clearAll` (which
/// have no document to classify) look the container up, through `containerProvider`, and only on
/// a background queue — and `prune` only when this device has shared History (a shared store was
/// used this session, or the sidecar exists). `load` and `save` never look it up.
///
/// `@unchecked Sendable`: its own state is guarded by `lock`; both stores are thread-safe.
public final class RoutingPassageHistoryStore: PassageHistoryPersisting, @unchecked Sendable {
    let local: FilePassageHistoryStore
    private let classify: @Sendable (URL) -> HistoryLocation
    private let containerProvider: @Sendable () -> URL?
    private let bookmarkDirectory: URL
    private let makeShared: @Sendable (URL) -> SharedPassageHistoryStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Keyed by `FileIdentity.key(for: container)`, so two spellings of one container
    /// (`/var/mobile` and `/private/var/mobile`, a symlink) share one store and one lock.
    private var sharedStores: [String: SharedPassageHistoryStore] = [:]
    /// Set by `clearAll`: every shared store this router vends drops what was touched before it.
    private var clearedFloor: Date?
    /// The sidecar's paths, read once; a path already there is not bookmarked again.
    private var bookmarkedPaths: Set<String>?
    /// Shared documents whose local History (D5a) was already looked for this session.
    private var migrationChecked: Set<String> = []
    /// Whether the sidecar's unwritten Clear History was read yet, and its date.
    private var pendingClearRead = false
    private var pendingClearDate: Date?
    private let queue = DispatchQueue(label: "com.lineform.history.shared", qos: .utility)

    private struct BookmarkEntry: Codable, Equatable {
        var path: String
        var bookmark: Data
    }

    private struct PendingClear: Codable {
        var clearedAt: Date
    }

    public init(local: FilePassageHistoryStore,
                classify: @escaping @Sendable (URL) -> HistoryLocation = { u in HistoryLocation.classify(u) },
                containerProvider: @escaping @Sendable () -> URL?, bookmarkDirectory: URL,
                makeShared: @escaping @Sendable (URL) -> SharedPassageHistoryStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.local = local
        self.classify = classify
        self.containerProvider = containerProvider
        self.bookmarkDirectory = bookmarkDirectory
        self.makeShared = makeShared
        self.now = now
        // A closed document moved into the container in Finder: its local History follows it.
        local.onPruneMoved = { [weak self] _, to in self?.migrateLocalEntry(at: to) }
    }

    /// The app's store. Local History stays where 1.8/1.9 keep it; the bookmark sidecar is in its
    /// own folder beside it, so the local format and `clearAll` are unchanged. The device name is
    /// read from `deviceIDStorage` (the Keychain) only when a shared document is first used.
    ///
    /// `deviceSalt` (the Mac: a hash of this Mac's hardware UUID) is appended to the name, so a
    /// Keychain carried to another Mac by Migration Assistant or Time Machine still makes a
    /// different name there. Read with the name, at first shared use.
    public static func live(platform: String, home: URL, defaults: UserDefaults = .standard,
                            deviceIDStorage: HistoryDeviceIDStoring = SystemHistoryDeviceIDKeychain(),
                            deviceSalt: @escaping @Sendable () -> String? = { nil }) -> RoutingPassageHistoryStore {
        let directory = FilePassageHistoryStore.defaultDirectory(home: home)
        let device = LazyDeviceName {
            HistoryDeviceIdentity.current(platform: platform, storage: deviceIDStorage, defaults: defaults,
                                          salt: deviceSalt())
        }
        return RoutingPassageHistoryStore(
            local: FilePassageHistoryStore(directory: directory),
            containerProvider: { FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.lineform.app") },
            bookmarkDirectory: directory.deletingLastPathComponent().appendingPathComponent("HistoryShared", isDirectory: true),
            makeShared: { container in SharedPassageHistoryStore(containerURL: container, device: device.value) })
    }

    // MARK: - PassageHistoryPersisting

    public func load(for url: URL) -> DocumentHistory {
        guard case let .shared(container, path) = classify(url) else { return local.load(for: url) }
        let store = shared(container)
        // D5a: History this Mac kept locally before the document was shared.
        if let migrated = migrate(localURL: url, into: store, path: path, bookmarking: url) { return migrated }
        return store.load(relativePath: path)
    }

    public func save(_ history: DocumentHistory, for url: URL) {
        guard case let .shared(container, path) = classify(url) else { return local.save(history, for: url) }
        let store = shared(container)
        guard !history.isEmpty else { return store.save(history, relativePath: path) }
        store.save(history, relativePath: path) { [weak self] written in
            if written { self?.rememberBookmark(for: url) }
        }
    }

    public func noteVersionDeleted(passage: UUID, at index: Int, in history: DocumentHistory, for url: URL) {
        guard case let .shared(container, path) = classify(url) else { return }
        shared(container).noteVersionDeleted(passage: passage, at: index, in: history, relativePath: path)
    }

    /// D6: inside → inside moves every record to the new key; local → inside carries the local
    /// History in; inside → local saves the merged History locally and deletes the shared folder
    /// only once that local copy is written.
    public func retarget(from old: URL, to new: URL) {
        switch (classify(old), classify(new)) {
        case (.local, .local):
            local.retarget(from: old, to: new)
        case let (.local, .shared(container, path)):
            _ = migrate(localURL: old, into: shared(container), path: path, bookmarking: new)
        case let (.shared(container, path), .local):
            // Rare and chosen by the writer: every record is read, downloaded if need be, because
            // the folder is deleted next.
            let store = shared(container)
            let history = store.load(relativePath: path, downloading: true)
            guard local.saveReportingSuccess(history, for: new) else { return }
            store.remove(relativePath: path)
            queue.async { [self] in forgetBookmark(for: old) }
        case let (.shared(oldContainer, oldPath), .shared(newContainer, newPath)):
            if sameContainer(oldContainer, newContainer) {
                shared(oldContainer).move(from: oldPath, to: newPath)
            } else {
                let from = shared(oldContainer)
                shared(newContainer).merge(from.load(relativePath: oldPath, downloading: true), into: newPath) { written in
                    if written { from.remove(relativePath: oldPath) }
                }
            }
            queue.async { [self] in
                forgetBookmark(for: old)
                rememberBookmark(for: new)
            }
        }
    }

    public func retargetDirectory(from oldDir: URL, to newDir: URL) {
        switch (classify(oldDir), classify(newDir)) {
        case (.local, .local):
            local.retargetDirectory(from: oldDir, to: newDir)
        case let (.shared(oldContainer, oldPath), .shared(newContainer, newPath))
            where sameContainer(oldContainer, newContainer):
            shared(oldContainer).moveDirectory(from: oldPath, to: newPath) { [weak self] moves in
                guard let self else { return }
                for move in moves {
                    guard let rest = SharedPassageHistoryStore.remainder(of: move.old, under: oldPath) else { continue }
                    forgetBookmark(for: oldDir.appendingPathComponents(rest))
                    rememberBookmark(for: newDir.appendingPathComponents(rest))
                }
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
    /// shared prune (D8) and the sidecar's own prune. The container is looked up only when this
    /// device has shared History and no shared store was used yet this session.
    public func prune(now date: Date) {
        local.prune(now: date)
        for url in local.storedDocumentURLs() { migrateLocalEntry(at: url) }
        followBookmarks()
        var stores = lock.withLock { Array(sharedStores.values) }
        if stores.isEmpty, hasSidecar, let container = containerProvider() {
            stores = [shared(container)]
        }
        for store in stores { store.prune(now: date) }
        pruneBookmarks()
    }

    /// D7. Local History is removed at once and every shared load from now on drops what was
    /// touched before this moment. On a background queue: the clear date is kept in the sidecar
    /// (so a relaunch before the container is reachable still drops it), then every shared store
    /// used this session and the container's store write their marker and delete their folders.
    /// The kept date is removed once a marker is written; until then every store this device
    /// makes later writes the marker.
    public func clearAll() {
        local.clearAll()
        let date = now()
        let stores = lock.withLock {
            clearedFloor = max(clearedFloor ?? date, date)
            bookmarkedPaths = []
            pendingClearRead = true
            pendingClearDate = max(pendingClearDate ?? date, date)
            return Array(sharedStores.values)
        }
        for store in stores { store.excludeHistory(touchedAtOrBefore: date) }
        queue.async { [self] in
            writePendingClear(date)
            CoordinatedFileAccess.remove(bookmarksURL)
            var targets = stores
            if let container = containerProvider() {
                let store = shared(container)
                if !targets.contains(where: { $0 === store }) { targets.append(store) }
            }
            for store in targets {
                store.clearAll(at: date) { [weak self] written in
                    if written { self?.removePendingClear(upTo: date) }
                }
            }
        }
    }

    /// The router's queued work (bookmarks, Clear History), then every shared store's writes,
    /// each retrying a held-back save once, then whatever their completions queued here.
    public func flushPendingWrites() {
        queue.sync {}
        for store in lock.withLock({ Array(sharedStores.values) }) { store.flushPendingWrites() }
        queue.sync {}
    }

    /// Waits for the router's background work and every shared store's queued writes (tests).
    func waitForBackgroundWork() {
        for _ in 0..<2 {
            queue.sync {}
            for store in lock.withLock({ Array(sharedStores.values) }) { store.waitForBackgroundWork() }
        }
        queue.sync {}
    }

    /// How many shared stores this router made (tests: one per container, however it is spelled).
    var sharedStoreCount: Int { lock.withLock { sharedStores.count } }

    // MARK: - Routing

    private func sameContainer(_ a: URL, _ b: URL) -> Bool {
        FileIdentity.key(for: a) == FileIdentity.key(for: b)
    }

    private func shared(_ container: URL) -> SharedPassageHistoryStore {
        let key = FileIdentity.key(for: container)
        lock.lock()
        if let store = sharedStores[key] { lock.unlock(); return store }
        let store = makeShared(container)
        sharedStores[key] = store
        let floor = clearedFloor
        let readPending = !pendingClearRead
        pendingClearRead = true
        lock.unlock()
        if let floor { store.excludeHistory(touchedAtOrBefore: floor) }
        if readPending, let date = readPendingClear() {
            lock.withLock {
                clearedFloor = max(clearedFloor ?? date, date)
                pendingClearDate = max(pendingClearDate ?? date, date)
            }
        }
        // A Clear History whose marker was never written (the container was unreachable): this
        // store writes it — the marker alone, so History written since then elsewhere stays.
        if let date = lock.withLock({ pendingClearDate }) {
            store.excludeHistory(touchedAtOrBefore: date)
            store.clearAll(at: date, deleteFolders: false) { [weak self] written in
                if written { self?.removePendingClear(upTo: date) }
            }
        }
        return store
    }

    /// Moves the local History stored for `localURL` (if any) into the shared document `path`;
    /// the local entry is removed only after the shared write succeeded. Returns the merged
    /// history when there was local History to move.
    private func migrate(localURL: URL, into store: SharedPassageHistoryStore, path: String, bookmarking: URL) -> DocumentHistory? {
        let key = FileIdentity.key(for: localURL)
        if lock.withLock({ migrationChecked.contains(key) }) { return nil }
        guard local.storedDocumentURLs().contains(where: { $0.path == key }) else {
            lock.withLock { _ = migrationChecked.insert(key) }
            return nil
        }
        let history = local.load(for: localURL)
        guard !history.isEmpty else {
            local.remove(for: localURL)
            lock.withLock { _ = migrationChecked.insert(key) }
            return nil
        }
        let localStore = local
        return store.merge(history, into: path) { [weak self] written in
            guard written else { return }
            localStore.remove(for: localURL)
            guard let self else { return }
            lock.withLock { _ = migrationChecked.insert(key) }
            rememberBookmark(for: bookmarking)
        }
    }

    private func migrateLocalEntry(at url: URL) {
        guard case let .shared(container, path) = classify(url) else { return }
        _ = migrate(localURL: url, into: shared(container), path: path, bookmarking: url)
    }

    // MARK: - Bookmark sidecar (D6)

    private var bookmarksURL: URL { bookmarkDirectory.appendingPathComponent("bookmarks.json") }
    private var pendingClearURL: URL { bookmarkDirectory.appendingPathComponent("pending-clear.json") }

    /// This device has (or had) shared History: the sidecar holds a bookmark or an unwritten clear.
    private var hasSidecar: Bool {
        FileManager.default.fileExists(atPath: bookmarksURL.path) || FileManager.default.fileExists(atPath: pendingClearURL.path)
    }

    private func readBookmarks() -> [BookmarkEntry] {
        guard let data = CoordinatedFileAccess.read(bookmarksURL),
              let entries = try? JSONDecoder().decode([BookmarkEntry].self, from: data) else { return [] }
        return entries
    }

    /// Under `lock`.
    private func writeBookmarks(_ entries: [BookmarkEntry]) {
        bookmarkedPaths = Set(entries.map(\.path))
        if entries.isEmpty { CoordinatedFileAccess.remove(bookmarksURL); return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        CoordinatedFileAccess.write(data, to: bookmarksURL)
    }

    /// Off the save path (a store's queue or the router's). Skipped when the sidecar already has
    /// an entry for this path: a bookmark follows the file by its identity, so it needs no refresh.
    private func rememberBookmark(for url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if bookmarkedPaths == nil { bookmarkedPaths = Set(readBookmarks().map(\.path)) }
        if bookmarkedPaths?.contains(path) == true { return }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var entries = readBookmarks()
        entries.removeAll { $0.path == path }
        entries.append(BookmarkEntry(path: path, bookmark: bookmark))
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
    /// document is left to the shared prune.
    private func followBookmarks() {
        let entries = lock.withLock { readBookmarks() }
        for entry in entries {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let old = URL(fileURLWithPath: entry.path)
            guard resolved.standardizedFileURL.path != entry.path, !resolved.pathComponents.contains(".Trash") else { continue }
            if FileIdentity.key(for: resolved) == FileIdentity.key(for: old) { continue }
            retarget(from: old, to: resolved)
        }
        queue.sync {}
    }

    /// Drops sidecar entries with nothing left to carry: the document is no longer shared, or its
    /// History folder is gone (Minor 6: it never shrank before).
    private func pruneBookmarks() {
        let entries = lock.withLock { readBookmarks() }
        guard !entries.isEmpty else { return }
        var dead = Set<String>()
        for entry in entries {
            guard case let .shared(container, path) = classify(URL(fileURLWithPath: entry.path)),
                  shared(container).hasFolder(relativePath: path) else { dead.insert(entry.path); continue }
        }
        guard !dead.isEmpty else { return }
        lock.withLock {
            let current = readBookmarks()
            let kept = current.filter { !dead.contains($0.path) }
            if kept != current { writeBookmarks(kept) }
        }
    }

    // MARK: - Unwritten Clear History

    private func readPendingClear() -> Date? {
        guard let data = CoordinatedFileAccess.read(pendingClearURL),
              let pending = try? HistoryMerge.decoder.decode(PendingClear.self, from: data) else { return nil }
        return pending.clearedAt
    }

    private func writePendingClear(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        let kept = readPendingClear().map { max($0, date) } ?? date
        guard let data = try? HistoryMerge.encoder.encode(PendingClear(clearedAt: kept)) else { return }
        CoordinatedFileAccess.write(data, to: pendingClearURL)
    }

    /// A marker at `date` is written: the kept clear is done unless a later one was made since.
    private func removePendingClear(upTo date: Date) {
        lock.lock(); defer { lock.unlock() }
        if let stored = readPendingClear(), stored > date { return }
        if let kept = pendingClearDate, kept > date { return }
        pendingClearDate = nil
        CoordinatedFileAccess.remove(pendingClearURL)
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { $0.appendingPathComponent($1) }
    }
}
