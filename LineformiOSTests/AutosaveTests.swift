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

        await document.flush()

        let url = folder.appendingPathComponent("Hello.md")
        XCTAssertEqual(try Data(contentsOf: url), Data("Hello".utf8))
        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.lastSyncedText, "Hello")
        XCTAssertEqual(try fileNames(), ["Hello.md"])
    }

    func testEmptyNewDocumentCreatesNoFile() async throws {
        let document = await preparedDocument()
        document.edit("   ")

        await document.flush()

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
        await document.flush()
        XCTAssertEqual(try fileNames(), ["H.md"])

        document.edit("Hello there\nBody")
        await document.flush()

        XCTAssertEqual(try fileNames(), ["Hello there.md"])
        XCTAssertEqual(document.url, folder.appendingPathComponent("Hello there.md"))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(document.url), encoding: .utf8), "Hello there\nBody")
    }

    func testCaseOnlyFirstLineChangeRenamesTheFile() async throws {
        let document = await preparedDocument()
        document.edit("hello")
        await document.flush()

        document.edit("Hello")
        await document.flush()

        XCTAssertEqual(try fileNames(), ["Hello.md"])
    }

    func testRenameAvoidsAnExistingFile() async throws {
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("Taken.md"))
        let document = await preparedDocument()
        document.edit("T")
        await document.flush()

        document.edit("Taken")
        await document.flush()

        XCTAssertEqual(try fileNames(), ["Taken 2.md", "Taken.md"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Taken.md"), encoding: .utf8), "theirs")
    }

    func testOpenedFileEditsWriteInPlace() async throws {
        let url = folder.appendingPathComponent("Kept Name.md")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("# Old\r\nBody".utf8)).write(to: url)
        let document = await preparedDocument()
        try await document.open(url)

        document.edit(document.text.replacingOccurrences(of: "Old", with: "A different title"))
        await document.flush()

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

        try await document.open(other)

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
        let textView = try host(DocumentScreen(document: document, profileStore: Self.profileStore()))
        textView.becomeFirstResponder()
        textView.insertText("Hello world")
        XCTAssertEqual(document.text, "Hello world", "typing reaches the document")
        textView.selectedRange = NSRange(location: 5, length: 0)

        await document.flush()
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
        await first.flush()
        let stored = first.storedPath
        XCTAssertEqual(stored, "Restored after a system termination.md", "a file in the save folder is stored relative to it")

        let document = makeDocument()
        await document.prepare(restoringStoredPath: stored)
        let textView = try host(DocumentScreen(document: document, profileStore: Self.profileStore()))

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

        try await document.open(elsewhere)

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
        await document.flush()
        let url = folder.appendingPathComponent("Doomed.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try coordinatedDelete(url)
        try await waitUntil { document.url == nil }

        await document.flush()
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
        try await document.open(url)

        try coordinatedDelete(url)
        try await waitUntil { document.url == nil }
        document.edit("Kept text, continued")
        await document.flush()

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
        try await document.open(url)
        document.edit("Open, with a pending edit")

        await document.newDocument()

        XCTAssertEqual(try Data(contentsOf: url), Data("Open, with a pending edit".utf8), "the pending save is flushed first")
        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.lastSyncedText, "")
        XCTAssertTrue(document.isNamedFromFirstLine)
        await document.flush()
        try await Task.sleep(for: OpenDocument.autosaveDelay + .milliseconds(300))
        XCTAssertEqual(try fileNames(), ["Open.md"], "a blank document creates no file")

        document.edit("Fresh")
        await document.flush()
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
        try await document.open(url)

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


    // MARK: - Races and failures

    /// A reload read that was in flight while our own save landed must not put the older disk
    /// text back on screen: the save would then lose what was just typed.
    func testReloadInFlightDuringASaveKeepsTheSavedText() async throws {
        let url = folder.appendingPathComponent("Race.md")
        try Data("Disk 0".utf8).write(to: url)
        let reader = GatedReader()
        let document = makeDocument(reader: reader)
        await document.prepare()
        try await document.open(url)

        // Another device writes D1 (not coordinated, so the watcher stays out of it).
        try Data("Disk 1 from elsewhere".utf8).write(to: url)
        reader.holdNextRead()
        let reload = Task { _ = await document.applyExternalChange() }
        try await waitUntil { reader.isHolding }

        // Meanwhile the writer types and the autosave writes T.
        document.edit("Typed while the read was in flight")
        await document.flush()
        reader.release()
        await reload.value

        XCTAssertEqual(document.text, "Typed while the read was in flight", "the stale disk text does not come back")
        await document.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Typed while the read was in flight")
    }

    /// Before the folder is known (launch), a flush waits for it instead of dropping the save.
    func testFlushBeforeTheFolderIsKnownWaitsForIt() async throws {
        let document = makeDocument()
        document.edit("Typed at launch")

        await document.flush()
        try await waitUntil { document.url != nil }

        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Typed at launch.md")), Data("Typed at launch".utf8))
    }

    /// The open file moved into a Trash folder (Files' Recently Deleted): that is a delete.
    func testMoveIntoTrashIsADelete() async throws {
        let url = folder.appendingPathComponent("Trashed.md")
        try Data("Trashed".utf8).write(to: url)
        let document = await preparedDocument()
        try await document.open(url)
        let trash = folder.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("Trashed.md")

        try coordinatedMove(url, to: trashed)
        try await waitUntil { document.url == nil }

        document.edit("Trashed, then typed")
        await document.flush()
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "Trashed", "nothing writes into the Trash")
        XCTAssertEqual(document.url, folder.appendingPathComponent("Trashed, then typed.md"))
    }

    func testTrashLocations() {
        XCTAssertTrue(OpenDocument.isTrashLocation(URL(fileURLWithPath: "/private/var/mobile/.Trash/A.md")))
        XCTAssertTrue(OpenDocument.isTrashLocation(URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/x/Trash/A.md")))
        XCTAssertFalse(OpenDocument.isTrashLocation(URL(fileURLWithPath: "/Users/me/Documents/Trash talk.md")))
        XCTAssertFalse(OpenDocument.isTrashLocation(URL(fileURLWithPath: "/Users/me/Documents/A.md")))
    }


    /// A save that fails before another file opens keeps the current text on screen.
    func testFailedSaveKeepsTheTextWhenOpeningAnotherFile() async throws {
        let other = folder.appendingPathComponent("Other.md")
        try Data("other".utf8).write(to: other)
        let document = await preparedDocument(writer: FailingWriter())
        document.edit("Precious words")

        do {
            try await document.open(other)
            XCTFail("the open does not go ahead")
        } catch {
            XCTAssertEqual(error as? OpenDocument.OpenError, .currentDocumentNotSaved)
        }
        await document.openReportingFailure(other)

        XCTAssertEqual(document.text, "Precious words", "the text stays")
        XCTAssertNil(document.url)
        XCTAssertTrue(document.saveFailed, "the screen shows the quiet notice")
        XCTAssertNil(document.failedOpenURL, "it is not reported as the other file failing to open")
    }

    func testFailedSaveKeepsTheTextOnNewDocument() async throws {
        let document = await preparedDocument(writer: FailingWriter())
        document.edit("Precious words")

        let started = await document.newDocument()

        XCTAssertFalse(started)
        XCTAssertEqual(document.text, "Precious words")
        XCTAssertTrue(document.saveFailed)
    }

    func testSaveFailureNoticeClearsOnTheNextSave() async throws {
        let writer = FailingWriter(failures: 1)
        let document = await preparedDocument(writer: writer)
        document.edit("Second try")

        let first = await document.flush()
        XCTAssertFalse(first)
        XCTAssertTrue(document.saveFailed)
        let second = await document.flush()

        XCTAssertTrue(second)
        XCTAssertFalse(document.saveFailed)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Second try.md")), Data("Second try".utf8))
    }

    /// A file that appears under the planned name just before the first save is never overwritten.
    func testCreateNeverOverwritesAFileThatAppearedAtTheLastMoment() async throws {
        let document = await preparedDocument(writer: CollidingWriter(theirText: "theirs"))
        document.edit("Clash")

        let saved = await document.flush()

        XCTAssertTrue(saved)
        XCTAssertEqual(try fileNames(), ["Clash 2.md", "Clash.md"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Clash.md"), encoding: .utf8), "theirs")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Clash 2.md"), encoding: .utf8), "Clash")
        XCTAssertEqual(document.url, folder.appendingPathComponent("Clash 2.md"))
    }

    /// The file list asks for the folder while `prepare` is still resolving it: it waits for the
    /// same folder instead of listing nothing.
    func testFolderResolutionIsSharedWhilePrepareIsRunning() async throws {
        let folder = self.folder!
        let gate = DispatchSemaphore(value: 0)
        let document = OpenDocument(folderProvider: { gate.wait(); return folder })

        let preparing = Task { await document.prepare() }
        let listing = Task { await document.resolveSaveFolder() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(document.saveFolder, "still resolving")
        gate.signal()

        let listed = await listing.value
        await preparing.value
        XCTAssertEqual(listed, folder)
        XCTAssertEqual(document.saveFolder, folder)
    }

    func testLeavingTheForegroundSavesAtOnce() {
        XCTAssertTrue(OpenDocument.savesImmediately(on: .inactive))
        XCTAssertTrue(OpenDocument.savesImmediately(on: .background))
        XCTAssertFalse(OpenDocument.savesImmediately(on: .active))
    }


    // MARK: - Open ordering

    /// The launch restore never takes over from an open the writer started.
    func testRestoreGivesWayToAnOpenInFlight() async throws {
        let chosen = folder.appendingPathComponent("Chosen.md")
        try Data("Chosen by the writer".utf8).write(to: chosen)
        try Data("Restored".utf8).write(to: folder.appendingPathComponent("Restored.md"))
        let reader = GatedReader()
        let document = makeDocument(reader: reader)
        reader.holdNextRead()

        let opening = Task { try await document.open(chosen) }
        try await waitUntil { reader.isHolding }
        await document.prepare(restoringStoredPath: "Restored.md")
        reader.release()
        try await opening.value

        XCTAssertEqual(document.url, chosen)
        XCTAssertEqual(document.text, "Chosen by the writer")
    }

    /// The restore waits on iCloud for a file with no local copy; the writer types meanwhile. The
    /// restore then gives up instead of putting the typed document away.
    func testRestoreNeverPutsAwayADocumentTypedIntoDuringItsDownloadCheck() async throws {
        let restored = folder.appendingPathComponent("In iCloud.md")
        let cloud = FakeUbiquitousItems(pending: [restored], arrivingText: "From iCloud", hold: .firstStateCheck)
        let document = makeDocument(ubiquitousItems: cloud)

        let preparing = Task { await document.prepare(restoringStoredPath: "In iCloud.md") }
        try await waitUntil { cloud.isHolding }
        document.edit("Typed at launch")
        cloud.release()
        await preparing.value

        XCTAssertEqual(document.text, "Typed at launch")
        XCTAssertNil(document.downloadingName)
        XCTAssertEqual(cloud.startedURLs, [], "the restore did not start a download")
    }

    /// New Document starts, an open starts after it; whichever finishes its save last, the open
    /// the writer asked for later is what stays on screen.
    func testNewDocumentDoesNotCloseAnOpenThatFinishedDuringItsSave() async throws {
        let other = folder.appendingPathComponent("Later.md")
        try Data("Opened later".utf8).write(to: other)
        let folder = self.folder!
        let gate = DispatchSemaphore(value: 0)
        let document = OpenDocument(folderProvider: { gate.wait(); return folder })
        document.edit("Typed first")

        let starting = Task { await document.newDocument() }
        try await Task.sleep(for: .milliseconds(50))
        let opening = Task { try await document.open(other) }
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()
        let started = await starting.value
        try await opening.value

        XCTAssertFalse(started, "New Document gave way to the later open")
        XCTAssertEqual(document.url, other)
        XCTAssertEqual(document.text, "Opened later")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Typed first.md")), Data("Typed first".utf8))
    }

    // MARK: - Helpers

    private func makeDocument(
        reader: any DocumentDiskReading = FileSystemDiskReader(),
        writer: any DocumentFileWriting = FileSystemDocumentWriter(),
        ubiquitousItems: any UbiquitousItemAccessing = LiveUbiquitousItems()
    ) -> OpenDocument {
        let folder = self.folder!
        return OpenDocument(folderProvider: { folder }, reader: reader, writer: writer, ubiquitousItems: ubiquitousItems)
    }

    private func preparedDocument(writer: any DocumentFileWriting = FileSystemDocumentWriter()) async -> OpenDocument {
        let document = makeDocument(writer: writer)
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

    /// Moves as Files or iCloud would: through file coordination, announced to presenters.
    private func coordinatedMove(_ source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
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

    /// A reading-profile store on its own defaults suite, so no test reads or writes the app's.
    private static func profileStore() -> ReadingProfileStore {
        ReadingProfileStore(defaults: UserDefaults(suiteName: "AutosaveTests.readingProfile") ?? .standard)
    }

    /// Shows `view` in a window of its own and returns its editor.
    private func host(_ view: some View) throws -> LineformTextView {
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

    private static func editor(in view: UIView) -> LineformTextView? {
        if let editor = view as? LineformTextView { return editor }
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

/// A disk reader that can hold one read after it has read the file, until the test releases it:
/// the read is then "in flight" while the test does other work on the main actor.
final class GatedReader: DocumentDiskReading, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldHold = false
    private var holding = false
    private let gate = DispatchSemaphore(value: 0)
    private var mainThreadReads = 0
    private var reads = 0

    var isHolding: Bool { lock.withLock { holding } }
    var readCount: Int { lock.withLock { reads } }
    var readsOnTheMainThread: Int { lock.withLock { mainThreadReads } }

    func holdNextRead() { lock.withLock { shouldHold = true } }
    func release() { gate.signal() }

    func readText(at url: URL) -> String? {
        let text = FileSystemDiskReader().readText(at: url)
        let hold = lock.withLock {
            reads += 1
            if Thread.isMainThread { mainThreadReads += 1 }
            let hold = shouldHold
            shouldHold = false
            holding = hold
            return hold
        }
        if hold {
            gate.wait()
            lock.withLock { holding = false }
        }
        return text
    }

    func modificationDate(at url: URL) -> Date? { FileSystemDiskReader().modificationDate(at: url) }
}

/// A writer that fails, always or for the first `failures` writes.
final class FailingWriter: DocumentFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?

    init(failures: Int? = nil) { remaining = failures }

    func write(_ data: Data, to url: URL, replaceExisting: Bool) throws {
        let fails = lock.withLock { () -> Bool in
            guard let left = remaining else { return true }
            remaining = left - 1
            return left > 0
        }
        if fails { throw CocoaError(.fileWriteNoPermission) }
        try FileSystemDocumentWriter().write(data, to: url, replaceExisting: replaceExisting)
    }
}

/// A writer that, on the first new file, lets another device create a file at that name a moment
/// before the write, then writes for real.
final class CollidingWriter: DocumentFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var hasCollided = false
    private let theirText: String

    init(theirText: String) { self.theirText = theirText }

    func write(_ data: Data, to url: URL, replaceExisting: Bool) throws {
        let collide = lock.withLock { () -> Bool in
            defer { hasCollided = true }
            return !replaceExisting && !hasCollided
        }
        if collide { try Data(theirText.utf8).write(to: url) }
        try FileSystemDocumentWriter().write(data, to: url, replaceExisting: replaceExisting)
    }
}
