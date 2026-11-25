import CryptoKit
import Foundation

/// History for documents in the Lineform iCloud container, shared between the writer's devices
/// (plan decisions D1, D4, D6–D8).
///
/// ```
/// <container>/History/v1/Documents/<key>/<device>.json   one record per device per document
/// <container>/History/v1/Cleared/<device>.json           Clear History markers
/// ```
///
/// `History/` is a sibling of the public `Documents/` folder, so it syncs but never shows as
/// documents. A device writes ONLY its own record; every load reads all the records of the
/// document and merges them (`HistoryMerge.merge`), so iCloud never makes a conflicted copy and no
/// version is lost to a conflict. A record that cannot be read — half-synced, corrupt, an
/// `.icloud` placeholder, not downloaded, or from a newer format — is skipped, never deleted or
/// rewritten.
///
/// **Another device's record is never folded into this device's.** Add-wins (D3 rule 4) holds only
/// because each record stays where its device wrote it: this device's engine drops passages it
/// cannot locate, so a record it writes may lack them. A move or a former-path retire therefore
/// MOVES each record file into the new folder under its own name (merging two files of the same
/// device when both exist); only this device's own record has its `path` and `formerPaths`
/// rewritten. Document absence never deletes another device's record either (prune, D8).
///
/// **Threads.** `load` is synchronous (the controllers are unchanged) and never reads a record
/// that is not downloaded: it starts the download and the record merges at a later load. Every
/// write — saves, moves, removes, Clear History — runs on one serial utility queue. Saves are
/// coalesced per document (the last one wins) and kept in memory until written, and `load`
/// prefers that pending record to this device's record on disk. `prune` runs its work on the same
/// queue, so it is ordered with every queued write. `waitForBackgroundWork()` drains the queue.
///
/// Every file access is coordinated (`CoordinatedFileAccess`). `@unchecked Sendable`: every piece
/// of mutable state is guarded by `lock`, which is never held across file I/O; file writes are
/// serialised by `queue`.
public final class SharedPassageHistoryStore: @unchecked Sendable {
    /// The most former paths a record keeps (iPhone renames a document every time its first line
    /// changes).
    static let formerPathLimit = 20
    /// Prune deletes this device's own record of a document confirmed missing only once it was
    /// last written this long ago (iCloud may still be delivering a rename).
    static let absenceGraceInterval: TimeInterval = 7 * 24 * 60 * 60
    /// How long a move out of the container waits for one record iCloud has not downloaded.
    static let downloadTimeout: TimeInterval = 30

    let containerURL: URL
    private let device: String
    private let now: @Sendable () -> Date
    private let isConfirmedMissing: (URL) -> Bool
    private let isDownloaded: (URL) -> Bool
    /// A coordinated read that waits for iCloud to download the file, or nil once it gives up
    /// (`downloadTimeout`). Only a move out of the container uses it, off the main thread.
    private let fetchWaiting: @Sendable (URL) -> Data?
    private let conflicts: HistoryRecordConflicts
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lineform.history.shared-store", qos: .utility)

    private struct PendingSave {
        var history: DocumentHistory
        var relativePath: String
        var generation: Int
        var completions: [@Sendable (Bool) -> Void]
    }

    /// Per document key: the history this store last loaded or was asked to save (D4: a version
    /// missing from a passage that is still present is a deleted version).
    private var lastKnown: [String: DocumentHistory] = [:]
    /// Per document key: the tombstones read from every record at the last load (or written).
    private var knownTombstones: [String: [VersionTombstone]] = [:]
    /// Per document key: tombstones not written yet (`noteVersionDeleted`, and derived at save).
    private var pendingTombstones: [String: [VersionTombstone]] = [:]
    /// Per document key: every former path the records know, oldest first.
    private var formerPaths: [String: [String]] = [:]
    /// Per document key: the relative path it was last loaded or saved at.
    private var paths: [String: String] = [:]
    /// Per document key: this device's record not written yet (coalesced; the last save wins).
    private var pending: [String: PendingSave] = [:]
    /// Keys with a flush on the queue.
    private var scheduled: Set<String> = []
    private var generation = 0
    /// A Clear History made on this device whose marker may not be written yet: every load drops
    /// passages last touched at or before it, and no write stores them.
    private var clearedFloor: Date?

    /// `containerURL` is the folder holding `Documents/` and `History/`. `isConfirmedMissing`
    /// must return true ONLY on positive evidence the document is gone.
    public convenience init(containerURL: URL, device: String, now: @escaping @Sendable () -> Date = Date.init,
                            isConfirmedMissing: @escaping (URL) -> Bool = SharedPassageHistoryStore.confirmedMissing) {
        self.init(containerURL: containerURL, device: device, now: now, isConfirmedMissing: isConfirmedMissing,
                  isDownloaded: { url in SharedPassageHistoryStore.isDownloaded(url) }, conflicts: .live)
    }

    /// `isDownloaded` false means the record has no local data: it is never read on `load` (the
    /// read would wait for the download). `conflicts` reads and resolves iCloud conflict versions.
    /// `fetchWaiting` reads a record that is not downloaded, waiting for iCloud (tests inject a
    /// fake that "downloads" a `.<device>.json.icloud` stub, or never does).
    init(containerURL: URL, device: String, now: @escaping @Sendable () -> Date, isConfirmedMissing: @escaping (URL) -> Bool,
         isDownloaded: @escaping (URL) -> Bool, conflicts: HistoryRecordConflicts,
         fetchWaiting: @escaping @Sendable (URL) -> Data? = { url in
             CoordinatedFileAccess.readWaitingForDownload(url, timeout: SharedPassageHistoryStore.downloadTimeout)
         }) {
        self.containerURL = containerURL
        self.device = device
        self.now = now
        self.isConfirmedMissing = isConfirmedMissing
        self.isDownloaded = isDownloaded
        self.fetchWaiting = fetchWaiting
        self.conflicts = conflicts
    }

