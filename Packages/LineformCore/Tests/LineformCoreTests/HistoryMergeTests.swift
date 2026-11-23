import XCTest
@testable import LineformCore

final class HistoryMergeTests: XCTestCase {
    private let t0: TimeInterval = 1_800_000_000
    private var now: Date { date(86_400) }

    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }

    private func v(_ text: String, _ at: TimeInterval, _ author: HistoryAuthor = .you) -> HistoryVersion {
        HistoryVersion(text: text, author: author, createdAt: date(at))
    }

    private func passage(_ id: UUID, _ versions: [HistoryVersion], current: Int? = nil, level: HistoryLevel = .sentence,
                         parent: UUID? = nil, parentVersion: Int? = nil, before: String = "", after: String = "",
                         touched: TimeInterval? = nil) -> HistoryPassage {
        HistoryPassage(id: id, level: level, versions: versions, currentIndex: current ?? versions.count - 1,
                       parentID: parent, parentVersionIndex: parentVersion,
                       contextBefore: before, contextAfter: after,
                       lastTouched: touched.map(date) ?? versions.map(\.createdAt).max()!)
    }

    private func record(_ device: String, written: TimeInterval, _ passages: [HistoryPassage],
                        deleted: [VersionTombstone] = []) -> SharedHistoryRecord {
        SharedHistoryRecord(format: SharedHistoryRecord.currentFormat, device: device, path: "Notes/Draft.md",
                            formerPaths: [], writtenAt: date(written), passages: passages, deletedVersions: deleted)
    }

    private func tombstone(_ id: UUID, _ at: TimeInterval, _ author: HistoryAuthor = .you,
                           deleted: TimeInterval = 1_000) -> VersionTombstone {
        VersionTombstone(passage: id, createdAt: date(at), author: author, deletedAt: date(deleted))
    }

    private func merge(_ records: [SharedHistoryRecord], clearedAt: Date? = nil) -> DocumentHistory {
        HistoryMerge.merge(records, clearedAt: clearedAt, now: now)
    }

    private func texts(_ history: DocumentHistory, _ id: UUID) -> [String]? {
        history.passages.first { $0.id == id }?.versions.map(\.text)
    }

    private let p1 = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let p2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let p3 = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    // MARK: - Laws

    func testSingleRecordMergesToItself() {
        let parent = passage(p1, [v("The sea was calm.", 0), v("The sea lay calm.", 10)], level: .paragraph,
                             before: "# A\n\n", after: "\n")
        let child = passage(p2, [v("lay", 10), v("rested", 20, .ai)], current: 0, level: .word,
                            parent: p1, parentVersion: 1, before: "The sea ", after: " calm.")
        let single = passage(p3, [v("Gulls.", 0), v("Gulls cried.", 30)])
        let passages = [parent, child, single]
        let merged = merge([record("mac-A", written: 100, passages)])
        XCTAssertEqual(merged, DocumentHistoryEngine.preparedForLoad(DocumentHistory(passages: passages)))
        XCTAssertEqual(merged.passages.count, 3)
    }

    func testMergeIsOrderIndependent() {
        let a = record("mac-A", written: 100, [passage(p1, [v("Alpha", 0), v("Alpha 2", 10)]),
                                               passage(p2, [v("Beta", 0), v("Beta 2", 5)])])
        let b = record("iphone-B", written: 200, [passage(p1, [v("Alpha", 0), v("Alpha 3", 20)], before: "B"),
                                                  passage(p3, [v("Gamma", 0), v("Gamma 2", 7)])],
                       deleted: [tombstone(p2, 5)])
        let c = record("mac-C", written: 200, [passage(p3, [v("Gamma", 0), v("Gamma 3", 9)])])
        let reference = merge([a, b, c])
        for order in [[a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            XCTAssertEqual(merge(order), reference)
        }
    }

    func testMergeIsIdempotent() {
        let a = record("mac-A", written: 100, [passage(p1, [v("Alpha", 0), v("Alpha", 0, .ai), v("Alpha 2", 10)]),
                                               passage(p2, [v("Beta", 0), v("Beta 2", 5)])],
                       deleted: [tombstone(p2, 5)])
        XCTAssertEqual(merge([a, a]), merge([a]))
        XCTAssertEqual(merge([a, a, a]), merge([a]))
    }

    /// Two devices offline each add a version to one passage, then sync: both survive, by date.
    func testConcurrentVersionsOnOnePassageBothSurvive() {
        let a = record("mac-A", written: 100, [passage(p1, [v("Alpha", 0), v("Alpha 2", 10)])])
        let b = record("iphone-B", written: 50, [passage(p1, [v("Alpha", 0), v("Alpha 3", 20)])])
        XCTAssertEqual(texts(merge([a, b]), p1), ["Alpha", "Alpha 2", "Alpha 3"])
        XCTAssertEqual(texts(merge([b, a]), p1), ["Alpha", "Alpha 2", "Alpha 3"])
    }

    func testScalarsComeFromNewestRecord() throws {
        let older = record("mac-A", written: 50, [passage(p1, [v("Alpha", 0), v("Alpha 2", 10)], current: 1,
                                                          level: .sentence, before: "old ", after: " old", touched: 90)])
        let newer = record("iphone-B", written: 100, [passage(p1, [v("Alpha", 0), v("Alpha 2", 10)], current: 0,
                                                              level: .paragraph, before: "new ", after: " new", touched: 60)])
        let merged = try XCTUnwrap(merge([older, newer]).passages.first)
        XCTAssertEqual(merged.currentIndex, 0)
        XCTAssertEqual(merged.level, .paragraph)
        XCTAssertEqual(merged.contextBefore, "new ")
        XCTAssertEqual(merged.contextAfter, " new")
        XCTAssertEqual(merged.lastTouched, date(90), "lastTouched is the max across records")

        // The newest record wins on text too, for a version both hold.
        let edited = record("mac-C", written: 200, [passage(p1, [v("Alpha", 0), v("Alpha 2 edited", 10)])])
        XCTAssertEqual(texts(merge([older, newer, edited]), p1), ["Alpha", "Alpha 2 edited"])
    }

    /// Add-wins: a passage one device no longer holds is never removed by that absence.
    func testPassageMissingFromOneRecordIsKept() {
        let a = record("mac-A", written: 50, [passage(p1, [v("Alpha", 0), v("Alpha 2", 10)]),
                                              passage(p2, [v("Beta", 0), v("Beta 2", 10)])])
        let b = record("iphone-B", written: 100, [passage(p1, [v("Alpha", 0), v("Alpha 2", 10)])])
        let merged = merge([a, b])
        XCTAssertEqual(merged.passages.map(\.id), [p1, p2])
        XCTAssertEqual(texts(merged, p2), ["Beta", "Beta 2"])
    }

    // MARK: - Tombstones

    func testTombstoneRemovesOnlyThatVersion() {
        let a = record("mac-A", written: 50, [passage(p1, [v("Alpha", 0), v("Beta", 10), v("Gamma", 20), v("Beta", 30)])])
        // The tombstone lives in ANOTHER record than the version it removes.
        let b = record("iphone-B", written: 100, [], deleted: [tombstone(p1, 10)])
        XCTAssertEqual(texts(merge([a, b]), p1), ["Alpha", "Gamma", "Beta"],
                       "the same text with another createdAt survives")

        // A tombstone of another author, another date or another passage removes nothing.
        let other = record("iphone-B", written: 100, [], deleted: [tombstone(p1, 20, .ai), tombstone(p1, 25), tombstone(p2, 10)])
        XCTAssertEqual(texts(merge([a, other]), p1), ["Alpha", "Beta", "Gamma", "Beta"])
    }

    func testTombstonedCurrentVersionFallsBackToNewestSurvivor() throws {
        let a = record("mac-A", written: 100, [passage(p1, [v("A", 0), v("B", 10), v("C", 20)], current: 1)],
                       deleted: [tombstone(p1, 10)])
        let merged = try XCTUnwrap(merge([a]).passages.first)
        XCTAssertEqual(merged.versions.map(\.text), ["A", "C"])
        XCTAssertEqual(merged.currentIndex, 1)
    }

    func testTombstonesForDeletedVersionsOnly() {
        let previous = DocumentHistory(passages: [passage(p1, [v("a", 0), v("b", 10), v("c", 20)]),
                                                  passage(p2, [v("x", 0), v("y", 10)])])
        let saved = DocumentHistory(passages: [passage(p1, [v("a", 0), v("c", 20)])])
        XCTAssertEqual(HistoryMerge.tombstones(from: previous, to: saved, now: now),
                       [VersionTombstone(passage: p1, createdAt: date(10), author: .you, deletedAt: now)],
                       "a version removed from a kept passage is tombstoned; a removed passage is not")
        XCTAssertEqual(HistoryMerge.tombstones(from: previous, to: previous, now: now), [])
        XCTAssertEqual(HistoryMerge.tombstones(from: DocumentHistory(passages: []), to: saved, now: now), [])
    }

    /// A tombstone names a date and author, not an ordinal: it is issued only when no version
    /// with that pair is left, since it would remove every one of them.
    func testNoTombstoneWhileAVersionWithTheSameDateAndAuthorRemains() {
        let previous = DocumentHistory(passages: [passage(p1, [v("a", 0), v("b", 0), v("c", 20)])])
        let saved = DocumentHistory(passages: [passage(p1, [v("a", 0), v("c", 20)])])
        XCTAssertEqual(HistoryMerge.tombstones(from: previous, to: saved, now: now), [])
    }

    func testExpiredTombstonesAreForgotten() {
        let expired = tombstone(p1, 10, deleted: 86_400 - FilePassageHistoryStore.staleInterval - 1)
        let live = tombstone(p1, 20, deleted: 86_400 - 24 * 60 * 60)
        let liveAgain = tombstone(p1, 20, deleted: 86_400 - 2 * 24 * 60 * 60)
        XCTAssertEqual(HistoryMerge.liveTombstones([expired, live, liveAgain, live], now: now), [live],
                       "unexpired, de-duplicated, latest deletedAt kept")

        let a = record("mac-A", written: 100, [passage(p1, [v("A", 0), v("B", 10), v("C", 20), v("D", 30)])],
                       deleted: [expired, live])
        XCTAssertEqual(texts(merge([a]), p1), ["A", "B", "D"], "an expired tombstone no longer removes its version")
    }

    // MARK: - Version keys

    func testSameCreatedAtDifferentAuthorsAreDistinct() {
        // An accepted AI change: [original(you), accepted(ai)] sharing one date.
        let a = record("mac-A", written: 50, [passage(p1, [v("orig", 0), v("accepted", 0, .ai)])])
        let b = record("iphone-B", written: 100, [passage(p1, [v("orig", 0), v("accepted", 0, .ai), v("more", 10)])])
        XCTAssertEqual(texts(merge([a, b]), p1), ["orig", "accepted", "more"])
        XCTAssertEqual(texts(merge([a, a]), p1), ["orig", "accepted"])

        let deletesAI = record("mac-C", written: 10, [], deleted: [tombstone(p1, 0, .ai)])
        XCTAssertEqual(texts(merge([a, b, deletesAI]), p1), ["orig", "more"])
    }

    /// A child whose parent version moved index after the union still hangs on the same version.
    func testChildFollowsParentVersionByKeyAcrossReordering() throws {
        let newer = record("mac-A", written: 100, [
            // The parent shows "P zero" now; the child was made in "P two".
            passage(p1, [v("P zero", 0), v("P two", 20)], current: 0, level: .paragraph),
            passage(p2, [v("two", 20), v("deux", 30, .ai)], level: .word, parent: p1, parentVersion: 1),
        ])
        let older = record("iphone-B", written: 50, [
            passage(p1, [v("P zero", 0), v("P one", 10)], current: 1, level: .paragraph),
        ])
        let merged = merge([newer, older])
        let parent = try XCTUnwrap(merged.passages.first { $0.id == p1 })
        let child = try XCTUnwrap(merged.passages.first { $0.id == p2 })
        XCTAssertEqual(parent.versions.map(\.text), ["P zero", "P one", "P two"])
        XCTAssertEqual(parent.currentIndex, 0)
        XCTAssertEqual(child.parentID, p1)
        XCTAssertEqual(child.parentVersionIndex, 2, "still on \"P two\", which moved from index 1 to 2")
    }

    func testChildOfDeletedParentVersionHangsOnParentsCurrent() throws {
        let a = record("mac-A", written: 100, [
            passage(p1, [v("P zero", 0), v("P one", 10), v("P two", 20)], current: 2, level: .paragraph),
            passage(p2, [v("one", 10), v("un", 30, .ai)], level: .word, parent: p1, parentVersion: 1),
        ], deleted: [tombstone(p1, 10)])
        let child = try XCTUnwrap(merge([a]).passages.first { $0.id == p2 })
        XCTAssertEqual(child.parentVersionIndex, 1, "the parent's current version, \"P two\", now at index 1")
    }

    // MARK: - Clear History and age

    func testClearDropsPassagesTouchedBeforeAndKeepsLater() {
        let a = record("mac-A", written: 100, [passage(p1, [v("A", 0), v("A2", 10)], touched: 10),
                                               passage(p2, [v("B", 0), v("B2", 10)], touched: 20)])
        let b = record("iphone-B", written: 200, [passage(p3, [v("C", 0), v("C2", 30)], touched: 30)])
        let merged = merge([a, b], clearedAt: date(20))
        XCTAssertEqual(merged.passages.map(\.id), [p3], "touched at or before the clear: dropped; after: kept")

        // A device that touched a passage after the clear keeps it, though the other record is old.
        let touchedAgain = record("iphone-B", written: 200, [passage(p1, [v("A", 0), v("A2", 10)], touched: 25)])
        XCTAssertEqual(merge([a, touchedAgain], clearedAt: date(20)).passages.map(\.id), [p1])
    }

    func testStalePassagesAreDropped() {
        let day: TimeInterval = 24 * 60 * 60
        let staleAt = 86_400 - 31 * day, freshAt = 86_400 - day
        let a = record("mac-A", written: 100, [passage(p1, [v("Old", staleAt - 10), v("Old 2", staleAt)]),
                                               passage(p2, [v("New", staleAt), v("New 2", freshAt)])])
        XCTAssertEqual(merge([a]).passages.map(\.id), [p2])
    }

    // MARK: - Format

    func testRecordRoundTripsThroughJSON() throws {
        let original = record("mac-A", written: 100.25, [
            passage(p1, [v("P zero", 0.5), v("P two", 20)], current: 1, level: .paragraph, before: "# A\n", after: "\n"),
            passage(p2, [v("two", 20), v("deux", 30, .ai)], level: .word, parent: p1, parentVersion: 1),
        ], deleted: [tombstone(p1, 10, .ai)])
        let data = try HistoryMerge.encoder.encode(original)
        let decoded = try HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(merge([decoded, original]), merge([original]),
                       "a version read back from disk has the same key as the one in memory")
        XCTAssertEqual(try HistoryMerge.encoder.encode(decoded), data, "the bytes are stable")
    }

    func testRecordFieldNames() throws {
        let original = record("iphone-B", written: 100, [passage(p1, [v("A", 0), v("B", 10)])],
                              deleted: [tombstone(p1, 5)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: HistoryMerge.encoder.encode(original)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "device", "path", "formerPaths", "writtenAt", "passages", "deletedVersions"])
        XCTAssertEqual(object["format"] as? Int, 1)
        XCTAssertEqual(object["device"] as? String, "iphone-B")
        XCTAssertEqual(object["path"] as? String, "Notes/Draft.md")
        XCTAssertEqual(object["writtenAt"] as? Double, t0 + 100, "dates are seconds since 1970")
        let tombstones = try XCTUnwrap(object["deletedVersions"] as? [[String: Any]])
        XCTAssertEqual(Set(tombstones[0].keys), ["passage", "createdAt", "author", "deletedAt"])
        XCTAssertEqual(tombstones[0]["author"] as? String, "you")
        let passages = try XCTUnwrap(object["passages"] as? [[String: Any]])
        XCTAssertEqual(Set(passages[0].keys), ["id", "level", "versions", "currentIndex",
                                               "contextBefore", "contextAfter", "lastTouched"],
                       "the local store's passage shape, unchanged")

        let marker = HistoryClearMarker(format: 1, device: "mac-A", clearedAt: date(0))
        let markerObject = try XCTUnwrap(JSONSerialization.jsonObject(with: HistoryMerge.encoder.encode(marker)) as? [String: Any])
        XCTAssertEqual(Set(markerObject.keys), ["format", "device", "clearedAt"])
        XCTAssertEqual(markerObject["clearedAt"] as? Double, t0)
    }

    func testRecordsOfAFutureFormatAreIgnored() {
        var future = record("mac-Z", written: 500, [passage(p1, [v("A", 0), v("Future", 40)])])
        future.format = SharedHistoryRecord.currentFormat + 1
        let a = record("mac-A", written: 100, [passage(p1, [v("A", 0), v("A2", 10)])])
        XCTAssertEqual(merge([a, future]), merge([a]))
    }

    // MARK: - Seeded fuzz

    /// SplitMix64: a fixed seed reproduces every case.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Random records over shared passages (no tombstones, no clear, nothing stale): the merge is
    /// order-independent and idempotent, and every version any record holds survives.
    func testSeededFuzzKeepsEveryVersionInAnyOrder() {
        var rng = SeededGenerator(state: 0x4C49_4E45_464F_524D)
        let ids = (0..<4).map { _ in UUID() }
        for round in 0..<200 {
            var records: [SharedHistoryRecord] = []
            var expected: [UUID: Set<String>] = [:]
            for device in 0..<Int.random(in: 1...4, using: &rng) {
                var passages: [HistoryPassage] = []
                for id in ids where Bool.random(using: &rng) {
                    // Unique text per version, so no adjacent duplicates collapse on load.
                    let count = Int.random(in: 2...4, using: &rng)
                    let versions = (0..<count).map { i in
                        v("\(id.uuidString.prefix(4))-\(device)-\(i)-\(round)", TimeInterval(i * 10 + device),
                          Bool.random(using: &rng) ? .you : .ai)
                    }
                    passages.append(passage(id, versions, current: Int.random(in: 0..<count, using: &rng)))
                    expected[id, default: []].formUnion(versions.map(\.text))
                }
                records.append(record("mac-\(device)", written: TimeInterval(Int.random(in: 0...3, using: &rng)), passages))
            }
            let reference = merge(records)
            XCTAssertEqual(merge(records.shuffled(using: &rng)), reference, "round \(round): order")
            XCTAssertEqual(merge(records + records), reference, "round \(round): idempotence")
            for (id, texts) in expected {
                XCTAssertEqual(Set(self.texts(reference, id) ?? []), texts, "round \(round): a version was lost")
            }
        }
    }
}
