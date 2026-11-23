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
/// `.icloud` placeholder, or from a newer format — is skipped, never deleted or rewritten.
///
/// Every file access is coordinated (`CoordinatedFileAccess`). `@unchecked Sendable`: every
/// method takes `lock`, like `FilePassageHistoryStore`.
public final class SharedPassageHistoryStore: @unchecked Sendable {
    private let containerURL: URL
    private let device: String
    private let now: @Sendable () -> Date
    private let isConfirmedMissing: (URL) -> Bool
    private let lock = NSLock()

    /// Per document key: the history this store last loaded or saved (D4: a version missing from
    /// a passage that is still present is a deleted version).
    private var lastKnown: [String: DocumentHistory] = [:]
    /// Per document key: the tombstones read from every record at the last load.
    private var knownTombstones: [String: [VersionTombstone]] = [:]
    /// Per document key: explicit Delete Versions not yet written (`noteVersionDeleted`).
    private var pendingTombstones: [String: [VersionTombstone]] = [:]
    /// Per document key: the folders of former paths merged at the last load, deleted after the
    /// next successful save.
    private var mergedFormerKeys: [String: Set<String>] = [:]
    /// Per document key: every former path the records know.
    private var formerPaths: [String: [String]] = [:]
    /// A Clear History made on this device whose marker may not be written yet: every load drops
    /// passages last touched at or before it.
    private var clearedFloor: Date?

    /// `containerURL` is the folder holding `Documents/` and `History/`. `isConfirmedMissing`
    /// must return true ONLY on positive evidence the document is gone.
    public init(containerURL: URL, device: String, now: @escaping @Sendable () -> Date = Date.init,
                isConfirmedMissing: @escaping (URL) -> Bool = SharedPassageHistoryStore.confirmedMissing) {
        self.containerURL = containerURL
        self.device = device
        self.now = now
        self.isConfirmedMissing = isConfirmedMissing
    }

    // MARK: - Paths

    private var historyRoot: URL {
        containerURL.appendingPathComponent("History", isDirectory: true).appendingPathComponent("v1", isDirectory: true)
    }
    private var documentsRoot: URL { historyRoot.appendingPathComponent("Documents", isDirectory: true) }
    private var clearedRoot: URL { historyRoot.appendingPathComponent("Cleared", isDirectory: true) }
    private func folder(_ key: String) -> URL { documentsRoot.appendingPathComponent(key, isDirectory: true) }
    private func ownRecordURL(_ key: String) -> URL { folder(key).appendingPathComponent("\(device).json") }

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

    // MARK: - Load and save

    public func load(relativePath: String) -> DocumentHistory {
        lock.lock(); defer { lock.unlock() }
        return loadLocked(relativePath)
    }

    /// Writes this device's record: the passages given, and the tombstones known, pending, and
    /// implied by versions gone from passages still present (D4). True when the record was written
    /// (or nothing needed writing).
    @discardableResult
    public func save(_ history: DocumentHistory, relativePath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return saveLocked(history, relativePath: relativePath)
    }

