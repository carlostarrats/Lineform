import XCTest
@testable import Lineform

final class SidebarFileActionsTests: XCTestCase {
    private final class RecordingFileManager: SidebarFileManaging {
        var moved: [(URL, URL)] = []
        var trashed: [URL] = []
        var errorToThrow: Error?

        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if let errorToThrow { throw errorToThrow }
            moved.append((srcURL, dstURL))
        }

        func trashItem(at url: URL) throws {
            if let errorToThrow { throw errorToThrow }
            trashed.append(url)
        }
    }

    func testDisplayNameStripsExtensionForFilesButNotFolders() {
        XCTAssertEqual(SidebarFileRenaming.displayName(for: URL(fileURLWithPath: "/tmp/Notes.md"), isDirectory: false), "Notes")
        XCTAssertEqual(SidebarFileRenaming.displayName(for: URL(fileURLWithPath: "/tmp/Archive.old", isDirectory: true), isDirectory: true), "Archive.old")
    }

    func testValidatedDestinationPreservesExtensionAndDirectory() {
        let url = URL(fileURLWithPath: "/tmp/Docs/Notes.md")
        let destination = SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "Journal")
        XCTAssertEqual(destination?.path, "/tmp/Docs/Journal.md")
    }

    func testValidatedDestinationForFolderKeepsWholeName() {
        let url = URL(fileURLWithPath: "/tmp/Docs/Old", isDirectory: true)
        let destination = SidebarFileRenaming.validatedDestination(for: url, isDirectory: true, newDisplayName: "New Name")
        XCTAssertEqual(destination?.path, "/tmp/Docs/New Name")
    }

    func testValidatedDestinationRejectsEmptySlashColonAndUnchangedNames() {
        let url = URL(fileURLWithPath: "/tmp/Notes.md")
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "  "))
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "a/b"))
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "a:b"))
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "Notes"))
    }

    func testRenameMovesFileOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("A.md")
        try "# A".write(to: source, atomically: true, encoding: .utf8)
        let destination = folder.appendingPathComponent("B.md")

        try SidebarFileOperations().rename(source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCaseOnlyRenameSucceedsOnCaseInsensitiveVolume() throws {
        // A naive fileExists pre-check would see "Notes.md" as already existing (it matches
        // notes.md case-insensitively) and block the most common rename there is.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("notes.md")
        try "# Notes".write(to: source, atomically: true, encoding: .utf8)

        try SidebarFileOperations().rename(source, to: folder.appendingPathComponent("Notes.md"))

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names, ["Notes.md"])
    }

    func testRenameOntoAnExistingFileThrowsAndLeavesBothFilesIntact() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("A.md")
        let destination = folder.appendingPathComponent("B.md")
        try "# A".write(to: source, atomically: true, encoding: .utf8)
        try "# B".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SidebarFileOperations().rename(source, to: destination))

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "# A")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# B")
    }

    func testTrashUsesTrashItemNeverRemoveItem() throws {
        let recorder = RecordingFileManager()
        let operations = SidebarFileOperations(fileManager: recorder)
        let url = URL(fileURLWithPath: "/tmp/A.md")
        try operations.trash(url)
        XCTAssertEqual(recorder.trashed, [url])
    }

    @MainActor
    func testDialogCopyMatchesMuseStyleSpec() {
        XCTAssertEqual(SidebarFileActionPresenter.renameFileTitle, "Rename File")
        XCTAssertEqual(SidebarFileActionPresenter.renameFolderTitle, "Rename Folder")
        XCTAssertEqual(SidebarFileActionPresenter.renameFileMessage, "Renames the file. Its contents are kept.")
        XCTAssertEqual(SidebarFileActionPresenter.renameFolderMessage, "Renames the folder. Its files are kept.")
        XCTAssertEqual(SidebarFileActionPresenter.deleteTitle(for: URL(fileURLWithPath: "/tmp/Notes.md")), "Delete “Notes.md”?")
        XCTAssertEqual(SidebarFileActionPresenter.deleteMessage, "It will be moved to the Trash.")
        XCTAssertEqual(SidebarFileActionPresenter.deleteButtonTitle, "Delete")
        XCTAssertEqual(SidebarFileActionPresenter.cancelButtonTitle, "Cancel")
        XCTAssertEqual(SidebarFileActionPresenter.renameButtonTitle, "Rename")
    }

    func testRenamePayloadRebasesTheRenamedItemAndDescendants() {
        let payload = LineformAppNotification.RenamePayload(
            from: URL(fileURLWithPath: "/tmp/Docs", isDirectory: true),
            to: URL(fileURLWithPath: "/tmp/Notes", isDirectory: true),
            isDirectory: true
        )
        XCTAssertEqual(payload.rebased(URL(fileURLWithPath: "/tmp/Docs"))?.path, "/tmp/Notes")
        XCTAssertEqual(payload.rebased(URL(fileURLWithPath: "/tmp/Docs/a/b.md"))?.path, "/tmp/Notes/a/b.md")
        XCTAssertNil(payload.rebased(URL(fileURLWithPath: "/tmp/Docs-other/b.md")))
        XCTAssertNil(payload.rebased(URL(fileURLWithPath: "/tmp/Other.md")))
        XCTAssertNil(payload.rebased(nil))

        let filePayload = LineformAppNotification.RenamePayload(
            from: URL(fileURLWithPath: "/tmp/A.md"),
            to: URL(fileURLWithPath: "/tmp/B.md"),
            isDirectory: false
        )
        XCTAssertEqual(filePayload.rebased(URL(fileURLWithPath: "/tmp/A.md"))?.path, "/tmp/B.md")
        XCTAssertNil(filePayload.rebased(URL(fileURLWithPath: "/tmp/C.md")))
    }
}
