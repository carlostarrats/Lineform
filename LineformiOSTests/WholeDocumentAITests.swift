import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// Ask AI for the whole document on iPhone (2026-11-22): the Menu's Document section has an
/// "Ask AI…" row while an AI is connected and Write or Preview is on screen. It opens the comment
/// field for the whole document after the shared `WholeDocumentAIPolicy`: up to 1,500 words at
/// once, above that after "Send the whole document (N words) to …?" (Send / Cancel, Cancel the
/// default), and past `AILimits` it is refused with the policy's message — nothing sent, the
/// Keychain not read. The review then runs over the whole document through the Task 5 overlay and
/// cards. Every client is `FakeAIClient`; the Keychain is `InMemoryAIKeychain`.
@MainActor
final class WholeDocumentAITests: XCTestCase {
    private var window: UIWindow?
    private var suites: [String] = []

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }

    func testAskAIRowOnlyWhenConnected() throws {
        // The row: connected, and an editor on screen (Write or Preview; Read has none).
        XCTAssertTrue(DocumentSection.showsAskAI(isConnected: true, mode: .write))
        XCTAssertTrue(DocumentSection.showsAskAI(isConnected: true, mode: .split))
        XCTAssertFalse(DocumentSection.showsAskAI(isConnected: false, mode: .write))
        XCTAssertFalse(DocumentSection.showsAskAI(isConnected: true, mode: .read))
        XCTAssertEqual(DocumentSection.askAITitle, "Ask AI…")

        // It sits with the document's commands, after Check Document Now.
        let titles = DocumentSection.rowTitles(for: .markdown, showsAskAI: true)
        let check = try XCTUnwrap(titles.firstIndex(of: DocumentSection.checkDocumentTitle))
        XCTAssertEqual(titles[check + 1], DocumentSection.askAITitle)
        XCTAssertFalse(DocumentSection.rowTitles(for: .markdown).contains(DocumentSection.askAITitle))
        XCTAssertEqual(DocumentSection.rowTitles(for: .markdown, showsAskAI: false), DocumentSection.rowTitles(for: .markdown))

        // Disconnected (or in Read), the controller opens nothing either.
        let (_, offline, _, _) = try makeEditor("A short document.\n", connected: false)
        offline.askAIForWholeDocument()
        XCTAssertEqual(offline.phase, .hidden)
        let (_, reading, _, _) = try makeEditor("A short document.\n", connected: true)
        reading.displayModeDidChange(to: .read)
        reading.askAIForWholeDocument()
        XCTAssertEqual(reading.phase, .hidden)

        // Connected in Write: the comment field opens for the whole document.
        let (editor, selection, _, keychain) = try makeEditor("A short document.\n", connected: true)
        editor.selectedRange = NSRange(location: 2, length: 0)
        selection.askAIForWholeDocument()
        XCTAssertEqual(selection.phase, .comment)
        XCTAssertTrue(selection.isWholeDocument)
        XCTAssertEqual(selection.anchorRange, NSRange(location: 0, length: editor.textStorage.length))
        XCTAssertEqual(selection.model.action, .custom)
        XCTAssertEqual(keychain.readCount, 0, "opening the field reads no key")

        // Cancel puts the caret back where it was.
        selection.cancelComment()
        XCTAssertEqual(selection.phase, .hidden)
        XCTAssertFalse(selection.isWholeDocument)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0))
    }

    func testConfirmAbove1500Words() throws {
        let client = FakeAIClient(.suspend)
        let text = String(repeating: "word ", count: 1_600) + "\n"
        let (_, selection, _, keychain) = try makeEditor(text, connected: true, client: client)
        var shown: [UIAlertController] = []
        selection.presentAlert = { shown.append($0) }

        selection.askAIForWholeDocument()
        let alert = try XCTUnwrap(shown.first, "above 1,500 words the writer is asked first")
        XCTAssertEqual(alert.title, WholeDocumentAIPolicy.confirmationTitle(words: 1_600, recipient: "Claude"))
        XCTAssertEqual(alert.title, "Send the whole document (1,600 words) to Claude?")
        XCTAssertEqual(alert.actions.map(\.title), [WholeDocumentAIPolicy.sendTitle, WholeDocumentAIPolicy.cancelTitle])
        XCTAssertEqual(alert.actions.last?.style, .cancel)
        XCTAssertTrue(alert.preferredAction === alert.actions.last, "Cancel is the default")
        XCTAssertEqual(selection.pendingWholeDocumentWords, 1_600)
        XCTAssertEqual(selection.phase, .hidden, "nothing opens before the writer answers")
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertTrue(client.prompts.isEmpty)

        // Cancel: nothing opens, nothing is sent.
        selection.cancelWholeDocumentConfirmation()
        XCTAssertNil(selection.pendingWholeDocumentWords)
        XCTAssertEqual(selection.phase, .hidden)

        // Send: the comment field opens for the whole document; still nothing sent.
        selection.askAIForWholeDocument()
        selection.confirmWholeDocument()
        XCTAssertNil(selection.pendingWholeDocumentWords)
        XCTAssertEqual(selection.phase, .comment)
        XCTAssertTrue(selection.isWholeDocument)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertTrue(client.prompts.isEmpty)

        // Up to 1,500 words, no question.
        let (_, short, _, _) = try makeEditor(String(repeating: "word ", count: 1_500) + "\n", connected: true)
        var shortShown: [UIAlertController] = []
        short.presentAlert = { shortShown.append($0) }
        short.askAIForWholeDocument()
        XCTAssertTrue(shortShown.isEmpty)
        XCTAssertEqual(short.phase, .comment)

        // Other names its address's host.
        XCTAssertEqual(WholeDocumentAIPolicy.recipient(for: .other, otherEndpoint: URL(string: "http://127.0.0.1:8080/v1")),
                       "127.0.0.1")
    }

    func testRefuseAboveLimitSendsNothing() async throws {
        let client = FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() })
        let text = String(repeating: "wordy ", count: 5_000) + "\n"
        let (editor, selection, ai, keychain) = try makeEditor(text, connected: true, client: client)
        var shown: [UIAlertController] = []
        selection.presentAlert = { shown.append($0) }

        selection.askAIForWholeDocument()
        XCTAssertTrue(shown.isEmpty, "no confirmation for a document that cannot be sent")
        XCTAssertEqual(selection.phase, .hidden, "no comment field")
        XCTAssertEqual(ai.state, .message(WholeDocumentAIPolicy.refusalMessage))
        XCTAssertEqual(selection.aiState, .message(WholeDocumentAIPolicy.refusalMessage), "shown on the AI's message card")

        // Even a Send that got past the field is refused by the controller, before any read.
        ai.dismissMessage()
        ai.runWholeDocument(.rephrase, text: editor.string, note: nil)
        XCTAssertEqual(ai.state, .message(WholeDocumentAIPolicy.refusalMessage))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(keychain.readCount, 0, "the Keychain is not read")
        XCTAssertTrue(client.prompts.isEmpty, "nothing is sent")
        XCTAssertEqual(editor.textStorage.string, text)
    }

    func testWholeDocumentReviewThenAccept() async throws {
        let text = "First paragraph here.\n\nSecond paragraph here.\n\n```\ncode here\n```\n"
        let client = FakeAIClient(FakeAIClient.revising { _, segment in
            segment.replacingOccurrences(of: "here", with: "there")
        })
        let (editor, selection, ai, keychain) = try makeEditor(text, connected: true, client: client)
        editor.selectedRange = NSRange(location: 5, length: 0)

        selection.askAIForWholeDocument()
        XCTAssertEqual(selection.phase, .comment)
        selection.model.action = .rephrase
        XCTAssertTrue(selection.canSendNow)
        XCTAssertTrue(selection.send())
        XCTAssertEqual(selection.phase, .hidden)
        try await spin { if case .reviewing = ai.state { return true }; return false }

        // The whole document's prose was sent, never its code.
        let prompt = try XCTUnwrap(client.prompts.first)
        XCTAssertEqual(FakeAIClient.segments(in: prompt), ["First paragraph here.", "Second paragraph here."])
        XCTAssertEqual(keychain.readCount, 1, "the one read, inside run")

        // The review is the Task 5 overlay: nothing in the buffer yet, the editor locked.
        guard case .reviewing(let session) = ai.state else { return XCTFail("no review") }
        XCTAssertEqual(session.pending.count, 1)
        XCTAssertEqual(editor.textStorage.string, text)
        XCTAssertTrue(editor.isAIReviewActive)
        let overlay = AIReviewOverlayTextView.make()
        overlay.present(selection.compositionCache.composition(text: editor.string, session: session),
                        currentID: session.currentID, profile: .original)
        XCTAssertTrue(overlay.textStorage.string.contains("First paragraph there."))
        XCTAssertTrue(overlay.textStorage.string.contains("Second paragraph there."))

        // Accept: one undo step, structure kept, the caret at the change's end.
        ai.handle(.acceptCurrent)
        XCTAssertEqual(ai.state, .idle)
        let accepted = "First paragraph there.\n\nSecond paragraph there.\n\n```\ncode here\n```\n"
        XCTAssertEqual(editor.textStorage.string, accepted)
        XCTAssertFalse(editor.isAIReviewActive)
        XCTAssertEqual(editor.selectedRange.length, 0)
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertEqual(undo.undoActionName, AIActionController.acceptOneActionName)
        undo.undo()
        XCTAssertEqual(editor.textStorage.string, text, "one undo takes back the whole decision")
    }

    // MARK: - Rig

    private func makeStore(connected: Bool, keychain: InMemoryAIKeychain) throws -> AIConnectionStore {
        let suite = "WholeDocumentAITests-\(UUID().uuidString)"
        suites.append(suite)
        let store = AIConnectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychain: keychain)
        if connected { XCTAssertNil(store.connect(.claude, key: "sk-test")) }
        return store
    }

    /// An editor in a window, first responder, with a selection controller (and its AI controller)
    /// attached.
    private func makeEditor(_ text: String, connected: Bool, client: FakeAIClient = FakeAIClient(.suspend)) throws
        -> (LineformTextView, SelectionController, AIActionController, InMemoryAIKeychain) {
        let keychain = InMemoryAIKeychain()
        let store = try makeStore(connected: connected, keychain: keychain)
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        let selection = SelectionController(connectionStore: { store }, aiController: ai)
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 400)
        host.view.addSubview(editor)
        window.makeKeyAndVisible()
        self.window = window
        editor.becomeFirstResponder()
        selection.attach(editor)
        return (editor, selection, ai, keychain)
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