    /// Load ∪ `history`, then save: migration of local History, and a document moved into the
    /// container from outside it.
    @discardableResult
    public func merge(_ history: DocumentHistory, into relativePath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(for: relativePath)
        let loaded = loadLocked(relativePath)
        let date = now()
        let tombstones = knownTombstones[key] ?? []
        // `history` wins scalar ties ("0" sorts first): it is what the writer last saw.
        let combined = HistoryMerge.merge([
            record(history, path: relativePath, device: "0-given", writtenAt: date, tombstones: tombstones),
            record(loaded, path: relativePath, device: "1-loaded", writtenAt: date, tombstones: tombstones),
        ], clearedAt: clearedAt(), now: date)
        return saveLocked(combined, relativePath: relativePath)
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
        // A tombstone names a date and author, so it would remove a twin too: skip it then.
        if !remaining.contains(where: { $0.createdAt == deleted.createdAt && $0.author == deleted.author }) {
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

    /// D6, inside → inside: the old folder (and every former path it merged) is merged into this
    /// device's record at the new key, with the old path added to `formerPaths`, then deleted. A
    /// device that writes to the old path while offline is still read through `formerPaths`.
    public func move(from old: String, to new: String) {
        lock.lock(); defer { lock.unlock() }
        moveLocked(from: old, to: new)
    }

    /// A folder inside the container was renamed or moved: every document recorded under
    /// `oldPrefix` (path-component prefix, case- and normalisation-insensitive) moves to the same
    /// relative path under `newPrefix`.
    public func moveDirectory(from oldPrefix: String, to newPrefix: String) {
        lock.lock(); defer { lock.unlock() }
        for path in recordedPathsLocked() {
            guard let rest = Self.remainder(of: path, under: oldPrefix) else { continue }
            moveLocked(from: path, to: Self.join(newPrefix, rest))
        }
    }

    /// Every document path this store's folder records (the newest readable record's `path`).
    public func storedRelativePaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedPathsLocked()
    }

    /// Deletes the document's folder: every device's record.
    public func remove(relativePath: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(for: relativePath)
        CoordinatedFileAccess.remove(folder(key))
        forget(key)
    }

    // MARK: - Clear and prune

    /// D7: writes this device's Clear History marker, then deletes every document folder (other
    /// devices' records included). The marker makes a device that was offline drop its pre-clear
    /// passages at its next merge.
    public func clearAll() {
        clearAll(at: now())
    }

    func clearAll(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        let marker = HistoryClearMarker(format: SharedHistoryRecord.currentFormat, device: device, clearedAt: date)
        if let data = try? HistoryMerge.encoder.encode(marker) {
            CoordinatedFileAccess.write(data, to: clearedRoot.appendingPathComponent("\(device).json"))
        }
        clearedFloor = max(clearedFloor ?? date, date)
        for item in CoordinatedFileAccess.contents(of: documentsRoot) ?? [] {
            CoordinatedFileAccess.remove(item)
        }
        lastKnown = [:]; knownTombstones = [:]; pendingTombstones = [:]; mergedFormerKeys = [:]; formerPaths = [:]
    }

    /// Every later load drops passages last touched at or before `date` (a Clear History whose
    /// marker is written later, on a background queue).
    func excludeHistory(touchedAtOrBefore date: Date) {
        lock.lock(); defer { lock.unlock() }
        clearedFloor = max(clearedFloor ?? date, date)
    }

    /// D8. A document's folder is deleted only on positive evidence the document is gone. This
    /// device rewrites only its own record (stale passages dropped); another device's record is
    /// deleted only when it was written more than 30 days ago. Clear markers expire after 30 days.
    /// The document checks run without the lock.
    public func prune(now date: Date) {
        let cutoff = date.addingTimeInterval(-FilePassageHistoryStore.staleInterval)

        lock.lock()
        for item in CoordinatedFileAccess.contents(of: clearedRoot) ?? [] where item.pathExtension == "json" {
            if let data = CoordinatedFileAccess.read(item),
               let marker = try? HistoryMerge.decoder.decode(HistoryClearMarker.self, from: data),
               marker.clearedAt < cutoff {
                CoordinatedFileAccess.remove(item)
            }
        }
        let folders = (CoordinatedFileAccess.contents(of: documentsRoot) ?? []).map(\.lastPathComponent)
        var paths: [String: String] = [:]
        for key in folders {
            if let path = newestRecord(in: readFolder(key).records)?.path { paths[key] = path }
        }
        lock.unlock()

        let documents = containerURL.appendingPathComponent("Documents", isDirectory: true)
        let gone = Set(paths.filter { isConfirmedMissing(documents.appendingPathComponent($0.value)) }.keys)

        lock.lock(); defer { lock.unlock() }
        for key in folders {
            if gone.contains(key) {
                CoordinatedFileAccess.remove(folder(key))
                forget(key)
                continue
            }
            for item in CoordinatedFileAccess.contents(of: folder(key)) ?? [] where item.pathExtension == "json" {
                guard let data = CoordinatedFileAccess.read(item),
                      var record = try? HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data),
                      record.format <= SharedHistoryRecord.currentFormat else { continue }
                if record.device == device {
                    let fresh = record.passages.filter { $0.lastTouched >= cutoff }
                    let tombstones = HistoryMerge.liveTombstones(record.deletedVersions, now: date)
                    guard fresh.count != record.passages.count || tombstones.count != record.deletedVersions.count else { continue }
                    record.passages = fresh
                    record.deletedVersions = tombstones
                    record.writtenAt = date
                    if let data = try? HistoryMerge.encoder.encode(record) { CoordinatedFileAccess.write(data, to: item) }
                } else if record.writtenAt < cutoff {
                    CoordinatedFileAccess.remove(item)
                }
            }
            removeFolderIfEmpty(key)
        }
    }

