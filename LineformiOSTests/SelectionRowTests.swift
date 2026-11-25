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
    /// The controllers' keyboard notifications: the test posts every frame, so the simulator's
    /// real keyboard never raises (or lowers) the caret's row behind a test's back.
    private var keyboardCenter = NotificationCenter()

    override func setUpWithError() throws {
        keyboardCenter = NotificationCenter()
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
        // The row rides on the keyboard as the editor's input accessory (mockup A, 2026-11-24):
        // 48 pt tall while it shows. ⋯ stays reachable: the keyboard's safe area (which holds
        // the accessory) lifts it above the row.
        XCTAssertTrue(editor.inputAccessoryView === controller.formatBar)
        try await spin { controller.formatBar.isShowing }
        XCTAssertEqual(controller.formatBar.intrinsicContentSize.height, SelectionRow.height)
        try await spin { Self.element(MoreButton.accessibilityTitle, in: window!) != nil }
        XCTAssertEqual(controller.phase, .row)
    }

    /// Without the software keyboard (keyboard down, or a hardware keyboard alone) a caret raises
    /// no row, and collapsing a selection hides it at once.
    func testRowHiddenForEmptySelection() async throws {
        let (_, editor, controller) = try await hostScreen(text: "Hello world\n")
        select(NSRange(location: 3, length: 0), in: editor)
        try await Task.sleep(for: .seconds(SelectionController.settleDelay + 0.2))
        XCTAssertEqual(controller.phase, .hidden, "a caret without the software keyboard raises no row")

        // A hardware keyboard leaves at most the shortcuts bar: still no row.
        postKeyboard(height: 72, in: try XCTUnwrap(window))
        try await spin { controller.keyboardOverlap == 72 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.phase, .hidden, "a hardware keyboard alone raises no row")

        select(NSRange(location: 0, length: 5), in: editor)
        try await spin { controller.phase == .row }
        // Collapsing hides it at once, with no settle wait.
        select(NSRange(location: 5, length: 0), in: editor)
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertNil(controller.anchorRange)
        try await spin { Self.element(MoreButton.accessibilityTitle, in: window!) != nil }
    }

    func testOrderMatchesSpec() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "word", offersReplaceWith: true), [
            .askAI, .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable, .replaceWith,
            .anotherWord, .checkSpelling,
        ])
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "two words", offersReplaceWith: true), [
            .askAI, .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable, .replaceWith,
            .checkSpelling,
        ])
        // Replace With… only where History can keep the selection (`offersReplaceWith`).
        XCTAssertEqual(SelectionController.rowItems(aiConnected: false, selectedText: "two words", offersReplaceWith: false), [
            .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable, .checkSpelling,
        ])
        // Reformat Table only when the selection starts on a table row.
        XCTAssertEqual(SelectionController.rowItems(aiConnected: false, selectedText: "a", offersReplaceWith: false,
                                                    startsOnTableRow: true).suffix(3), [.insertTable, .reformatTable, .checkSpelling])
        // pinned-en: the titles each button carries (its VoiceOver label).
        XCTAssertEqual(
            [SelectionRowItem.heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable,
             .reformatTable, .replaceWith, .anotherWord, .checkSpelling]
                .map(\.title),
            ["Heading", "Bold", "Italic", "Strikethrough", "Code", "List", "Link", "Blockquote", "Image", "Insert Table",
             "Reformat Table", "Replace With…", "Another Word", "Check Spelling"]
        )
        // pinned-en: the words on the keys, as in mockup A.
        XCTAssertEqual(
            [SelectionRowItem.askAI, .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image,
             .insertTable, .checkSpelling].map(\.keyText),
            ["Ask", "Heading", "B", "I", "S", "Code", "List", "Link", "Quote", "Image", "Table", "Check Spelling"]
        )
        // Ask shows the short word beside the sparkle; VoiceOver still hears the AI's name.
        XCTAssertEqual(SelectionRowItem.askShortTitle, "Ask")
        XCTAssertEqual(SelectionRowItem.askAI.systemImage, "sparkles")
        XCTAssertEqual(SelectionController.headingLevels.map(\.title),
                       ["Title", "Section", "Heading 3", "Heading 4", "Heading 5", "Heading 6", "Body"])

        // An editor without History offers no Replace With… (it opens History: `PhoneAIHistoryTests`).
        let (editor, controller, _) = try makeEditor("Find this phrase here\n", connected: false)
        editor.selectedRange = NSRange(location: 5, length: 11)
        controller.showRowNow()
        XCTAssertEqual(controller.phase, .row)
        XCTAssertFalse(controller.items.contains(.replaceWith))
    }

    func testAskAIOnlyWhenConnected() throws {
        try skipUnlessEnglishInterface()
        XCTAssertFalse(SelectionController.rowItems(aiConnected: false, selectedText: "two words", offersReplaceWith: true).contains(.askAI))
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "two words", offersReplaceWith: true).first, .askAI)

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

        // Ask AI opens the AI sheet (2026-11-24); the row goes, the selection stays.
        let selected = editor.selectedRange
        controller.perform(.askAI)
        XCTAssertTrue(controller.isShowingAISheet)
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertEqual(editor.selectedRange, selected, "the sheet's requests go to the selection")
    }

    func testAnotherWordOnlyForSingleWord() throws {
        // Another Word is the last button before Check Spelling, which always ends the row.
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "word", offersReplaceWith: true).suffix(2),
                       [.anotherWord, .checkSpelling])
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "don't", offersReplaceWith: true).suffix(2),
                       [.anotherWord, .checkSpelling])
        XCTAssertFalse(SelectionController.rowItems(aiConnected: true, selectedText: "two words", offersReplaceWith: true).contains(.anotherWord))
        XCTAssertFalse(SelectionController.rowItems(aiConnected: true, selectedText: "42", offersReplaceWith: true).contains(.anotherWord))
        XCTAssertFalse(SelectionController.rowItems(aiConnected: false, selectedText: "word", offersReplaceWith: true).contains(.anotherWord),
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

    /// Heading opens the levels IN PLACE (the row swaps to ‹ and the levels); a level applies as
    /// one undo step and the buttons come back; ‹ returns without a change; a new row always opens
    /// on the buttons.
    func testHeadingOpensLevelsInPlace() throws {
        let (editor, controller, _) = try makeEditor("Hello world\n", connected: false)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        XCTAssertFalse(controller.showsHeadingLevels)

        controller.perform(.heading)
        XCTAssertTrue(controller.showsHeadingLevels)
        XCTAssertEqual(editor.text, "Hello world\n", "opening the levels changes nothing")
        controller.showHeadingLevels(false)
        XCTAssertFalse(controller.showsHeadingLevels, "‹ goes back")
        XCTAssertFalse(undo.canUndo)

        controller.perform(.heading)
        controller.setHeading(3)
        XCTAssertEqual(editor.text, "### Hello world\n")
        XCTAssertFalse(controller.showsHeadingLevels, "picking a level returns to the buttons")
        XCTAssertEqual(controller.phase, .row)
        undo.undo()
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertFalse(undo.canUndo, "one level, one undo step")

        controller.perform(.heading)
        controller.hide()
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        XCTAssertFalse(controller.showsHeadingLevels, "a new row opens on the buttons")
    }

    /// Insert Table and Reformat Table moved to the row: one undo step each, through the editor.
    func testTableButtonsAreOneUndoEach() throws {
        let (editor, controller, _) = try makeEditor("Hello world\n", connected: false)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        XCTAssertFalse(controller.items.contains(.reformatTable), "not on a table row")
        controller.perform(.insertTable)
        XCTAssertTrue(editor.text.contains("| --- |"), editor.text)
        undo.undo()
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertFalse(undo.canUndo)

        editor.setDocumentText("| a | bb |\n|---|---|\n| ccc | d |\n")
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 2, length: 1)
        controller.showRowNow()
        XCTAssertTrue(controller.items.contains(.reformatTable))
        controller.perform(.reformatTable)
        XCTAssertNotEqual(editor.text, "| a | bb |\n|---|---|\n| ccc | d |\n")
        undo.undo()
        XCTAssertEqual(editor.text, "| a | bb |\n|---|---|\n| ccc | d |\n")
        XCTAssertFalse(undo.canUndo)
    }

    func testCommentReturnDuringMarkedTextDoesNotSend() async throws {
        let client = FakeAIClient(.suspend)
        let (editor, controller, store) = try makeEditor("Hello there world\n", connected: true, client: client)
        _ = store
        editor.selectedRange = NSRange(location: 0, length: 11)
        controller.showRowNow()
        controller.openComment()
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

    /// The row is docked on the keyboard (format-row option 1, 2026-11-24): the editor's input accessory,
    /// 50 pt tall while it shows and 0 otherwise, never a card floating over the page. It never
    /// changes the system edit menu.
    func testRowIsTheKeyboardsAccessory() async throws {
        try skipUnlessEnglishInterface("needs prose the keyboard language’s dictionary accepts, so no spelling items join the edit menu")
        let (_, editor, controller) = try await hostScreen(text: "Hello world, a short line.\n\nMore text below.\n")
        XCTAssertTrue(editor.inputAccessoryView === controller.formatBar, "the row rides on the keyboard")
        XCTAssertFalse(controller.formatBar.isShowing)
        XCTAssertEqual(controller.formatBar.intrinsicContentSize.height, 0, "nothing on the keyboard without the row")

        let selection = NSRange(location: 0, length: 5)
        select(selection, in: editor)
        try await spin { controller.phase == .row }
        try await spin { controller.formatBar.isShowing }
        XCTAssertEqual(controller.formatBar.intrinsicContentSize.height, SelectionRow.height)
        XCTAssertEqual(SelectionRow.height, 50, "the mockup's bar (option 1, `.b1`)")

        // The edit menu is the system's (spelling items only on a misspelling).
        let coordinator = try XCTUnwrap(editor.delegate as? MarkdownEditor.Coordinator)
        XCTAssertNil(coordinator.textView(editor, editMenuForTextIn: selection, suggestedActions: []))

        // The row goes: the accessory folds away.
        select(NSRange(location: 5, length: 0), in: editor)
        try await spin { !controller.formatBar.isShowing }
        XCTAssertEqual(controller.formatBar.intrinsicContentSize.height, 0)
        // The comment field still places itself above the keyboard.
        XCTAssertEqual(SelectionRowPlacement.bottomPadding(keyboardOverlap: 0, safeAreaBottom: 34), SelectionRowPlacement.gap)
        XCTAssertEqual(SelectionRowPlacement.bottomPadding(keyboardOverlap: 336, safeAreaBottom: 34), 302 + SelectionRowPlacement.gap)
    }

    /// Check Spelling, last on the row: the Check Document Now pass (it left Settings). The first
    /// misspelling after the caret is selected and the row stays, now for that selection; no edit.
    func testCheckSpellingSelectsTheFirstMisspelling() async throws {
        guard SpellCheckPass.language(primary: "en-US") != nil else { throw XCTSkip("no English dictionary") }
        let (editor, controller, _) = try makeEditor("The weathr was kind.\n", connected: false)
        postKeyboard(height: 336, in: try XCTUnwrap(window))
        try await spin { controller.keyboardOverlap == 336 }
        editor.selectedRange = NSRange(location: 0, length: 0)
        controller.showRowNow()
        XCTAssertEqual(controller.items.last, .checkSpelling)
        // The pass checks in the keyboard's language: the English sentence needs an English one.
        guard editor.spellCheckLanguage?.hasPrefix("en") == true else { throw XCTSkip("the keyboard's language is not English") }
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        controller.perform(.checkSpelling)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 6), "“weathr” is selected")
        XCTAssertEqual(controller.phase, .row, "the row stays, for the misspelling")
        XCTAssertEqual(controller.anchorRange, NSRange(location: 4, length: 6))
        XCTAssertFalse(undo.canUndo, "no edit, so no undo step")
        XCTAssertEqual(editor.text, "The weathr was kind.\n")
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
        controller.openComment()
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
        bareController.openComment()
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
        controller.openComment()
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
        // The message is the AI sheet's now (2026-11-24): the ⋯ button stays reachable.
        try await spin { Self.element(MoreButton.accessibilityTitle, in: window) != nil }
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .hidden, aiState: .message("x")))
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .hidden, aiState: .marking([])))
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .hidden, aiState: .idle))
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .hidden, aiState: .running(.rephrase, .claude)))
        let session = AIReviewSession(action: .rephrase, changes: [], selectionRange: NSRange(location: 0, length: 1),
                                      originalSelection: "a")
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .hidden, aiState: .reviewing(session)))
        XCTAssertTrue(SelectionController.showsBottomButtons(phase: .row, aiState: .idle), "⋯ floats above the row")
        XCTAssertFalse(SelectionController.showsBottomButtons(phase: .comment, aiState: .idle))
    }

    // MARK: - The caret's row (2026-11-24: whenever the software keyboard is up)

    /// A caret with the software keyboard up raises the row (no settle wait); it goes with the
    /// keyboard. ⋯ floats above it. A selection then gets its own row once it settles, and
    /// collapsing it returns to the caret's row, not to nothing.
    func testCaretRowFollowsSoftwareKeyboard() async throws {
        try skipUnlessEnglishInterface()
        let (_, editor, controller) = try await hostScreen(text: "Hello world, this is a test.\n")
        let window = try XCTUnwrap(self.window)
        select(NSRange(location: 3, length: 0), in: editor)
        XCTAssertEqual(controller.phase, .hidden)

        postKeyboard(height: 336, in: window)
        try await spin { controller.phase == .row }
        XCTAssertEqual(controller.anchorRange, NSRange(location: 3, length: 0))
        XCTAssertTrue(controller.items.contains(.image), "Image works at a caret")
        XCTAssertFalse(controller.items.contains(.replaceWith), "Replace With… needs a selection")
        XCTAssertFalse(controller.items.contains(.anotherWord))
        // The row is the keyboard's accessory: it shows on the keyboard. ⋯ stays reachable.
        try await spin { controller.formatBar.isShowing }
        try await spin { Self.element(MoreButton.accessibilityTitle, in: window) != nil }

        // Moving the caret keeps the row; a selection gets its own row after the settle.
        select(NSRange(location: 8, length: 0), in: editor)
        try await spin { controller.anchorRange == NSRange(location: 8, length: 0) }
        XCTAssertEqual(controller.phase, .row)
        select(NSRange(location: 6, length: 5), in: editor)
        try await spin { controller.anchorRange == NSRange(location: 6, length: 5) }
        select(NSRange(location: 11, length: 0), in: editor)
        XCTAssertEqual(controller.phase, .row, "collapsing turns it into the caret's row at once")
        XCTAssertEqual(controller.anchorRange, NSRange(location: 11, length: 0))

        // The keyboard goes: so does the caret's row.
        postKeyboardHidden()
        try await spin { controller.phase == .hidden }
        try await spin { Self.element(MoreButton.accessibilityTitle, in: window) != nil }

        // Back up, then the editor resigns: no row (it is the editor's keyboard only).
        postKeyboard(height: 336, in: window)
        try await spin { controller.phase == .row }
        editor.resignFirstResponder()
        controller.editorFocusDidChange()
        try await spin { controller.phase == .hidden }
    }

    /// The caret's commands: each is ONE undo step and the row stays for the caret.
    func testCaretCommandsAreOneUndoEach() async throws {
        let (editor, controller, _) = try makeEditor("Hello world\n", connected: false)
        let window = try XCTUnwrap(self.window)
        postKeyboard(height: 336, in: window)
        try await spin { controller.keyboardOverlap == 336 }
        let undo = try XCTUnwrap(editor.undoManager)

        func check(_ caret: Int, _ command: () -> Void, _ expected: String, caretAfter: Int,
                   file: StaticString = #filePath, line: UInt = #line) {
            editor.setDocumentText("Hello world\n")
            undo.removeAllActions()
            editor.selectedRange = NSRange(location: caret, length: 0)
            controller.showRowNow()
            XCTAssertEqual(controller.phase, .row, file: file, line: line)
            command()
            XCTAssertEqual(editor.text, expected, file: file, line: line)
            XCTAssertEqual(editor.selectedRange, NSRange(location: caretAfter, length: 0), file: file, line: line)
            XCTAssertEqual(controller.phase, .row, "the row stays for the caret", file: file, line: line)
            undo.undo()
            XCTAssertEqual(editor.text, "Hello world\n", file: file, line: line)
            XCTAssertFalse(undo.canUndo, "one button, one undo step", file: file, line: line)
        }

        // In a word: the word, the caret kept in it.
        check(8, { controller.perform(.bold) }, "Hello **world**\n", caretAfter: 10)
        check(2, { controller.perform(.italic) }, "_Hello_ world\n", caretAfter: 3)
        check(11, { controller.perform(.strikethrough) }, "Hello ~~world~~\n", caretAfter: 13)
        check(6, { controller.perform(.code) }, "Hello `world`\n", caretAfter: 7)
        // Not in a word: the Mac's paired markers, the caret between.
        check(12, { controller.perform(.bold) }, "Hello world\n****", caretAfter: 14)
        // The line: List, Blockquote, Heading.
        check(8, { controller.applyList(ordered: false) }, "- Hello world\n", caretAfter: 10)
        check(8, { controller.applyList(ordered: true) }, "1. Hello world\n", caretAfter: 11)
        check(8, { controller.perform(.blockquote) }, "> Hello world\n", caretAfter: 10)
        check(0, { controller.perform(.blockquote) }, "> Hello world\n", caretAfter: 2)

        // A second Bold in the same word removes the markers again.
        editor.setDocumentText("Hello **world**\n")
        editor.selectedRange = NSRange(location: 10, length: 0)
        controller.showRowNow()
        controller.perform(.bold)
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 8, length: 0))

        // Heading applies to the caret's line.
        editor.setDocumentText("Hello world\n")
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 8, length: 0)
        controller.showRowNow()
        controller.setHeading(2)
        XCTAssertEqual(editor.text, "## Hello world\n")
        XCTAssertEqual(controller.phase, .row)
        undo.undo()
        XCTAssertFalse(undo.canUndo)

        // Insert Table at the caret.
        editor.setDocumentText("Hello world\n")
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 12, length: 0)
        controller.showRowNow()
        controller.perform(.insertTable)
        XCTAssertTrue(editor.text.contains("| --- |"), editor.text)
        undo.undo()
        XCTAssertEqual(editor.text, "Hello world\n")
        XCTAssertFalse(undo.canUndo)

        // Link is the Mac's: `[](https://example.com)` at the caret, the address selected.
        editor.setDocumentText("Hello world\n")
        undo.removeAllActions()
        editor.selectedRange = NSRange(location: 12, length: 0)
        controller.showRowNow()
        controller.perform(.link)
        XCTAssertEqual(editor.text, "Hello world\n[](https://example.com)")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 15, length: 19))
        undo.undo()
        XCTAssertFalse(undo.canUndo)

        // Reformat Table only on a table row.
        editor.setDocumentText("| a | bb |\n|---|---|\n| ccc | d |\n")
        editor.selectedRange = NSRange(location: 2, length: 0)
        controller.showRowNow()
        XCTAssertTrue(controller.items.contains(.reformatTable))
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        controller.showRowNow()
        XCTAssertFalse(controller.items.contains(.reformatTable))
    }

    func testWordAndLineRanges() {
        let text = "Don't stop\r\nnow, 日本語です\n" as NSString
        XCTAssertEqual(SelectionController.wordRange(at: 2, in: text), NSRange(location: 0, length: 5), "an apostrophe stays in the word")
        XCTAssertEqual(SelectionController.wordRange(at: 5, in: text), NSRange(location: 0, length: 5), "the caret at a word's end")
        XCTAssertEqual(SelectionController.wordRange(at: 6, in: text), NSRange(location: 6, length: 4))
        XCTAssertNil(SelectionController.wordRange(at: 16, in: text), "between words")
        XCTAssertEqual(SelectionController.lineContentRange(at: 3, in: text), NSRange(location: 0, length: 10), "without its CRLF")
        XCTAssertEqual(SelectionController.lineContentRange(at: 12, in: text), NSRange(location: 12, length: 10))
        XCTAssertEqual(SelectionController.lineContentRange(at: text.length, in: text), NSRange(location: text.length, length: 0))
    }

    /// Ask with a caret opens the AI sheet for the whole document, through the shared policy;
    /// with no text there is no Ask. Replace With… and Another Word never show for a caret.
    func testCaretAskIsForTheWholeDocument() async throws {
        XCTAssertEqual(SelectionController.rowItems(aiConnected: true, selectedText: "", offersReplaceWith: true,
                                                    hasSelection: false),
                       [.askAI, .heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable,
                        .checkSpelling])
        let (editor, controller, _) = try makeEditor("Hello world\n", connected: true)
        postKeyboard(height: 336, in: try XCTUnwrap(window))
        try await spin { controller.keyboardOverlap == 336 }
        editor.selectedRange = NSRange(location: 3, length: 0)
        controller.showRowNow()
        XCTAssertEqual(controller.items.first, .askAI)
        controller.perform(.askAI)
        XCTAssertTrue(controller.isShowingAISheet)
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertEqual(editor.selectedRange.length, 0, "the sheet's requests go to the whole text")

        controller.isShowingAISheet = false
        editor.setDocumentText("   \n")
        editor.selectedRange = NSRange(location: 1, length: 0)
        controller.showRowNow()
        XCTAssertEqual(controller.phase, .row)
        XCTAssertFalse(controller.items.contains(.askAI), "nothing to send")
    }

    /// While an input method composes, the caret's row is left exactly as it is: a keyboard frame
    /// change (the candidate bar) or a selection change moves nothing, and its buttons do nothing.
    func testCaretRowStillWhileComposing() async throws {
        let (editor, controller, _) = try makeEditor("Hello world\n", connected: false)
        let window = try XCTUnwrap(self.window)
        postKeyboard(height: 336, in: window)
        try await spin { controller.keyboardOverlap == 336 }
        editor.selectedRange = NSRange(location: 12, length: 0)
        controller.showRowNow()
        XCTAssertEqual(controller.phase, .row)
        let items = controller.items

        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        controller.editorSelectionDidChange()
        controller.editorTextDidChange()
        postKeyboard(height: 380, in: window)
        try await spin { controller.keyboardOverlap == 380 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.phase, .row, "the row stays as it was")
        XCTAssertEqual(controller.items, items)
        let composing = editor.text
        controller.perform(.bold)
        XCTAssertEqual(editor.text, composing, "no command runs mid-composition")
        XCTAssertNotNil(editor.markedTextRange, "the composition is not disturbed")
        editor.unmarkText()
    }

    // MARK: - Helpers

    /// A keyboard `height` pt tall at the bottom of `window`, posted where the controllers listen.
    @discardableResult
    private func postKeyboard(height: CGFloat, in window: UIWindow) -> CGRect {
        let keyboard = CGRect(x: 0, y: window.bounds.maxY - height, width: window.bounds.width, height: height)
        keyboardCenter.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: window.screen.coordinateSpace)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
        return keyboard
    }

    private func postKeyboardHidden() {
        keyboardCenter.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: [
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
    }

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
        let controller = SelectionController(connectionStore: { store }, aiController: ai, keyboardNotifications: keyboardCenter)
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
            aiController: AIActionController(connectionStore: store, clientFactory: { _ in client }),
            keyboardNotifications: keyboardCenter
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
