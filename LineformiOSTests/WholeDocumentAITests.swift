import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// Ask AI for the whole document on iPhone (2026-11-22): the Menu's Document section has an
/// "Ask AI…" row while an AI is connected and Write or Preview is on screen. It opens the AI sheet
/// (2026-11-24; it was the comment field) for the whole document after the shared `WholeDocumentAIPolicy`: up to 1,500 words at
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
        try skipUnlessEnglishInterface()
        // The row: connected, and an editor on screen (Write or Preview; Read has none).
        XCTAssertTrue(DocumentSection.showsAskAI(isConnected: true, mode: .write, hasText: true))
        XCTAssertTrue(DocumentSection.showsAskAI(isConnected: true, mode: .split, hasText: true))
        XCTAssertFalse(DocumentSection.showsAskAI(isConnected: false, mode: .write, hasText: true))
        XCTAssertFalse(DocumentSection.showsAskAI(isConnected: true, mode: .read, hasText: true))
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
        XCTAssertFalse(offline.isShowingAISheet)
        let (_, reading, _, _) = try makeEditor("A short document.\n", connected: true)
        reading.displayModeDidChange(to: .read)
        reading.askAIForWholeDocument()
        XCTAssertFalse(reading.isShowingAISheet)

        // Connected in Write: the AI sheet opens, with nothing selected (its requests go to the
        // whole document).
        let (editor, selection, _, keychain) = try makeEditor("A short document.\n", connected: true)
        editor.selectedRange = NSRange(location: 2, length: 5)
        selection.askAIForWholeDocument()
        XCTAssertTrue(selection.isShowingAISheet)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(keychain.readCount, 0, "opening the sheet reads no key")
    }

    func testConfirmAbove1500Words() throws {
        try skipUnlessEnglishInterface()
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
        XCTAssertFalse(selection.isShowingAISheet, "nothing opens before the writer answers")
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertTrue(client.prompts.isEmpty)

        // Cancel: nothing opens, nothing is sent.
        selection.cancelWholeDocumentConfirmation()
        XCTAssertNil(selection.pendingWholeDocumentWords)
        XCTAssertFalse(selection.isShowingAISheet)

        // Send: the AI sheet opens; still nothing sent, and the count is not asked about again.
        selection.askAIForWholeDocument()
        selection.confirmWholeDocument()
        XCTAssertNil(selection.pendingWholeDocumentWords)
        XCTAssertTrue(selection.isShowingAISheet)
        XCTAssertEqual(selection.conversation.confirmedWholeDocumentWords, 1_600)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertTrue(client.prompts.isEmpty)

        // Up to 1,500 words, no question.
        let (_, short, _, _) = try makeEditor(String(repeating: "word ", count: 1_500) + "\n", connected: true)
        var shortShown: [UIAlertController] = []
        short.presentAlert = { shortShown.append($0) }
        short.askAIForWholeDocument()
        XCTAssertTrue(shortShown.isEmpty)
        XCTAssertTrue(short.isShowingAISheet)

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
        XCTAssertTrue(selection.isShowingAISheet, "the sheet opens on the refusal")
        XCTAssertEqual(ai.state, .message(WholeDocumentAIPolicy.refusalMessage))
        XCTAssertTrue(selection.conversation.messages.contains { $0.content == .notice(WholeDocumentAIPolicy.refusalMessage) },
                      "shown in the conversation")

        // Even a request that got past the sheet is refused by the controller, before any read.
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
        XCTAssertTrue(selection.isShowingAISheet)
        selection.conversation.runQuickAction(.rephrase)
        try await spin { if case .reviewing = ai.state { return true }; return false }
        XCTAssertNotNil(selection.conversation.pendingSuggestion, "the suggestion is in the sheet")

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

    // MARK: - Fixes after the step 8 review

    /// A request from the sheet checks the policy again. A document that grew past the count the
    /// writer confirmed is asked about again; one that grew past the limit is refused.
    func testPastingPast1500AfterConfirmingReasks() async throws {
        let client = FakeAIClient(.suspend)
        let text = String(repeating: "word ", count: 1_600) + "\n"
        let (editor, selection, ai, keychain) = try makeEditor(text, connected: true, client: client)
        var shown: [UIAlertController] = []
        selection.presentAlert = { shown.append($0) }
        selection.askAIForWholeDocument()
        XCTAssertEqual(shown.count, 1)
        selection.confirmWholeDocument()
        XCTAssertTrue(selection.isShowingAISheet)

        // 200 more words arrive.
        editor.textStorage.replaceCharacters(in: NSRange(location: editor.textStorage.length, length: 0),
                                             with: String(repeating: "more ", count: 200))
        selection.conversation.runQuickAction(.rephrase)
        let again = try XCTUnwrap(shown.last)
        XCTAssertEqual(shown.count, 2, "1,800 words were never confirmed: asked again")
        XCTAssertEqual(again.title, WholeDocumentAIPolicy.confirmationTitle(words: 1_800, recipient: "Claude"))
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertTrue(client.prompts.isEmpty)
        XCTAssertEqual(ai.state, .idle)

        // Fewer words than confirmed: no question.
        let (smaller, smallerSelection, smallerAI, _) = try makeEditor(text, connected: true, client: FakeAIClient(.suspend))
        var smallerShown: [UIAlertController] = []
        smallerSelection.presentAlert = { smallerShown.append($0) }
        smallerSelection.askAIForWholeDocument()
        smallerSelection.confirmWholeDocument()
        smaller.textStorage.replaceCharacters(in: NSRange(location: 0, length: 50), with: "")
        smallerSelection.conversation.runQuickAction(.rephrase)
        XCTAssertEqual(smallerShown.count, 1)
        XCTAssertEqual(smallerAI.state, .running(.rephrase, .claude))
        smallerAI.cancel()

        // Past the limit: refused, nothing sent, the Keychain not read.
        let (grown, grownSelection, grownAI, grownKeychain) = try makeEditor(text, connected: true, client: client)
        grownSelection.presentAlert = { _ in }
        grownSelection.askAIForWholeDocument()
        grownSelection.confirmWholeDocument()
        grown.textStorage.replaceCharacters(in: NSRange(location: grown.textStorage.length, length: 0),
                                            with: String(repeating: "more ", count: 4_000))
        grownSelection.conversation.runQuickAction(.rephrase)
        XCTAssertEqual(grownAI.state, .message(WholeDocumentAIPolicy.refusalMessage))
        XCTAssertEqual(grownKeychain.readCount, 0)
        XCTAssertTrue(client.prompts.isEmpty)
    }

    /// The confirmation going away by ANY path (here, its presenter dismissing it, as when the
    /// screen changes under it) clears the pending count, so Ask AI… works again.
    func testConfirmationGoneByAnyPathClearsPending() async throws {
        let text = String(repeating: "word ", count: 1_600) + "\n"
        let (_, selection, _, _) = try makeEditor(text, connected: true)
        let host = try XCTUnwrap(window?.rootViewController)
        selection.askAIForWholeDocument()
        try await spin { host.presentedViewController is UIAlertController }
        XCTAssertEqual(selection.pendingWholeDocumentWords, 1_600)

        host.dismiss(animated: false)
        try await spin { host.presentedViewController == nil }
        try await spin { selection.pendingWholeDocumentWords == nil }

        // Ask AI… asks again.
        selection.askAIForWholeDocument()
        try await spin { host.presentedViewController is UIAlertController }
        XCTAssertEqual(selection.pendingWholeDocumentWords, 1_600)
        host.dismiss(animated: false)
        try await spin { selection.pendingWholeDocumentWords == nil }
    }

    /// No Ask AI… for an empty document: there is nothing to send.
    func testAskAIRowHiddenForEmptyDocument() throws {
        XCTAssertFalse(DocumentSection.showsAskAI(isConnected: true, mode: .write, hasText: false))
        XCTAssertTrue(DocumentSection.showsAskAI(isConnected: true, mode: .write, hasText: true))
        XCTAssertFalse(DocumentSection.hasText(""))
        XCTAssertFalse(DocumentSection.hasText(" \n\n\t"))
        XCTAssertTrue(DocumentSection.hasText("\nA"))
        let (_, selection, _, _) = try makeEditor("  \n\n", connected: true)
        XCTAssertFalse(selection.allowsWholeDocumentAI)
        selection.askAIForWholeDocument()
        XCTAssertEqual(selection.phase, .hidden)
    }

    // (The whole-document comment field's subtitle test went with the comment field: the Menu's
    // Ask AI… opens the AI sheet, 2026-11-24.)

    private static func hasLabel(_ label: String, in root: NSObject, depth: Int = 0) -> Bool {
        guard depth < 60 else { return false }
        if root.accessibilityLabel == label { return true }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        children += (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count { if let child = root.accessibilityElement(at: index) as? NSObject { children.append(child) } }
        }
        return children.contains { hasLabel(label, in: $0, depth: depth + 1) }
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
