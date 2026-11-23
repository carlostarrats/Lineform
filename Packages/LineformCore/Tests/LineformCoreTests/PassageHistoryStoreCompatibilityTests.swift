import XCTest
@testable import LineformCore

/// History written by Lineform 1.8.0 must still load after the move into LineformCore.
///
/// `Fixtures/history-1.8.0/` is a real store directory (`index.json` plus one `<uuid>.json`)
/// written by the baseline build's own `FilePassageHistoryStore.save(_:for:)` (History code
/// unchanged since 1.8.0 build 41). How it was made: `docs/notes/shared-package-baseline.md`,
/// Task 7. Never regenerate it with the current code: its point is that the bytes predate the move.
final class PassageHistoryStoreCompatibilityTests: XCTestCase {
    /// The store keys a document on `FileIdentity.key(for:)` (the index's `pathKey`). The fixture's
    /// document is a path whose parent chain exists on no machine, so its key is the path as
    /// written, and the baseline stored no bookmark for it (there was no file to bookmark).
    private let fixtureIdentity = URL(fileURLWithPath: "/Lineform-1.8.0-fixture/Documents/Two passages.md")
    private let recordFileName = "765470F0-A5A0-4B50-8A51-561097BFC28D.json"

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassageHistoryStoreCompatibilityTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// A private copy of the fixture, so no store call can ever change the committed bytes.
    private func fixtureDirectory(_ name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil),
                                   "\(name) missing from the test bundle")
        let copy = workDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func jsonObject(_ file: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file))
    }

    func testDecodesHistoryWrittenBy1_8_0() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureIdentity.path),
                       "the fixture's document must not exist, or its key could change")
        let store = FilePassageHistoryStore(directory: try fixtureDirectory("history-1.8.0"))
        let record = store.load(for: fixtureIdentity)
        XCTAssertEqual(record.passages.count, 2)
        guard record.passages.count == 2 else { return }   // fail, not crash, on an index miss
        XCTAssertEqual(record.passages[0].versions.map(\.text), ["gentle", "dangerous"])

        // Every stored field, so a renamed key (an optional one decodes as nil, not as an error) fails.
        let word = record.passages[0]
        let sentence = record.passages[1]
        XCTAssertEqual(word.id, UUID(uuidString: "A1B2C3D4-E5F6-4789-8ABC-DEF012345678"))
        XCTAssertEqual(word.level, .word)
        XCTAssertEqual(word.versions.map(\.author), [.you, .ai])
        XCTAssertEqual(word.versions.map(\.createdAt),
                       [Date(timeIntervalSince1970: 1_793_491_200), Date(timeIntervalSince1970: 1_793_494_800)])
        XCTAssertEqual(word.currentIndex, 1)
        XCTAssertEqual(word.parentID, sentence.id)
        XCTAssertEqual(word.parentVersionIndex, 1)
        XCTAssertEqual(word.contextBefore, "The wind was ")
        XCTAssertEqual(word.contextAfter, " that night.")
        XCTAssertEqual(word.lastTouched, Date(timeIntervalSince1970: 1_793_494_800))

        XCTAssertEqual(sentence.id, UUID(uuidString: "5E2B1C3A-7D4F-4A60-9B8E-1F2A3B4C5D6E"))
        XCTAssertEqual(sentence.level, .sentence)
        XCTAssertEqual(sentence.versions.map(\.text),
                       ["The wind was gentle that night.", "The wind was dangerous that night."])
        XCTAssertEqual(sentence.versions.map(\.author), [.you, .you])
        XCTAssertEqual(sentence.currentIndex, 1)
        XCTAssertNil(sentence.parentID)
        XCTAssertNil(sentence.parentVersionIndex)
        XCTAssertEqual(sentence.contextBefore, "")
        XCTAssertEqual(sentence.contextAfter, "\n")
        XCTAssertEqual(sentence.lastTouched, Date(timeIntervalSince1970: 1_793_494_800))
    }

    /// The 1.8.0 field names, read without the store, so the fixture itself is pinned.
    func testFixtureUsesThe1_8_0FieldNames() throws {
        let directory = try fixtureDirectory("history-1.8.0")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, [recordFileName, "index.json"])

        let index = try XCTUnwrap(try jsonObject(directory.appendingPathComponent("index.json")) as? [[String: Any]])
        XCTAssertEqual(index.count, 1)
        // `bookmark` is optional and omitted when nil: the fixture's document never existed.
        XCTAssertEqual(Set(index[0].keys), ["id", "pathKey"])
        XCTAssertEqual(index[0]["id"] as? String, "765470F0-A5A0-4B50-8A51-561097BFC28D")
        XCTAssertEqual(index[0]["pathKey"] as? String, fixtureIdentity.path)

        let record = try XCTUnwrap(try jsonObject(directory.appendingPathComponent(recordFileName)) as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["passages"])
        let passages = try XCTUnwrap(record["passages"] as? [[String: Any]])
        XCTAssertEqual(passages.count, 2)
        XCTAssertEqual(Set(passages[0].keys), ["id", "level", "versions", "currentIndex", "parentID",
                                               "parentVersionIndex", "contextBefore", "contextAfter", "lastTouched"])
        XCTAssertEqual(Set(passages[1].keys), ["id", "level", "versions", "currentIndex",
                                               "contextBefore", "contextAfter", "lastTouched"])
        for passage in passages {
            let versions = try XCTUnwrap(passage["versions"] as? [[String: Any]])
            for version in versions {
                XCTAssertEqual(Set(version.keys), ["text", "author", "createdAt"])
            }
        }
    }

    /// What this build writes for the same history is the 1.8.0 record: same keys, same values
    /// (dates as seconds since 1970), so a 1.8.0 build could read it back.
    func testSavingLoadedHistoryWritesThe1_8_0Format() throws {
        let fixture = try fixtureDirectory("history-1.8.0")
        let loaded = FilePassageHistoryStore(directory: fixture).load(for: fixtureIdentity)
        XCTAssertEqual(loaded.passages.count, 2)

        let output = workDirectory.appendingPathComponent("written", isDirectory: true)
        FilePassageHistoryStore(directory: output).save(loaded, for: fixtureIdentity)

        let index = try XCTUnwrap(try jsonObject(output.appendingPathComponent("index.json")) as? [[String: Any]])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index[0]["pathKey"] as? String, fixtureIdentity.path)
        // No bookmark: the document does not exist, so there is nothing to bookmark.
        XCTAssertEqual(Set(index[0].keys), ["id", "pathKey"])
        let id = try XCTUnwrap(index[0]["id"] as? String)

        let written = try XCTUnwrap(try jsonObject(output.appendingPathComponent("\(id).json")) as? NSDictionary)
        let original = try XCTUnwrap(try jsonObject(fixture.appendingPathComponent(recordFileName)) as? NSDictionary)
        XCTAssertEqual(written, original)
    }

    // MARK: - 1.9.0

    /// `Fixtures/history-1.9.0/` was written on 2026-11-22 by the 1.9.0 `FilePassageHistoryStore`
    /// (`save(_:for:)`, before History sync changed the store) from three passages: a paragraph
    /// with a word-level child hanging on its second version, and a sentence with three versions.
    /// Like the 1.8.0 fixture, its document path exists on no machine, so it has no bookmark.
    /// Never regenerate it with later code: its point is that the bytes predate History sync.
    private let fixtureIdentity1_9_0 = URL(fileURLWithPath: "/Lineform-1.9.0-fixture/Documents/Two passages and a child.md")
    private let recordFileName1_9_0 = "7D75E7A0-ED45-4559-9C54-91BB92E1C351.json"

    func testDecodesHistoryWrittenBy1_9_0() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureIdentity1_9_0.path),
                       "the fixture's document must not exist, or its key could change")
        let directory = try fixtureDirectory("history-1.9.0")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, [recordFileName1_9_0, "index.json"])

        let record = FilePassageHistoryStore(directory: directory).load(for: fixtureIdentity1_9_0)
        XCTAssertEqual(record.passages.count, 3)
        guard record.passages.count == 3 else { return }   // fail, not crash, on an index miss
        let paragraph = record.passages[0], word = record.passages[1], sentence = record.passages[2]
        let t0 = Date(timeIntervalSince1970: 1_798_761_600)
        let t1 = Date(timeIntervalSince1970: 1_798_765_200)
        let t2 = Date(timeIntervalSince1970: 1_798_768_800)

        XCTAssertEqual(paragraph.id, UUID(uuidString: "9A3E1F20-4B5C-4D6E-8F70-819203A4B5C6"))
        XCTAssertEqual(paragraph.level, .paragraph)
        XCTAssertEqual(paragraph.versions.map(\.text), ["The harbour was quiet at dawn.", "The harbour lay quiet at dawn."])
        XCTAssertEqual(paragraph.versions.map(\.author), [.you, .you])
        XCTAssertEqual(paragraph.versions.map(\.createdAt), [t0, t1])
        XCTAssertEqual(paragraph.currentIndex, 1)
        XCTAssertNil(paragraph.parentID)
        XCTAssertNil(paragraph.parentVersionIndex)
        XCTAssertEqual(paragraph.contextBefore, "# Morning\n\n")
        XCTAssertEqual(paragraph.contextAfter, "\n\n")
        XCTAssertEqual(paragraph.lastTouched, t2)

        XCTAssertEqual(word.id, UUID(uuidString: "C7D8E9F0-1A2B-4C3D-9E4F-5A6B7C8D9E0F"))
        XCTAssertEqual(word.level, .word)
        XCTAssertEqual(word.versions.map(\.text), ["lay", "rested"])
        XCTAssertEqual(word.versions.map(\.author), [.you, .ai])
        XCTAssertEqual(word.versions.map(\.createdAt), [t1, t2])
        XCTAssertEqual(word.currentIndex, 0)
        XCTAssertEqual(word.parentID, paragraph.id)
        XCTAssertEqual(word.parentVersionIndex, 1)
        XCTAssertEqual(word.contextBefore, "The harbour ")
        XCTAssertEqual(word.contextAfter, " quiet at dawn.")
        XCTAssertEqual(word.lastTouched, t2)

        XCTAssertEqual(sentence.id, UUID(uuidString: "2F4E6D8C-0B1A-4392-A5B6-C7D8E9F0A1B2"))
        XCTAssertEqual(sentence.level, .sentence)
        XCTAssertEqual(sentence.versions.map(\.text), ["Gulls circled.", "Gulls circled overhead.", "Gulls wheeled overhead."])
        XCTAssertEqual(sentence.versions.map(\.author), [.you, .ai, .you])
        XCTAssertEqual(sentence.versions.map(\.createdAt), [t0, t1, t2])
        XCTAssertEqual(sentence.currentIndex, 2)
        XCTAssertNil(sentence.parentID)
        XCTAssertEqual(sentence.contextBefore, "\n\n")
        XCTAssertEqual(sentence.contextAfter, "\n")
        XCTAssertEqual(sentence.lastTouched, t2)
    }

    /// What this build writes for the loaded 1.9.0 history is the 1.9.0 record, key for key and
    /// value for value, and its index entry has the 1.9.0 fields.
    func testSavingLoaded1_9_0HistoryWritesTheSameFormat() throws {
        let fixture = try fixtureDirectory("history-1.9.0")
        let loaded = FilePassageHistoryStore(directory: fixture).load(for: fixtureIdentity1_9_0)
        XCTAssertEqual(loaded.passages.count, 3)

        let output = workDirectory.appendingPathComponent("written-1.9.0", isDirectory: true)
        FilePassageHistoryStore(directory: output).save(loaded, for: fixtureIdentity1_9_0)

        let index = try XCTUnwrap(try jsonObject(output.appendingPathComponent("index.json")) as? [[String: Any]])
        let fixtureIndex = try XCTUnwrap(try jsonObject(fixture.appendingPathComponent("index.json")) as? [[String: Any]])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(Set(index[0].keys), Set(fixtureIndex[0].keys))
        XCTAssertEqual(index[0]["pathKey"] as? String, fixtureIdentity1_9_0.path)
        let id = try XCTUnwrap(index[0]["id"] as? String)

        let written = try XCTUnwrap(try jsonObject(output.appendingPathComponent("\(id).json")) as? NSDictionary)
        let original = try XCTUnwrap(try jsonObject(fixture.appendingPathComponent(recordFileName1_9_0)) as? NSDictionary)
        XCTAssertEqual(written, original)
    }

    /// The History directory and the 30-day cleanup are persisted behaviour: unchanged since 1.8.0.
    func testHistoryDirectoryAndCleanupIntervalAreThe1_8_0Values() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(FilePassageHistoryStore.defaultDirectory(home: home).path,
                       "/Users/someone/Library/Application Support/Lineform/History")
        XCTAssertEqual(FilePassageHistoryStore.staleInterval, 30 * 24 * 60 * 60)
    }
}
