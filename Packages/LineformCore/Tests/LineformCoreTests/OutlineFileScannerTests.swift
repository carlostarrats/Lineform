import XCTest
@testable import LineformCore

/// The Files tree scan rules, pinned against today's Mac behaviour. The Mac store's own tests
/// (`OutlineSidebarViewTests`) still run the same rules through its forwarder.
final class OutlineFileScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutlineFileScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String = "# Note") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func testScannerExcludesNodeModulesAndGit() throws {
        try write("Draft.md")
        try write("node_modules/readme.md")
        try write(".git/config.md")
        try write("Notes/node_modules/inner.md")
        try write("Notes/kept.md")

        for showsHidden in [false, true] {
            let items = OutlineFileScanner.items(in: root, showsHidden: showsHidden)
            XCTAssertEqual(items.map(\.name), ["Notes", "Draft.md"], "showsHidden: \(showsHidden)")
            XCTAssertEqual(items.first?.children.map(\.name), ["kept.md"], "showsHidden: \(showsHidden)")
        }
    }

    func testScannerDropsEmptyFolders() throws {
        try folder("Empty")
        try folder("images")
        try Data().write(to: root.appendingPathComponent("images/cover.png"))
        try folder("Nested/Deeper")
        try write("Drafts/chapter.md")

        let items = OutlineFileScanner.items(in: root, showsHidden: false)
        XCTAssertEqual(items.map(\.name), ["Drafts"])
        XCTAssertEqual(items.first?.children.map(\.name), ["chapter.md"])
    }

    func testScannerDepthLimit() throws {
        XCTAssertEqual(OutlineFileScanner.maximumTreeDepth, 4)
        // Depth 0 is the root's own children; a file in the fourth folder level is depth 4.
        try write("a/b/c/three.md")
        try write("a/b/c/d/four.md")

        let items = OutlineFileScanner.items(in: root, showsHidden: false)
        let a = try XCTUnwrap(items.first { $0.name == "a" })
        let b = try XCTUnwrap(a.children.first { $0.name == "b" })
        let c = try XCTUnwrap(b.children.first { $0.name == "c" })
        XCTAssertEqual(c.children.map(\.name), ["three.md"], "the folder past the depth limit is not scanned, so it is dropped as empty")
    }

    func testScannerListsOnlySupportedExtensions() throws {
        try write("a.md")
        try write("b.markdown")
        try write("c.txt")
        try write("d.MD")
        try write("e.rtf")
        try write("f.html")

        let names = OutlineFileScanner.items(in: root, showsHidden: false).map(\.name)
        XCTAssertEqual(names, ["a.md", "b.markdown", "c.txt", "d.MD"])
        XCTAssertEqual(OutlineFileScanner.supportedFileExtensions, ["md", "markdown", "txt"])
        XCTAssertEqual(OutlineFileScanner.excludedDirectoryNames, ["node_modules", ".git"])
    }

    func testScannerSkipsDotItemsUnlessShownAndFlagsThemHidden() throws {
        try write("Draft.md")
        try write(".claude/notes.md")

        XCTAssertEqual(OutlineFileScanner.items(in: root, showsHidden: false).map(\.name), ["Draft.md"])

        let shown = OutlineFileScanner.items(in: root, showsHidden: true)
        XCTAssertEqual(shown.map(\.name), [".claude", "Draft.md"])
        let claude = try XCTUnwrap(shown.first { $0.name == ".claude" })
        XCTAssertTrue(claude.isHidden)
        XCTAssertEqual(claude.children.first?.isHidden, true, "children of a hidden folder inherit the flag")
        XCTAssertEqual(shown.first { $0.name == "Draft.md" }?.isHidden, false)
    }

    func testScannerListsEveryDocumentWithoutTruncation() throws {
        for index in 0..<120 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("Note \(index).md").path, contents: Data())
        }
        XCTAssertEqual(OutlineFileScanner.items(in: root, showsHidden: false).count, 120)
    }

    func testScannerAppliesTheSortOrder() throws {
        try write("b.md")
        try write("a.md")
        try write("Folder/x.md")
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent("b.md").path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: root.appendingPathComponent("a.md").path)

        XCTAssertEqual(OutlineFileScanner.items(in: root, showsHidden: false, sortOrder: .name).map(\.name), ["Folder", "a.md", "b.md"])
        XCTAssertEqual(OutlineFileScanner.items(in: root, showsHidden: false, sortOrder: .dateModified).map(\.name), ["Folder", "a.md", "b.md"])
        try FileManager.default.setAttributes([.modificationDate: new.addingTimeInterval(10)], ofItemAtPath: root.appendingPathComponent("b.md").path)
        XCTAssertEqual(OutlineFileScanner.items(in: root, showsHidden: false, sortOrder: .dateModified).map(\.name), ["Folder", "b.md", "a.md"])
    }

    func testDocumentsFolderIsEmptyCountsHiddenDocuments() throws {
        XCTAssertTrue(OutlineFileScanner.documentsFolderIsEmpty(at: root))
        try write(".hidden/notes.md")
        XCTAssertFalse(OutlineFileScanner.documentsFolderIsEmpty(at: root))
    }

    func testMissingRootScansToNothing() {
        XCTAssertEqual(OutlineFileScanner.items(in: root.appendingPathComponent("missing"), showsHidden: false), [])
    }

    // MARK: - iCloud placeholders (the iPhone's opt-in)

    func testPlaceholderNameIsTheRealFileName() {
        XCTAssertEqual(OutlineFileScanner.realName(ofEntry: ".Notes.md.icloud"), "Notes.md")
        XCTAssertNil(OutlineFileScanner.realName(ofEntry: ".icloud"), "a bare suffix names nothing")
        XCTAssertNil(OutlineFileScanner.realName(ofEntry: ".DS_Store"))
        XCTAssertEqual(OutlineFileScanner.realName(ofEntry: "Notes.md"), "Notes.md")
    }

    func testScannerListsPlaceholdersUnderTheirRealNamesWhenAsked() throws {
        try write("Kept.md")
        try write(".Evicted.md.icloud", "placeholder")
        try write(".Picture.png.icloud", "placeholder")
        try write(".Hidden.md")
        try write("Sub/.Deep.md.icloud", "placeholder")

        // The Mac's scan (the default) is unchanged: a placeholder is a hidden, unsupported entry.
        XCTAssertEqual(OutlineFileScanner.items(in: root, showsHidden: false).map(\.name), ["Kept.md"])

        let items = OutlineFileScanner.items(in: root, showsHidden: false, includesICloudPlaceholders: true)
        XCTAssertEqual(items.map(\.name), ["Sub", "Evicted.md", "Kept.md"])
        let evicted = try XCTUnwrap(items.first { $0.name == "Evicted.md" })
        XCTAssertEqual(evicted.url.lastPathComponent, "Evicted.md", "the item stands for the real file")
        XCTAssertFalse(evicted.isHidden, "a placeholder is not a hidden item")
        XCTAssertEqual(items.first?.children.map(\.name), ["Deep.md"])

        let withHidden = OutlineFileScanner.items(in: root, showsHidden: true, includesICloudPlaceholders: true)
        XCTAssertEqual(withHidden.map(\.name), ["Sub", ".Hidden.md", "Evicted.md", "Kept.md"])
        XCTAssertEqual(withHidden.first { $0.name == ".Hidden.md" }?.isHidden, true)
    }

    func testScannerItemDatesAreReadable() throws {
        try write("Dated.md")
        let item = try XCTUnwrap(OutlineFileScanner.items(in: root, showsHidden: false).first)
        XCTAssertNotNil(item.modifiedAt)
        XCTAssertNotNil(item.createdAt)
    }
}
