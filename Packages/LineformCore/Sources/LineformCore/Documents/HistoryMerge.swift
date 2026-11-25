import Foundation

/// One device's History for one shared document: `History/v1/Documents/<key>/<device>.json`.
/// Each device writes only its own record, so iCloud never makes a conflicted copy of a History
/// file; every reader merges all the records it finds (`HistoryMerge.merge`).
///
/// `passages` uses the local store's `HistoryPassage` shape unchanged. A record whose `format` is
/// newer than `currentFormat` is skipped on read and never deleted or rewritten.
public struct SharedHistoryRecord: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    var format: Int
    /// `mac-<UUID>` or `iphone-<UUID>`: the writer, which is also the file name.
    var device: String
    /// The document's path relative to the container's `Documents` folder, exactly as written.
    var path: String
    /// Earlier relative paths of this document (renames, folder moves): a reader also merges any
    /// record still filed under one of them.
    var formerPaths: [String]
    var writtenAt: Date
    var passages: [HistoryPassage]
    var deletedVersions: [VersionTombstone]
}

/// An explicit Delete Version, so a merge does not bring the version back from another record.
/// It names the version by passage, `createdAt` and author; it expires 30 days after `deletedAt`.
public struct VersionTombstone: Codable, Hashable, Sendable {
    var passage: UUID
    var createdAt: Date
    var author: HistoryAuthor
    var deletedAt: Date
}

/// Clear History on one device: `History/v1/Cleared/<device>.json`. Every passage last touched
/// at or before the latest marker across devices is dropped by every merge.
public struct HistoryClearMarker: Codable, Equatable, Sendable {
    var format: Int
    var device: String
    var clearedAt: Date
}

/// The pure merge of shared History records (plan decisions D3 and D4). Deterministic: the result
/// depends on the set of records, never on the order they were listed in, and merging a record
/// with itself changes nothing. Nothing is ever lost to a conflict: a version leaves only through
/// a tombstone, a Clear History marker, or the 30-day rule.
enum HistoryMerge {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        // Stable bytes for the same record, so a rewrite that changes nothing is recognisable.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Identity of a version across records: `createdAt` (exact bits), author, and how many
    /// earlier versions of the same passage IN THE SAME RECORD share that date and author (the
    /// `[original(you), accepted(ai)]` pair of an accepted AI change shares one date).
    struct VersionKey: Hashable {
        var createdAt: UInt64
        var author: HistoryAuthor
        var ordinal: Int
    }

    /// What a tombstone matches: every version of the passage with this date and author.
    private struct TombstoneKey: Hashable {
        var passage: UUID
        var createdAt: UInt64
        var author: HistoryAuthor
    }

    /// Two histories of ONE document as one, add-wins (a move out of the container: the local
    /// History ∪ every shared record). `given` wins scalar ties, as in `SharedPassageHistoryStore.merge`.
    static func union(_ given: DocumentHistory, _ other: DocumentHistory, now: Date) -> DocumentHistory {
        func record(_ history: DocumentHistory, _ device: String) -> SharedHistoryRecord {
            SharedHistoryRecord(format: SharedHistoryRecord.currentFormat, device: device, path: "", formerPaths: [],
                                writtenAt: now, passages: history.passages, deletedVersions: [])
        }
        return merge([record(given, "0-given"), record(other, "1-other")], clearedAt: nil, now: now)
    }

    static func merge(_ records: [SharedHistoryRecord], clearedAt: Date?, now: Date) -> DocumentHistory {
        // Rule 1: newest record first; ties by device. A future format is never read.
        let ordered = records
            .filter { $0.format <= SharedHistoryRecord.currentFormat }
            .sorted { $0.writtenAt != $1.writtenAt ? $0.writtenAt > $1.writtenAt : $0.device < $1.device }
        let deleted = Set(liveTombstones(ordered.flatMap(\.deletedVersions), now: now).map {
            TombstoneKey(passage: $0.passage, createdAt: $0.createdAt.timeIntervalSince1970.bitPattern, author: $0.author)
        })

        // Every passage id, in the order first seen scanning newest-first.
        var passageOrder: [UUID] = []
        var holders: [UUID: [HistoryPassage]] = [:]   // newest-first copies of each passage
        var newestRecord: [UUID: Int] = [:]           // index in `ordered` of each passage's newest holder
        var byRecord: [[UUID: HistoryPassage]] = []
        for (r, record) in ordered.enumerated() {
            var here: [UUID: HistoryPassage] = [:]
            for passage in record.passages where here[passage.id] == nil {
                here[passage.id] = passage
                if holders[passage.id] == nil {
                    passageOrder.append(passage.id)
                    newestRecord[passage.id] = r
                }
                holders[passage.id, default: []].append(passage)
            }
            byRecord.append(here)
        }

        // Rule 3: versions are the union by key; text from the newest holder; order by createdAt,
        // ties in first-seen order. Rule 4: a tombstone removes every version it names.
        struct Merged {
            var newest: HistoryPassage
            var versions: [HistoryVersion]
            var keys: [VersionKey]
            var lastTouched: Date
        }
        var merged: [UUID: Merged] = [:]
        for id in passageOrder {
            guard let copies = holders[id], let newest = copies.first else { continue }
            var seen: [VersionKey: (version: HistoryVersion, sequence: Int)] = [:]
            var sequence = 0
            for copy in copies {
                for (key, version) in zip(keys(of: copy), copy.versions) where seen[key] == nil {
                    seen[key] = (version, sequence)
                    sequence += 1
                }
            }
            let survivors = seen
                .filter { !deleted.contains(TombstoneKey(passage: id, createdAt: $0.key.createdAt, author: $0.key.author)) }
                .sorted { ($0.value.version.createdAt, $0.value.sequence) < ($1.value.version.createdAt, $1.value.sequence) }
            // Rule 5: a passage with no surviving versions is dropped.
            guard !survivors.isEmpty else { continue }
            merged[id] = Merged(newest: newest, versions: survivors.map(\.value.version), keys: survivors.map(\.key),
                                lastTouched: copies.map(\.lastTouched).max() ?? newest.lastTouched)
        }

        // Rules 6 and 7: Clear History, then the 30-day rule, by the merged `lastTouched`.
        let staleCutoff = now.addingTimeInterval(-FilePassageHistoryStore.staleInterval)
        merged = merged.filter { _, passage in
            if let clearedAt, passage.lastTouched <= clearedAt { return false }
            return passage.lastTouched >= staleCutoff
        }

        // Rule 2: scalars from the newest holder; current and parent versions by key (rule 5's
        // fallbacks when the version is gone).
        var passages: [HistoryPassage] = []
        for id in passageOrder {
            guard let entry = merged[id] else { continue }
            let newest = entry.newest
            var passage = newest
            passage.versions = entry.versions
            passage.lastTouched = entry.lastTouched
            passage.currentIndex = currentIndex(of: newest, in: entry.keys)
            if let parentID = newest.parentID, let parent = merged[parentID] {
                // The parent version is read from the parent's copy in the SAME record as the
                // child's newest copy: that is the version list the child's index refers to.
                let parentCurrent = currentIndex(of: parent.newest, in: parent.keys)
                if let index = newest.parentVersionIndex,
                   let r = newestRecord[id], let parentCopy = byRecord[r][parentID] {
                    let own = keys(of: parentCopy)
                    passage.parentVersionIndex = own.indices.contains(index)
                        ? parent.keys.firstIndex(of: own[index]) ?? parentCurrent
                        : parentCurrent
                } else if newest.parentVersionIndex != nil {
                    passage.parentVersionIndex = parentCurrent
                }
            }
            passages.append(passage)
        }
        // Rule 8: what any stored history is when loaded.
        return DocumentHistoryEngine.preparedForLoad(DocumentHistory(passages: passages))
    }

