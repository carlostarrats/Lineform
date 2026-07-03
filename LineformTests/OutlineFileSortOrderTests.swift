import XCTest
@testable import Lineform

final class OutlineFileSortOrderTests: XCTestCase {
    private func item(_ name: String, isDirectory: Bool = false, created: Date? = nil, modified: Date? = nil, children: [OutlineFileTreeItem] = []) -> OutlineFileTreeItem {
        OutlineFileTreeItem(
            url: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            children: children,
            createdAt: created,
            modifiedAt: modified
        )
    }

    func testSortTitlesMatchMuseStyleMenuWithoutManual() {
        XCTAssertEqual(OutlineFileSortOrder.allCases.map(\.title), ["Name", "Date Created", "Date Modified"])
    }

    func testNameSortKeepsFoldersFirstThenNaturalNameOrder() {
        let items = [item("b.md"), item("10.md"), item("2.md"), item("Zed", isDirectory: true), item("Alpha", isDirectory: true)]
        let sorted = OutlineFileSortOrder.sorted(items, by: .name)
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Zed", "2.md", "10.md", "b.md"])
    }

    func testDateSortsAreNewestFirstWithinFoldersThenFiles() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let items = [
            item("old.md", created: old, modified: old),
            item("new.md", created: new, modified: new),
            item("OldFolder", isDirectory: true, created: old, modified: old),
            item("NewFolder", isDirectory: true, created: new, modified: new)
        ]
        XCTAssertEqual(OutlineFileSortOrder.sorted(items, by: .dateCreated).map(\.name), ["NewFolder", "OldFolder", "new.md", "old.md"])
        XCTAssertEqual(OutlineFileSortOrder.sorted(items, by: .dateModified).map(\.name), ["NewFolder", "OldFolder", "new.md", "old.md"])
    }

    func testMissingDatesSortLastAndFallBackToName() {
        let dated = Date(timeIntervalSince1970: 100)
        let items = [item("b-undated.md"), item("a-undated.md"), item("dated.md", created: dated, modified: dated)]
        XCTAssertEqual(OutlineFileSortOrder.sorted(items, by: .dateCreated).map(\.name), ["dated.md", "a-undated.md", "b-undated.md"])
    }

    func testSortRecursesIntoChildren() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let folder = item("Folder", isDirectory: true, children: [item("old.md", created: old, modified: old), item("new.md", created: new, modified: new)])
        let sorted = OutlineFileSortOrder.sorted([folder], by: .dateModified)
        XCTAssertEqual(sorted.first?.children.map(\.name), ["new.md", "old.md"])
    }

    func testTreeItemDecodingToleratesSnapshotsWithoutDates() throws {
        let json = #"[{"url":"file:///tmp/a.md","name":"a.md","isDirectory":false,"children":[]}]"#
        let items = try JSONDecoder().decode([OutlineFileTreeItem].self, from: Data(json.utf8))
        XCTAssertNil(items.first?.createdAt)
        XCTAssertNil(items.first?.modifiedAt)
    }
}
