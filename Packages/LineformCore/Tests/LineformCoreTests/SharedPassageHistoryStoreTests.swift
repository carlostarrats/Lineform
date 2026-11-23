import XCTest
@testable import LineformCore

/// Two devices are two store instances (`mac-A`, `iphone-B`) on ONE temp container folder. No test
/// touches the real iCloud container.
final class SharedPassageHistoryStoreTests: XCTestCase {
    private var container: URL!
    private var missing: Set<String> = []
    private let clock = TestClock()

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedHistory-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("iCloud~com~lineform~app", isDirectory: true)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        missing = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container.deletingLastPathComponent())
    }

    private func store(_ device: String, confirmedMissing: ((URL) -> Bool)? = nil,
                       isDownloaded: @escaping (URL) -> Bool = { _ in true },
                       conflicts: HistoryRecordConflicts = .none) -> SharedPassageHistoryStore {
        let clock = clock
        return SharedPassageHistoryStore(containerURL: container, device: device, now: { clock.now },
                                         isConfirmedMissing: confirmedMissing ?? { [unowned self] url in
                                             self.missing.contains(url.lastPathComponent)
                                         },
                                         isDownloaded: isDownloaded, conflicts: conflicts)
    }

    private func record(_ path: String, _ device: String) throws -> SharedHistoryRecord {
        let data = try Data(contentsOf: folder(path).appendingPathComponent("\(device).json"))
        return try HistoryMerge.decoder.decode(SharedHistoryRecord.self, from: data)
    }

    private func v(_ text: String, _ offset: TimeInterval, _ author: HistoryAuthor = .you) -> HistoryVersion {
        HistoryVersion(text: text, author: author, createdAt: clock.now.addingTimeInterval(offset))
    }

    private func passage(_ id: UUID = UUID(), _ versions: [HistoryVersion], parent: UUID? = nil,
                         parentVersion: Int? = nil) -> HistoryPassage {
        HistoryPassage(id: id, level: .sentence, versions: versions, currentIndex: versions.count - 1,
                       parentID: parent, parentVersionIndex: parentVersion, contextBefore: "", contextAfter: "",
                       lastTouched: versions.map(\.createdAt).max()!)
    }

    private func folder(_ path: String) -> URL {
        container.appendingPathComponent("History/v1/Documents/\(SharedPassageHistoryStore.key(for: path))")
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func texts(_ history: DocumentHistory, _ id: UUID) -> [String]? {
        history.passages.first { $0.id == id }?.versions.map(\.text)
    }

    private let p1 = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let p2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // MARK: - Records

    func testSaveWritesOnlyThisDevicesRecord() {
        let a = store("mac-A")
        XCTAssertTrue(a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -10), v("Two", -5)])]), relativePath: "Notes/Draft.md"))
        XCTAssertEqual(names(folder("Notes/Draft.md")), ["mac-A.json"])
        XCTAssertEqual(names(container.appendingPathComponent("Documents")), [])
        XCTAssertEqual(names(container.appendingPathComponent("History/v1/Documents")).count, 1)
    }

    func testTwoDevicesSeeEachOthersVersions() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        var history = b.load(relativePath: "d.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two"])
        history.passages[0].versions.append(v("Three", -10))
        history.passages[0].currentIndex = 2
        clock.advance(1)
        b.saveAndWait(history, relativePath: "d.md")
        XCTAssertEqual(names(folder("d.md")), ["iphone-B.json", "mac-A.json"])
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p1), ["One", "Two", "Three"])
    }

    /// Review Focus 1: B's `.md` is stale, so B's engine cannot find A's passage and saves without
    /// it. A's record still holds it, and every reader still sees it.
    func testPassageDroppedLocallyIsNotDeletedFromOtherRecords() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)]),
                                          passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        var history = b.load(relativePath: "d.md")
        history.passages.removeAll { $0.id == p1 }
        clock.advance(1)
        b.saveAndWait(history, relativePath: "d.md")
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p1), ["One", "Two"])
        XCTAssertEqual(texts(b.load(relativePath: "d.md"), p1), ["One", "Two"])
    }

    func testDeletedVersionStaysDeletedAfterOtherDeviceSaves() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20), v("Three", -10)])]), relativePath: "d.md")
        let stale = b.load(relativePath: "d.md")       // B holds all three
        var history = a.load(relativePath: "d.md")
        history.passages[0].versions.remove(at: 1)
        history.passages[0].currentIndex = 1
        clock.advance(1)
        a.saveAndWait(history, relativePath: "d.md")
        clock.advance(1)
        b.saveAndWait(stale, relativePath: "d.md")             // B's stale record still has "Two", and is newer
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p1), ["One", "Three"])
        XCTAssertEqual(texts(b.load(relativePath: "d.md"), p1), ["One", "Three"])
        XCTAssertEqual(texts(store("mac-C").load(relativePath: "d.md"), p1), ["One", "Three"])
    }

    /// The amendment: Delete Version on a two-version passage makes the engine remove the passage,
    /// which by itself writes no tombstone. `noteVersionDeleted` does.
    func testDeletingOneOfTwoVersionsStaysDeletedOnOtherDevice() {
        let a = store("mac-A"), b = store("iphone-B")
        let child = UUID()
        let original = DocumentHistory(passages: [
            passage(p1, [v("One", -30), v("Two", -20)]),
            passage(child, [v("w", -20), v("word", -15)], parent: p1, parentVersion: 1),
            passage(p2, [v("Uno", -30), v("Dos", -20)]),
        ])
        a.saveAndWait(original, relativePath: "d.md")
        let stale = b.load(relativePath: "d.md")
        XCTAssertEqual(texts(stale, p1), ["One", "Two"])

        // The engine removes p1 (and its child) when one of its two versions is deleted.
        let before = a.load(relativePath: "d.md")
        a.noteVersionDeleted(passage: p1, at: 0, in: before, relativePath: "d.md")
        var after = before
        after.passages.removeAll { $0.id == p1 || $0.id == child }
        clock.advance(1)
        a.saveAndWait(after, relativePath: "d.md")
        clock.advance(1)
        b.saveAndWait(stale, relativePath: "d.md")

        for reader in [a, b, store("mac-C")] {
            let merged = reader.load(relativePath: "d.md")
            XCTAssertNil(texts(merged, p1))
            XCTAssertNil(texts(merged, child))
            XCTAssertEqual(texts(merged, p2), ["Uno", "Dos"])
        }
    }

    /// Review Focus 3: garbage bytes, a newer format and an `.icloud` placeholder are skipped,
    /// never deleted, and the readable record still merges.
    func testUnreadableAndFutureRecordsAreSkippedNotDeleted() throws {
        let a = store("mac-A")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        let dir = folder("d.md")
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("mac-X.json"))
        let future = #"{"format":2,"device":"mac-F","path":"d.md","formerPaths":[],"writtenAt":1900000000,"passages":[],"deletedVersions":[]}"#
        try Data(future.utf8).write(to: dir.appendingPathComponent("mac-F.json"))
        try Data().write(to: dir.appendingPathComponent(".mac-C.json.icloud"))

        let b = store("iphone-B")
        let history = b.load(relativePath: "d.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two"])
        clock.advance(1)
        b.saveAndWait(history, relativePath: "d.md")
        clock.advance(1)
        a.saveAndWait(DocumentHistory(passages: []), relativePath: "d.md")
        b.saveAndWait(DocumentHistory(passages: []), relativePath: "d.md")
        b.prune(now: clock.now)
        XCTAssertEqual(names(dir), [".mac-C.json.icloud", "iphone-B.json", "mac-A.json", "mac-F.json", "mac-X.json"])
    }

    /// Review Focus 4: A renames `a.md` to `b.md`; B, offline, then writes to the old path. A
    /// reads B's version at the new path, and its next save retires the old folder.
    func testRecordWrittenToFormerPathIsMergedAtNewPath() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "a.md")
        var offline = b.load(relativePath: "a.md")
        a.move(from: "a.md", to: "b.md")
        a.waitForBackgroundWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("a.md").path))
        XCTAssertEqual(names(folder("b.md")), ["mac-A.json"])

        offline.passages[0].versions.append(v("Three", -10))
        offline.passages[0].currentIndex = 2
        clock.advance(1)
        b.saveAndWait(offline, relativePath: "a.md")
        XCTAssertEqual(names(folder("a.md")), ["iphone-B.json"])

        let fresh = store("mac-A")   // a relaunched A: only the record's formerPaths lead to the old folder
        let history = fresh.load(relativePath: "b.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two", "Three"])
        clock.advance(1)
        XCTAssertTrue(fresh.saveAndWait(history, relativePath: "b.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("a.md").path))
        XCTAssertEqual(texts(store("iphone-B").load(relativePath: "b.md"), p1), ["One", "Two", "Three"])
    }

    func testKeyIsCaseAndNormalisationInsensitive() {
        let nfc = "Caf\u{00E9}.md", nfd = "Cafe\u{0301}.md"
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        XCTAssertEqual(SharedPassageHistoryStore.key(for: nfc), SharedPassageHistoryStore.key(for: nfd))
        XCTAssertEqual(SharedPassageHistoryStore.key(for: "NOTES.md"), SharedPassageHistoryStore.key(for: "notes.md"))
        XCTAssertNotEqual(SharedPassageHistoryStore.key(for: "notes.md"), SharedPassageHistoryStore.key(for: "notes2.md"))
        XCTAssertEqual(SharedPassageHistoryStore.key(for: "notes.md").count, 64)
        XCTAssertEqual(SharedPassageHistoryStore.key(for: "notes.md"), SharedPassageHistoryStore.key(for: "notes.md").lowercased())
    }

    func testFolderMoveCarriesEveryDocumentAndLeavesNeighbours() {
        let a = store("mac-A")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "Old/x.md")
        a.saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "Older/y.md")
        a.moveDirectory(from: "Old", to: "New/Sub")
        a.waitForBackgroundWork()
        XCTAssertEqual(texts(a.load(relativePath: "New/Sub/x.md"), p1), ["One", "Two"])
        XCTAssertEqual(texts(a.load(relativePath: "Older/y.md"), p2), ["Uno", "Dos"])
        XCTAssertEqual(a.storedRelativePaths(), ["New/Sub/x.md", "Older/y.md"])
    }

    // MARK: - Prune and empty

    func testPruneDeletesFolderOnlyWhenDocumentConfirmedMissing() {
        let a = store("mac-A")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "gone.md")
        a.saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "here.md")
        missing = ["gone.md"]
        a.prune(now: clock.now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder("gone.md").path), "written less than 7 days ago")
        clock.advance(8 * 86_400)
        a.prune(now: clock.now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("gone.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder("here.md").path))
    }

    func testPruneKeepsFolderForICloudPlaceholder() throws {
        let documents = container.appendingPathComponent("Documents/Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data().write(to: documents.appendingPathComponent(".Draft.md.icloud"))
        let a = store("mac-A", confirmedMissing: SharedPassageHistoryStore.confirmedMissing)
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "Notes/Draft.md")
        a.saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "Notes/Gone.md")
        XCTAssertFalse(SharedPassageHistoryStore.confirmedMissing(documents.appendingPathComponent("Draft.md")))
        clock.advance(8 * 86_400)
        a.prune(now: clock.now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder("Notes/Draft.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("Notes/Gone.md").path))
    }

    func testPruneDeletesOtherDevicesRecordOnlyAfter30Days() {
        let a = store("mac-A"), b = store("iphone-B")
        // B's passages are touched recently enough to survive the merge, but its record is old.
        b.saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        clock.advance(20 * 86_400)
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        a.prune(now: clock.now)
        XCTAssertEqual(names(folder("d.md")), ["iphone-B.json", "mac-A.json"])
        clock.advance(11 * 86_400)
        a.prune(now: clock.now)
        XCTAssertEqual(names(folder("d.md")), ["mac-A.json"])
    }

    func testEmptySaveRemovesFolderWhenAllRecordsEmpty() {
        let a = store("mac-A"), b = store("iphone-B")
        // An empty save of a document with no History creates nothing.
        XCTAssertTrue(a.saveAndWait(DocumentHistory(passages: []), relativePath: "none.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("none.md").path))

        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        b.saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        a.saveAndWait(DocumentHistory(passages: []), relativePath: "d.md")
        XCTAssertEqual(names(folder("d.md")), ["iphone-B.json", "mac-A.json"])
        b.saveAndWait(DocumentHistory(passages: []), relativePath: "d.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("d.md").path))
    }

    // MARK: - C1: a move or a former-path retire never folds another device's record

    /// A and B both hold p1; B has a version A's `.md` does not show yet. A renames the document,
    /// then A's engine cannot locate p1 and saves without it. B's record moved WITH its own name,
    /// so p1 and every version survive.
    func testMoveKeepsOtherDevicesVersionsWhenTheEngineDropsAPassage() throws {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)]),
                                                 passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "a.md")
        var onB = b.load(relativePath: "a.md")
        let i = try XCTUnwrap(onB.passages.firstIndex { $0.id == p1 })
        onB.passages[i].versions.append(v("Three", -10))
        onB.passages[i].currentIndex = 2
        clock.advance(1)
        b.saveAndWait(onB, relativePath: "a.md")
        let onA = a.load(relativePath: "a.md")
        XCTAssertEqual(texts(onA, p1), ["One", "Two", "Three"])

        a.move(from: "a.md", to: "b.md")
        a.waitForBackgroundWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("a.md").path))
        XCTAssertEqual(names(folder("b.md")), ["iphone-B.json", "mac-A.json"])
        XCTAssertEqual(try record("b.md", "mac-A").path, "b.md")
        XCTAssertEqual(try record("b.md", "mac-A").formerPaths, ["a.md"])
        XCTAssertEqual(try record("b.md", "iphone-B").path, "a.md", "only this device's record is rewritten")

        var dropped = onA
        dropped.passages.removeAll { $0.id == p1 }
        clock.advance(1)
        XCTAssertTrue(a.saveAndWait(dropped, relativePath: "b.md"))
        for reader in [store("mac-A"), store("iphone-B"), store("mac-C")] {
            let merged = reader.load(relativePath: "b.md")
            XCTAssertEqual(texts(merged, p1), ["One", "Two", "Three"])
            XCTAssertEqual(texts(merged, p2), ["Uno", "Dos"])
        }
        XCTAssertEqual(a.storedRelativePaths(), ["b.md"])
    }

    /// Review Focus 4 with the engine dropping the passage: B writes to the old path after A's
    /// rename; A (relaunched) loads the new path through `formerPaths`, cannot locate p1, saves.
    /// The retire MOVES B's record into the new folder (merging it with B's file there).
    func testFormerPathRetireKeepsOtherDevicesVersionsWhenTheEngineDropsAPassage() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)]),
                                                 passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "a.md")
        var offline = b.load(relativePath: "a.md")
        b.saveAndWait(offline, relativePath: "a.md")
        a.move(from: "a.md", to: "b.md")
        a.waitForBackgroundWork()
        XCTAssertEqual(names(folder("b.md")), ["iphone-B.json", "mac-A.json"])

        let i = offline.passages.firstIndex { $0.id == p1 }!
        offline.passages[i].versions.append(v("Three", -10))
        offline.passages[i].currentIndex = 2
        clock.advance(1)
        b.saveAndWait(offline, relativePath: "a.md")   // B, offline, still at the old path
        XCTAssertEqual(names(folder("a.md")), ["iphone-B.json"])

        let fresh = store("mac-A")
        var history = fresh.load(relativePath: "b.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two", "Three"])
        history.passages.removeAll { $0.id == p1 }
        clock.advance(1)
        XCTAssertTrue(fresh.saveAndWait(history, relativePath: "b.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("a.md").path))
        XCTAssertEqual(names(folder("b.md")), ["iphone-B.json", "mac-A.json"])
        for reader in [store("mac-A"), store("iphone-B"), store("mac-C")] {
            let merged = reader.load(relativePath: "b.md")
            XCTAssertEqual(texts(merged, p1), ["One", "Two", "Three"])
            XCTAssertEqual(texts(merged, p2), ["Uno", "Dos"])
        }
    }

    /// RF1 variant: B dropped A's passage locally (stale `.md`), then renames. A's record moves
    /// with its own name: the passage is still there for every reader.
    func testRenameAfterAPassageWasDroppedLocallyKeepsIt() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)]),
                                                 passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        var onB = b.load(relativePath: "d.md")
        onB.passages.removeAll { $0.id == p1 }
        clock.advance(1)
        b.saveAndWait(onB, relativePath: "d.md")
        b.move(from: "d.md", to: "e.md")
        b.waitForBackgroundWork()
        clock.advance(1)
        b.saveAndWait(onB, relativePath: "e.md")
        XCTAssertEqual(texts(store("mac-C").load(relativePath: "e.md"), p1), ["One", "Two"])
    }

    // MARK: - C2: absence is not proof in iCloud

    /// History arrives before the document: the document is absent here, the record is another
    /// device's, so only the 30-day rule removes it.
    func testPruneKeepsAnotherDevicesRecordOfAnAbsentDocument() {
        let b = store("iphone-B")
        b.saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "Notes/New.md")
        missing = ["New.md"]
        clock.advance(8 * 86_400)
        store("mac-A").prune(now: clock.now)
        XCTAssertEqual(names(folder("Notes/New.md")), ["iphone-B.json"])
        clock.advance(23 * 86_400)
        store("mac-A").prune(now: clock.now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("Notes/New.md").path), "the 30-day rule")
    }

    /// A rename made elsewhere: the old path is absent on every device. The old folder is listed
    /// as a former path, so neither device's prune deletes it, and the next load of the new path
    /// merges it.
    func testFormerPathFolderSurvivesPruneAndMergesAtTheNextLoad() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "a.md")
        var offline = b.load(relativePath: "a.md")
        a.move(from: "a.md", to: "b.md")
        a.waitForBackgroundWork()
        offline.passages[0].versions.append(v("Three", -10))
        offline.passages[0].currentIndex = 2
        clock.advance(1)
        b.saveAndWait(offline, relativePath: "a.md")

        missing = ["a.md"]
        clock.advance(8 * 86_400)
        store("mac-A").prune(now: clock.now)
        store("iphone-B").prune(now: clock.now)
        XCTAssertEqual(names(folder("a.md")), ["iphone-B.json"])
        XCTAssertEqual(texts(store("mac-A").load(relativePath: "b.md"), p1), ["One", "Two", "Three"])
    }

    /// The session prune runs on a background queue while the first document loads.
    func testPruneRacingALoadLosesNothing() {
        let a = store("mac-A"), b = store("iphone-B")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "a.md")
        var offline = b.load(relativePath: "a.md")
        a.move(from: "a.md", to: "b.md")
        a.waitForBackgroundWork()
        offline.passages[0].versions.append(v("Three", -10))
        offline.passages[0].currentIndex = 2
        clock.advance(1)
        b.saveAndWait(offline, relativePath: "a.md")
        missing = ["a.md"]
        clock.advance(8 * 86_400)

        let pruner = store("mac-A"), loader = store("mac-A")
        let group = DispatchGroup()
        let clock = clock
        DispatchQueue.global().async(group: group) {
            for _ in 0..<10 { pruner.prune(now: clock.now) }
        }
        for _ in 0..<30 {
            let loaded = texts(loader.load(relativePath: "b.md"), p1) ?? []
            XCTAssertTrue(loaded.starts(with: ["One", "Two"]), "\(loaded)")
        }
        group.wait()
        XCTAssertEqual(texts(loader.load(relativePath: "b.md"), p1), ["One", "Two", "Three"])
        XCTAssertEqual(names(folder("a.md")), ["iphone-B.json"])
    }

    // MARK: - I1: queued, coalesced writes

    func testQueuedSavesCoalesceAndLoadPrefersThePendingRecord() {
        let a = store("mac-A")
        let first = DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])])
        let last = DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])])
        let results = Counter()
        a.save(first, relativePath: "d.md") { ok in results.add(ok) }
        a.save(last, relativePath: "d.md") { ok in results.add(ok) }
        XCTAssertNil(texts(a.load(relativePath: "d.md"), p1), "the pending record, not the disk")
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p2), ["Uno", "Dos"])
        a.waitForBackgroundWork()
        XCTAssertEqual(results.values, [true, true])
        XCTAssertEqual(texts(store("mac-C").load(relativePath: "d.md"), p2), ["Uno", "Dos"])
        XCTAssertNil(texts(store("mac-C").load(relativePath: "d.md"), p1))
    }

    /// A save queued before Clear History never writes the cleared History back.
    func testQueuedSaveNeverResurrectsClearedHistory() {
        let a = store("mac-A")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        clock.advance(1)
        a.clearAll(at: clock.now)
        a.waitForBackgroundWork()
        XCTAssertEqual(names(container.appendingPathComponent("History/v1/Documents")), [])
        XCTAssertEqual(a.load(relativePath: "d.md"), DocumentHistory(passages: []))
        XCTAssertEqual(store("mac-C").load(relativePath: "d.md"), DocumentHistory(passages: []))
    }

    /// A save queued for the old path follows the move: nothing is written at the old key.
    func testQueuedSaveFollowsAMove() {
        let a = store("mac-A")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "a.md")
        a.move(from: "a.md", to: "b.md")
        a.waitForBackgroundWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("a.md").path))
        XCTAssertEqual(texts(store("mac-C").load(relativePath: "b.md"), p1), ["One", "Two"])
        XCTAssertEqual(try record("b.md", "mac-A").path, "b.md")
    }

    /// A record with no local data is never read on load (that would wait for iCloud); it merges
    /// once it is downloaded.
    func testLoadSkipsARecordThatIsNotDownloaded() {
        store("iphone-B").saveAndWait(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        let downloaded = Flag()
        let a = store("mac-A", isDownloaded: { url in url.lastPathComponent != "iphone-B.json" || downloaded.isSet })
        XCTAssertNil(texts(a.load(relativePath: "d.md"), p2))
        downloaded.set()
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p2), ["Uno", "Dos"])
    }

    // MARK: - I2: this device's evicted record

    /// iCloud evicted this device's record (`.<device>.json.icloud`): the save does not overwrite
    /// it unread. It stays pending (load shows it) and is written once the record is back.
    func testOwnPlaceholderBlocksTheSaveAndKeepsItPending() throws {
        let a = store("mac-A")
        let stone = VersionTombstone(passage: p1, createdAt: clock.now.addingTimeInterval(-25), author: .you, deletedAt: clock.now)
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        let dir = folder("d.md")
        var stored = try record("d.md", "mac-A")
        stored.deletedVersions = [stone]
        let bytes = try HistoryMerge.encoder.encode(stored)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("mac-A.json"))
        try Data().write(to: dir.appendingPathComponent(".mac-A.json.icloud"))

        let relaunched = store("mac-A")
        XCTAssertEqual(relaunched.load(relativePath: "d.md"), DocumentHistory(passages: []))
        let newer = DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])])
        XCTAssertFalse(relaunched.saveAndWait(newer, relativePath: "d.md"))
        XCTAssertEqual(names(dir), [".mac-A.json.icloud"], "nothing written over the evicted record")
        XCTAssertEqual(texts(relaunched.load(relativePath: "d.md"), p2), ["Uno", "Dos"], "the save is still pending")

        // The record downloads; the next save writes, keeping what the evicted record held.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".mac-A.json.icloud"))
        try bytes.write(to: dir.appendingPathComponent("mac-A.json"))
        XCTAssertTrue(relaunched.saveAndWait(newer, relativePath: "d.md"))
        XCTAssertEqual(try record("d.md", "mac-A").deletedVersions, [stone])
    }

    // MARK: - I3: conflict versions

    /// Two writers of one record (a device id restored onto a second device): the conflict
    /// version merges on load, and prune folds it into the file and resolves it.
    func testConflictVersionsMergeOnLoadAndResolveAtPrune() throws {
        let a = store("mac-A")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        var other = try record("d.md", "mac-A")
        other.passages = [passage(p2, [v("Uno", -30), v("Dos", -20)])]
        let conflict = try HistoryMerge.encoder.encode(other)
        let resolved = Flag()
        let conflicts = HistoryRecordConflicts(
            versions: { url in url.lastPathComponent == "mac-A.json" && !resolved.isSet ? [conflict] : [] },
            resolve: { _ in resolved.set() })
        let reader = store("iphone-B", conflicts: conflicts)
        XCTAssertEqual(texts(reader.load(relativePath: "d.md"), p1), ["One", "Two"])
        XCTAssertEqual(texts(reader.load(relativePath: "d.md"), p2), ["Uno", "Dos"])
        reader.prune(now: clock.now)
        XCTAssertTrue(resolved.isSet)
        let merged = store("mac-C").load(relativePath: "d.md")
        XCTAssertEqual(texts(merged, p1), ["One", "Two"])
        XCTAssertEqual(texts(merged, p2), ["Uno", "Dos"])
    }

    // MARK: - Former paths

    func testFormerPathsAreCappedAndTrimmedWhenTheirFolderIsGone() throws {
        let a = store("mac-A")
        a.saveAndWait(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "n0.md")
        for n in 1...25 { a.move(from: "n\(n - 1).md", to: "n\(n).md") }
        a.waitForBackgroundWork()
        let formers = try record("n25.md", "mac-A").formerPaths
        XCTAssertEqual(formers.count, 20)
        XCTAssertEqual(formers.last, "n24.md", "the most recent kept")
        XCTAssertFalse(formers.contains("n0.md"))
        XCTAssertEqual(texts(store("mac-C").load(relativePath: "n25.md"), p1), ["One", "Two"])
        a.prune(now: clock.now)
        XCTAssertEqual(try record("n25.md", "mac-A").formerPaths, [], "none of those folders exists any more")
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
        func add(_ value: Bool) { lock.lock(); stored.append(value); lock.unlock() }
    }
}