    /// D4: a tombstone for every version that was in `previous` and is gone from a passage `saved`
    /// still holds. A passage missing from `saved` produces none (add-wins: the engine drops
    /// passages it cannot find in the text, and that must never delete another device's versions).
    static func tombstones(from previous: DocumentHistory, to saved: DocumentHistory, now: Date) -> [VersionTombstone] {
        let before = Dictionary(previous.passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [VersionTombstone] = []
        for passage in saved.passages {
            guard let old = before[passage.id] else { continue }
            // A tombstone names a date and author, not an ordinal, so it is issued only when NO
            // version with that date and author is left: it would remove every one of them.
            let kept = Set(passage.versions.map { TombstoneKey(passage: passage.id, createdAt: $0.createdAt.timeIntervalSince1970.bitPattern, author: $0.author) })
            var issued = Set<TombstoneKey>()
            for version in old.versions {
                let key = TombstoneKey(passage: passage.id, createdAt: version.createdAt.timeIntervalSince1970.bitPattern, author: version.author)
                guard !kept.contains(key), issued.insert(key).inserted else { continue }
                result.append(VersionTombstone(passage: passage.id, createdAt: version.createdAt, author: version.author, deletedAt: now))
            }
        }
        return result
    }

    /// The union of `all`, one per version named (the latest `deletedAt` wins), without those
    /// expired 30 days after `deletedAt`, in a stable order.
    static func liveTombstones(_ all: [VersionTombstone], now: Date) -> [VersionTombstone] {
        let cutoff = now.addingTimeInterval(-FilePassageHistoryStore.staleInterval)
        var latest: [TombstoneKey: VersionTombstone] = [:]
        for tombstone in all where tombstone.deletedAt > cutoff {
            let key = TombstoneKey(passage: tombstone.passage, createdAt: tombstone.createdAt.timeIntervalSince1970.bitPattern, author: tombstone.author)
            if let known = latest[key], known.deletedAt >= tombstone.deletedAt { continue }
            latest[key] = tombstone
        }
        return latest.values.sorted {
            ($0.passage.uuidString, $0.createdAt, $0.author.rawValue) < ($1.passage.uuidString, $1.createdAt, $1.author.rawValue)
        }
    }

    // MARK: - Keys

    static func keys(of passage: HistoryPassage) -> [VersionKey] {
        var counts: [TombstoneKey: Int] = [:]
        return passage.versions.map { version in
            let pair = TombstoneKey(passage: passage.id, createdAt: version.createdAt.timeIntervalSince1970.bitPattern, author: version.author)
            let ordinal = counts[pair, default: 0]
            counts[pair] = ordinal + 1
            return VersionKey(createdAt: pair.createdAt, author: version.author, ordinal: ordinal)
        }
    }

    /// The newest holder's current version, by key; the newest surviving version when it is gone.
    private static func currentIndex(of newest: HistoryPassage, in merged: [VersionKey]) -> Int {
        let own = keys(of: newest)
        if own.indices.contains(newest.currentIndex), let index = merged.firstIndex(of: own[newest.currentIndex]) {
            return index
        }
        return merged.count - 1
    }
}

public extension DocumentHistory {
    /// This history ∪ `other` (`HistoryMerge.union`; this one wins ties). Nothing is lost: every
    /// passage and version of either is kept.
    func merging(_ other: DocumentHistory, now: Date = Date()) -> DocumentHistory {
        if other.isEmpty { return self }
        if isEmpty { return other }
        return HistoryMerge.union(self, other, now: now)
    }
}
