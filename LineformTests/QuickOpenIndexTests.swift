import XCTest
@testable import Lineform

final class QuickOpenIndexTests: XCTestCase {
    private func file(_ path: String) -> OutlineFileTreeItem {
        let url = URL(fileURLWithPath: path)
        return OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: false, children: [])
    }

    private func folder(_ path: String, children: [OutlineFileTreeItem]) -> OutlineFileTreeItem {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: true, children: children)
    }

    private func root(id: String, title: String, items: [OutlineFileTreeItem]) -> OutlineFileRoot {
        OutlineFileRoot(id: id, title: title, systemImage: "folder", state: .available, items: items)
    }

    // MARK: flatten

    func testFlattenMergesBothRootsAndRecursesIntoFolders() {
        let iCloud = root(id: "icloud", title: "Lineform", items: [file("/icloud/notes.md")])
        let workspace = root(id: "workspace", title: "Docs", items: [
            file("/ws/readme.md"),
            folder("/ws/projects", children: [file("/ws/projects/roadmap.md")]),
        ])

        let entries = QuickOpenIndex.flatten(iCloudRoot: iCloud, workspaceRoot: workspace)

        XCTAssertEqual(entries.map(\.name), ["notes.md", "readme.md", "roadmap.md"])
        XCTAssertEqual(entries.map(\.relativePath), ["notes.md", "readme.md", "projects/roadmap.md"])
        XCTAssertEqual(entries.map(\.rootTitle), ["Lineform", "Docs", "Docs"])
        XCTAssertEqual(entries.map(\.id), ["/icloud/notes.md", "/ws/readme.md", "/ws/projects/roadmap.md"])
    }

    func testFlattenExcludesDirectoriesThemselves() {
        let workspace = root(id: "workspace", title: "Docs", items: [
            folder("/ws/empty", children: []),
            folder("/ws/projects", children: [file("/ws/projects/a.md")]),
        ])
        let entries = QuickOpenIndex.flatten(
            iCloudRoot: root(id: "icloud", title: "Lineform", items: []),
            workspaceRoot: workspace
        )
        XCTAssertEqual(entries.map(\.name), ["a.md"])
    }

    func testFlattenOfEmptyRootsIsEmpty() {
        let entries = QuickOpenIndex.flatten(
            iCloudRoot: root(id: "icloud", title: "Lineform", items: []),
            workspaceRoot: root(id: "workspace", title: "Docs", items: [])
        )
        XCTAssertEqual(entries, [])
    }

    // MARK: search

    private var sampleEntries: [QuickOpenEntry] {
        QuickOpenIndex.flatten(
            iCloudRoot: root(id: "icloud", title: "Lineform", items: []),
            workspaceRoot: root(id: "workspace", title: "Docs", items: [
                file("/ws/roadmap.md"),
                file("/ws/readme.md"),
                file("/ws/release-notes.md"),
                folder("/ws/journal", children: [file("/ws/journal/2026.md")]),
            ])
        )
    }

    func testSearchMatchesSubsequence() {
        // "rdmp" is not a substring of "roadmap.md" but is an in-order subsequence.
        let results = QuickOpenIndex.search(sampleEntries, query: "rdmp")
        XCTAssertEqual(results.map(\.name), ["roadmap.md"])
    }

    func testSearchIsCaseInsensitive() {
        let results = QuickOpenIndex.search(sampleEntries, query: "README")
        XCTAssertEqual(results.first?.name, "readme.md")
    }

    func testSearchRanksPrefixMatchAboveMidStringMatch() {
        // "re" prefixes readme.md and release-notes.md but only appears mid-string
        // elsewhere; both prefix matches must rank above any subsequence-only match.
        let results = QuickOpenIndex.search(sampleEntries, query: "re")
        XCTAssertEqual(Set(results.prefix(2).map(\.name)), ["readme.md", "release-notes.md"])
    }

    func testSearchExactSubstringBeatsScatteredSubsequence() {
        let entries = [
            QuickOpenEntry(id: "/a", url: URL(fileURLWithPath: "/a"), name: "meeting-notes.md", relativePath: "meeting-notes.md", rootTitle: "Docs"),
            QuickOpenEntry(id: "/b", url: URL(fileURLWithPath: "/b"), name: "mail-sorting-hints.md", relativePath: "mail-sorting-hints.md", rootTitle: "Docs"),
        ]
        let results = QuickOpenIndex.search(entries, query: "notes")
        XCTAssertEqual(results.first?.name, "meeting-notes.md")
    }

    func testSearchEmptyOrWhitespaceQueryReturnsNothing() {
        XCTAssertEqual(QuickOpenIndex.search(sampleEntries, query: ""), [])
        XCTAssertEqual(QuickOpenIndex.search(sampleEntries, query: "   "), [])
    }

    func testSearchNoMatchesReturnsEmpty() {
        XCTAssertEqual(QuickOpenIndex.search(sampleEntries, query: "zzzz"), [])
    }

    func testSearchRespectsLimit() {
        let many = (0..<30).map { index in
            QuickOpenEntry(
                id: "/f\(index)",
                url: URL(fileURLWithPath: "/f\(index)"),
                name: "note-\(index).md",
                relativePath: "note-\(index).md",
                rootTitle: "Docs"
            )
        }
        XCTAssertEqual(QuickOpenIndex.search(many, query: "note", limit: 20).count, 20)
        XCTAssertEqual(QuickOpenIndex.search(many, query: "note", limit: 5).count, 5)
    }
}