    // MARK: - Locked work

    private func loadLocked(_ relativePath: String) -> DocumentHistory {
        let key = Self.key(for: relativePath)
        var read = readFolder(key)
        var formers = Set(read.records.flatMap(\.formerPaths)).union(formerPaths[key] ?? [])
        var mergedFormers = Set<String>()
        // One level of former paths per load: a record another device wrote to the old path.
        for former in formers.sorted() {
            let formerKey = Self.key(for: former)
            guard formerKey != key else { continue }
            let old = readFolder(formerKey)
            guard old.listed else { continue }
            read.records += old.records
            mergedFormers.insert(formerKey)
        }
        formers = formers.filter { Self.key(for: $0) != key }
        let history = HistoryMerge.merge(read.records, clearedAt: clearedAt(), now: now())
        lastKnown[key] = history
        knownTombstones[key] = HistoryMerge.liveTombstones(read.records.flatMap(\.deletedVersions), now: now())
        mergedFormerKeys[key] = mergedFormers
        formerPaths[key] = formers.sorted()
        return history
    }

    private func saveLocked(_ history: DocumentHistory, relativePath: String) -> Bool {
        let key = Self.key(for: relativePath)
        let date = now()
        let existing = readFolder(key)
        // Nothing stored and nothing to store: create no folder.
        if history.isEmpty, !existing.listed, (mergedFormerKeys[key] ?? []).isEmpty { return true }

        let derived = lastKnown[key].map { HistoryMerge.tombstones(from: $0, to: history, now: date) } ?? []
        let own = existing.records.first { $0.device == device }
        let tombstones = HistoryMerge.liveTombstones(
            (knownTombstones[key] ?? []) + (pendingTombstones[key] ?? []) + derived + (own?.deletedVersions ?? []), now: date)
        let formers = Set(formerPaths[key] ?? []).union(own?.formerPaths ?? [])
            .filter { Self.key(for: $0) != key }.sorted()
        var record = record(history, path: relativePath, device: device, writtenAt: date, tombstones: tombstones)
        record.formerPaths = formers

        // A rewrite that changes nothing but the date is skipped.
        var unchanged = own
        unchanged?.writtenAt = date
        if unchanged != record {
            guard let data = try? HistoryMerge.encoder.encode(record),
                  CoordinatedFileAccess.write(data, to: ownRecordURL(key)) else { return false }
        }
        pendingTombstones[key] = nil
        knownTombstones[key] = tombstones
        lastKnown[key] = history
        formerPaths[key] = formers
        // The former-path folders merged at load are now in this record.
        for formerKey in mergedFormerKeys[key] ?? [] where formerKey != key {
            retireFolder(formerKey, into: key)
        }
        mergedFormerKeys[key] = []
        if history.isEmpty { removeFolderIfEmpty(key) }
        return true
    }

    private func moveLocked(from old: String, to new: String) {
        let oldKey = Self.key(for: old)
        let newKey = Self.key(for: new)
        guard oldKey != newKey else { return }
        let moving = loadLocked(old)
        let movingTombstones = (knownTombstones[oldKey] ?? []) + (pendingTombstones[oldKey] ?? [])
        let oldFormers = (formerPaths[oldKey] ?? []) + [old]
        let oldMerged = (mergedFormerKeys[oldKey] ?? []).union([oldKey])
        guard !moving.isEmpty || readFolder(oldKey).listed else { forget(oldKey); return }
        let staying = loadLocked(new)
        let date = now()
        let combined = HistoryMerge.merge([
            record(moving, path: new, device: "0-moving", writtenAt: date, tombstones: movingTombstones),
            record(staying, path: new, device: "1-staying", writtenAt: date, tombstones: knownTombstones[newKey] ?? []),
        ], clearedAt: clearedAt(), now: date)
        formerPaths[newKey] = Array(Set((formerPaths[newKey] ?? []) + oldFormers)).filter { Self.key(for: $0) != newKey }.sorted()
        knownTombstones[newKey] = HistoryMerge.liveTombstones((knownTombstones[newKey] ?? []) + movingTombstones, now: date)
        mergedFormerKeys[newKey] = (mergedFormerKeys[newKey] ?? []).union(oldMerged)
        forget(oldKey)
        // Saving deletes the old folder (and every folder it merged) once the new record is written.
        _ = saveLocked(combined, relativePath: new)
    }