    // MARK: - Paths

    private var historyRoot: URL {
        containerURL.appendingPathComponent("History", isDirectory: true).appendingPathComponent("v1", isDirectory: true)
    }
    private var documentsRoot: URL { historyRoot.appendingPathComponent("Documents", isDirectory: true) }
    private var clearedRoot: URL { historyRoot.appendingPathComponent("Cleared", isDirectory: true) }
    private func folder(_ key: String) -> URL { documentsRoot.appendingPathComponent(key, isDirectory: true) }
    private var ownFileName: String { "\(device).json" }
    private func ownRecordURL(_ key: String) -> URL { folder(key).appendingPathComponent(ownFileName) }

    /// D1: lowercase hex SHA-256 of the relative path, NFC-normalised and lowercased (iCloud Drive
    /// names are case-insensitive), so every device files one document under one folder.
    public static func key(for relativePath: String) -> String {
        let normalised = relativePath.precomposedStringWithCanonicalMapping.lowercased()
        return SHA256.hash(data: Data(normalised.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The local rule (`FilePassageHistoryStore.confirmedMissing`), plus: an iCloud placeholder
    /// `.<name>.icloud` (a file not downloaded yet) counts as present.
    public static func confirmedMissing(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let placeholder = ".\(url.lastPathComponent).icloud"
        if names.contains(where: { $0.compare(placeholder, options: [.caseInsensitive]) == .orderedSame }) { return false }
        return FilePassageHistoryStore.confirmedMissing(url)
    }

    /// False only for a ubiquitous item with no local data (reading it would wait for iCloud).
    /// `url` must come from a fresh listing: `URL` caches resource values per instance.
    public static func isDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status != .notDownloaded
    }

    // MARK: - Load and save

    /// Every readable, downloaded record of the document (and of its former paths) merged, with
    /// this device's pending record in place of its record on disk.
    public func load(relativePath: String) -> DocumentHistory {
        load(relativePath: relativePath, downloading: false)
    }

    /// `downloading`: also read records that are not downloaded, waiting for them (a move out of
    /// the container, which then deletes the folder).
    func load(relativePath: String, downloading: Bool) -> DocumentHistory {
        loadReportingCompleteness(relativePath: relativePath, downloading: downloading).history
    }

    /// A move out of the container (call it off the main thread: it waits for iCloud). Every
    /// record of the document and its former paths, those not downloaded included — a
    /// `.<device>.json.icloud` stub or a dataless file is read through a coordinated read that
    /// waits for the download (`fetchWaiting`, with a timeout). `complete` is false when any
    /// record could not be read (not downloaded in time, unreadable, a newer format): the caller
    /// must then NOT delete the folder, or that record's History is lost.
    func loadForMove(relativePath: String) -> (history: DocumentHistory, complete: Bool) {
        loadReportingCompleteness(relativePath: relativePath, downloading: true)
    }

    private func loadReportingCompleteness(relativePath: String, downloading: Bool) -> (history: DocumentHistory, complete: Bool) {
        let key = Self.key(for: relativePath)
        lock.lock()
        let pendingOwn = pending[key]
        let memoryFormers = formerPaths[key] ?? []
        let memoryTombstones = (knownTombstones[key] ?? []) + (pendingTombstones[key] ?? [])
        let floor = clearedFloor
        lock.unlock()

        let folderRead = readFolder(key, downloading: downloading)
        var records = folderRead.records
        var complete = folderRead.complete
        if let pendingOwn {
            // The pending record replaces this device's record on disk (keeping its tombstones).
            let disk = records.filter { $0.device == device }
            records.removeAll { $0.device == device }
            records.append(makeRecord(pendingOwn.history, path: relativePath, device: device, writtenAt: now(),
                                      tombstones: memoryTombstones + disk.flatMap(\.deletedVersions)))
        }
        let formers = Self.orderedUnion(memoryFormers, records.flatMap(\.formerPaths)).filter { Self.key(for: $0) != key }
        // One level of former paths per load: a record another device wrote to the old path.
        for former in formers {
            let formerRead = readFolder(Self.key(for: former), downloading: downloading)
            records += formerRead.records
            complete = complete && formerRead.complete
        }
        let date = now()
        let history = HistoryMerge.merge(records, clearedAt: clearedAt(floor: floor), now: date)

        lock.lock()
        lastKnown[key] = history
        knownTombstones[key] = HistoryMerge.liveTombstones(records.flatMap(\.deletedVersions), now: date)
        formerPaths[key] = formers
        paths[key] = relativePath
        lock.unlock()
        return (history, complete)
    }

    /// Queues this device's record: the passages given, and the tombstones known, pending, and
    /// implied by versions gone from passages still present (D4). Coalesced: a later save of the
    /// same document replaces this one before it is written. `completion` runs on the store's queue
    /// with whether the record was written (or nothing needed writing); a save replaced before it
    /// was written reports the replacing save's result.
    public func save(_ history: DocumentHistory, relativePath: String, completion: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        scheduleLocked(history, relativePath: relativePath, completion: completion)
    }

    /// `save`, then waits for it (tests). True when written.
    @discardableResult
    func saveAndWait(_ history: DocumentHistory, relativePath: String) -> Bool {
        let result = ResultBox()
        save(history, relativePath: relativePath) { ok in result.set(ok) }
        waitForBackgroundWork()
        return result.value ?? false
    }

    /// Load ∪ `history`, then a queued save: migration of local History, and a document moved into
    /// the container from outside it. Returns the merged history (what a load now returns);
    /// `completion` reports whether it was written.
    @discardableResult
    public func merge(_ history: DocumentHistory, into relativePath: String,
                      completion: (@Sendable (Bool) -> Void)? = nil) -> DocumentHistory {
        let key = Self.key(for: relativePath)
        let loaded = load(relativePath: relativePath)
        lock.lock()
        let floor = clearedFloor
        lock.unlock()
        let cleared = clearedAt(floor: floor)
        let date = now()
        lock.lock(); defer { lock.unlock() }
        let tombstones = knownTombstones[key] ?? []
        // `history` wins scalar ties ("0" sorts first): it is what the writer last saw.
        let combined = HistoryMerge.merge([
            makeRecord(history, path: relativePath, device: "0-given", writtenAt: date, tombstones: tombstones),
            makeRecord(loaded, path: relativePath, device: "1-loaded", writtenAt: date, tombstones: tombstones),
        ], clearedAt: cleared, now: date)
        lastKnown[key] = loaded
        scheduleLocked(combined, relativePath: relativePath, completion: completion)
        return combined
    }

    /// Delete Version on passage `passage` (version `index` of `history`, the history BEFORE the
    /// engine deletes it): the next save writes a tombstone for that version, and for every version
    /// of the passages the engine removes with it (children made in that version; the whole passage
    /// and its descendants when one version would be left). Without it a passage the engine removed
    /// would come back from another device's record (a missing passage writes no tombstone).
    public func noteVersionDeleted(passage: UUID, at index: Int, in history: DocumentHistory, relativePath: String) {
        guard let target = history.passages.first(where: { $0.id == passage }),
              target.versions.indices.contains(index) else { return }
        lock.lock(); defer { lock.unlock() }
        let date = now()
        let deleted = target.versions[index]
        var stones: [VersionTombstone] = []
        let remaining = target.versions.enumerated().filter { $0.offset != index }.map(\.element)
        if remaining.count < 2 {
            // The engine removes the whole passage: every version of it goes (another device's
            // later version, with its own date, still survives).
            for version in target.versions {
                stones.append(VersionTombstone(passage: passage, createdAt: version.createdAt, author: version.author, deletedAt: date))
            }
        } else if !remaining.contains(where: { $0.createdAt == deleted.createdAt && $0.author == deleted.author }) {
            // A tombstone names a date and author, so it would remove a twin too: skip it then.
            stones.append(VersionTombstone(passage: passage, createdAt: deleted.createdAt, author: deleted.author, deletedAt: date))
        }
        var doomed: Set<UUID> = remaining.count < 2
            ? Set(history.passages.filter { $0.parentID == passage }.map(\.id))
            : Set(history.passages.filter { $0.parentID == passage && $0.parentVersionIndex == index }.map(\.id))
        var grew = true
        while grew {
            grew = false
            for p in history.passages where !doomed.contains(p.id) {
                if let parent = p.parentID, doomed.contains(parent) { doomed.insert(p.id); grew = true }
            }
        }
        for p in history.passages where doomed.contains(p.id) {
            for version in p.versions {
                stones.append(VersionTombstone(passage: p.id, createdAt: version.createdAt, author: version.author, deletedAt: date))
            }
        }
        pendingTombstones[Self.key(for: relativePath), default: []] += stones
    }

    // MARK: - Moves

    /// D6, inside → inside. Every record in the old folder moves to the new folder under its own
    /// name (two files of one device are merged into the one already there); this device's own
    /// record gets the new `path` and the old path in `formerPaths`, so a device that writes to the
    /// old path while offline is still read. A save queued for the old path is redirected to the
    /// new one and written after the move.
    public func move(from old: String, to new: String) {
        lock.lock(); defer { lock.unlock() }
        guard let redirected = rekeyLocked(from: old, to: new) else { return }
        queue.async { [self] in moveOnQueue(from: old, to: new) }
        if redirected { scheduleFlushLocked(Self.key(for: new)) }
    }

    /// A folder inside the container was renamed or moved: every document recorded under
    /// `oldPrefix` (path-component prefix, case- and normalisation-insensitive) moves to the same
    /// relative path under `newPrefix`. `completion` runs on the store's queue with the moves made.
    public func moveDirectory(from oldPrefix: String, to newPrefix: String,
                              completion: (@Sendable ([HistoryPathMove]) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        var redirected: [String] = []
        for path in Set(paths.values) {
            guard let rest = Self.remainder(of: path, under: oldPrefix) else { continue }
            let new = Self.join(newPrefix, rest)
            if rekeyLocked(from: path, to: new) == true { redirected.append(Self.key(for: new)) }
        }
        queue.async { [self] in
            var moves: [HistoryPathMove] = []
            for path in recordedPaths() {
                guard let rest = Self.remainder(of: path, under: oldPrefix) else { continue }
                let new = Self.join(newPrefix, rest)
                moveOnQueue(from: path, to: new)
                moves.append(HistoryPathMove(old: path, new: new))
            }
            completion?(moves)
        }
        for key in redirected { scheduleFlushLocked(key) }
    }

    /// Every document path this store's folder records (this device's record's `path`, or the
    /// newest readable record's). Reads every record.
    public func storedRelativePaths() -> [String] {
        recordedPaths()
    }

    /// Whether the document has a History folder at all (the bookmark sidecar's prune).
    func hasFolder(relativePath: String) -> Bool {
        CoordinatedFileAccess.contents(of: folder(Self.key(for: relativePath))) != nil
    }

    /// Deletes the document's folder (every device's record), after every queued write; a save
    /// queued for it is dropped.
    public func remove(relativePath: String) {
        let key = Self.key(for: relativePath)
        lock.lock()
        let dropped = pending.removeValue(forKey: key)
        forgetLocked(key)
        queue.async { [self] in _ = CoordinatedFileAccess.remove(folder(key)) }
        lock.unlock()
        dropped?.completions.forEach { $0(false) }
    }

    // MARK: - Clear and prune

    /// D7: writes this device's Clear History marker, then deletes every document folder (other
    /// devices' records included). The marker makes a device that was offline drop its pre-clear
    /// passages at its next merge.
    public func clearAll() {
        clearAll(at: now())
    }

    /// Drops every queued save at once; the marker write and (with `deleteFolders`) the deletes run
    /// on the queue, after every write already queued. `completion` reports whether the marker was
    /// written. `deleteFolders` false is a Clear History made while the container was unreachable,
    /// applied later: the marker alone, so History written since then elsewhere stays.
    func clearAll(at date: Date, deleteFolders: Bool = true, completion: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        clearedFloor = max(clearedFloor ?? date, date)
        // Queued saves stay (a version added after the Clear must not be dropped): every write
        // strips what was touched at or before the floor. What this store knows is cut the same way.
        let floor = clearedFloor ?? date
        lastKnown = lastKnown.mapValues { history in
            DocumentHistory(passages: history.passages.filter { $0.lastTouched > floor })
        }
        knownTombstones = [:]; pendingTombstones = [:]; formerPaths = [:]
        queue.async { [self] in
            let markerURL = clearedRoot.appendingPathComponent(ownFileName)
            var written = false
            if let existing = CoordinatedFileAccess.read(markerURL),
               let known = try? HistoryMerge.decoder.decode(HistoryClearMarker.self, from: existing), known.clearedAt >= date {
                written = true   // a later marker is kept
            } else if let data = try? HistoryMerge.encoder.encode(
                HistoryClearMarker(format: SharedHistoryRecord.currentFormat, device: device, clearedAt: date)) {
                written = CoordinatedFileAccess.write(data, to: markerURL)
            }
            if deleteFolders {
                for item in CoordinatedFileAccess.contents(of: documentsRoot) ?? [] {
                    CoordinatedFileAccess.remove(item)
                }
                // A save made after the Clear, already written and so just deleted: written again.
                lock.lock()
                for (key, history) in lastKnown where !history.isEmpty && pending[key] == nil {
                    guard let path = paths[key] else { continue }
                    generation += 1
                    pending[key] = PendingSave(history: history, relativePath: path, generation: generation, completions: [])
                }
                let keys = Array(pending.keys)
                lock.unlock()
                // Written here, on the queue, so nothing queued after the Clear runs before them.
                for key in keys { flush(key) }
            }
            completion?(written)
        }
        lock.unlock()
    }

    /// Every later load drops passages last touched at or before `date`, and no write stores them
    /// (a Clear History whose marker is written later, on a background queue).
    func excludeHistory(touchedAtOrBefore date: Date) {
        lock.lock(); defer { lock.unlock() }
        clearedFloor = max(clearedFloor ?? date, date)
    }

    /// Waits for every queued write (tests, and callers that must order after them).
    func waitForBackgroundWork() { queue.sync {} }

    /// Every queued write, now; then one retry of every save still pending (held back because this
    /// device's record on disk was evicted or unreadable). Never from the store's own queue.
    public func flushPendingWrites() {
        queue.sync {}
        lock.lock()
        for key in pending.keys { scheduleFlushLocked(key) }
        lock.unlock()
        queue.sync {}
    }

    /// D8, on the store's queue (call it from a background queue, never from a completion):
    /// - Another device's record is deleted only when it was written more than 30 days ago —
    ///   NEVER because the document is absent here (iCloud syncs `History/` and `Documents/`
    ///   separately, and a rename made elsewhere may not have arrived).
    /// - This device's own record is deleted on positive evidence the document is gone, and only
    ///   when it was last written more than 7 days ago and no record of any document lists its path
    ///   as a former path (a rename still being delivered).
    /// - This device's own record drops stale passages, expired tombstones, and former paths whose
    ///   folder is gone. iCloud conflict versions of a record are merged into it and resolved.
    /// - Clear markers expire after 30 days. A folder left with nothing in it is removed.
    public func prune(now date: Date) {
        queue.sync { pruneOnQueue(now: date) }
    }

    private func pruneOnQueue(now date: Date) {
        let cutoff = date.addingTimeInterval(-FilePassageHistoryStore.staleInterval)
        let grace = date.addingTimeInterval(-Self.absenceGraceInterval)

        for item in CoordinatedFileAccess.contents(of: clearedRoot) ?? [] where item.pathExtension == "json" {
            if let data = CoordinatedFileAccess.read(item),
               let marker = try? HistoryMerge.decoder.decode(HistoryClearMarker.self, from: data),
               marker.clearedAt < cutoff {
                CoordinatedFileAccess.remove(item)
            }
        }

        // Read every downloaded record once (resolving conflict versions), and every former path.
        let keys = (CoordinatedFileAccess.contents(of: documentsRoot) ?? []).map(\.lastPathComponent)
        var folders: [String: [(url: URL, record: SharedHistoryRecord)]] = [:]
        var formerKeys = Set<String>()
        for key in keys {
            var entries: [(url: URL, record: SharedHistoryRecord)] = []
            for item in CoordinatedFileAccess.contents(of: folder(key)) ?? [] where Self.isRecordName(item) {
                guard isDownloaded(item), var record = readRecord(item) else { continue }
                let versions = conflictRecords(of: item)
                if !versions.isEmpty {
                    record = versions.reduce(record) { merged, version in union(merged, version) }
                    if let data = try? HistoryMerge.encoder.encode(record), CoordinatedFileAccess.write(data, to: item) {
                        conflicts.resolve(item)
                    }
                }
                entries.append((item, record))
                formerKeys.formUnion(record.formerPaths.map { Self.key(for: $0) })
            }
            folders[key] = entries
        }

        let documents = containerURL.appendingPathComponent("Documents", isDirectory: true)
        lock.lock()
        let busy = Set(pending.keys)
        lock.unlock()
        for key in keys {
            for (item, original) in folders[key] ?? [] {
                if original.device != device {
                    if original.writtenAt < cutoff { CoordinatedFileAccess.remove(item) }
                    continue
                }
                if !busy.contains(key), original.writtenAt < grace, !formerKeys.contains(Self.key(for: original.path)),
                   isConfirmedMissing(documents.appendingPathComponent(original.path)) {
                    CoordinatedFileAccess.remove(item)
                    lock.lock(); forgetLocked(key); lock.unlock()
                    continue
                }
                var record = original
                record.passages = record.passages.filter { $0.lastTouched >= cutoff }
                record.deletedVersions = HistoryMerge.liveTombstones(record.deletedVersions, now: date)
                record.formerPaths = record.formerPaths.filter {
                    CoordinatedFileAccess.contents(of: folder(Self.key(for: $0))) != nil
                }
                // Its date stays: nothing new was written, and the grace above reads it.
                guard record != original, let data = try? HistoryMerge.encoder.encode(record) else { continue }
                CoordinatedFileAccess.write(data, to: item)
            }
            removeFolderIfEmpty(key)
        }
    }

    // MARK: - Queued work

    private func scheduleLocked(_ history: DocumentHistory, relativePath: String, completion: (@Sendable (Bool) -> Void)?) {
        let key = Self.key(for: relativePath)
        let date = now()
        if let previous = lastKnown[key] {
            pendingTombstones[key, default: []] += HistoryMerge.tombstones(from: previous, to: history, now: date)
        }
        lastKnown[key] = history
        paths[key] = relativePath
        generation += 1
        var completions = pending[key]?.completions ?? []
        if let completion { completions.append(completion) }
        pending[key] = PendingSave(history: history, relativePath: relativePath, generation: generation, completions: completions)
        scheduleFlushLocked(key)
    }

    private func scheduleFlushLocked(_ key: String) {
        guard scheduled.insert(key).inserted else { return }
        queue.async { [self] in flush(key) }
    }

    /// Writes the pending record of `key`. On failure (this device's record on disk is a
    /// placeholder, not downloaded or unreadable — I2 — or the write failed) the pending record
    /// stays, for `load` and for the next save to retry.
    private func flush(_ key: String) {
        lock.lock()
        scheduled.remove(key)
        guard let job = pending[key] else { lock.unlock(); return }
        pending[key]?.completions = []
        let consumed = pendingTombstones[key]?.count ?? 0
        let tombstones = (knownTombstones[key] ?? []) + (pendingTombstones[key] ?? [])
        let formers = formerPaths[key] ?? []
        let floor = clearedFloor
        lock.unlock()

        let written = writeOwnRecord(job.history, relativePath: job.relativePath, key: key,
                                     tombstones: tombstones, formers: formers, floor: floor)

        lock.lock()
        // A key moved away (or removed) while the write ran keeps no state: `paths` no longer
        // names this document there.
        if let written, paths[key].map({ Self.key(for: $0) == key }) == true {
            if pending[key]?.generation == job.generation { pending[key] = nil }
            if let left = pendingTombstones[key] {
                pendingTombstones[key] = left.count > consumed ? Array(left.dropFirst(consumed)) : nil
            }
            knownTombstones[key] = written.tombstones
            formerPaths[key] = Self.orderedUnion(formerPaths[key] ?? [], written.formers)
        } else if written != nil, pending[key]?.generation == job.generation {
            pending[key] = nil
        }
        lock.unlock()
        job.completions.forEach { $0(written != nil) }
    }

    /// nil when nothing was written and the save must be retried.
    private func writeOwnRecord(_ history: DocumentHistory, relativePath: String, key: String,
                                tombstones: [VersionTombstone], formers: [String], floor: Date?)
        -> (tombstones: [VersionTombstone], formers: [String])? {
        let date = now()
        let own = readOwn(key)
        let existing: SharedHistoryRecord?
        switch own {
        case .blocked: return nil
        case .absent: existing = nil
        case let .readable(record): existing = record
        }
        let liveFormers = formers.filter { Self.key(for: $0) != key }
        // Nothing stored and nothing to store: create no folder.
        if history.isEmpty, existing == nil, liveFormers.isEmpty, CoordinatedFileAccess.contents(of: folder(key)) == nil {
            return (HistoryMerge.liveTombstones(tombstones, now: date), liveFormers)
        }
        let allTombstones = HistoryMerge.liveTombstones(tombstones + (existing?.deletedVersions ?? []), now: date)
        let formerList = Self.trimmedFormers(Self.orderedUnion(existing?.formerPaths ?? [], liveFormers), excluding: key)
        var stored = history
        if let floor { stored.passages.removeAll { $0.lastTouched <= floor } }
        var record = makeRecord(stored, path: relativePath, device: device, writtenAt: date, tombstones: allTombstones)
        record.formerPaths = formerList

        // A rewrite that changes nothing but the date is skipped.
        var unchanged = existing
        unchanged?.writtenAt = date
        if unchanged != record {
            guard let data = try? HistoryMerge.encoder.encode(record),
                  CoordinatedFileAccess.write(data, to: ownRecordURL(key)) else { return nil }
        }
        // The records still filed under a former path join this folder, each under its own name.
        for former in formerList {
            retireFolder(Self.key(for: former), into: key, path: relativePath)
        }
        if stored.isEmpty { removeFolderIfEmpty(key) }
        return (allTombstones, formerList)
    }

    /// Moves the records of `old` into `new`'s folder (see `move`).
    private func moveOnQueue(from old: String, to new: String) {
        let oldKey = Self.key(for: old)
        let newKey = Self.key(for: new)
        guard oldKey != newKey, CoordinatedFileAccess.contents(of: folder(oldKey)) != nil else { return }
        // This device's record at the new key, carrying the old path. If this device's record
        // there cannot be read, nothing moves: the old folder stays, read through `formerPaths`.
        let existing: SharedHistoryRecord?
        switch readOwn(newKey) {
        case .blocked: return
        case .absent: existing = nil
        case let .readable(record): existing = record
        }
        // This device's old record evicted or unreadable (I2): it is neither merged nor removed. It
        // stays in the old folder, which the new record lists as a former path, and joins the new
        // folder at a later save once it is readable.
        var ownOld: SharedHistoryRecord?
        if case let .readable(record) = readOwn(oldKey) { ownOld = record }
        lock.lock()
        let memoryTombstones = (knownTombstones[newKey] ?? []) + (pendingTombstones[newKey] ?? [])
        lock.unlock()
        let date = now()
        var own: SharedHistoryRecord
        switch (existing, ownOld) {
        case let (existing?, old?): own = union(existing, old)
        case let (existing?, nil): own = existing
        case let (nil, old?): own = old
        case (nil, nil): own = makeRecord(DocumentHistory(passages: []), path: new, device: device, writtenAt: date, tombstones: [])
        }
        own.path = new
        own.formerPaths = Self.trimmedFormers(
            Self.orderedUnion(existing?.formerPaths ?? [], (ownOld?.formerPaths ?? []) + [old]), excluding: newKey)
        own.deletedVersions = HistoryMerge.liveTombstones(own.deletedVersions + memoryTombstones, now: date)
        own.writtenAt = date
        guard let data = try? HistoryMerge.encoder.encode(own),
              CoordinatedFileAccess.write(data, to: ownRecordURL(newKey)) else { return }
        if ownOld != nil { CoordinatedFileAccess.remove(ownRecordURL(oldKey)) }
        retireFolder(oldKey, into: newKey, path: new)
        lock.lock()
        formerPaths[newKey] = Self.orderedUnion(formerPaths[newKey] ?? [], own.formerPaths)
        lock.unlock()
    }

    /// The in-memory half of a move: former paths, tombstones and a pending save follow to the new
    /// key. nil when the keys are the same; otherwise whether a pending save was redirected.
    private func rekeyLocked(from old: String, to new: String) -> Bool? {
        let oldKey = Self.key(for: old)
        let newKey = Self.key(for: new)
        guard oldKey != newKey else { return nil }
        formerPaths[newKey] = Self.trimmedFormers(
            Self.orderedUnion(formerPaths[newKey] ?? [], (formerPaths[oldKey] ?? []) + [old]), excluding: newKey)
        if let known = knownTombstones[oldKey] { knownTombstones[newKey, default: []] += known }
        if let stones = pendingTombstones[oldKey] { pendingTombstones[newKey, default: []] += stones }
        if lastKnown[newKey] == nil { lastKnown[newKey] = lastKnown[oldKey] }
        var redirected = false
        if var moving = pending.removeValue(forKey: oldKey) {
            generation += 1
            moving.relativePath = new
            moving.generation = generation
            moving.completions = (pending[newKey]?.completions ?? []) + moving.completions
            pending[newKey] = moving
            redirected = true
        }
        forgetLocked(oldKey)
        paths[newKey] = new
        return redirected
    }

    private func forgetLocked(_ key: String) {
        lastKnown[key] = nil
        knownTombstones[key] = nil
        pendingTombstones[key] = nil
        formerPaths[key] = nil
        paths[key] = nil
    }

    // MARK: - Disk

    private static func isRecordName(_ item: URL) -> Bool {
        item.pathExtension == "json" && !item.lastPathComponent.hasPrefix(".")
    }

    /// The readable records of one document's folder (with their unresolved conflict versions);
    /// `listed` is whether the folder exists. A record not downloaded is not read unless
    /// `downloading`: its download is started, and a later load merges it. It stays.
    ///
    /// `downloading` (a move out of the container): a stub `.<device>.json.icloud` is mapped to its
    /// logical `<device>.json` and read, like a dataless record, through `fetchWaiting`, which
    /// waits for iCloud. `complete` is false when any record could not be read.
    private func readFolder(_ key: String, downloading: Bool = false)
        -> (records: [SharedHistoryRecord], listed: Bool, complete: Bool) {
        guard let items = CoordinatedFileAccess.contents(of: folder(key)) else { return ([], false, true) }
        var records: [SharedHistoryRecord] = []
        var complete = true
        let listedNames = Set(items.map(\.lastPathComponent))
        for item in items {
            // A record not downloaded yet (`.<device>.json.icloud`): ask for it, or (moving) wait for it.
            guard let logicalName = Self.recordName(ofStub: item.lastPathComponent) else { continue }
            let logical = folder(key).appendingPathComponent(logicalName)
            if downloading {
                // Listed under both names (mid-download): the real file is read below.
                if listedNames.contains(logicalName) { continue }
                guard let data = fetchWaiting(logical), let record = Self.decodeRecord(data) else {
                    complete = false
                    continue
                }
                records.append(record)
            } else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: logical)
            }
        }
        for item in items where Self.isRecordName(item) {
            if !isDownloaded(item) {
                if downloading {
                    guard let data = fetchWaiting(item), let record = Self.decodeRecord(data) else {
                        complete = false
                        continue
                    }
                    records.append(record)
                    records += conflictRecords(of: item)
                } else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: item)
                }
                continue
            }
            guard let record = readRecord(item) else {
                complete = false
                continue
            }
            records.append(record)
            records += conflictRecords(of: item)
        }
        return (records, true, complete)
    }

    /// `<device>.json` for an iCloud stub named `.<device>.json.icloud`, else nil.
    static func recordName(ofStub name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".json.icloud"), name.count > ".json.icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private func readRecord(_ item: URL) -> SharedHistoryRecord? {
        guard let data = CoordinatedFileAccess.read(item) else { return nil }
        return Self.decodeRecord(data)
    }

    private static func decodeRecord(_ data: Data) -> SharedHistoryRecord? {
        guard let record = try? HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data),
              record.format <= SharedHistoryRecord.currentFormat else { return nil }
        return record
    }

    /// iCloud's conflict versions of a record (two writers of one file: only a device id restored
    /// onto a second device does that), read-only.
    private func conflictRecords(of item: URL) -> [SharedHistoryRecord] {
        conflicts.versions(item).compactMap { data in Self.decodeRecord(data) }
    }

    private enum OwnRecord {
        case absent
        case readable(SharedHistoryRecord)
        /// A placeholder, not downloaded, unreadable, or from a newer format: never overwritten.
        case blocked
    }

    /// This device's record of `key`, with its conflict versions merged in. Not downloaded: its
    /// download is started.
    private func readOwn(_ key: String) -> OwnRecord {
        let items = CoordinatedFileAccess.contents(of: folder(key)) ?? []
        let names = Set(items.map(\.lastPathComponent))
        if names.contains(".\(ownFileName).icloud"), !names.contains(ownFileName) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: ownRecordURL(key))
            return .blocked
        }
        guard let item = items.first(where: { $0.lastPathComponent == ownFileName }) else { return .absent }
        guard isDownloaded(item) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: item)
            return .blocked
        }
        guard var record = readRecord(item) else { return .blocked }
        for version in conflictRecords(of: item) { record = union(record, version) }
        return .readable(record)
    }

    /// Two records of ONE device merged (a move or a retire meeting that device's file at the
    /// destination, or a conflict version): `a`'s name and path, the union of everything else.
    private func union(_ a: SharedHistoryRecord, _ b: SharedHistoryRecord) -> SharedHistoryRecord {
        let date = now()
        var result = a
        result.passages = HistoryMerge.merge([a, b], clearedAt: nil, now: date).passages
        result.deletedVersions = HistoryMerge.liveTombstones(a.deletedVersions + b.deletedVersions, now: date)
        result.formerPaths = Self.trimmedFormers(Self.orderedUnion(a.formerPaths, b.formerPaths), excluding: Self.key(for: a.path))
        result.writtenAt = max(a.writtenAt, b.writtenAt)
        return result
    }

    /// Empties a former path's folder into `key`'s, never deleting a record: each file moves under
    /// its own name; when that device already has a file there, the two are merged into it (this
    /// device's keeps `path`). Whatever cannot be moved or merged (an unreadable record, a
    /// placeholder whose name is taken) stays, and so does its folder.
    private func retireFolder(_ oldKey: String, into key: String, path: String) {
        guard oldKey != key, let items = CoordinatedFileAccess.contents(of: folder(oldKey)) else { return }
        var keep = false
        for item in items {
            let name = item.lastPathComponent
            // An `.icloud` stub is never moved by its literal name (its logical file would then
            // clash with that device's record at the destination): it stays, with its folder, and
            // is retired once downloaded.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: folder(oldKey).appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count))))
                keep = true
                continue
            }
            let destination = folder(key).appendingPathComponent(name)
            let taken = FileManager.default.fileExists(atPath: destination.path)
            guard Self.isRecordName(item), isDownloaded(item), let record = readRecord(item) else {
                if taken || !CoordinatedFileAccess.move(item, to: destination) { keep = true }
                continue
            }
            var merged = record
            if taken {
                guard let there = readRecord(destination) else { keep = true; continue }
                merged = union(there, record)
            }
            if record.device == device { merged.path = path }
            for version in conflictRecords(of: item) { merged = union(merged, version) }
            if !taken, merged == record {
                if !CoordinatedFileAccess.move(item, to: destination) { keep = true }
                continue
            }
            guard let data = try? HistoryMerge.encoder.encode(merged),
                  CoordinatedFileAccess.write(data, to: destination),
                  CoordinatedFileAccess.remove(item) else { keep = true; continue }
        }
        if !keep { CoordinatedFileAccess.remove(folder(oldKey)) }
    }

    /// Removes the folder only when everything in it is a readable record with no passages and no
    /// live tombstones (a tombstone must outlive a stale record another device may still upload): a
    /// record that cannot be read, is not downloaded, or is a placeholder may hold History, so it
    /// is never deleted.
    private func removeFolderIfEmpty(_ key: String) {
        guard let items = CoordinatedFileAccess.contents(of: folder(key)) else { return }
        for item in items {
            guard Self.isRecordName(item), isDownloaded(item), let record = readRecord(item),
                  record.passages.isEmpty, record.deletedVersions.isEmpty else { return }
        }
        CoordinatedFileAccess.remove(folder(key))
        lock.lock(); forgetLocked(key); lock.unlock()
    }

    private func recordedPaths() -> [String] {
        (CoordinatedFileAccess.contents(of: documentsRoot) ?? []).compactMap { item in
            let records = readFolder(item.lastPathComponent).records
            return records.first(where: { $0.device == device })?.path ?? newestRecord(in: records)?.path
        }.sorted()
    }

    private func newestRecord(in records: [SharedHistoryRecord]) -> SharedHistoryRecord? {
        records.min { $0.writtenAt != $1.writtenAt ? $0.writtenAt > $1.writtenAt : $0.device < $1.device }
    }

    /// The latest Clear History across devices, or this device's not-yet-written one.
    private func clearedAt(floor: Date?) -> Date? {
        var latest = floor
        for item in CoordinatedFileAccess.contents(of: clearedRoot) ?? [] where item.pathExtension == "json" {
            guard let data = CoordinatedFileAccess.read(item),
                  let marker = try? HistoryMerge.decoder.decode(HistoryClearMarker.self, from: data) else { continue }
            latest = max(latest ?? marker.clearedAt, marker.clearedAt)
        }
        return latest
    }

    private func makeRecord(_ history: DocumentHistory, path: String, device: String, writtenAt: Date,
                            tombstones: [VersionTombstone]) -> SharedHistoryRecord {
        SharedHistoryRecord(format: SharedHistoryRecord.currentFormat, device: device, path: path, formerPaths: [],
                            writtenAt: writtenAt, passages: history.passages, deletedVersions: tombstones)
    }

    // MARK: - Former paths

    /// `a` then whatever of `b` is new, each path once (case- and normalisation-insensitive); a
    /// path seen again moves to the end. Oldest first.
    static func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
        var result: [String] = []
        for path in a + b {
            let k = key(for: path)
            result.removeAll { key(for: $0) == k }
            result.append(path)
        }
        return result
    }

    /// Without the document's own key, at most `formerPathLimit`, the most recent kept.
    static func trimmedFormers(_ formers: [String], excluding key: String) -> [String] {
        Array(formers.filter { Self.key(for: $0) != key }.suffix(formerPathLimit))
    }

    // MARK: - Relative paths

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `path` below `prefix` by whole components (case- and normalisation-insensitive), or nil.
    static func remainder(of path: String, under prefix: String) -> [String]? {
        let p = components(path), q = components(prefix)
        guard !q.isEmpty, p.count > q.count else { return nil }
        for (a, b) in zip(p, q) where a.precomposedStringWithCanonicalMapping.lowercased()
            != b.precomposedStringWithCanonicalMapping.lowercased() { return nil }
        return Array(p.dropFirst(q.count))
    }

    static func join(_ prefix: String, _ rest: [String]) -> String {
        (components(prefix) + rest).joined(separator: "/")
    }
}

/// One document moved by `SharedPassageHistoryStore.moveDirectory`.
public struct HistoryPathMove: Equatable, Sendable {
    public var old: String
    public var new: String
}

/// iCloud's conflict versions of a History record (`NSFileVersion`), behind a seam so tests can
/// make some: a real conflict needs two writers of one file in iCloud.
struct HistoryRecordConflicts: Sendable {
    /// The bytes of every unresolved conflict version of the file.
    var versions: @Sendable (URL) -> [Data]
    /// Marks them resolved and removes them (after their contents were merged into the file).
    var resolve: @Sendable (URL) -> Void

    static let live = HistoryRecordConflicts(
        versions: { url in CoordinatedFileAccess.conflictVersionData(of: url) },
        resolve: { url in CoordinatedFileAccess.resolveConflictVersions(of: url) })
    static let none = HistoryRecordConflicts(versions: { _ in [] }, resolve: { _ in })
}

/// A value set once from another queue (`saveAndWait`, tests).
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
}
