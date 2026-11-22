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
