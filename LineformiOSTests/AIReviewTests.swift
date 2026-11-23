import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// AI actions and their review on iPhone (spec §4, §5.5): the editor's `AIEditorSurface`
/// conformance, the read-only review overlay composed by `AIReviewComposition`, the cards above the
/// keyboard, and Mark's wash. Suggestions never enter the editor's text storage until accepted; one
/// decision is one undo step; the document is locked while a review is up; leaving a review by any
/// path collapses the selection to `caretEnd`; abandoning records nothing; and nothing reaches the
/// network unless connected. Every client here is `FakeAIClient` or a real client over
/// `StubURLProtocol`; the Keychain is `InMemoryAIKeychain`.
@MainActor
final class AIReviewTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var suites: [String] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aireview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.requestedRequests = []
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data()
        StubURLProtocol.redirectTo = nil
        StubURLProtocol.declaredLength = nil
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The buffer

    func testSuggestionNotInBufferUntilAccepted() async throws {
        let text = "Hello world. This is fine.\n"
        let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() }))
        let range = NSRange(location: 0, length: 26)
        try await review(rig, .rephrase, range: range)

        // The suggestion is only in the overlay's composition, never in the editor or the document.
        XCTAssertEqual(rig.editor.text, text)
        XCTAssertEqual(rig.editor.textStorage.string, text)
        guard case .reviewing(let session) = rig.ai.state else { return XCTFail("no review") }
        let overlay = AIReviewOverlayTextView.make()
        overlay.present(AIReviewCompositionCache().composition(text: rig.editor.string, session: session),
                        currentID: session.currentID, profile: .original)
        XCTAssertTrue(overlay.textStorage.string.contains("HELLO WORLD. THIS IS FINE."))
        XCTAssertFalse(overlay.isEditable)
        XCTAssertNil(overlay.undoManager?.canUndo == true ? "undo" : nil, "the overlay's undo manager is empty")
        XCTAssertFalse(rig.editor.undoManager?.canUndo ?? false, "nothing was registered on the document")

        rig.ai.handle(.acceptCurrent)
        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertEqual(rig.editor.text, "HELLO WORLD. THIS IS FINE.\n")
    }

    func testAcceptIsOneUndo() async throws {
        let text = "First paragraph here.\n\nSecond paragraph here.\n"
        let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, segment in
            segment.replacingOccurrences(of: "here", with: "there")
        }))
        let listener = TextChangeListener()
        rig.editor.delegate = listener
        try await review(rig, .rephrase, range: NSRange(location: 0, length: (text as NSString).length))
        rig.ai.handle(.acceptCurrent)
        XCTAssertEqual(rig.editor.text, "First paragraph there.\n\nSecond paragraph there.\n")
        XCTAssertEqual(listener.changes.last, rig.editor.text, "the binding (and so autosave) hears the accept")

        let undo = try XCTUnwrap(rig.editor.undoManager)
        XCTAssertEqual(undo.undoActionName, AIActionController.acceptOneActionName)
        undo.undo()
        XCTAssertEqual(rig.editor.text, text, "one ⌘Z takes back the whole decision")
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(rig.editor.text, "First paragraph there.\n\nSecond paragraph there.\n")
    }

    func testStructureChangingSuggestionRefused() async throws {
        // A reply that would add a heading marker never opens a review.
        let text = "Hello world.\n\nMore text.\n"
        let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, _ in "# Hello world." }))
        rig.editor.selectedRange = NSRange(location: 0, length: 12)
        rig.ai.run(.rephrase, range: NSRange(location: 0, length: 12), text: rig.editor.string)
        try await spin { if case .message = rig.ai.state { return true }; return false }
        XCTAssertEqual(rig.editor.text, text)

        // A review whose passage changed underneath (outside the review's locks) is re-verified on
        // accept against the CURRENT text, and refused.
        let second = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() }))
        try await review(second, .rephrase, range: NSRange(location: 0, length: 12))
        second.editor.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
        let changed = second.editor.textStorage.string
        second.ai.handle(.acceptCurrent)
        XCTAssertEqual(second.editor.textStorage.string, changed, "nothing is spliced at offsets that moved")
        guard case .message(let message) = second.ai.state else { return XCTFail("no refusal shown") }
        XCTAssertTrue([AIActionController.textChangedMessage, AIActionController.structureRefusedMessage].contains(message))
    }

    func testTypingRefusedDuringReview() async throws {
        let text = "Hello world.\n\n- [ ] task\n"
        let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() }))
        try await review(rig, .rephrase, range: NSRange(location: 0, length: 12))
        XCTAssertTrue(rig.editor.isAIReviewActive)

        // Typing, Delete, Return, paste and every rule edit are refused, with the controller's message.
        rig.editor.selectedRange = NSRange(location: 20, length: 0)
        rig.editor.insertText("x")
        rig.editor.deleteBackward()
        XCTAssertTrue(rig.editor.refusesEditForAI(), "Return and every other key edit is refused")
        let coordinator = MarkdownEditor(text: .constant(text), profile: .original).makeCoordinator()
        XCTAssertFalse(coordinator.textView(rig.editor, shouldChangeTextIn: NSRange(location: 20, length: 0), replacementText: "\n"))
        XCTAssertFalse(coordinator.textView(rig.editor, shouldChangeTextIn: NSRange(location: 20, length: 0), replacementText: "y"))
        let pasteboard = UIPasteboard.withUniqueName()
        pasteboard.string = "pasted"
        rig.editor.pasteboardForTesting = pasteboard
        rig.editor.paste(nil)
        XCTAssertFalse(rig.editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        XCTAssertFalse(rig.editor.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
        rig.editor.selectedRange = NSRange(location: 0, length: 5)
        rig.editor.apply(.bold)
        rig.editor.setHeadingLevel(2)
        XCTAssertFalse(rig.editor.applyRuleEdit(replacing: NSRange(location: 0, length: 0), with: "z"))
        // Read's checkbox (and Reconnect) edits, and Search's Replace / Replace All.
        XCTAssertFalse(rig.editor.applyReadEdit("Hello world.\n\n- [x] task\n"))
        let commands = LiveEditorCommands(positionKeeper: rig.keeper, document: rig.document, mode: .write)
        XCTAssertFalse(commands.replace(range: NSRange(location: 0, length: 5), with: "Howdy"))
        XCTAssertFalse(commands.replaceAll(ranges: [NSRange(location: 0, length: 5)], with: "Howdy"))
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in })
        let inserted = await rig.editor.insertImage(png: png, preferredName: "x", at: 0)
        XCTAssertNil(inserted, "an image paste is refused too")

        XCTAssertEqual(rig.editor.textStorage.string, text, "nothing reached the document")
        XCTAssertFalse(rig.editor.undoManager?.canUndo ?? false)
        XCTAssertGreaterThan(rig.selection.refusedEditCount, 0)
        XCTAssertEqual(rig.selection.refusedEditMessage, AIActionController.changeSuggestedMessage)
        guard case .reviewing = rig.ai.state else { return XCTFail("the review stays up") }

        // After the review, editing works again.
        rig.ai.handle(.end)
        rig.editor.selectedRange = NSRange(location: 12, length: 0)
        rig.editor.insertText("!")
        XCTAssertEqual(rig.editor.textStorage.string, "Hello world.!\n\n- [ ] task\n")
    }

    func testLeavingReviewCollapsesSelectionToCaretEnd() async throws {
        let text = "Hello world.\nSecond line.\n"
        // The passage selected WITH its line ending (a triple-tap): the caret goes before it.
        let range = NSRange(location: 0, length: 13)
        let caret = NSRange(location: 12, length: 0)
        let paths: [(String, (Rig) -> Void)] = [
            ("accept", { $0.ai.handle(.acceptCurrent) }),
            ("reject", { $0.ai.handle(.rejectCurrent) }),
            ("done", { $0.ai.handle(.end) }),
            ("abandon", { $0.ai.abandon() }),
            ("disconnect", { $0.store.disconnect() }),
            ("read mode", { $0.selection.displayModeDidChange(to: .read) }),
            ("overlay key", { rig in
                let overlay = AIReviewOverlayTextView.make()
                overlay.commandHandler = { rig.ai.handle($0) }
                overlay.performReviewKey(.reject)
            }),
        ]
        for (name, leave) in paths {
            let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() }))
            try await review(rig, .rephrase, range: range)
            XCTAssertEqual(rig.editor.selectedRange, range, "the passage stays selected under the overlay (\(name))")
            leave(rig)
            if case .reviewing = rig.ai.state { XCTFail("still reviewing after \(name)") }
            XCTAssertEqual(rig.editor.selectedRange, caret, "\(name) collapses to caretEnd")
            XCTAssertFalse(rig.editor.isAIReviewActive, name)
        }

        // The collapse is the app's own selection: the row does not rise for it.
        let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() }))
        try await review(rig, .rephrase, range: NSRange(location: 0, length: 5))
        rig.ai.handle(.end)
        rig.selection.editorSelectionDidChange()
        try await Task.sleep(for: .seconds(SelectionController.settleDelay + 0.15))
        XCTAssertEqual(rig.selection.phase, .hidden)
    }

    func testAbandonRecordsNothing() async throws {
        let text = "Teh cat sat on teh mat.\n"
        let rig = try makeRig(text, client: FakeAIClient(FakeAIClient.revising { _, _ in "The cat sat on the mat." }))
        let recorder = FakeAIHistoryRecorder()
        rig.selection.aiHistory = recorder
        XCTAssertTrue(rig.ai.history === recorder, "the one History assignment reaches the controller")
        try await review(rig, .proofread, range: NSRange(location: 0, length: 23))
        guard case .reviewing(let session) = rig.ai.state, let first = session.pending.first else {
            return XCTFail("no review")
        }
        rig.ai.handle(.accept(first.id))
        rig.ai.abandon()

        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertEqual(rig.editor.textStorage.string, text, "abandon applies nothing, accepted or not")
        XCTAssertFalse(rig.editor.undoManager?.canUndo ?? false)
        XCTAssertFalse(recorder.calls.contains { if case .recordAccepted = $0 { return true }; return false })
        XCTAssertFalse(recorder.calls.contains(.acceptWillApply))
        XCTAssertEqual(recorder.calls.last, .actionAbandoned)
        XCTAssertEqual(rig.editor.selectedRange, NSRange(location: 23, length: 0))
    }

    func testDisconnectDuringRequestAppliesNothing() async throws {
        let text = "Hello world.\n"
        let client = FakeAIClient(.suspend)
        let rig = try makeRig(text, client: client)
        rig.editor.selectedRange = NSRange(location: 0, length: 12)
        rig.ai.run(.rephrase, range: NSRange(location: 0, length: 12), text: rig.editor.string)
        XCTAssertEqual(rig.ai.state, .running(.rephrase, .claude))
        try await spin { client.prompts.count == 1 }

        rig.store.disconnect()
        XCTAssertEqual(rig.ai.state, .idle, "the request is dropped at once")
        try await spin { client.observedCancellation }
        XCTAssertEqual(rig.editor.textStorage.string, text)
        XCTAssertFalse(rig.editor.undoManager?.canUndo ?? false)
        XCTAssertFalse(rig.keychain.hasKey(for: .claude), "no key is left in the Keychain")
        XCTAssertNil(rig.selection.aiStatus)
        XCTAssertFalse(rig.editor.isAIReviewActive)
    }

    // MARK: - Mark

    func testMarkActionDrawsWashNotAttribute() async throws {
        let text = "One short line. Two is here. Three ends it.\n"
        let rig = try makeRig(text, client: FakeAIClient(.reply(#"{"sentences":[2]}"#)))
        let range = NSRange(location: 0, length: 43)
        rig.editor.selectedRange = range
        rig.ai.run(.markWeakest, range: range, text: rig.editor.string)
        try await spin { if case .marking = rig.ai.state { return true }; return false }
        guard case .marking(let ranges) = rig.ai.state else { return XCTFail("no marks") }
        XCTAssertEqual(rig.editor.aiMarkRanges, ranges)
        rig.editor.layoutIfNeeded()

        // A layer behind the text, from the layout manager's rects; nothing in the storage.
        let wash = try XCTUnwrap(rig.editor.aiMarkWashLayer)
        let path = try XCTUnwrap(wash.path)
        let glyphs = rig.editor.layoutManager.glyphRange(forCharacterRange: ranges[0], actualCharacterRange: nil)
        let rect = rig.editor.layoutManager.boundingRect(forGlyphRange: glyphs, in: rig.editor.textContainer)
            .offsetBy(dx: rig.editor.textContainerInset.left, dy: rig.editor.textContainerInset.top)
        XCTAssertTrue(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(wash.fillColor, HistoryPalette.markWash(for: Theme.theme(for: .original))
            .resolvedColor(with: rig.editor.traitCollection).cgColor, "History's mark wash")
        XCTAssertEqual(rig.editor.layer.sublayers?.first, wash, "drawn behind the text")
        var stored = false
        rig.editor.textStorage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: rig.editor.textStorage.length)) { value, _, _ in
            if value != nil { stored = true }
        }
        XCTAssertFalse(stored, "the wash is drawn, never a stored attribute")
        XCTAssertFalse(rig.editor.undoManager?.canUndo ?? false)
        XCTAssertEqual(rig.editor.selectedRange.length, 0, "the selection would draw over the wash")

        // A real edit dismisses the marks; so does the card.
        rig.editor.insertText("x")
        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertTrue(rig.editor.aiMarkRanges.isEmpty)
        rig.editor.layoutIfNeeded()
        XCTAssertNil(rig.editor.aiMarkWashLayer?.path)
    }

    // MARK: - Network

    func testNoNetworkWithoutConnection() async throws {
        let keychain = InMemoryAIKeychain()
        let store = try makeStore(connected: false, keychain: keychain)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let ai = AIActionController(connectionStore: store, clientFactory: { connection in
            AIClientFactory.client(for: connection, transport: URLSessionAITransport(configuration: configuration))
        })
        let rig = try makeRig("Hello world.\n", store: store, keychain: keychain, ai: ai)

        // Not connected: no Ask AI, no Another Word, and a run sends nothing and reads no key.
        rig.editor.selectedRange = NSRange(location: 0, length: 5)
        rig.selection.showRowNow()
        XCTAssertFalse(rig.selection.items.contains(.askAI))
        XCTAssertFalse(rig.selection.items.contains(.anotherWord))
        rig.ai.run(.rephrase, range: NSRange(location: 0, length: 12), text: rig.editor.string)
        rig.ai.run(.anotherWord, range: NSRange(location: 0, length: 5), text: rig.editor.string)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.ai.state, .idle)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty, "StubURLProtocol sees nothing")
        XCTAssertEqual(keychain.readCount, 0)

        // The stub would have seen a request: connected, the same run reaches it.
        XCTAssertNil(store.connect(.claude, key: "sk-test"))
        rig.ai.run(.rephrase, range: NSRange(location: 0, length: 12), text: rig.editor.string)
        try await spin { !StubURLProtocol.requestedURLs.isEmpty || rig.ai.state != .running(.rephrase, .claude) }
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
        rig.ai.cancel()
    }

    // MARK: - Hosted: the overlay and the cards

    func testOverlayCoversEditorAndCardsSitAboveKeyboard() async throws {
        let text = "Hello world. This is fine.\n\nMore text below.\n"
        let (editor, selection, ai, document) = try await hostScreen(text: text,
            client: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() }))
        let window = try XCTUnwrap(self.window)
        editor.selectedRange = NSRange(location: 0, length: 26)
        ai.run(.rephrase, range: NSRange(location: 0, length: 26), text: editor.string)
        try await spin { Self.find(AIReviewOverlayTextView.self, in: window) != nil }
        let overlay = try XCTUnwrap(Self.find(AIReviewOverlayTextView.self, in: window))

        // Over the editor, with its profile, insets and container; read-only; empty undo. The overlay
        // takes the focus, so the software keyboard (when the simulator shows one) goes down and the
        // screen lays out again: compare once both views have settled.
        try await spin { overlay.convert(overlay.bounds, to: nil) == editor.convert(editor.bounds, to: nil) }
        XCTAssertEqual(overlay.convert(overlay.bounds, to: nil), editor.convert(editor.bounds, to: nil))
        XCTAssertEqual(overlay.textContainerInset, editor.textContainerInset)
        XCTAssertEqual(overlay.textContainer.size.width, editor.textContainer.size.width)
        XCTAssertEqual(overlay.contentInset.top, editor.contentInset.top)
        XCTAssertEqual(overlay.backgroundColor, editor.backgroundColor)
        XCTAssertFalse(overlay.isEditable)
        XCTAssertFalse(overlay.undoManager?.canUndo ?? false)
        XCTAssertTrue(overlay.undoManager !== editor.undoManager)
        XCTAssertNotNil(overlay.accessibilityCustomActions?.first { $0.name == AIReviewCardsPresentation.accessibilityActionTitles()[0] })

        // The card: Accept, Reject and Done, no key hints, above the keyboard.
        let titles = AIReviewCardPresentation.buttonTitles
        try await spin { Self.element(titles.accept, in: window) != nil }
        XCTAssertNotNil(Self.element(titles.reject, in: window))
        XCTAssertNotNil(Self.element(AIReviewCardsPresentation.doneTitle, in: window))
        XCTAssertNil(Self.element(AIReviewCardPresentation.reviewHint, in: window), "no Esc / Return hints")
        let keyboardHeight: CGFloat = 336
        let keyboard = CGRect(x: 0, y: window.bounds.maxY - keyboardHeight, width: window.bounds.width, height: keyboardHeight)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: window.screen.coordinateSpace)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
        try await spin {
            let accept = Self.element(titles.accept, in: window)?.accessibilityFrame ?? .zero
            return accept.maxY <= keyboard.minY && accept.maxY > keyboard.minY - 160
        }
        XCTAssertEqual(selection.phase, .hidden)

        // Hardware keys: Return accepts.
        XCTAssertTrue(overlay.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags.isEmpty } ?? false)
        XCTAssertTrue(overlay.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } ?? false)
        try await spin { overlay.isFirstResponder }
        XCTAssertFalse(editor.isFirstResponder, "the overlay holds the focus: the read-only editor gets no keys")
        overlay.performReviewKey(.accept)
        XCTAssertEqual(ai.state, .idle)
        try await spin { Self.find(AIReviewOverlayTextView.self, in: window) == nil }
        XCTAssertEqual(editor.textStorage.string, "HELLO WORLD. THIS IS FINE.\n\nMore text below.\n")
        XCTAssertEqual(document.text, editor.textStorage.string, "the document (and so autosave) has the accept")
        try await spin { editor.isFirstResponder }
    }

    func testRowIgnoresProgrammaticSelection() async throws {
        let rig = try makeRig("Hello world, a short line.\n", client: FakeAIClient(.suspend))
        let commands = LiveEditorCommands(positionKeeper: rig.keeper, document: rig.document, mode: .write)
        commands.selectRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(rig.editor.isSelectionProgrammatic)
        rig.selection.editorSelectionDidChange()
        try await Task.sleep(for: .seconds(SelectionController.settleDelay + 0.15))
        XCTAssertEqual(rig.selection.phase, .hidden, "a Search or Outline jump never raises the row")
        rig.editor.setDocumentText("Hello world, a short line, reloaded.\n")
        rig.selection.editorSelectionDidChange()
        XCTAssertEqual(rig.selection.phase, .hidden)

        // The writer's own selection still does.
        rig.editor.selectedRange = NSRange(location: 6, length: 5)
        XCTAssertFalse(rig.editor.isSelectionProgrammatic)
        rig.selection.editorSelectionDidChange()
        try await spin { rig.selection.phase == .row }
    }

    // MARK: - Helpers

    private struct Rig {
        let editor: LineformTextView
        let selection: SelectionController
        let ai: AIActionController
        let store: AIConnectionStore
        let keychain: InMemoryAIKeychain
        let keeper: ModePositionKeeper
        let document: OpenDocument
    }

    private func makeStore(connected: Bool, keychain: InMemoryAIKeychain) throws -> AIConnectionStore {
        let suite = "AIReviewTests-\(UUID().uuidString)"
        suites.append(suite)
        let store = AIConnectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychain: keychain)
        if connected { XCTAssertNil(store.connect(.claude, key: "sk-test")) }
        return store
    }

    private func makeRig(_ text: String, client: FakeAIClient) throws -> Rig {
        let keychain = InMemoryAIKeychain()
        let store = try makeStore(connected: true, keychain: keychain)
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        return try makeRig(text, store: store, keychain: keychain, ai: ai)
    }

    /// An editor in a window, first responder, with a selection controller (and so the AI
    /// controller's surface) attached.
    private func makeRig(_ text: String, store: AIConnectionStore, keychain: InMemoryAIKeychain,
                         ai: AIActionController) throws -> Rig {
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
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: AIReviewTestUbiquitousItems())
        document.readEditor = editor
        editor.imageInsertionHost = document
        return Rig(editor: editor, selection: selection, ai: ai, store: store, keychain: keychain,
                   keeper: keeper, document: document)
    }

    /// Runs `action` on `range` (selected, as the row leaves it) and waits for the review.
    private func review(_ rig: Rig, _ action: AIAction, range: NSRange) async throws {
        rig.editor.selectedRange = range
        rig.ai.run(action, range: range, text: rig.editor.string)
        try await spin { if case .reviewing = rig.ai.state { return true }; return false }
    }

    private func hostScreen(text: String, client: FakeAIClient) async throws
        -> (LineformTextView, SelectionController, AIActionController, OpenDocument) {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: AIReviewTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        let suite = "AIReviewTests-profile-\(UUID().uuidString)"
        suites.append(suite)
        let profiles = ReadingProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let settingsSuite = "AIReviewTests-settings-\(UUID().uuidString)"
        suites.append(settingsSuite)
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: settingsSuite)))
        let store = try makeStore(connected: true, keychain: InMemoryAIKeychain())
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
        let editor = try XCTUnwrap(Self.find(LineformTextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
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

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// The accessibility element labelled exactly `label`.
    static func element(_ label: String, in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if root.accessibilityLabel == label, !(root is UIWindow) { return root }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        if let elements = root.accessibilityElements as? [NSObject] { children += elements }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = root.accessibilityElement(at: index) as? NSObject { children.append(element) }
            }
        }
        for child in children where child !== root {
            if let found = element(label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

/// Stands in for `MarkdownEditor.Coordinator`, which writes each change to the binding.
private final class TextChangeListener: NSObject, UITextViewDelegate {
    var changes: [String] = []
    func textViewDidChange(_ textView: UITextView) { changes.append(textView.text) }
}

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct AIReviewTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
