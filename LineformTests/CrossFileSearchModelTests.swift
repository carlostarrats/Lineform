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

    func testFilenameMatchIsReturnedWhenContentsCannotBeRead() async {
        let model = CrossFileSearchModel(reader: StubReader(texts: [:]), debounceInterval: 0)
        await model.search(query: "launch", entries: [entry("/launch-plan.md")])?.value

        XCTAssertEqual(model.results.map(\.name), ["launch-plan.md"])
        XCTAssertEqual(model.results.first?.matchCount, 1)
        XCTAssertEqual(model.results.first?.snippets, [])
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

    // Reproduces the All Files "stale during first scan" bug at the model boundary: the
    // first search runs before the deferred scan has populated the roots (empty entries →
    // no results); when the roots publish, the view re-issues the search with the full
    // entry set and results appear — without the user editing the query.
    func testReSearchWithNewlyPopulatedEntriesSupersedesEmptyInitial() async {
        let reader = StubReader(texts: ["/found.md": "needle here"])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)

        // Scan not done yet: no entries → no results.
        await model.search(query: "needle", entries: [])?.value
        XCTAssertEqual(model.results, [])

        // Roots populated: re-issued search finds the file.
        await model.search(query: "needle", entries: [entry("/found.md")])?.value
        XCTAssertEqual(model.results.map(\.name), ["found.md"])
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
