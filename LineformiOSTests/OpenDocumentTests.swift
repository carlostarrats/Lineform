import LineformCore
import XCTest
@testable import LineformiOS

/// Opening files and live reload. Every test works in its own temporary folder; none touches the
/// app's Documents folder or an iCloud container.
@MainActor
final class OpenDocumentTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOpeningAFileShowsItsText() throws {
        let url = try write("# Notes\r\nSecond line", named: "Notes.md")
        let document = makeDocument()

        try document.open(url)

        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.text, "# Notes\r\nSecond line", "CRLF is kept as it is")
        XCTAssertEqual(document.lastSyncedText, document.text)
    }

    func testOpeningKeepsALeadingByteOrderMark() throws {
        let url = folder.appendingPathComponent("BOM.md")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8)).write(to: url)
        let document = makeDocument()

        try document.open(url)

        XCTAssertEqual(document.text, "\u{FEFF}Hi")
    }

    func testExternalWriteReloadsWhenClean() async throws {
        let url = try write("Before", named: "Shared.md")
        let document = makeDocument()
        try document.open(url)

        try coordinatedWrite("After, from another device", to: url)
        let outcome = await document.applyExternalChange()

        XCTAssertEqual(outcome, .reload)
        XCTAssertEqual(document.text, "After, from another device")
        XCTAssertEqual(document.lastSyncedText, "After, from another device")
    }

    func testExternalWriteKeepsLocalEdits() async throws {
        let url = try write("Before", named: "Shared.md")
        let document = makeDocument()
        try document.open(url)
        document.edit("Before, and my local edit")

        try coordinatedWrite("Their edit", to: url)
        let outcome = await document.applyExternalChange()

        XCTAssertEqual(outcome, .ignoreDirty)
        XCTAssertEqual(document.text, "Before, and my local edit")
    }

    /// The file presenter alone (no explicit call) brings an external write in.
    func testExternalWriteReloadsLiveThroughTheWatcher() throws {
        let url = try write("Before", named: "Live.md")
        let document = makeDocument()
        try document.open(url)

        try coordinatedWrite("After", to: url)

        let deadline = Date().addingTimeInterval(3)
        while document.text != "After", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(document.text, "After")
    }

    func testOpenedFileIsNeverAutoRenamed() throws {
        let url = try write("# Old title", named: "Kept Name.md")
        let document = makeDocument()
        XCTAssertTrue(document.isNamedFromFirstLine, "a new document is named from its first line")

        try document.open(url)

        XCTAssertFalse(document.isNamedFromFirstLine)
    }

    func testInvalidUTF8FileIsRefused() throws {
        let good = try write("Good text", named: "Good.md")
        let bad = folder.appendingPathComponent("Bad.md")
        try Data([0x48, 0xFF, 0xFE, 0x49]).write(to: bad)
        let document = makeDocument()
        try document.open(good)

        XCTAssertThrowsError(try document.open(bad))

        XCTAssertEqual(document.url, good, "the current document stays")
        XCTAssertEqual(document.text, "Good text")
        XCTAssertEqual(try Data(contentsOf: bad), Data([0x48, 0xFF, 0xFE, 0x49]), "the bad file is untouched")
    }

    /// A reload replaces the editor's text without throwing the caret to the end.
    func testReloadedTextKeepsTheEditorSelection() {
        let textView = PlainTextEditor.makeTextView(profile: .original)
        PlainTextEditor.setText("Hello world", in: textView)
        textView.selectedRange = NSRange(location: 5, length: 0)

        PlainTextEditor.setText("Hello there, world", in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))

        PlainTextEditor.setText("Hi", in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0), "clamped to the new text")
    }

    // MARK: - File list

    func testFileListShowsMarkdownAndTextFilesNewestFirst() throws {
        let old = try write("old", named: "Old.md")
        let newer = try write("newer", named: "Newer.txt")
        try write("ignored", named: "Picture.png")
        try write("hidden", named: ".Hidden.md")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Sub.md", isDirectory: true), withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let names = FileListModel.listFiles(in: folder).map(\.name)

        XCTAssertEqual(names, ["Newer.txt", "Old.md"])
    }

    func testFileListNamesAnICloudPlaceholderByItsFile() {
        XCTAssertEqual(FileListModel.displayName(of: ".Notes.md.icloud"), "Notes.md")
        XCTAssertNil(FileListModel.displayName(of: ".DS_Store"))
        XCTAssertEqual(FileListModel.displayName(of: "Notes.md"), "Notes.md")
    }

    // MARK: - Helpers

    private func makeDocument() -> OpenDocument {
        let folder = self.folder!
        return OpenDocument(folderProvider: { folder })
    }

    @discardableResult
    private func write(_ text: String, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Writes as another app or iCloud would: through file coordination, with no presenter.
    private func coordinatedWrite(_ text: String, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
                do { try Data(text.utf8).write(to: writeURL) } catch { writeError = error }
            }
        if let error = coordinationError ?? writeError { throw error }
    }
}
