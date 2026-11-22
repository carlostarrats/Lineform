import XCTest
@testable import LineformCore

/// Moved from the Mac's `SidebarFileActionsTests` (the pure half). The file-system half stays there.
final class FileRenamingTests: XCTestCase {
    func testDisplayNameStripsExtensionForFilesButNotFolders() {
        XCTAssertEqual(FileRenaming.displayName(for: URL(fileURLWithPath: "/tmp/Notes.md"), isDirectory: false), "Notes")
        XCTAssertEqual(FileRenaming.displayName(for: URL(fileURLWithPath: "/tmp/Archive.old", isDirectory: true), isDirectory: true), "Archive.old")
    }

    func testValidatedDestinationPreservesExtensionAndDirectory() {
        let url = URL(fileURLWithPath: "/tmp/Docs/Notes.md")
        let destination = FileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "Journal")
        XCTAssertEqual(destination?.path, "/tmp/Docs/Journal.md")
        XCTAssertEqual(FileRenaming.validatedDestination(for: url, newName: "Journal"), destination)
    }

    func testValidatedDestinationForFolderKeepsWholeName() {
        let url = URL(fileURLWithPath: "/tmp/Docs/Old", isDirectory: true)
        let destination = FileRenaming.validatedDestination(for: url, isDirectory: true, newDisplayName: "New Name")
        XCTAssertEqual(destination?.path, "/tmp/Docs/New Name")
    }

    func testValidatedDestinationRejectsEmptySlashColonAndUnchangedNames() {
        let url = URL(fileURLWithPath: "/tmp/Notes.md")
        XCTAssertNil(FileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "  "))
        XCTAssertNil(FileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "a/b"))
        XCTAssertNil(FileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "a:b"))
        XCTAssertNil(FileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "Notes"))
    }

    // "." / ".." would, for a folder (no extension appended), resolve the destination to the
    // parent directory — a move disguised as a rename, which the file system rejects with a
    // confusing raw error. They must be treated as invalid names, not attempted.
    func testValidatedDestinationRejectsDotAndDotDot() {
        let folder = URL(fileURLWithPath: "/tmp/Journal", isDirectory: true)
        XCTAssertNil(FileRenaming.validatedDestination(for: folder, isDirectory: true, newDisplayName: "."))
        XCTAssertNil(FileRenaming.validatedDestination(for: folder, isDirectory: true, newDisplayName: ".."))
        XCTAssertNil(FileRenaming.validatedDestination(for: folder, isDirectory: true, newDisplayName: "  ..  "))
        let file = URL(fileURLWithPath: "/tmp/Notes.md")
        XCTAssertNil(FileRenaming.validatedDestination(for: file, isDirectory: false, newDisplayName: ".."))
    }
}
