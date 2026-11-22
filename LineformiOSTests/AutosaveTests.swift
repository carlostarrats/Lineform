import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// Autosave, naming by the first line, the background flush and scene restoration. Every test
/// saves into its own temporary folder, injected as the save folder.
@MainActor
final class AutosaveTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Saving

    func testTypingSavesIntoSaveFolder() async throws {
        let document = await preparedDocument()
        for prefix in ["H", "He", "Hel", "Hell", "Hello"] { document.edit(prefix) }

        document.flush()

        let url = folder.appendingPathComponent("Hello.md")
        XCTAssertEqual(try Data(contentsOf: url), Data("Hello".utf8))
        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.lastSyncedText, "Hello")
        XCTAssertEqual(try fileNames(), ["Hello.md"])
    }

    func testEmptyNewDocumentCreatesNoFile() async throws {
        let document = await preparedDocument()
        document.edit("   ")

        document.flush()

        XCTAssertNil(document.url)
        XCTAssertEqual(try fileNames(), [])
    }

    func testAutosaveWritesOneSecondAfterTheLastKeystroke() async throws {
        XCTAssertEqual(OpenDocument.autosaveDelay, .seconds(1))
        let document = await preparedDocument()
        document.edit("Saved by itself")
        let url = folder.appendingPathComponent("Saved by itself.md")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "not before the delay")

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("Saved by itself".utf8))
    }

    /// The first save names the file from the first keystroke; editing the first line renames it.
    func testEditingTheFirstLineRenamesTheNewFile() async throws {
        let document = await preparedDocument()
        document.edit("H")
        document.flush()
        XCTAssertEqual(try fileNames(), ["H.md"])

        document.edit("Hello there\nBody")
        document.flush()

        XCTAssertEqual(try fileNames(), ["Hello there.md"])
        XCTAssertEqual(document.url, folder.appendingPathComponent("Hello there.md"))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(document.url), encoding: .utf8), "Hello there\nBody")
    }

    func testCaseOnlyFirstLineChangeRenamesTheFile() async throws {
        let document = await preparedDocument()
        document.edit("hello")
        document.flush()

        document.edit("Hello")
        document.flush()

        XCTAssertEqual(try fileNames(), ["Hello.md"])
    }

    func testRenameAvoidsAnExistingFile() async throws {
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("Taken.md"))
        let document = await preparedDocument()
        document.edit("T")
        document.flush()

        document.edit("Taken")
        document.flush()

        XCTAssertEqual(try fileNames(), ["Taken 2.md", "Taken.md"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Taken.md"), encoding: .utf8), "theirs")
    }

    func testOpenedFileEditsWriteInPlace() async throws {
        let url = folder.appendingPathComponent("Kept Name.md")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("# Old\r\nBody".utf8)).write(to: url)
        let document = await preparedDocument()
        try document.open(url)

        document.edit(document.text.replacingOccurrences(of: "Old", with: "A different title"))
        document.flush()

        XCTAssertEqual(document.url, url)
        XCTAssertEqual(try fileNames(), ["Kept Name.md"])
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data("# A different title\r\nBody".utf8),
                       "the BOM and CRLF survive the write")
    }

    func testOpeningAnotherFileSavesPendingEdits() async throws {
        let other = folder.appendingPathComponent("Other.md")
        try Data("other".utf8).write(to: other)
        let document = await preparedDocument()
        document.edit("Unsaved thought")

        try document.open(other)

        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Unsaved thought.md")), Data("Unsaved thought".utf8))
        XCTAssertEqual(document.text, "other")
    }

    // MARK: - Background

    func testBackgroundFlushWritesPendingText() async throws {
        let document = await preparedDocument()
        document.edit("Typed, then switched apps")
        let tasks = RecordingBackgroundTasks()

        document.flushForBackground(using: tasks)

        let url = folder.appendingPathComponent("Typed, then switched apps.md")
        XCTAssertEqual(try Data(contentsOf: url), Data("Typed, then switched apps".utf8))
        XCTAssertEqual(tasks.events, ["begin 1", "end 1"], "the write runs inside a background task")
    }

    // MARK: - Own writes

    /// Our own save does not come back as a reload, and the caret stays where the writer left it.
    func testSaveDoesNotReloadOrMoveTheCursor() async throws {
        let document = await preparedDocument()
        let textView = try host(DocumentScreen(document: document))
        textView.becomeFirstResponder()
        textView.insertText("Hello world")
        XCTAssertEqual(document.text, "Hello world", "typing reaches the document")
        textView.selectedRange = NSRange(location: 5, length: 0)

        document.flush()
        let outcome = await document.applyExternalChange()
        // Give a presenter callback, if one were coming, time to land and debounce.
        try await Task.sleep(for: .seconds(DocumentReloadPolicy.debounceInterval * 2))

        XCTAssertEqual(outcome, .ignoreUnchanged)
        XCTAssertEqual(textView.text, "Hello world")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
    }

    // MARK: - Scene restoration

    func testSceneStorageReopensDocument() async throws {
        let first = await preparedDocument()
        first.edit("Restored after a system termination")
        first.flush()
        let stored = first.storedPath
        XCTAssertEqual(stored, "Restored after a system termination.md", "a file in the save folder is stored relative to it")

        let document = makeDocument()
        await document.prepare(restoringStoredPath: stored)
        let textView = try host(DocumentScreen(document: document))

        XCTAssertEqual(document.url, folder.appendingPathComponent(stored))
        XCTAssertEqual(textView.text, "Restored after a system termination")
    }

    func testMissingStoredFileFallsBackToBlank() async throws {
        let document = makeDocument()

        await document.prepare(restoringStoredPath: "Gone.md")

        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.storedPath, "")
    }

    func testStoredPathOutsideTheSaveFolderIsAbsolute() async throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("elsewhere-\(UUID().uuidString).md")
        try Data("x".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let document = await preparedDocument()

        try document.open(elsewhere)

        XCTAssertEqual(document.storedPath, elsewhere.path)
        let restored = makeDocument()
        await restored.prepare(restoringStoredPath: document.storedPath)
        XCTAssertEqual(restored.text, "x")
    }

    // MARK: - Deleted elsewhere

    /// The open file is deleted in Files or on another device: the text stays on screen, and
    /// nothing writes the file back.
    func testExternalDeleteDoesNotResurrectFile() async throws {
        let document = await preparedDocument()
        document.edit("Doomed")
        document.flush()
        let url = folder.appendingPathComponent("Doomed.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try coordinatedDelete(url)
        try await waitUntil { document.url == nil }

        document.flush()
        try await Task.sleep(for: OpenDocument.autosaveDelay + .milliseconds(300))
        XCTAssertEqual(document.text, "Doomed", "the text stays on screen")
        XCTAssertEqual(try fileNames(), [], "nothing is written back")
        XCTAssertTrue(document.isNamedFromFirstLine, "it is a new document again")
        XCTAssertEqual(document.storedBookmark, "")
    }

    /// After the delete, the next change saves the text as a new document named from its first line.
    func testTypingAfterDeleteCreatesNewFile() async throws {
        let url = folder.appendingPathComponent("Old name.md")
        try Data("Kept text".utf8).write(to: url)
        let document = await preparedDocument()
        try document.open(url)

        try coordinatedDelete(url)
        try await waitUntil { document.url == nil }
        document.edit("Kept text, continued")
        document.flush()

        let newURL = folder.appendingPathComponent("Kept text, continued.md")
        XCTAssertEqual(document.url, newURL)
        XCTAssertEqual(try fileNames(), ["Kept text, continued.md"])
        XCTAssertEqual(try Data(contentsOf: newURL), Data("Kept text, continued".utf8))
    }

    // MARK: - New Document

    func testNewDocumentStartsBlankAndCreatesNoFile() async throws {
        let url = folder.appendingPathComponent("Open.md")
        try Data("Open".utf8).write(to: url)
        let document = await preparedDocument()
        try document.open(url)
        document.edit("Open, with a pending edit")

        document.newDocument()

        XCTAssertEqual(try Data(contentsOf: url), Data("Open, with a pending edit".utf8), "the pending save is flushed first")
        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.lastSyncedText, "")
        XCTAssertTrue(document.isNamedFromFirstLine)
        document.flush()
        try await Task.sleep(for: OpenDocument.autosaveDelay + .milliseconds(300))
        XCTAssertEqual(try fileNames(), ["Open.md"], "a blank document creates no file")

        document.edit("Fresh")
        document.flush()
        XCTAssertEqual(try fileNames(), ["Fresh.md", "Open.md"])
    }

    // MARK: - Restoring by bookmark

    /// A file from outside the save folder is stored as a bookmark, so it reopens after iOS ends
    /// the app even when it has been renamed meanwhile.
    func testFileOutsideTheSaveFolderReopensByBookmark() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let url = outside.appendingPathComponent("From Files.md")
        try Data("From outside".utf8).write(to: url)
        let document = await preparedDocument()
        try document.open(url)

        let bookmark = document.storedBookmark
        XCTAssertFalse(bookmark.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: bookmark), "the bookmark is stored as base64")
        let renamed = outside.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: url, to: renamed)

        let restored = makeDocument()
        await restored.prepare(restoringBookmark: bookmark)

        XCTAssertEqual(restored.text, "From outside")
        XCTAssertEqual(restored.url?.lastPathComponent, "Renamed.md", "the bookmark, not the path, found it")
    }

    /// A document stored the old way, by path, still reopens once.
    func testLegacyStoredPathStillReopens() async throws {
        let url = folder.appendingPathComponent("Legacy.md")
        try Data("Stored by path".utf8).write(to: url)

        let document = makeDocument()
        await document.prepare(restoringBookmark: "", restoringStoredPath: "Legacy.md")

        XCTAssertEqual(document.text, "Stored by path")
        XCTAssertFalse(document.storedBookmark.isEmpty, "from now on it is stored as a bookmark")
    }

    func testBrokenBookmarkFallsBackToBlank() async throws {
        let document = makeDocument()

        await document.prepare(restoringBookmark: "bm90IGEgYm9va21hcms=")

        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "")
    }

    // MARK: - Helpers

    private func makeDocument() -> OpenDocument {
        let folder = self.folder!
        return OpenDocument(folderProvider: { folder })
    }

    private func preparedDocument() async -> OpenDocument {
        let document = makeDocument()
        await document.prepare(restoringStoredPath: "")
        return document
    }

    /// Deletes as Files or iCloud would: through file coordination, with no presenter.
    private func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deleteURL in
                do { try FileManager.default.removeItem(at: deleteURL) } catch { deleteError = error }
            }
        if let error = coordinationError ?? deleteError { throw error }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Shows `view` in a window of its own and returns its editor.
    private func host(_ view: some View) throws -> EditorTextView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        self.window = window
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.layoutIfNeeded()
            if let editor = Self.editor(in: window) { return editor }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        throw NoEditor()
    }

    private static func editor(in view: UIView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        for subview in view.subviews {
            if let editor = editor(in: subview) { return editor }
        }
        return nil
    }
}

private struct NoEditor: Error {}

/// Records background-task assertions instead of asking the system for them.
@MainActor
private final class RecordingBackgroundTasks: BackgroundTaskAsserting {
    private(set) var events: [String] = []
    private var next = 1

    func beginAssertion(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        let identifier = UIBackgroundTaskIdentifier(rawValue: next)
        next += 1
        events.append("begin \(identifier.rawValue)")
        return identifier
    }

    func endAssertion(_ identifier: UIBackgroundTaskIdentifier) {
        events.append("end \(identifier.rawValue)")
    }
}
