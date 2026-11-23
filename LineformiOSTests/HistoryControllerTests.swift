import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// The iPhone History controller (the Mac's `DocumentHistoryController`, ported): Replace With…,
/// steps, the exit collapse, reload, moves, Untitled documents, prune, and the lifecycle hooks
/// `OpenDocument` drives. Every store is a temporary folder or an in-memory fake.
@MainActor
final class HistoryControllerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let text = "Alpha beta gamma delta. Epsilon zeta eta theta."
    private let sentence = "Alpha beta gamma delta."
    private let accepted = "Alpha BETA gamma delta."
    private var directory: URL!
    private var window: UIWindow?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Replace With…

    func testAddThenReplacementKeepsTwoVersions() throws {
        let store = fileStore()
        let a = try makeFile("a.md", contents: text)
        let controller = makeController(store: store)
        controller.open(url: a, text: text)

        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertTrue(controller.isHistoryModeActive, "Replace With… shows the passage in History mode")
        XCTAssertEqual(controller.selectedPassageID, id)
        XCTAssertEqual(controller.pendingReplacementFieldID, id, "the replacement field is asked for")

        let edit = try XCTUnwrap(controller.addReplacement("Alpha BETA gamma delta.", text: text))
        let replaced = apply(edit, to: text)
        XCTAssertEqual(replaced, "Alpha BETA gamma delta. Epsilon zeta eta theta.")
        controller.exitHistoryMode(text: replaced)

        XCTAssertTrue(controller.hasHistory)
        let stored = try XCTUnwrap(store.load(for: a).passages.first)
        XCTAssertEqual(stored.versions.map(\.text), [sentence, "Alpha BETA gamma delta."])
        XCTAssertEqual(stored.currentIndex, 1)
    }

    func testLeavingWithoutReplacementDiscardsThePassage() throws {
        let store = fileStore()
        let a = try makeFile("a.md", contents: text)
        let controller = makeController(store: store)
        controller.open(url: a, text: text)

        XCTAssertNotNil(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertTrue(controller.hasHistory)
        let exit = try XCTUnwrap(controller.exitHistoryMode(text: text))

        XCTAssertNil(exit.collapse, "nothing changed the text")
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertFalse(controller.hasHistory, "a passage never given a replacement was not kept")
        XCTAssertTrue(store.load(for: a).isEmpty)
    }

    func testReplacementIsRefusedForAnotherPassage() throws {
        let controller = makeController()
        controller.open(url: nil, text: text)
        XCTAssertNotNil(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertNil(controller.addReplacement("Other words.", text: text, for: UUID()),
                     "text written for another passage is not added")
    }

    func testReplaceWithIsOfferedOnlyWhereOneLineCanReplace() {
        let controller = makeController()
        let doc = "Intro line.\n\n```\ncode here\n```\n\nLast line."
        controller.open(url: nil, text: doc)
        XCTAssertTrue(controller.canAdd(range(of: "Intro line.", in: doc), text: doc))
        XCTAssertFalse(controller.canAdd(range(of: "code here", in: doc), text: doc), "never inside fenced code")
        XCTAssertFalse(controller.canAdd(range(of: "Intro line.\n\n", in: doc).union(range(of: "Last", in: doc)), text: doc),
                       "never across lines")
    }

    // MARK: - Steps and exit

    func testStepAppliesEditAndSaves() throws {
        let store = fileStore()
        let a = try makeFile("a.md", contents: text)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: a)
        let textView = makeEditor(edited, controller: controller)

        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        let id = try XCTUnwrap(controller.located.first?.id)
        controller.select(id)
        let edit = try XCTUnwrap(controller.step(by: -1, text: textView.text))

        XCTAssertEqual(textView.text, text, "the step updates the document at once")
        XCTAssertEqual(edit.replacement, sentence)
        XCTAssertEqual(store.load(for: a).passages.first?.currentIndex, 0, "the store sees the new current version")
        XCTAssertTrue(controller.isHistoryModeActive, "History's own edit is not typing")
    }

    func testExitCollapsesToOneUndoableEdit() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let textView = makeEditor(edited, controller: controller)

        controller.enterHistoryMode(text: textView.text)
        let id = try XCTUnwrap(controller.located.first?.id)
        controller.select(id)
        controller.step(by: -1, text: textView.text)
        XCTAssertEqual(textView.text, text)
        XCTAssertFalse(try XCTUnwrap(textView.undoManager).canUndo, "steps are not undoable one by one")
        settle()

        let exit = try XCTUnwrap(controller.exitHistoryMode(text: textView.text))
        XCTAssertNotNil(exit.collapse)
        XCTAssertEqual(exit.restoreVersions[id], 1)
        XCTAssertEqual(exit.exitVersions[id], 0)
        XCTAssertEqual(textView.text, text, "the text showing when you leave is the document text")
        let undo = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undo.canUndo)
        settle()

        undo.undo()
        XCTAssertEqual(textView.text, edited, "one undo restores the entry text")
        XCTAssertEqual(controller.passage(id)?.currentIndex, 1, "and the entry version")
        XCTAssertFalse(undo.canUndo, "the session was one undo step")
        settle()

        undo.redo()
        XCTAssertEqual(textView.text, text)
        XCTAssertEqual(controller.passage(id)?.currentIndex, 0, "redo makes the exit version current again")
    }

    func testDocumentReloadedEndsHistoryWithoutCollapse() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let textView = makeEditor(edited, controller: controller)
        controller.enterHistoryMode(text: textView.text)
        controller.select(controller.located.first?.id)
        controller.step(by: -1, text: textView.text)
        let stepped: String = textView.text

        // Disk now holds the stepped text plus another device's line.
        let disk = stepped + "\nFrom elsewhere."
        controller.documentReloaded(text: disk)

        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertEqual(textView.text, stepped, "the reload, not History, replaces the text")
        XCTAssertFalse(try XCTUnwrap(textView.undoManager).canUndo, "no collapse was registered")
        XCTAssertEqual(controller.located.first?.range, (disk as NSString).range(of: sentence),
                       "the passage is re-found literally in the reloaded text")
    }

    func testDeleteVersionNotesTheDeletionWithThePreviousHistory() throws {
        let store = MemoryHistoryStore()
        let a = try makeFile("a.md", contents: text)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: a)
        controller.enterHistoryMode(text: edited)
        let id = try XCTUnwrap(controller.located.first?.id)
        controller.select(id)

        controller.deleteVersion(0, text: edited)

        XCTAssertEqual(store.deletions.count, 1)
        XCTAssertEqual(store.deletions.first?.passage, id)
        XCTAssertEqual(store.deletions.first?.index, 0)
        XCTAssertEqual(store.deletions.first?.versionCount, 2, "the history from before the delete")
    }

    // MARK: - Files

    func testFileMovedRetargetsStore() throws {
        let store = fileStore()
        let a = try makeFile("a.md", contents: text)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: a)
        let b = directory.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: a, to: b)

        controller.fileMoved(from: a, to: b)

        XCTAssertEqual(controller.url.map(FileIdentity.key(for:)), FileIdentity.key(for: b))
        let reopened = makeController(store: store)
        reopened.open(url: b, text: edited)
        XCTAssertTrue(reopened.hasHistory)
        XCTAssertTrue(store.load(for: a).isEmpty, "nothing stays under the old name")
    }

    func testUntitledDocumentGetsFileStoresHistory() throws {
        let store = fileStore()
        let (controller, edited) = controllerWithEditedPassage(store: store, url: nil)
        let a = try makeFile("a.md", contents: edited)

        controller.documentGotFile(a, text: edited)

        let reopened = makeController(store: store)
        reopened.open(url: a, text: edited)
        XCTAssertTrue(reopened.hasHistory)
    }

    func testTypedChangesPersist() throws {
        let store = fileStore()
        let a = try makeFile("a.md", contents: text)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: a)
        let r = range(of: "gamma", in: edited)
        controller.noteUserEdit(r, replacement: "GAMMA")
        let typed = (edited as NSString).replacingCharacters(in: r, with: "GAMMA")
        controller.persist(text: typed)

        XCTAssertEqual(store.load(for: a).passages.first?.versions.last?.text, "Alpha BETA GAMMA delta.")
    }

    // MARK: - Prune and launch

    func testPruneRunsOnceAtFirstOpenOffMain() throws {
        let store = MemoryHistoryStore()
        let queue = DispatchQueue(label: "HistoryControllerTests.prune")
        let a = try makeFile("a.md", contents: text)
        let b = try makeFile("b.md", contents: text)

        let first = makeController(store: store, pruneQueue: queue)
        first.open(url: nil, text: "")
        queue.sync {}
        XCTAssertEqual(store.pruneCount, 0, "an Untitled document prunes nothing")
        first.open(url: a, text: text)
        first.open(url: b, text: text)
        makeController(store: store, pruneQueue: queue).open(url: a, text: text)
        queue.sync {}

        XCTAssertEqual(store.pruneCount, 1, "once per store per session")
        XCTAssertEqual(store.prunedOnMainThread, false)
    }

    func testNothingRunsBeforeFirstOpen() {
        let store = MemoryHistoryStore()
        let queue = DispatchQueue(label: "HistoryControllerTests.launch")
        let controller = makeController(store: store, pruneQueue: queue)
        controller.persist(text: text)
        controller.documentReloaded(text: text)
        controller.close(text: text)
        controller.open(url: nil, text: text)
        queue.sync {}
        XCTAssertEqual(store.calls, [], "no store access until a document with a file opens")
    }

    func testClearAllReloadsEveryController() throws {
        let store = fileStore()
        let a = try makeFile("a.md", contents: text)
        let (controller, _) = controllerWithEditedPassage(store: store, url: a)
        XCTAssertTrue(controller.hasHistory)

        PhoneHistoryController.clearAllHistory(in: store)

        XCTAssertFalse(controller.hasHistory)
        XCTAssertTrue(store.load(for: a).isEmpty)
    }

    // MARK: - AI (for step 8)

    func testAIActionsAreRefusedInHistoryMode() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let whole = NSRange(location: 0, length: (edited as NSString).length)
        XCTAssertTrue(controller.allowsAIAction(on: whole))
        controller.enterHistoryMode(text: edited)
        XCTAssertFalse(controller.allowsAIAction(on: whole))

        controller.aiActionWillStart()
        XCTAssertFalse(controller.isHistoryModeActive, "History and AI never overlap")
    }

    func testAcceptedAIPassageIsSelectedByTheNextMenuEntry() throws {
        let controller = makeController()
        controller.open(url: nil, text: text)
        let r = range(of: "beta", in: text)
        controller.noteUserEdit(r, replacement: "BETA")
        let edited = (text as NSString).replacingCharacters(in: r, with: "BETA")
        let id = try XCTUnwrap(controller.recordAccepted(
            range: range(of: accepted, in: edited), original: sentence, accepted: accepted, text: edited))
        controller.aiActionDidEnd(recorded: id, text: edited)
        XCTAssertEqual(controller.rememberedPassageID, id)

        XCTAssertTrue(controller.enterHistoryModeFromMenu(text: edited))
        XCTAssertEqual(controller.selectedPassageID, id)
        XCTAssertNil(controller.rememberedPassageID, "the memory is spent")
    }

    // MARK: - OpenDocument

    func testOpenDocumentDrivesTheLifecycle() async throws {
        let store = fileStore()
        let saveFolder = directory.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let a = saveFolder.appendingPathComponent("a.md")
        try text.write(to: a, atomically: true, encoding: .utf8)
        let history = makeController(store: store)
        let document = OpenDocument(folderProvider: { saveFolder }, ubiquitousItems: StaticUbiquitousItems(), history: history)

        try await document.open(a)
        XCTAssertEqual(history.url.map(FileIdentity.key(for:)), FileIdentity.key(for: a), "open → open")
        let r = range(of: "beta", in: text)
        history.noteUserEdit(r, replacement: "BETA")
        let edited = (text as NSString).replacingCharacters(in: r, with: "BETA")
        document.edit(edited)
        history.recordAccepted(range: range(of: accepted, in: edited), original: sentence, accepted: accepted, text: edited)
        let flushed = await document.flush()
        XCTAssertTrue(flushed)

        let b = saveFolder.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: a, to: b)
        document.userRenamed(to: b)
        XCTAssertEqual(history.url.map(FileIdentity.key(for:)), FileIdentity.key(for: b), "a rename → fileMoved")
        XCTAssertFalse(store.load(for: b).isEmpty)

        let swapped = await document.newDocument()
        XCTAssertTrue(swapped)
        XCTAssertNil(history.url, "a swap → close")
        XCTAssertFalse(history.hasHistory)

        document.edit("Fresh draft\nwith text")
        let flushedNew = await document.flush()
        XCTAssertTrue(flushedNew)
        XCTAssertNotNil(history.url, "a new document's first save → documentGotFile")
    }

    // MARK: - Helpers

    private func makeController(
        store: PassageHistoryPersisting = MemoryHistoryStore(),
        pruneQueue: DispatchQueue = DispatchQueue(label: "HistoryControllerTests.default")
    ) -> PhoneHistoryController {
        let date = fixedDate
        return PhoneHistoryController(store: store, now: { date }, pruneQueue: pruneQueue)
    }

    private func fileStore() -> FilePassageHistoryStore {
        FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
    }

    /// `sentence` with two versions, the second ("BETA") current, recorded as an accepted change.
    private func controllerWithEditedPassage(
        store: PassageHistoryPersisting = MemoryHistoryStore(), url: URL? = nil
    ) -> (PhoneHistoryController, String) {
        let controller = makeController(store: store)
        controller.open(url: url, text: text)
        let r = range(of: "beta", in: text)
        controller.noteUserEdit(r, replacement: "BETA")
        let edited = (text as NSString).replacingCharacters(in: r, with: "BETA")
        controller.recordAccepted(range: range(of: accepted, in: edited), original: sentence, accepted: accepted, text: edited)
        return (controller, edited)
    }

    /// A real editor in a window, attached to `controller`, with an empty undo stack.
    private func makeEditor(_ string: String, controller: PhoneHistoryController) -> LineformTextView {
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText(string)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            host.view.addSubview(textView)
            window.isHidden = false
            self.window = window
        }
        controller.attach(textView)
        textView.undoManager?.removeAllActions()
        settle()
        return textView
    }

    private func range(of needle: String, in haystack: String) -> NSRange {
        let found = (haystack as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle)")
        return found
    }

    private func apply(_ edit: HistoryEdit?, to string: String) -> String {
        guard let edit else { return string }
        return (string as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Lets the run loop close the undo manager's per-event group.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

/// An in-memory store that records what it was asked to do.
final class MemoryHistoryStore: PassageHistoryPersisting, @unchecked Sendable {
    struct Deletion { let passage: UUID; let index: Int; let versionCount: Int }

    private let lock = NSLock()
    private var histories: [String: DocumentHistory] = [:]
    private var recordedCalls: [String] = []
    private var recordedDeletions: [Deletion] = []
    private var prunes = 0
    private var prunedOnMain: Bool?

    var calls: [String] { lock.withLock { recordedCalls } }
    var deletions: [Deletion] { lock.withLock { recordedDeletions } }
    var pruneCount: Int { lock.withLock { prunes } }
    var prunedOnMainThread: Bool? { lock.withLock { prunedOnMain } }

    func load(for url: URL) -> DocumentHistory {
        lock.withLock {
            recordedCalls.append("load")
            return histories[FileIdentity.key(for: url)] ?? DocumentHistory(passages: [])
        }
    }

    func save(_ history: DocumentHistory, for url: URL) {
        lock.withLock {
            recordedCalls.append("save")
            histories[FileIdentity.key(for: url)] = history
        }
    }

    func retarget(from old: URL, to new: URL) {
        lock.withLock {
            recordedCalls.append("retarget")
            histories[FileIdentity.key(for: new)] = histories.removeValue(forKey: FileIdentity.key(for: old))
        }
    }

    func retargetDirectory(from oldDir: URL, to newDir: URL) {
        lock.withLock { recordedCalls.append("retargetDirectory") }
    }

    func prune(now: Date) {
        let onMain = Thread.isMainThread
        lock.withLock {
            recordedCalls.append("prune")
            prunes += 1
            prunedOnMain = onMain
        }
    }

    func clearAll() {
        lock.withLock {
            recordedCalls.append("clearAll")
            histories = [:]
        }
    }

    func noteVersionDeleted(passage: UUID, at index: Int, in history: DocumentHistory, for url: URL) {
        let count = history.passages.first { $0.id == passage }?.versions.count ?? 0
        lock.withLock {
            recordedCalls.append("noteVersionDeleted")
            recordedDeletions.append(Deletion(passage: passage, index: index, versionCount: count))
        }
    }
}

/// Every file is local and current: no iCloud is touched.
private struct StaticUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