    private func forget(_ key: String) {
        lastKnown[key] = nil
        knownTombstones[key] = nil
        pendingTombstones[key] = nil
        mergedFormerKeys[key] = nil
        formerPaths[key] = nil
    }

    // MARK: - Disk

    /// The readable records of one document's folder; `listed` is whether the folder exists.
    private func readFolder(_ key: String) -> (records: [SharedHistoryRecord], listed: Bool) {
        guard let items = CoordinatedFileAccess.contents(of: folder(key)) else { return ([], false) }
        var records: [SharedHistoryRecord] = []
        for item in items {
            let name = item.lastPathComponent
            // A record not downloaded yet (`.<device>.json.icloud`): ask for it, so a later load
            // merges it. It is not a record now, and it stays.
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let logical = folder(key).appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? FileManager.default.startDownloadingUbiquitousItem(at: logical)
            }
        }
        // `.json` only: a placeholder or anything else is not a record (and stays).
        for item in items where item.pathExtension == "json" && !item.lastPathComponent.hasPrefix(".") {
            guard let data = CoordinatedFileAccess.read(item),
                  let record = try? HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data),
                  record.format <= SharedHistoryRecord.currentFormat else { continue }
            records.append(record)
        }
        return (records, true)
    }

    /// Deletes a folder whose records were merged into `key`'s, first moving into `key`'s folder
    /// whatever in it was NOT merged (an unreadable or future-format record, a placeholder), so
    /// nothing unread is ever deleted. An item whose name is already taken there stays put, and so
    /// does its folder.
    private func retireFolder(_ oldKey: String, into key: String) {
        guard let items = CoordinatedFileAccess.contents(of: folder(oldKey)) else { return }
        var keep = false
        for item in items where !isReadableRecord(item) {
            let destination = folder(key).appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) || !CoordinatedFileAccess.move(item, to: destination) {
                keep = true
            }
        }
        if !keep { CoordinatedFileAccess.remove(folder(oldKey)) }
    }

    private func isReadableRecord(_ item: URL) -> Bool {
        guard item.pathExtension == "json", !item.lastPathComponent.hasPrefix("."),
              let data = CoordinatedFileAccess.read(item),
              let record = try? HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data) else { return false }
        return record.format <= SharedHistoryRecord.currentFormat
    }

    /// Removes the folder only when everything in it is a readable record with no passages: a
    /// record that cannot be read (or a placeholder) may hold History, so it is never deleted.
    private func removeFolderIfEmpty(_ key: String) {
        guard let items = CoordinatedFileAccess.contents(of: folder(key)) else { return }
        for item in items {
            guard item.pathExtension == "json", !item.lastPathComponent.hasPrefix("."),
                  let data = CoordinatedFileAccess.read(item),
                  let record = try? HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data),
                  record.format <= SharedHistoryRecord.currentFormat, record.passages.isEmpty else { return }
        }
        CoordinatedFileAccess.remove(folder(key))
        forget(key)
    }

    private func recordedPathsLocked() -> [String] {
        (CoordinatedFileAccess.contents(of: documentsRoot) ?? []).compactMap { item in
            newestRecord(in: readFolder(item.lastPathComponent).records)?.path
        }.sorted()
    }

    private func newestRecord(in records: [SharedHistoryRecord]) -> SharedHistoryRecord? {
        records.min { $0.writtenAt != $1.writtenAt ? $0.writtenAt > $1.writtenAt : $0.device < $1.device }
    }

    /// The latest Clear History across devices, or this device's not-yet-written one.
    private func clearedAt() -> Date? {
        var latest = clearedFloor
        for item in CoordinatedFileAccess.contents(of: clearedRoot) ?? [] where item.pathExtension == "json" {
            guard let data = CoordinatedFileAccess.read(item),
                  let marker = try? HistoryMerge.decoder.decode(HistoryClearMarker.self, from: data) else { continue }
            latest = max(latest ?? marker.clearedAt, marker.clearedAt)
        }
        return latest
    }

    private func record(_ history: DocumentHistory, path: String, device: String, writtenAt: Date,
                        tombstones: [VersionTombstone]) -> SharedHistoryRecord {
        SharedHistoryRecord(format: SharedHistoryRecord.currentFormat, device: device, path: path, formerPaths: [],
                            writtenAt: writtenAt, passages: history.passages, deletedVersions: tombstones)
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
