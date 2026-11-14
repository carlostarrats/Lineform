import XCTest
@testable import Lineform

final class PassageHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var missing: Set<String> = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassageHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        missing = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> FilePassageHistoryStore {
        FilePassageHistoryStore(directory: directory, isConfirmedMissing: { [unowned self] url in
            self.missing.contains(url.path)
        })
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/lineform-history-tests/\(name)")
    }

    private func history(touched: Date = Date(timeIntervalSince1970: 1_000_000)) -> DocumentHistory {
        // Two versions: a one-version passage is discarded on load.
        let versions = [HistoryVersion(text: "Hi", author: .you, createdAt: touched),
                        HistoryVersion(text: "Hello", author: .you, createdAt: touched)]
        let passage = HistoryPassage(
            id: UUID(), level: .sentence, versions: versions, currentIndex: 1,
            parentID: nil, parentVersionIndex: nil,
            contextBefore: "before ", contextAfter: " after", lastTouched: touched)
        return DocumentHistory(passages: [passage])
    }

    private func storedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func testRoundTripsHistoryForAFile() {
        let store = makeStore()
        let saved = history()
        store.save(saved, for: url("a.md"))
        XCTAssertEqual(store.load(for: url("a.md")), saved)
    }

    /// 1.8.0's Add to History stored the original twice (a frozen copy plus an identical live
    /// version). Loading collapses adjacent identical versions, so the sidebar lists it once.
    func testLoadCollapsesAdjacentDuplicateVersions() throws {
        let store = makeStore()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let passage = HistoryPassage(
            id: UUID(), level: .word,
            versions: [HistoryVersion(text: "gentle", author: .you, createdAt: date),
                       HistoryVersion(text: "gentle", author: .you, createdAt: date),
                       HistoryVersion(text: "dangerous", author: .you, createdAt: date)],
            currentIndex: 2, parentID: nil, parentVersionIndex: nil,
            contextBefore: "The wind was ", contextAfter: " that night.", lastTouched: date)
        store.save(DocumentHistory(passages: [passage]), for: url("a.md"))
        let loaded = try XCTUnwrap(store.load(for: url("a.md")).passages.first)
        XCTAssertEqual(loaded.versions.map(\.text), ["gentle", "dangerous"])
        XCTAssertEqual(loaded.currentIndex, 1)
    }

    /// A one-version passage only exists while History mode is open on it, so one on disk (quit
    /// while History was open, or 1.8.0's doubled Add once collapsed) is discarded on load; its
    /// revised children move up to its parent. Two-version passages load untouched.
    func testLoadDiscardsOneVersionPassages() throws {
        let store = makeStore()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let passage = HistoryPassage(
            id: UUID(), level: .word,
            versions: [HistoryVersion(text: "gentle", author: .you, createdAt: date),
                       HistoryVersion(text: "gentle", author: .you, createdAt: date)],
            currentIndex: 1, parentID: nil, parentVersionIndex: nil,
            contextBefore: "The wind was ", contextAfter: " that night.", lastTouched: date)
        store.save(DocumentHistory(passages: [passage]), for: url("a.md"))
        let kept = history().passages[0]
        let unrevisedID = UUID()
        let unrevised = HistoryPassage(
            id: unrevisedID, level: .sentence,
            versions: [HistoryVersion(text: "The wind was gentle that night.", author: .you, createdAt: date)],
            currentIndex: 0, parentID: nil, parentVersionIndex: nil,
            contextBefore: "", contextAfter: "", lastTouched: date)
        let child = HistoryPassage(
            id: UUID(), level: .word,
            versions: [HistoryVersion(text: "calm", author: .you, createdAt: date),
                       HistoryVersion(text: "gentle", author: .you, createdAt: date)],
            currentIndex: 1, parentID: unrevisedID, parentVersionIndex: 0,
            contextBefore: "The wind was ", contextAfter: " that night.", lastTouched: date)
        store.save(DocumentHistory(passages: [passage, kept, unrevised, child]), for: url("a.md"))
        let loaded = store.load(for: url("a.md"))
        XCTAssertEqual(loaded.passages.map(\.id), [kept.id, child.id], "both one-version passages are gone")
        XCTAssertEqual(loaded.passages.first, kept, "a two-version passage loads untouched")
        let movedUp = try XCTUnwrap(loaded.passages.last)
        XCTAssertNil(movedUp.parentID)
        XCTAssertNil(movedUp.parentVersionIndex)
        XCTAssertEqual(movedUp.versions.map(\.text), ["calm", "gentle"])
    }

    func testSavingEmptyHistoryRemovesItsFiles() throws {
        let store = makeStore()
        store.save(history(), for: url("a.md"))
        XCTAssertEqual(storedFiles().count, 2)
        store.save(DocumentHistory(passages: []), for: url("a.md"))
        XCTAssertFalse(storedFiles().contains { $0 != "index.json" })
        let indexData = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let index = try JSONSerialization.jsonObject(with: indexData) as? [Any]
        XCTAssertEqual(index?.count, 0)
    }

    func testRetargetMovesHistoryToNewURL() {
        let store = makeStore()
        let saved = history()
        store.save(saved, for: url("a.md"))
        store.retarget(from: url("a.md"), to: url("b.md"))
        XCTAssertEqual(store.load(for: url("b.md")), saved)
        XCTAssertTrue(store.load(for: url("a.md")).isEmpty)
    }

    func testPruneDropsHistoryOfDeletedFile() {
        let store = makeStore()
        store.save(history(touched: Date()), for: url("gone.md"))
        missing.insert(FileIdentity.key(for: url("gone.md")))
        store.prune(now: Date())
        XCTAssertTrue(store.load(for: url("gone.md")).isEmpty)
    }

    func testPruneDropsPassagesUntouchedFor30Days() {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 100_000_000)
        let stale = history(touched: now.addingTimeInterval(-FilePassageHistoryStore.staleInterval - 1))
        let fresh = history(touched: now.addingTimeInterval(-29 * 24 * 60 * 60))
        store.save(DocumentHistory(passages: stale.passages + fresh.passages), for: url("a.md"))
        store.prune(now: now)
        XCTAssertEqual(store.load(for: url("a.md")).passages, fresh.passages)
    }

    func testClearAllRemovesEverything() {
        let store = makeStore()
        store.save(history(), for: url("a.md"))
        store.save(history(), for: url("b.md"))
        store.clearAll()
        XCTAssertEqual(storedFiles(), [])
        XCTAssertTrue(store.load(for: url("a.md")).isEmpty)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let store = makeStore()
        store.save(history(), for: url("a.md"))
        let file = try XCTUnwrap(storedFiles().first { $0 != "index.json" })
        try Data("{".utf8).write(to: directory.appendingPathComponent(file))
        XCTAssertTrue(store.load(for: url("a.md")).isEmpty)
    }

    private func realFile(_ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        return file
    }

    func testPruneDropsHistoryOfTrashedFile() throws {
        let work = directory.appendingPathComponent("work", isDirectory: true)
        let file = try realFile("t.md", in: work)
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store"))
        store.save(history(touched: Date()), for: file)
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        } catch {
            // Fallback: a directory named .Trash exercises the path-component check.
            let trash = work.appendingPathComponent(".Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent("t.md"))
        }
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }
        store.prune(now: Date())
        XCTAssertTrue(store.load(for: file).isEmpty)
        if let trashed { XCTAssertTrue(store.load(for: trashed as URL).isEmpty) }
    }

    func testPruneFollowsAMovedFileThroughItsBookmark() throws {
        let work = directory.appendingPathComponent("work", isDirectory: true)
        let file = try realFile("a.md", in: work)
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store"))
        let saved = history(touched: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()))
        store.save(saved, for: file)
        let moved = work.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: file, to: moved)
        store.prune(now: Date())
        XCTAssertEqual(store.load(for: moved), saved)
        XCTAssertTrue(store.load(for: file).isEmpty)
    }

    func testPruneOnAStoreThatHoldsNothingWritesNothing() {
        let store = makeStore()
        store.prune(now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "nothing is stored until a version is kept — not even an empty index")
    }

    // MARK: - Folder moves

    /// Real files in a real folder, so keys and bookmarks behave as in the app.
    private func makeDocs() throws -> URL {
        let docs = directory.deletingLastPathComponent()
            .appendingPathComponent("PassageHistoryStoreDocs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("b/deep", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("bc", isDirectory: true), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: docs) }
        return docs
    }

    private func touch(_ url: URL) throws {
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func testRetargetDirectoryMovesAllNestedEntries() throws {
        let docs = try makeDocs()
        let one = docs.appendingPathComponent("b/one.md"), two = docs.appendingPathComponent("b/deep/two.md")
        try touch(one); try touch(two)
        let store = makeStore()
        let h1 = history(), h2 = history(touched: Date(timeIntervalSince1970: 2_000_000))
        store.save(h1, for: one)
        store.save(h2, for: two)

        let renamed = docs.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: docs.appendingPathComponent("b"), to: renamed)
        store.retargetDirectory(from: docs.appendingPathComponent("b", isDirectory: true), to: renamed)

        XCTAssertEqual(store.load(for: renamed.appendingPathComponent("one.md")), h1)
        XCTAssertEqual(store.load(for: renamed.appendingPathComponent("deep/two.md")), h2)
        XCTAssertTrue(store.load(for: one).isEmpty)
        XCTAssertTrue(store.load(for: two).isEmpty)
    }

    func testRetargetDirectoryDoesNotMatchSiblingPrefix() throws {
        let docs = try makeDocs()
        let sibling = docs.appendingPathComponent("bc/note.md")
        try touch(sibling)
        let store = makeStore()
        let saved = history()
        store.save(saved, for: sibling)

        store.retargetDirectory(from: docs.appendingPathComponent("b", isDirectory: true),
                                to: docs.appendingPathComponent("z", isDirectory: true))

        XCTAssertEqual(store.load(for: sibling), saved, "/a/b must not match /a/bc")
    }

    func testPruneClashKeepsNewerHistory() throws {
        let docs = try makeDocs()
        let old = docs.appendingPathComponent("b/old.md"), new = docs.appendingPathComponent("b/new.md")
        try touch(old)
        let store = makeStore()
        // Whole seconds: the store's date encoding does not round-trip sub-second precision.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let stale = history(touched: now.addingTimeInterval(-2 * 24 * 60 * 60))
        store.save(stale, for: old)
        // The file moves without a retarget, then the writer keeps a version at the new path.
        try FileManager.default.moveItem(at: old, to: new)
        let fresh = history(touched: now.addingTimeInterval(-60))
        store.save(fresh, for: new)

        store.prune(now: Date())

        XCTAssertEqual(store.load(for: new), fresh, "the newly kept versions survive the clash")
        XCTAssertEqual(storedFiles().filter { $0 != "index.json" }.count, 1, "the stale entry is deleted")
    }
    // MARK: - Final review I1: delete only on positive evidence

    /// An unplugged external drive, an unmounted network volume, or a folder the sandbox cannot
    /// see: the file is not KNOWN to be gone, so its history stays (the 30-day rule cleans up).
    func testPruneKeepsHistoryWhenTheFilesFolderIsUnreachable() {
        let store = FilePassageHistoryStore(directory: directory)
        let offline = URL(fileURLWithPath: "/Volumes/LineformUnpluggedDrive-\(UUID().uuidString)/notes/a.md")
        let saved = history(touched: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        store.save(saved, for: offline)
        store.prune(now: Date())
        XCTAssertEqual(store.load(for: offline), saved)
    }

    func testPruneDropsHistoryWhenTheFolderIsReachableAndTheFileIsGone() throws {
        let work = directory.appendingPathComponent("work", isDirectory: true)
        let file = try realFile("deleted.md", in: work)
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store"))
        store.save(history(touched: Date()), for: file)
        try FileManager.default.removeItem(at: file)
        store.prune(now: Date())
        XCTAssertTrue(store.load(for: file).isEmpty)
    }
}
