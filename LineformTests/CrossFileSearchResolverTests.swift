import XCTest
@testable import Lineform

final class CrossFileSearchResolverTests: XCTestCase {
    private func entry(name: String = "notes.md", relativePath: String = "projects/notes.md") -> QuickOpenEntry {
        QuickOpenEntry(
            id: "/tmp/\(relativePath)",
            url: URL(fileURLWithPath: "/tmp/\(relativePath)"),
            name: name,
            relativePath: relativePath,
            rootTitle: "Workspace"
        )
    }

    func testFindsLiteralMatchWithCountAndFirstLineSnippet() {
        let text = "# Title\nThe launch plan is here.\nlaunch again"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "launch")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchCount, 2)
        XCTAssertEqual(result?.snippet.lineText, "The launch plan is here.")
        XCTAssertEqual(result?.snippet.matchRange, NSRange(location: 4, length: 6))
        XCTAssertEqual(result?.name, "notes.md")
        XCTAssertEqual(result?.rootTitle, "Workspace")
    }

    func testMatchingIsCaseAndDiacriticInsensitiveLikeInFileSearch() {
        let text = "Café LAUNCH day"
        XCTAssertEqual(CrossFileSearchResolver.result(for: entry(), text: text, query: "cafe launch")?.matchCount, 1)
        // Must agree with EditorSearchResolver on the same inputs.
        XCTAssertEqual(
            CrossFileSearchResolver.result(for: entry(), text: text, query: "cafe launch")?.matchCount,
            EditorSearchResolver.matches(in: text, query: "cafe launch").count
        )
    }

    func testNoMatchReturnsNilAndEmptyQueryReturnsNil() {
        XCTAssertNil(CrossFileSearchResolver.result(for: entry(), text: "nothing here", query: "absent"))
        XCTAssertNil(CrossFileSearchResolver.result(for: entry(), text: "anything", query: "   "))
    }

    func testLongLineSnippetIsElidedAroundTheMatch() {
        let prefix = String(repeating: "a", count: 200)
        let suffix = String(repeating: "b", count: 200)
        let text = prefix + " needle " + suffix
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertNotNil(result)
        let snippet = result!.snippet
        XCTAssertLessThanOrEqual(snippet.lineText.count, 124) // 120 cap + up to two "…"
        // The reported range must still point at "needle" within the elided line.
        let found = (snippet.lineText as NSString).substring(with: snippet.matchRange)
        XCTAssertEqual(found.lowercased(), "needle")
    }

    func testSnippetComesFromFirstMatchingLineAndStripsTrailingNewline() {
        let text = "first needle line\nsecond needle line\n"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertEqual(result?.snippet.lineText, "first needle line")
    }

    func testMatchLongerThanSnippetCapYieldsValidInBoundsRange() {
        let longWord = String(repeating: "z", count: 150)
        let text = "prefix " + longWord + " suffix"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: longWord)
        XCTAssertNotNil(result)
        let snippet = result!.snippet
        XCTAssertGreaterThanOrEqual(snippet.matchRange.location, 0)
        XCTAssertLessThanOrEqual(NSMaxRange(snippet.matchRange), (snippet.lineText as NSString).length)
        XCTAssertGreaterThan(snippet.matchRange.length, 0)
        let shown = (snippet.lineText as NSString).substring(with: snippet.matchRange)
        XCTAssertTrue(shown.allSatisfy { $0 == "z" })
    }

    func testRankedOrdersByMatchCountThenNameThenPath() {
        func make(_ name: String, _ path: String, _ count: Int) -> CrossFileSearchResult {
            CrossFileSearchResult(
                id: path, url: URL(fileURLWithPath: "/\(path)"), name: name,
                relativePath: path, rootTitle: "Workspace", matchCount: count,
                snippet: CrossFileSearchSnippet(lineText: "x", matchRange: NSRange(location: 0, length: 1))
            )
        }
        let ranked = CrossFileSearchResolver.ranked([
            make("b.md", "b.md", 1),
            make("a.md", "z/a.md", 1),
            make("a.md", "a/a.md", 1),
            make("c.md", "c.md", 5),
        ])
        XCTAssertEqual(ranked.map(\.relativePath), ["c.md", "a/a.md", "z/a.md", "b.md"])
    }
}
