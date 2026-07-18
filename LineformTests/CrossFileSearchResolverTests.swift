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
        XCTAssertEqual(result?.snippets.first?.lineText, "The launch plan is here.")
        XCTAssertEqual(result?.snippets.first?.matchRange, NSRange(location: 4, length: 6))
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
        let snippet = result!.snippets.first!
        XCTAssertLessThanOrEqual(
            snippet.lineText.count,
            CrossFileSearchResolver.snippetMaximumLength + 2 // cap + up to two "…"
        )
        // The reported range must still point at "needle" within the elided line.
        let found = (snippet.lineText as NSString).substring(with: snippet.matchRange)
        XCTAssertEqual(found.lowercased(), "needle")
        // Left-bias guarantee: the match must sit near the snippet's START (leading
        // context + one possible "…"), so it is visible at any card width.
        XCTAssertLessThanOrEqual(
            snippet.matchRange.location,
            CrossFileSearchResolver.snippetLeadingContextLength + 1
        )
    }

    func testMatchAtEndOfLongLineStaysNearSnippetStart() {
        // A match at the END of an over-cap line: the window must still lead with the
        // match (no backward fill to spend the cap), or narrow pills re-hide the match.
        let text = String(repeating: "a", count: 100) + " needle"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertNotNil(result)
        let snippet = result!.snippets.first!
        XCTAssertEqual((snippet.lineText as NSString).substring(with: snippet.matchRange), "needle")
        XCTAssertLessThanOrEqual(
            snippet.matchRange.location,
            CrossFileSearchResolver.snippetLeadingContextLength + 1
        )
    }

    func testSnippetComesFromFirstMatchingLineAndStripsTrailingNewline() {
        let text = "first needle line\nsecond needle line\n"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertEqual(result?.snippets.first?.lineText, "first needle line")
    }

    func testMatchLongerThanSnippetCapYieldsValidInBoundsRange() {
        let longWord = String(repeating: "z", count: 150)
        let text = "prefix " + longWord + " suffix"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: longWord)
        XCTAssertNotNil(result)
        let snippet = result!.snippets.first!
        XCTAssertGreaterThanOrEqual(snippet.matchRange.location, 0)
        XCTAssertLessThanOrEqual(NSMaxRange(snippet.matchRange), (snippet.lineText as NSString).length)
        XCTAssertGreaterThan(snippet.matchRange.length, 0)
        let shown = (snippet.lineText as NSString).substring(with: snippet.matchRange)
        XCTAssertTrue(shown.allSatisfy { $0 == "z" })
    }

    func testMatchesOnDistinctLinesProduceOneSnippetEachInOrder() {
        let text = "needle one\nneedle two\nneedle three"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertEqual(result?.matchCount, 3)
        XCTAssertEqual(result?.snippets.map(\.lineText), ["needle one", "needle two", "needle three"])
    }

    func testMatchesOnSameLineProduceOnlyOneSnippet() {
        let text = "needle needle needle"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertEqual(result?.matchCount, 3)
        XCTAssertEqual(result?.snippets.count, 1)
        XCTAssertEqual(result?.snippets.first?.lineText, "needle needle needle")
    }

    func testSnippetsAreCappedAtMaximumSnippetsPerFile() {
        let lines = (0..<(CrossFileSearchResolver.maximumSnippetsPerFile + 5)).map { "needle line \($0)" }
        let text = lines.joined(separator: "\n")
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertEqual(result?.matchCount, lines.count)
        XCTAssertEqual(result?.snippets.count, CrossFileSearchResolver.maximumSnippetsPerFile)
        XCTAssertEqual(result?.snippets.first?.lineText, "needle line 0")
    }

    func testRankedOrdersByMatchCountThenNameThenPath() {
        func make(_ name: String, _ path: String, _ count: Int) -> CrossFileSearchResult {
            CrossFileSearchResult(
                id: path, url: URL(fileURLWithPath: "/\(path)"), name: name,
                relativePath: path, rootTitle: "Workspace", matchCount: count,
                snippets: [CrossFileSearchSnippet(lineText: "x", matchRange: NSRange(location: 0, length: 1))]
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
