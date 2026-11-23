import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// AI and History together on iPhone (step 8's wiring of step 9): `PhoneHistoryController` is the
/// AI controller's `AIHistoryRecording`, with the Mac's semantics. History records ONCE, when a
/// review ends (one passage per changed paragraph); abandoning records nothing; AI is unavailable
/// in History mode; entering History ends a review; and the selection row's Replace With… is
/// History's (the Mac's meaning), the one entry point. Every client is `FakeAIClient`, the Keychain
/// `InMemoryAIKeychain`, and the History store in memory.
@MainActor
final class PhoneAIHistoryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let twoParagraphs = "First paragraph here.\n\nSecond paragraph here.\n"
    private var folder: URL!
    private var window: UIWindow?
    private var suites: [String] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-ai-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The wiring

    func testScreenAssignsDocumentHistoryToAI() async throws {
        let history = makeHistory()
        let (_, selection, ai, document) = try await hostScreen(text: twoParagraphs, history: history,
                                                                 client: FakeAIClient(.suspend))
        XCTAssertTrue(document.history === history)
        XCTAssertTrue((selection.aiHistory as AnyObject?) === history, "the screen's one assignment")
        XCTAssertTrue((ai.history as AnyObject?) === history, "the AI controller records into the document's History")
    }

    // MARK: - Recording

    func testAcceptingRecordsHistoryOnceWhenReviewEnds() async throws {
        let rig = try makeRig(twoParagraphs, client: FakeAIClient(FakeAIClient.revising { _, segment in
            segment.replacingOccurrences(of: "here", with: "there")
        }))
        try await review(rig, .proofread, range: NSRange(location: 0, length: (twoParagraphs as NSString).length))
        guard case .reviewing(let session) = rig.ai.state else { return XCTFail("no review") }
        XCTAssertEqual(session.pending.count, 2)

        // The first accept is a decision, not the end: History has nothing yet.
        rig.ai.handle(.acceptCurrent)
        guard case .reviewing = rig.ai.state else { return XCTFail("the review ended after one of two") }
        XCTAssertFalse(rig.history.hasHistory, "nothing is recorded until the review ends")

        // The last decision ends the review: ONE recording, one passage per changed paragraph.
        rig.ai.handle(.acceptCurrent)
        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertEqual(rig.editor.text, "First paragraph there.\n\nSecond paragraph there.\n")
        XCTAssertTrue(rig.history.hasHistory)

        XCTAssertTrue(rig.history.enterHistoryMode(text: rig.editor.text))
        let passages = rig.history.located.compactMap { rig.history.passage($0.id) }
        XCTAssertEqual(passages.count, 2, "one passage per changed paragraph")
        XCTAssertEqual(Set(passages.map { $0.versions.map(\.text) }), [
            ["First paragraph here.", "First paragraph there."],
            ["Second paragraph here.", "Second paragraph there."],
        ], "the original and the accepted text, each recorded once")
        XCTAssertEqual(passages.map { $0.versions.map(\.author) }, [[.you, .ai], [.you, .ai]])
        XCTAssertEqual(passages.map(\.currentIndex), [1, 1])
    }

    func testAbandoningRecordsNothing() async throws {
        let rig = try makeRig(twoParagraphs, client: FakeAIClient(FakeAIClient.revising { _, segment in
            segment.replacingOccurrences(of: "here", with: "there")
        }))
        try await review(rig, .proofread, range: NSRange(location: 0, length: (twoParagraphs as NSString).length))
        rig.ai.handle(.acceptCurrent)
        guard case .reviewing = rig.ai.state else { return XCTFail("no review") }

        // An outside replacement (live reload, another document) abandons: nothing applied or recorded.
        rig.selection.editorTextWillBeReplaced()
        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertEqual(rig.editor.text, twoParagraphs)
        XCTAssertFalse(rig.history.hasHistory, "abandoning records nothing")
        XCTAssertFalse(rig.history.enterHistoryMode(text: rig.editor.text), "there is nothing to show")

        // The controller's own abandon, too.
        try await review(rig, .proofread, range: NSRange(location: 0, length: (twoParagraphs as NSString).length))
        rig.ai.handle(.acceptCurrent)
        rig.ai.abandon()
        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertEqual(rig.editor.text, twoParagraphs)
        XCTAssertFalse(rig.history.hasHistory)
    }

    // MARK: - History mode and AI never overlap

    func testAskAIUnavailableInHistoryMode() async throws {
        let client = FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() })
        let rig = try makeRig(twoParagraphs, client: client)
        try keepReplacement(in: rig, of: "First paragraph here.", with: "First paragraph, here.")
        XCTAssertTrue(rig.history.enterHistoryMode(text: rig.editor.text))
        let range = NSRange(location: 0, length: 5)
        rig.editor.selectedRange = range
        let readsBefore = rig.keychain.readCount

        XCTAssertFalse(rig.history.allowsAIAction(on: range))
        XCTAssertFalse(rig.ai.isAvailable(for: range, text: rig.editor.text), "the controller asks History")
        rig.selection.showRowNow()
        XCTAssertEqual(rig.selection.phase, .hidden, "no row, so no Ask AI or Another Word")
        XCTAssertFalse(rig.selection.allowsWholeDocumentAI, "the Menu's Ask AI… is off too")

        // Even a direct run is refused: nothing is sent, and History mode stays.
        rig.ai.run(.rephrase, range: range, text: rig.editor.text)
        rig.ai.runWholeDocument(.rephrase, text: rig.editor.text, note: nil)
        XCTAssertEqual(rig.ai.state, .idle)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(client.prompts.isEmpty, "nothing reached the AI")
        XCTAssertEqual(rig.keychain.readCount, readsBefore, "the Keychain was not read")
        XCTAssertTrue(rig.history.isHistoryModeActive)
    }

    func testEnteringHistoryEndsAReview() async throws {
        let rig = try makeRig(twoParagraphs, client: FakeAIClient(FakeAIClient.revising { _, segment in
            segment.replacingOccurrences(of: " here.", with: " now.")
        }))
        try keepReplacement(in: rig, of: "Second paragraph here.", with: "Second paragraph, here.")
        // A review of two changes, one accepted.
        try await review(rig, .proofread, range: NSRange(location: 0, length: (rig.editor.text as NSString).length))
        guard case .reviewing(let session) = rig.ai.state else { return XCTFail("no review") }
        XCTAssertEqual(session.pending.count, 2)
        rig.ai.handle(.acceptCurrent)

        // Menu ▸ History: the review ends FIRST (keeping what was accepted, recorded), then History opens.
        var steps: [String] = []
        let entered = HistoryEntry.enterFromMenu(
            history: rig.history,
            text: { rig.editor.text },
            dismissMenu: { steps.append("dismiss") },
            endAI: {
                steps.append("endAI")
                rig.selection.endAIForHistory()
            },
            switchToWrite: { steps.append("write") }
        )
        XCTAssertEqual(steps, ["dismiss", "endAI", "write"])
        XCTAssertEqual(rig.ai.state, .idle, "History mode and AI never overlap")
        XCTAssertFalse(rig.editor.isAIReviewActive)
        XCTAssertTrue(entered)
        XCTAssertTrue(rig.history.isHistoryModeActive)
        XCTAssertEqual(rig.editor.text, "First paragraph now.\n\nSecond paragraph, here.\n",
                       "what was accepted stays; the undecided change is rejected")
        let texts = rig.history.located.compactMap { rig.history.passage($0.id)?.versions.last?.text }
        XCTAssertTrue(texts.contains("First paragraph now."), "and is in History")

        // Find's marks are dropped too (the Menu shows beside them).
        _ = rig.history.exitHistoryMode(text: rig.editor.text)
        let marker = try makeRig(twoParagraphs, client: FakeAIClient(.reply(#"{"sentences":[1]}"#)))
        marker.editor.selectedRange = NSRange(location: 0, length: 21)
        marker.ai.run(.markWeakest, range: NSRange(location: 0, length: 21), text: marker.editor.text)
        try await spin { if case .marking = marker.ai.state { return true }; return false }
        marker.selection.endAIForHistory()
        XCTAssertEqual(marker.ai.state, .idle)
    }

    // MARK: - Replace With… on the row

    func testRowReplaceWithOpensHistoryOnTheSelection() async throws {
        let rig = try makeRig(twoParagraphs, client: FakeAIClient(.suspend))
        let sentence = (twoParagraphs as NSString).range(of: "Second paragraph here.")
        rig.editor.selectedRange = sentence
        rig.selection.showRowNow()
        XCTAssertEqual(rig.selection.phase, .row)
        XCTAssertTrue(rig.selection.items.contains(.replaceWith))

        rig.selection.perform(.replaceWith)
        XCTAssertEqual(rig.selection.phase, .hidden, "History's card takes the bottom")
        XCTAssertTrue(rig.history.isHistoryModeActive)
        let id = try XCTUnwrap(rig.history.selectedPassageID, "History opens on the new passage")
        XCTAssertEqual(rig.history.pendingReplacementFieldID, id)
        let model = HistoryCardModel(controller: rig.history)
        XCTAssertTrue(model.opensReplacementField, "the card opens Type a replacement")
        XCTAssertEqual(model.rows.map(\.text), ["Second paragraph here."], "the selection is the original")
        XCTAssertEqual(rig.editor.text, twoParagraphs, "nothing changes until a replacement is typed")

        // Offered only where History can keep the selection (the Mac rule): never across lines.
        _ = rig.history.exitHistoryMode(text: rig.editor.text)
        rig.editor.becomeFirstResponder()
        rig.editor.selectedRange = NSRange(location: 0, length: (twoParagraphs as NSString).length - 1)
        rig.selection.showRowNow()
        XCTAssertEqual(rig.selection.phase, .row)
        XCTAssertFalse(rig.selection.items.contains(.replaceWith))

        // The one entry point: the edit menu no longer carries it.
        let menu = MarkdownEditor.Coordinator.leadingMenuElements(for: rig.editor, range: sentence)
        XCTAssertFalse(menu.contains { ($0 as? UIAction)?.title == SelectionRowItem.replaceWith.title })
    }

    func testRowReplaceWithDropsFindMarks() async throws {
        let rig = try makeRig(twoParagraphs, client: FakeAIClient(.reply(#"{"sentences":[1]}"#)))
        let sentence = (twoParagraphs as NSString).range(of: "First paragraph here.")
        rig.editor.selectedRange = sentence
        rig.ai.run(.markWeakest, range: sentence, text: rig.editor.text)
        try await spin { if case .marking = rig.ai.state { return true }; return false }
        rig.editor.selectedRange = sentence
        rig.selection.showRowNow()
        rig.selection.perform(.replaceWith)
        XCTAssertEqual(rig.ai.state, .idle, "History opening dismisses Find's wash (`yieldToHistory`)")
        XCTAssertTrue(rig.history.isHistoryModeActive)
    }

    // MARK: - Helpers

    private struct Rig {
        let editor: LineformTextView
        let selection: SelectionController
        let ai: AIActionController
        let history: PhoneHistoryController
        let keychain: InMemoryAIKeychain
    }

    private func makeHistory() -> PhoneHistoryController {
        let date = fixedDate
        let history = PhoneHistoryController(
            store: MemoryHistoryStore(), now: { date },
            pruneQueue: DispatchQueue(label: "PhoneAIHistoryTests"), notificationCenter: NotificationCenter()
        )
        return history
    }

    private func makeStore(keychain: InMemoryAIKeychain) throws -> AIConnectionStore {
        let suite = "PhoneAIHistoryTests-\(UUID().uuidString)"
        suites.append(suite)
        let store = AIConnectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychain: keychain)
        XCTAssertNil(store.connect(.claude, key: "sk-test"))
        return store
    }

    /// An editor in a window with its History attached, a selection controller, and the AI
    /// controller wired to that History (as `DocumentScreen` wires it).
    private func makeRig(_ text: String, client: FakeAIClient) throws -> Rig {
        let keychain = InMemoryAIKeychain()
        let store = try makeStore(keychain: keychain)
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        let selection = SelectionController(connectionStore: { store }, aiController: ai)
        let history = makeHistory()
        history.open(url: nil, text: text)
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        host.view.addSubview(editor)
        window.makeKeyAndVisible()
        self.window = window
        editor.becomeFirstResponder()
        history.attach(editor)
        selection.attach(editor)
        selection.aiHistory = history
        editor.undoManager?.removeAllActions()
        return Rig(editor: editor, selection: selection, ai: ai, history: history, keychain: keychain)
    }

    private func review(_ rig: Rig, _ action: AIAction, range: NSRange) async throws {
        rig.editor.selectedRange = range
        rig.ai.run(action, range: range, text: rig.editor.string)
        try await spin { if case .reviewing = rig.ai.state { return true }; return false }
    }

    /// A two-version passage on `needle` (Replace With… and a replacement), then out of History mode.
    private func keepReplacement(in rig: Rig, of needle: String, with replacement: String) throws {
        let found = (rig.editor.text as NSString).range(of: needle)
        XCTAssertTrue(rig.editor.performReplaceWith(found))
        let id = try XCTUnwrap(rig.history.selectedPassageID)
        XCTAssertNotNil(rig.history.addReplacement(replacement, text: rig.editor.text, for: id))
        _ = rig.history.exitHistoryMode(text: rig.editor.text)
        rig.editor.becomeFirstResponder()
    }

    private func hostScreen(text: String, history: PhoneHistoryController, client: FakeAIClient) async throws
        -> (LineformTextView, SelectionController, AIActionController, OpenDocument) {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: PhoneAIHistoryUbiquitousItems(),
                                    history: history)
        await document.prepare()
        document.edit(text)
        let suite = "PhoneAIHistoryTests-profile-\(UUID().uuidString)"
        suites.append(suite)
        let profiles = ReadingProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let settingsSuite = "PhoneAIHistoryTests-settings-\(UUID().uuidString)"
        suites.append(settingsSuite)
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: settingsSuite)))
        let store = try makeStore(keychain: InMemoryAIKeychain())
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        let selection = SelectionController(connectionStore: { store }, aiController: ai)
        let screen = DocumentScreen(document: document, profileStore: profiles, settings: settings, selection: selection)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        self.window = window
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
        let editor = try XCTUnwrap(AIReviewTests.find(LineformTextView.self, in: window))
        return (editor, selection, ai, document)
    }

    private func spin(timeout: TimeInterval = 3, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
            window?.layoutIfNeeded()
        }
    }
}

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct PhoneAIHistoryUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
