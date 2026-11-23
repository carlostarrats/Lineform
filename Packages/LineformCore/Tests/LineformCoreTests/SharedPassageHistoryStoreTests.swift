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

    private func store(_ device: String, confirmedMissing: ((URL) -> Bool)? = nil) -> SharedPassageHistoryStore {
        let clock = clock
        return SharedPassageHistoryStore(containerURL: container, device: device, now: { clock.now },
                                         isConfirmedMissing: confirmedMissing ?? { [unowned self] url in
                                             self.missing.contains(url.lastPathComponent)
                                         })
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
        XCTAssertTrue(a.save(DocumentHistory(passages: [passage(p1, [v("One", -10), v("Two", -5)])]), relativePath: "Notes/Draft.md"))
        XCTAssertEqual(names(folder("Notes/Draft.md")), ["mac-A.json"])
        XCTAssertEqual(names(container.appendingPathComponent("Documents")), [])
        XCTAssertEqual(names(container.appendingPathComponent("History/v1/Documents")).count, 1)
    }

    func testTwoDevicesSeeEachOthersVersions() {
        let a = store("mac-A"), b = store("iphone-B")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        var history = b.load(relativePath: "d.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two"])
        history.passages[0].versions.append(v("Three", -10))
        history.passages[0].currentIndex = 2
        clock.advance(1)
        b.save(history, relativePath: "d.md")
        XCTAssertEqual(names(folder("d.md")), ["iphone-B.json", "mac-A.json"])
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p1), ["One", "Two", "Three"])
    }

    /// Review Focus 1: B's `.md` is stale, so B's engine cannot find A's passage and saves without
    /// it. A's record still holds it, and every reader still sees it.
    func testPassageDroppedLocallyIsNotDeletedFromOtherRecords() {
        let a = store("mac-A"), b = store("iphone-B")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)]),
                                          passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        var history = b.load(relativePath: "d.md")
        history.passages.removeAll { $0.id == p1 }
        clock.advance(1)
        b.save(history, relativePath: "d.md")
        XCTAssertEqual(texts(a.load(relativePath: "d.md"), p1), ["One", "Two"])
        XCTAssertEqual(texts(b.load(relativePath: "d.md"), p1), ["One", "Two"])
    }

    func testDeletedVersionStaysDeletedAfterOtherDeviceSaves() {
        let a = store("mac-A"), b = store("iphone-B")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20), v("Three", -10)])]), relativePath: "d.md")
        let stale = b.load(relativePath: "d.md")       // B holds all three
        var history = a.load(relativePath: "d.md")
        history.passages[0].versions.remove(at: 1)
        history.passages[0].currentIndex = 1
        clock.advance(1)
        a.save(history, relativePath: "d.md")
        clock.advance(1)
        b.save(stale, relativePath: "d.md")             // B's stale record still has "Two", and is newer
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
        a.save(original, relativePath: "d.md")
        let stale = b.load(relativePath: "d.md")
        XCTAssertEqual(texts(stale, p1), ["One", "Two"])

        // The engine removes p1 (and its child) when one of its two versions is deleted.
        let before = a.load(relativePath: "d.md")
        a.noteVersionDeleted(passage: p1, at: 0, in: before, relativePath: "d.md")
        var after = before
        after.passages.removeAll { $0.id == p1 || $0.id == child }
        clock.advance(1)
        a.save(after, relativePath: "d.md")
        clock.advance(1)
        b.save(stale, relativePath: "d.md")

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
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        let dir = folder("d.md")
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("mac-X.json"))
        let future = #"{"format":2,"device":"mac-F","path":"d.md","formerPaths":[],"writtenAt":1900000000,"passages":[],"deletedVersions":[]}"#
        try Data(future.utf8).write(to: dir.appendingPathComponent("mac-F.json"))
        try Data().write(to: dir.appendingPathComponent(".mac-C.json.icloud"))

        let b = store("iphone-B")
        let history = b.load(relativePath: "d.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two"])
        clock.advance(1)
        b.save(history, relativePath: "d.md")
        clock.advance(1)
        a.save(DocumentHistory(passages: []), relativePath: "d.md")
        b.save(DocumentHistory(passages: []), relativePath: "d.md")
        b.prune(now: clock.now)
        XCTAssertEqual(names(dir), [".mac-C.json.icloud", "iphone-B.json", "mac-A.json", "mac-F.json", "mac-X.json"])
    }

    /// Review Focus 4: A renames `a.md` to `b.md`; B, offline, then writes to the old path. A
    /// reads B's version at the new path, and its next save retires the old folder.
    func testRecordWrittenToFormerPathIsMergedAtNewPath() {
        let a = store("mac-A"), b = store("iphone-B")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "a.md")
        var offline = b.load(relativePath: "a.md")
        a.move(from: "a.md", to: "b.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("a.md").path))
        XCTAssertEqual(names(folder("b.md")), ["mac-A.json"])

        offline.passages[0].versions.append(v("Three", -10))
        offline.passages[0].currentIndex = 2
        clock.advance(1)
        b.save(offline, relativePath: "a.md")
        XCTAssertEqual(names(folder("a.md")), ["iphone-B.json"])

        let fresh = store("mac-A")   // a relaunched A: only the record's formerPaths lead to the old folder
        let history = fresh.load(relativePath: "b.md")
        XCTAssertEqual(texts(history, p1), ["One", "Two", "Three"])
        clock.advance(1)
        XCTAssertTrue(fresh.save(history, relativePath: "b.md"))
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
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "Old/x.md")
        a.save(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "Older/y.md")
        a.moveDirectory(from: "Old", to: "New/Sub")
        XCTAssertEqual(texts(a.load(relativePath: "New/Sub/x.md"), p1), ["One", "Two"])
        XCTAssertEqual(texts(a.load(relativePath: "Older/y.md"), p2), ["Uno", "Dos"])
        XCTAssertEqual(a.storedRelativePaths(), ["New/Sub/x.md", "Older/y.md"])
    }

    // MARK: - Prune and empty

    func testPruneDeletesFolderOnlyWhenDocumentConfirmedMissing() {
        let a = store("mac-A")
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "gone.md")
        a.save(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "here.md")
        missing = ["gone.md"]
        a.prune(now: clock.now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("gone.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder("here.md").path))
    }

    func testPruneKeepsFolderForICloudPlaceholder() throws {
        let documents = container.appendingPathComponent("Documents/Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data().write(to: documents.appendingPathComponent(".Draft.md.icloud"))
        let a = store("mac-A", confirmedMissing: SharedPassageHistoryStore.confirmedMissing)
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "Notes/Draft.md")
        a.save(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "Notes/Gone.md")
        XCTAssertFalse(SharedPassageHistoryStore.confirmedMissing(documents.appendingPathComponent("Draft.md")))
        a.prune(now: clock.now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder("Notes/Draft.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("Notes/Gone.md").path))
    }

    func testPruneDeletesOtherDevicesRecordOnlyAfter30Days() {
        let a = store("mac-A"), b = store("iphone-B")
        // B's passages are touched recently enough to survive the merge, but its record is old.
        b.save(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        clock.advance(20 * 86_400)
        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        a.prune(now: clock.now)
        XCTAssertEqual(names(folder("d.md")), ["iphone-B.json", "mac-A.json"])
        clock.advance(11 * 86_400)
        a.prune(now: clock.now)
        XCTAssertEqual(names(folder("d.md")), ["mac-A.json"])
    }

    func testEmptySaveRemovesFolderWhenAllRecordsEmpty() {
        let a = store("mac-A"), b = store("iphone-B")
        // An empty save of a document with no History creates nothing.
        XCTAssertTrue(a.save(DocumentHistory(passages: []), relativePath: "none.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("none.md").path))

        a.save(DocumentHistory(passages: [passage(p1, [v("One", -30), v("Two", -20)])]), relativePath: "d.md")
        b.save(DocumentHistory(passages: [passage(p2, [v("Uno", -30), v("Dos", -20)])]), relativePath: "d.md")
        a.save(DocumentHistory(passages: []), relativePath: "d.md")
        XCTAssertEqual(names(folder("d.md")), ["iphone-B.json", "mac-A.json"])
        b.save(DocumentHistory(passages: []), relativePath: "d.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("d.md").path))
    }
}
