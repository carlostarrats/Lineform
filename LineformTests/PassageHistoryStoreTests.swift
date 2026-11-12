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
        FilePassageHistoryStore(directory: directory, fileExists: { [unowned self] url in
            !self.missing.contains(url.path)
        })
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/lineform-history-tests/\(name)")
    }

    private func history(touched: Date = Date(timeIntervalSince1970: 1_000_000)) -> DocumentHistory {
        let version = HistoryVersion(text: "Hello", author: .you, createdAt: touched)
        let passage = HistoryPassage(
            id: UUID(), level: .sentence, versions: [version], currentIndex: 0,
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
}
