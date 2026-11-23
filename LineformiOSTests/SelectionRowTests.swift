import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// The iPhone selection row (spec §5.5) and its comment field: it rises once a non-empty selection
/// settles, in the spec's order, Ask AI only while connected and Another Word only for one word;
/// each formatting button is one undo step; the comment field never sends while an input method is
/// composing; and the row sits above the keyboard (or the home indicator), clear of the system
/// edit menu, which it never changes. No test touches the real network or Keychain.
@MainActor
final class SelectionRowTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var suites: [String] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: folder)
    }

    func testRowAppearsAfterSelectionSettles() async throws {
        XCTAssertEqual(SelectionController.settleDelay, 0.35, "the spec's settle delay; the Mac has no delay value of its own")
        let (screen, editor, controller) = try await hostScreen(text: "Hello world, this is a test.\n")
        _ = screen
        select(NSRange(location: 0, length: 5), in: editor)
        XCTAssertEqual(controller.phase, .hidden, "nothing rises while the selection may still be changing")
        try await Task.sleep(for: .seconds(0.2))
        // Still changing: the handle moved again, so the wait starts over.
        select(NSRange(location: 0, length: 11), in: editor)
        try await Task.sleep(for: .seconds(0.25))
        XCTAssertEqual(controller.phase, .hidden, "0.45 s after the first change but only 0.25 s after the last")
        try await spin { controller.phase == .row }
        XCTAssertEqual(controller.anchorRange, NSRange(location: 0, length: 11))
        // The row replaces the bottom-right buttons while it shows.
        try await spin { Self.element(SelectionRowItem.bold.title, in: window!) != nil }
        try await spin { Self.element(MenuButton.accessibilityTitle, in: window!) == nil }
    }

    func testRowHiddenForEmptySelection() async throws {
        let (_, editor, controller) = try await hostScreen(text: "Hello world\n")
        select(NSRange(location: 3, length: 0), in: editor)
        try await Task.sleep(for: .seconds(SelectionController.settleDelay + 0.2))
        XCTAssertEqual(controller.phase, .hidden, "a caret is not a selection")

        select(NSRange(location: 0, length: 5), in: editor)
        try await spin { controller.phase == .row }
        // Collapsing hides it at once, with no settle wait.
        select(NSRange(location: 5, length: 0), in: editor)
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertNil(controller.anchorRange)
        try await spin { Self.element(MenuButton.accessibilityTitle, in: window!) != nil }
    }

    func testOrderMatchesSpec() throws {
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "word"), [
            .askAI, .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .replaceWith, .anotherWord,
        ])
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "two words"), [
            .askAI, .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .replaceWith,
        ])
        // pinned-en: the titles each button carries.
        XCTAssertEqual(
            [SelectionRowItem.heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .replaceWith, .anotherWord]
                .map(\.title),
            ["Heading", "Bold", "Italic", "Strikethrough", "Code", "List", "Link", "Blockquote", "Replace With…", "Another Word"]
        )

        // Replace With… opens Search with the selection as the query.
        let (editor, controller, _) = try makeEditor("Find this phrase here\n", connected: false)
        var query: String?
        controller.onReplaceWith = { query = $0 }
        editor.selectedRange = NSRange(location: 5, length: 11)
        controller.showRowNow()
        controller.perform(.replaceWith)
        XCTAssertEqual(query, "this phrase")
        XCTAssertEqual(controller.phase, .hidden, "the Menu sheet takes over")
    }

    func testAskAIOnlyWhenConnected() throws {
        XCTAssertFalse(SelectionController.rowItems(aiConnected: false, selectedText: "two words").contains(.askAI))
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "two words").first, .askAI)

        let (editor, controller, store) = try makeEditor("Hello there world\n", connected: false)
        editor.selectedRange = NSRange(location: 0, length: 11)
        controller.showRowNow()
        XCTAssertFalse(controller.items.contains(.askAI), "no AI UI without a connection")
        XCTAssertNil(controller.model.aiName)

        XCTAssertNil(store.connect(.claude, key: "sk-test"))
        controller.showRowNow()
        XCTAssertEqual(controller.items.first, .askAI)
        XCTAssertEqual(controller.model.aiName, "Claude")
        XCTAssertEqual(SelectionRowItem.askAI.title(aiName: "Claude"), "Ask Claude")

        // Ask AI swaps the row for the comment field, note empty and action Custom.
        controller.perform(.askAI)
        XCTAssertEqual(controller.phase, .comment)
        XCTAssertEqual(controller.model.note, "")
        XCTAssertEqual(controller.model.action, .custom)
        XCTAssertFalse(controller.model.canSend, "Custom needs a note")
    }

    func testAnotherWordOnlyForSingleWord() throws {
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "word").last, .anotherWord)
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "don't").last, .anotherWord)
        XCTAssertFalse(SelectionController.rowItems(aiConnected: true, selectedText: "two words").contains(.anotherWord))
        XCTAssertFalse(SelectionController.rowItems(aiConnected: true, selectedText: "42").contains(.anotherWord))
        XCTAssertFalse(SelectionController.rowItems(aiConnected: false, selectedText: "word").contains(.anotherWord),
                       "an AI action: only while connected")
    }

    func testBoldButtonIsOneUndo() throws {
        let (editor, controller, _) = try makeEditor("Hello world\n", connected: false)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        XCTAssertEqual(controller.phase, .row)

        controller.perform(.bold)
        XCTAssertEqual(editor.text, "**Hello** world\n")
        XCTAssertEqual(controller.phase, .row, "the row stays for the formatted selection")
        XCTAssertEqual(controller.anchorRange, editor.selectedRange)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertFalse(undo.canUndo, "one button, one undo step")

        // The menus' commands go the same way: one step each.
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        controller.setHeading(2)
        XCTAssertEqual(editor.text, "## Hello world\n")
        undo.undo()
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertFalse(undo.canUndo)
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        controller.perform(.blockquote)
        XCTAssertEqual(editor.text, "> Hello world\n")
        undo.undo()
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertFalse(undo.canUndo)
    }

    func testCommentReturnDuringMarkedTextDoesNotSend() async throws {
        let client = FakeAIClient(.suspend)
        let (editor, controller, store) = try makeEditor("Hello there world\n", connected: true, client: client)
        _ = store
        editor.selectedRange = NSRange(location: 0, length: 11)
        controller.showRowNow()
        controller.perform(.askAI)
        XCTAssertEqual(controller.phase, .comment)

        let field = CommentField(controller: controller, profile: .original)
        let host = UIHostingController(rootView: field)
        host.view.frame = CGRect(x: 0, y: 400, width: 393, height: 220)
        window?.rootViewController?.view.addSubview(host.view)
        host.view.layoutIfNeeded()
        try await spin { Self.find(UITextView.self, in: host.view, excluding: LineformTextView.self) != nil }
        let note = try XCTUnwrap(Self.find(UITextView.self, in: host.view, excluding: LineformTextView.self))
        XCTAssertTrue(note.becomeFirstResponder())

        // Composing: Return confirms the candidate; nothing is sent, and Send is refused.
        note.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(note.markedTextRange)
        XCTAssertTrue(controller.isNoteComposing)
        XCTAssertFalse(controller.canSendNow, "Send is off while an input method is composing")
        XCTAssertFalse(controller.send())
        note.unmarkText()
        try await spin { controller.model.note == "にほん" }
        XCTAssertEqual(controller.phase, .comment)
        XCTAssertEqual(client.prompts.count, 0)

        // Return inserts a newline; it never sends.
        note.insertText("\n")
        try await spin { controller.model.note == "にほん\n" }
        XCTAssertEqual(controller.phase, .comment)
        XCTAssertEqual(client.prompts.count, 0)
        XCTAssertEqual(controller.aiController.state, .idle)

        // Send is a button: it runs the shared controller on the selection.
        XCTAssertTrue(controller.canSendNow)
        XCTAssertTrue(controller.send())
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertEqual(controller.aiController.state, .running(.custom, .claude))
        try await spin { client.prompts.count == 1 }
        XCTAssertTrue(client.prompts[0].user.contains("Hello there"))
        XCTAssertEqual(controller.aiStatus, AIAction.custom.progressVerb, "the controller's status shows while it runs")
        controller.aiController.cancel()
    }

    func testRowSitsAboveKeyboardAndClearOfEditMenu() async throws {
        let (_, editor, controller) = try await hostScreen(text: "Hello world, a short line.\n\nMore text below.\n")
        let window = try XCTUnwrap(self.window)
        let selection = NSRange(location: 0, length: 5)
        select(selection, in: editor)
        try await spin { controller.phase == .row }
        try await spin { Self.element(SelectionRowItem.bold.title, in: window) != nil }

        // Keyboard up: the row sits above it.
        let keyboardHeight: CGFloat = 336
        let keyboard = CGRect(x: 0, y: window.bounds.maxY - keyboardHeight, width: window.bounds.width, height: keyboardHeight)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: window.screen.coordinateSpace)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
        try await spin { controller.keyboardOverlap == keyboardHeight }
        try await spin {
            let row = Self.element(SelectionRowItem.bold.title, in: window)?.accessibilityFrame ?? .zero
            return row.maxY <= keyboard.minY && row.maxY > keyboard.minY - 80
        }

        // Clear of the system edit menu, which floats at the selection (above or below it).
        let glyphs = editor.layoutManager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        let selectionRect = editor.layoutManager.boundingRect(forGlyphRange: glyphs, in: editor.textContainer)
            .offsetBy(dx: editor.textContainerInset.left, dy: editor.textContainerInset.top)
        let onScreen = editor.convert(selectionRect, to: nil)
        let editMenuZone = onScreen.insetBy(dx: -40, dy: -60)
        let rowFrame = try XCTUnwrap(Self.element(SelectionRowItem.bold.title, in: window)).accessibilityFrame
        XCTAssertFalse(rowFrame.intersects(editMenuZone), "the row never covers the edit menu's place")
        // The edit menu is the system's (spelling items only on a misspelling).
        let coordinator = try XCTUnwrap(editor.delegate as? MarkdownEditor.Coordinator)
        XCTAssertNil(coordinator.textView(editor, editMenuForTextIn: selection, suggestedActions: []))

        // Keyboard down: above the home indicator.
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: [
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
        try await spin { controller.keyboardOverlap == 0 }
        let bottomInset = window.safeAreaInsets.bottom
        try await spin {
            let row = Self.element(SelectionRowItem.bold.title, in: window)?.accessibilityFrame ?? .zero
            return row.maxY <= window.bounds.maxY - bottomInset && row.maxY > window.bounds.maxY - bottomInset - 80
        }
        XCTAssertEqual(SelectionRowPlacement.bottomPadding(keyboardOverlap: 0, safeAreaBottom: 34), SelectionRowPlacement.gap)
        XCTAssertEqual(SelectionRowPlacement.bottomPadding(keyboardOverlap: 336, safeAreaBottom: 34), 302 + SelectionRowPlacement.gap)
    }

    // MARK: - The comment field closes on any change (fix after the step 8 review)

    /// What UIKit does when the writer types: the storage changes, then the delegate hears it.
    private func type(_ text: String, at location: Int, in editor: LineformTextView) {
        editor.textStorage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
        editor.delegate?.textViewDidChange?(editor)
    }

    /// Opens the comment field on the hosted screen for `range`, with a note, and checks it stays
    /// open while the note takes the focus (the editor resigning moves no selection).
    private func openHostedComment(_ range: NSRange, editor: LineformTextView, controller: SelectionController) async throws {
        select(range, in: editor)
        try await spin { controller.phase == .row }
        controller.perform(.askAI)
        controller.model.note = "warmer"
        XCTAssertEqual(controller.phase, .comment)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            window?.layoutIfNeeded()
        }
        XCTAssertEqual(controller.phase, .comment, "opening the field (the note taking the focus) does not close it")
    }

    func testTypingElsewhereClosesCommentAndSendsNothing() async throws {
        let client = FakeAIClient(.suspend)
        let (_, editor, controller, _) = try await hostScreen(text: "Hello there world, and more.\n", connected: true, client: client)
        try await openHostedComment(NSRange(location: 0, length: 5), editor: editor, controller: controller)

        // Typing elsewhere: the range the field holds no longer names the same text.
        type("big ", at: 12, in: editor)
        XCTAssertEqual(controller.phase, .hidden, "any edit closes the field, as the Mac's card closes on any click")
        XCTAssertFalse(controller.send(), "nothing is left to send")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(client.prompts.isEmpty, "nothing is sent")
        XCTAssertEqual(controller.aiController.state, .idle)
        XCTAssertEqual(editor.textStorage.string, "Hello there big world, and more.\n")
    }

    func testSelectingOtherTextClosesComment() async throws {
        let client = FakeAIClient(.suspend)
        let (_, editor, controller, _) = try await hostScreen(text: "Hello there world, and more.\n", connected: true, client: client)
        try await openHostedComment(NSRange(location: 0, length: 5), editor: editor, controller: controller)

        select(NSRange(location: 6, length: 5), in: editor)
        XCTAssertNotEqual(controller.phase, .comment, "a new selection closes the field")
        XCTAssertFalse(controller.send())
        // The new selection is the writer's: its own row rises once it settles.
        try await spin { controller.phase == .row }
        XCTAssertEqual(controller.anchorRange, NSRange(location: 6, length: 5))
        XCTAssertTrue(client.prompts.isEmpty)
    }

    func testLiveReloadClosesComment() async throws {
        let client = FakeAIClient(.suspend)
        let (_, editor, controller, document) = try await hostScreen(text: "Hello there world, and more.\n",
                                                                    connected: true, client: client)
        try await openHostedComment(NSRange(location: 0, length: 5), editor: editor, controller: controller)

        // The text replaced from outside (a live reload, Open, Save As, Convert) through the binding.
        document.edit("Replaced from outside.\n")
        try await spin { editor.textStorage.string == "Replaced from outside.\n" }
        XCTAssertEqual(controller.phase, .hidden, "an outside replacement closes the field")
        XCTAssertFalse(controller.send())

        // Also without an AI controller made yet: the field still closes.
        let (bare, bareController, _) = try makeEditor("Hello there world\n", connected: true)
        bare.selectedRange = NSRange(location: 0, length: 5)
        bareController.showRowNow()
        bareController.perform(.askAI)
        XCTAssertEqual(bareController.phase, .comment)
        bareController.editorTextWillBeReplaced()
        XCTAssertEqual(bareController.phase, .hidden)
        XCTAssertTrue(client.prompts.isEmpty)
    }

    /// The backstop: a change that reached no hook still never sends a stale range.
    func testSnapshotMismatchRefusesSend() async throws {
        let client = FakeAIClient(.suspend)
        let (editor, controller, _) = try makeEditor("Hello there world\n", connected: true, client: client)
        editor.selectedRange = NSRange(location: 6, length: 5)
        controller.showRowNow()
        controller.perform(.askAI)
        controller.model.note = "warmer"
        XCTAssertTrue(controller.canSendNow)

        // The storage changes with no delegate call: the hooks never hear it.
        editor.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Oh, ")
        XCTAssertFalse(controller.send(), "the text differs from the one the field opened on")
        XCTAssertEqual(controller.phase, .hidden, "the field closes")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(client.prompts.isEmpty)
        XCTAssertEqual(controller.aiController.state, .idle)
    }

    // MARK: - The writer's gesture on the app's selection (fix after the step 8 review)

    /// A Search jump selects a match: the row stays down. The writer's own next touch on that
    /// selection, or a key, makes it theirs, and the row can rise for it.
    func testWriterGestureOnAppSelectionRaisesRow() async throws {
        let (_, editor, controller) = try await hostScreen(text: "Hello world, this is a test.\n")
        let match = NSRange(location: 6, length: 5)
        editor.selectProgrammatically(match)
        editor.delegate?.textViewDidChangeSelection?(editor)
        try await Task.sleep(for: .seconds(SelectionController.settleDelay + 0.2))
        XCTAssertEqual(controller.phase, .hidden, "the app's own selection raises no row")

        // A touch away from the selection changes nothing. (`hitTest` calls `writerTouched(at:)`
        // for every real touch; a test cannot make a touch event, so it calls it directly.)
        let far = CGPoint(x: editor.bounds.midX, y: editor.bounds.maxY - 10)
        editor.writerTouched(at: far)
        try await Task.sleep(for: .seconds(SelectionController.settleDelay + 0.2))
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertTrue(editor.isSelectionProgrammatic)

        // A touch on the selection: the writer's now.
        let rect = try XCTUnwrap(editor.selectedTextRange.flatMap { editor.selectionRects(for: $0).first?.rect })
        editor.writerTouched(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertFalse(editor.isSelectionProgrammatic)
        try await spin { controller.phase == .row }
        XCTAssertEqual(controller.anchorRange, match)

        // A key does the same.
        controller.hide()
        editor.selectProgrammatically(match)
        editor.delegate?.textViewDidChangeSelection?(editor)
        XCTAssertEqual(controller.phase, .hidden)
        editor.pressesBegan([], with: nil)
        XCTAssertFalse(editor.isSelectionProgrammatic)
        try await spin { controller.phase == .row }
    }

    // MARK: - Menu and Aa beside a message card (fix after the step 8 review)

    func testMenuButtonsReachableWhileMessageCardShows() async throws {
        let (_, _, controller, _) = try await hostScreen(text: "Hello world.\n", connected: true, client: FakeAIClient(.suspend))
        let window = try XCTUnwrap(self.window)
        controller.aiController.refuseWholeDocument()
        XCTAssertEqual(controller.aiState, .message(WholeDocumentAIPolicy.refusalMessage))
        try await spin { Self.element(WholeDocumentAIPolicy.refusalMessage, in: window) != nil }
        try await spin { Self.element(MenuButton.accessibilityTitle, in: window) != nil }
        let menu = try XCTUnwrap(Self.element(MenuButton.accessibilityTitle, in: window)).accessibilityFrame
        let message = try XCTUnwrap(Self.element(WholeDocumentAIPolicy.refusalMessage, in: window)).accessibilityFrame
        XCTAssertGreaterThan(menu.minY, message.maxY, "the card sits above the buttons; neither covers the other")
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .hidden, aiState: .message("x")))
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .hidden, aiState: .marking([])))
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .hidden, aiState: .idle))
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .hidden, aiState: .running(.rephrase, .claude)))
        let session = AIReviewSession(action: .rephrase, changes: [], selectionRange: NSRange(location: 0, length: 1),
                                      originalSelection: "a")
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .hidden, aiState: .reviewing(session)))
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .row, aiState: .idle))
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .comment, aiState: .idle))
    }

    // MARK: - Helpers

    /// What UIKit does for a writer's selection: set it, then tell the delegate.
    private func select(_ range: NSRange, in editor: LineformTextView) {
        editor.selectedRange = range
        editor.delegate?.textViewDidChangeSelection?(editor)
    }

    private func makeStore(connected: Bool) throws -> AIConnectionStore {
        let suite = "SelectionRowTests-\(UUID().uuidString)"
        suites.append(suite)
        let store = AIConnectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychain: InMemoryAIKeychain())
        if connected { XCTAssertNil(store.connect(.claude, key: "sk-test")) }
        return store
    }

    /// An editor in a window, first responder, with a selection controller attached.
    private func makeEditor(_ text: String, connected: Bool, client: FakeAIClient = FakeAIClient(.suspend)) throws
        -> (LineformTextView, SelectionController, AIConnectionStore) {
        let store = try makeStore(connected: connected)
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        let controller = SelectionController(connectionStore: { store }, aiController: ai)
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
        controller.attach(editor)
        return (editor, controller, store)
    }

    private func hostScreen(text: String) async throws -> (DocumentScreen, LineformTextView, SelectionController) {
        let (screen, editor, controller, _) = try await hostScreen(text: text, connected: false, client: FakeAIClient(.suspend))
        return (screen, editor, controller)
    }

    private func hostScreen(text: String, connected: Bool, client: FakeAIClient) async throws
        -> (DocumentScreen, LineformTextView, SelectionController, OpenDocument) {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: SelectionRowTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        let suite = "SelectionRowTests-profile-\(UUID().uuidString)"
        suites.append(suite)
        let profiles = ReadingProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let settingsSuite = "SelectionRowTests-settings-\(UUID().uuidString)"
        suites.append(settingsSuite)
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: settingsSuite)))
        let store = try makeStore(connected: connected)
        let controller = SelectionController(
            connectionStore: { store },
            aiController: AIActionController(connectionStore: store, clientFactory: { _ in client })
        )
        let screen = DocumentScreen(document: document, profileStore: profiles, settings: settings, selection: controller)
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
        return (screen, editor, controller, document)
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

    static func find<T: UIView>(_ type: T.Type, in view: UIView, excluding excluded: UIView.Type? = nil) -> T? {
        if let match = view as? T, excluded.map({ !view.isKind(of: $0) }) ?? true { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview, excluding: excluded) { return match }
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

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct SelectionRowTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
