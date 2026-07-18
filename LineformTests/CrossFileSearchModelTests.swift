import XCTest
@testable import Lineform

/// Injectable reader over an in-memory corpus — no disk, no iCloud.
private struct StubReader: CrossFileSearchFileReading {
    let texts: [String: String]   // keyed by URL path
    func readSearchableText(at url: URL) -> String? { texts[url.path] }
}

@MainActor
final class CrossFileSearchModelTests: XCTestCase {
    private func entry(_ path: String) -> QuickOpenEntry {
        QuickOpenEntry(
            id: path, url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            relativePath: String(path.dropFirst()), rootTitle: "Workspace"
        )
    }

    func testSearchPublishesRankedResultsAcrossTheCorpus() async {
        let reader = StubReader(texts: [
            "/a.md": "needle once",
            "/b.md": "needle and needle again",
            "/c.md": "nothing relevant",
        ])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        await model.search(query: "needle", entries: [entry("/a.md"), entry("/b.md"), entry("/c.md")])?.value
        XCTAssertEqual(model.results.map(\.name), ["b.md", "a.md"])
        XCTAssertEqual(model.results.first?.matchCount, 2)
        XCTAssertFalse(model.isSearching)
    }

    func testUnreadableFilesAreSkippedSilently() async {
        let reader = StubReader(texts: ["/a.md": "needle"])   // /gone.md reads nil
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        await model.search(query: "needle", entries: [entry("/gone.md"), entry("/a.md")])?.value
        XCTAssertEqual(model.results.map(\.name), ["a.md"])
    }

    func testEmptyQueryClearsResultsWithoutSearching() async {
        let model = CrossFileSearchModel(reader: StubReader(texts: [:]), debounceInterval: 0)
        await model.search(query: "needle", entries: [])?.value
        XCTAssertNil(model.search(query: "   ", entries: [entry("/a.md")]))
        XCTAssertEqual(model.results, [])
        XCTAssertFalse(model.isSearching)
    }

    func testStaleSearchNeverPublishesOverANewerOne() async {
        let reader = StubReader(texts: ["/old.md": "alpha", "/new.md": "beta"])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        let stale = model.search(query: "alpha", entries: [entry("/old.md")])
        let fresh = model.search(query: "beta", entries: [entry("/new.md")])
        await stale?.value
        await fresh?.value
        XCTAssertEqual(model.results.map(\.name), ["new.md"])
    }

    func testResetClearsResultsAndCancelsInFlightWork() async {
        let reader = StubReader(texts: ["/a.md": "needle"])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        let task = model.search(query: "needle", entries: [entry("/a.md")])
        model.reset()
        await task?.value
        XCTAssertEqual(model.results, [])
        XCTAssertFalse(model.isSearching)
    }

    func testProductionReaderSkipsOversizedFilesAndReadsNormalOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossFileSearchModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let normal = directory.appendingPathComponent("normal.md")
        try "hello needle".write(to: normal, atomically: true, encoding: .utf8)
        let huge = directory.appendingPathComponent("huge.md")
        try String(repeating: "x", count: 1_100_000).write(to: huge, atomically: true, encoding: .utf8)

        let reader = CrossFileSearchFileReader()
        XCTAssertEqual(reader.readSearchableText(at: normal), "hello needle")
        XCTAssertNil(reader.readSearchableText(at: huge))
        XCTAssertNil(reader.readSearchableText(at: directory.appendingPathComponent("absent.md")))
    }
}
