import XCTest
import AppKit
@testable import Lineform

/// AI actions in the text view, without a window (default test plan: no NSWindow).
@MainActor
final class LineformTextViewAITests: XCTestCase {
    private let sample = "Alpha beta gamma. Delta epsilon."

    private final class UndoManagerVendor: NSObject, NSTextViewDelegate {
        let manager: UndoManager
        /// `groupsByEvent: false` stands in for separate events: two decisions in one test run in
        /// one runloop turn, which AppKit's automatic per-event group would otherwise merge. It
        /// also proves each call opens its own group (registering outside one would fail).
        init(groupsByEvent: Bool = true) {
            manager = UndoManager()
            manager.groupsByEvent = groupsByEvent
            super.init()
        }
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private func makeTextView(_ string: String? = nil) -> LineformTextView {
        let textView = LineformTextView()
        textView.string = string ?? sample
        return textView
    }

    private static func contextMenuEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func range(of needle: String, in text: String) -> NSRange {
        let found = (text as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle)")
        return found
    }

    // MARK: - Context menu

    func testContextMenuHasNoAIItemsWhenDisconnected() throws {
        let textView = makeTextView()
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        for handler in [nil, { (_: NSRange) in false }] as [((NSRange) -> Bool)?] {
            textView.aiAvailabilityHandler = handler
            let menu = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent()))
            let titles = menu.items.map(\.title)
            XCTAssertFalse(titles.contains(LineformTextContextMenuPresentation.aiRewriteMenuTitle))
            XCTAssertFalse(titles.contains(AIAction.proofread.title))
            XCTAssertFalse(titles.contains(LineformTextContextMenuPresentation.aiMarkMenuTitle))
            XCTAssertFalse(menu.items.contains { $0.hasSubmenu }, "absent, not disabled")
        }
    }

    func testContextMenuOffersAIGroupForSelection() throws {
        let textView = makeTextView()
        let selection = NSRange(location: 6, length: 4)
        textView.setSelectedRange(selection)
        var asked: [NSRange] = []
        textView.aiAvailabilityHandler = { asked.append($0); return true }
        textView.historyCanAddHandler = { _ in true }
        let menu = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent()))
        XCTAssertEqual(asked, [selection])

        let titles = menu.items.map(\.title)
        let paste = try XCTUnwrap(titles.firstIndex(of: LineformTextContextMenuPresentation.pasteTitle))
        let history = try XCTUnwrap(titles.firstIndex(of: LineformTextContextMenuPresentation.addToHistoryTitle))
        let rewrite = try XCTUnwrap(titles.firstIndex(of: LineformTextContextMenuPresentation.aiRewriteMenuTitle))
        XCTAssertLessThan(paste, history)
        XCTAssertLessThan(history, rewrite)
        XCTAssertTrue(menu.items[rewrite - 1].isSeparatorItem)
        XCTAssertEqual(titles[rewrite + 1], AIAction.proofread.title)
        XCTAssertEqual(titles[rewrite + 2], LineformTextContextMenuPresentation.aiMarkMenuTitle)

        let rewriteMenu = try XCTUnwrap(menu.items[rewrite].submenu)
        XCTAssertEqual(rewriteMenu.items.map(\.title), ["Trim", "Cut in half", "Rewrite"])
        XCTAssertEqual(rewriteMenu.identifier, MainMenuIconDecorator.excludedMenuIdentifier)
        let markMenu = try XCTUnwrap(menu.items[rewrite + 2].submenu)
        XCTAssertEqual(markMenu.items.map(\.title), ["Weakest sentences", "Long sentences"])
        XCTAssertEqual(markMenu.identifier, MainMenuIconDecorator.excludedMenuIdentifier)

        let actionItems = rewriteMenu.items + [menu.items[rewrite + 1]] + markMenu.items
        XCTAssertEqual(actionItems.compactMap { $0.representedObject as? AIAction },
                       [.trim, .cutInHalf, .rewrite, .proofread, .markWeakest, .markLong])
        for item in actionItems {
            XCTAssertEqual(item.action, #selector(LineformTextView.runAIAction(_:)))
            XCTAssertTrue(item.target === textView)
        }
    }

    func testNoAIItemsForEmptySelection() throws {
        let textView = makeTextView()
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        var asked: [NSRange] = []
        textView.aiAvailabilityHandler = { asked.append($0); return true }
        let titles = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent())).items.map(\.title)
        XCTAssertFalse(titles.contains(LineformTextContextMenuPresentation.aiRewriteMenuTitle))
        XCTAssertFalse(titles.contains(AIAction.proofread.title))
        XCTAssertEqual(asked, [], "an empty selection must not run the O(document) check")
    }

    func testChoosingAnItemSendsRun() throws {
        let textView = makeTextView()
        let selection = NSRange(location: 6, length: 4)
        textView.setSelectedRange(selection)
        textView.aiAvailabilityHandler = { _ in true }
        var commands: [AITextCommand] = []
        textView.aiCommandHandler = { commands.append($0) }
        let menu = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent()))
        let rewrite = try XCTUnwrap(menu.items.first { $0.title == LineformTextContextMenuPresentation.aiRewriteMenuTitle }?.submenu)
        let trim = try XCTUnwrap(rewrite.items.first)
        _ = textView.perform(try XCTUnwrap(trim.action), with: trim)
        XCTAssertEqual(commands, [.run(.trim, selection)])
    }

    // MARK: - Keys

    func testEscapeCancelsRunningRequest() {
        let textView = makeTextView()
        var commands: [AITextCommand] = []
        textView.aiCommandHandler = { commands.append($0) }

        textView.isAIRequestRunning = true
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(commands, [.cancel])

        textView.isAIRequestRunning = false
        textView.aiMarkRanges = [NSRange(location: 0, length: 5)]
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(commands, [.cancel, .dismissMarks])

        textView.aiMarkRanges = []
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(commands, [.cancel, .dismissMarks], "nothing to cancel: Esc is not taken")
    }

    // MARK: - Applying edits

    func testApplyAIEditsIsOneUndoStep() {
        let vendor = UndoManagerVendor()
        let textView = makeTextView()
        textView.delegate = vendor
        // Descending, each in the coordinates the previous one left (as the controller sends).
        textView.applyAIEdits([
            AIReviewEdit(range: range(of: "epsilon", in: sample), replacement: "EPSILON"),
            AIReviewEdit(range: range(of: "beta", in: sample), replacement: "B"),
        ], actionName: "Accept Suggestions")
        XCTAssertEqual(textView.string, "Alpha B gamma. Delta EPSILON.")
        XCTAssertEqual(vendor.manager.undoActionName, "Accept Suggestions")

        vendor.manager.undo()
        XCTAssertEqual(textView.string, sample, "one ⌘Z undoes the whole call")
        XCTAssertFalse(vendor.manager.canUndo)
        vendor.manager.redo()
        XCTAssertEqual(textView.string, "Alpha B gamma. Delta EPSILON.")
    }

    func testApplyAIEditsPreservesCRLFAndBOM() {
        let text = "\u{FEFF}# Head\r\n\r\nThe big dog.\r\nIt ran far.\r\n"
        let vendor = UndoManagerVendor()
        let textView = makeTextView(text)
        textView.delegate = vendor
        textView.applyAIEdits([
            AIReviewEdit(range: range(of: "far", in: text), replacement: "near"),
            AIReviewEdit(range: range(of: "big", in: text), replacement: "large"),
        ], actionName: "Accept Suggestions")
        XCTAssertEqual(textView.string, "\u{FEFF}# Head\r\n\r\nThe large dog.\r\nIt ran near.\r\n")
        XCTAssertEqual(textView.string.unicodeScalars.first, "\u{FEFF}")
        XCTAssertEqual(textView.string.components(separatedBy: "\r\n").count, text.components(separatedBy: "\r\n").count)
        vendor.manager.undo()
        XCTAssertEqual(textView.string, text)
    }

    /// Defence in depth: an edit that would touch a line ending or the BOM, or split a composed
    /// character, is skipped — never applied widened or half.
    func testApplyAIEditsSkipsStructureAndSplitCharacters() {
        let text = "\u{FEFF}A👍🏽b\r\nc"
        let textView = makeTextView(text)
        XCTAssertTrue(textView.applyAIEdits([], actionName: "Accept Suggestions"))
        for (index, skipped) in [NSRange(location: 4, length: 2), NSRange(location: 7, length: 2)].enumerated() {
            XCTAssertFalse(textView.applyAIEdits([AIReviewEdit(range: skipped, replacement: "x")],
                                                 actionName: "Accept Suggestion"), "a skip is reported (\(index))")
        }
        XCTAssertFalse(textView.applyAIEdits([
            AIReviewEdit(range: NSRange(location: 4, length: 2), replacement: "x"),     // inside 👍🏽
            AIReviewEdit(range: NSRange(location: 7, length: 2), replacement: ""),      // the CRLF
            AIReviewEdit(range: NSRange(location: 0, length: 1), replacement: ""),      // the BOM
            AIReviewEdit(range: NSRange(location: 1, length: 1), replacement: "a\n"),   // a newline in
        ], actionName: "Accept Suggestions"))
        XCTAssertEqual(textView.string, text)
        XCTAssertTrue(textView.applyAIEdits([AIReviewEdit(range: NSRange(location: 1, length: 1), replacement: "Z")],
                                            actionName: "Accept Suggestion"))
        XCTAssertEqual(textView.string, "\u{FEFF}Z👍🏽b\r\nc")
    }

    /// Accept → ⌘Z, and Accept Remaining → ⌘Z, through the real controller and the real text view.
    /// The selection spans two paragraphs, so its one change is applied as one edit per paragraph:
    /// the real text view refuses any AI edit that touches a line ending, and none does.
    func testAcceptAndAcceptRemainingAreOneUndoEachThroughTheController() async throws {
        let text = "The big dog ran.\r\n\r\nIt went far away from home."
        let accepted = "The large dog ran.\r\n\r\nIt went near away from here."
        for command in [AIReviewCommand.accept(0), .acceptRemaining] {
            let vendor = UndoManagerVendor(groupsByEvent: false)
            let textView = makeTextView(text)
            textView.delegate = vendor
            let controller = makeController(replacing: ["big": "large", "far": "near", "home": "here"])
            controller.editor = textView
            controller.run(.rewrite, range: NSRange(location: 0, length: (text as NSString).length), text: text)
            await controller.runTask?.value
            guard case .reviewing(let session) = controller.state else { return XCTFail("\(controller.state)") }
            XCTAssertEqual(session.changes.count, 1, "one decision for the whole selection")

            controller.handle(command)
            XCTAssertEqual(textView.string, accepted, "\(command)")
            XCTAssertEqual(controller.state, .idle)

            vendor.manager.undo()
            XCTAssertEqual(textView.string, text, "one decision is one ⌘Z (\(command))")
            XCTAssertFalse(vendor.manager.canUndo)
        }
    }

    /// The accept reaches History through the text view's one user-edit source, so a passage
    /// AFTER the change keeps its live range.
    func testHistoryLiveRangesFollowAnAccept() async throws {
        let text = "The big dog ran far away from home.\n\nA later sentence keeps its place."
        let later = "A later sentence keeps its place."
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        let textView = makeTextView(text)
        history.attach(textView)
        history.open(url: nil, text: text)
        _ = history.handle(.add(range(of: later, in: text)), text: text)

        let controller = makeController(replacing: ["big": "enormous", "far": "near"])
        controller.editor = textView
        controller.history = history
        controller.run(.rewrite, range: range(of: "The big dog ran far away from home.", in: text), text: text)
        await controller.runTask?.value
        controller.handle(.acceptRemaining)
        XCTAssertEqual(textView.string, "The enormous dog ran near away from home.\n\n\(later)")

        XCTAssertTrue(history.enterHistoryMode(text: textView.string))
        let ranges = try XCTUnwrap(history.display?.passages).map(\.range)
        XCTAssertTrue(ranges.contains(range(of: later, in: textView.string)), "\(ranges)")
        _ = history.handle(.exit, text: textView.string)
    }

    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeController(replacing words: [String: String]) -> AIActionController {
        suiteName = "LineformTextViewAITests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let fake = FakeAIClient(FakeAIClient.revising { _, segment in
            var result = segment
            for (old, new) in words { result = result.replacingOccurrences(of: old, with: new) }
            return result
        })
        return AIActionController(connectionStore: store) { _ in fake }
    }

    // MARK: - Review and marks

    func testUserEditsRefusedDuringReview() {
        let textView = makeTextView()
        textView.isAIReviewActive = true
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(textView.string, sample)

        // The review's own accepts still apply.
        textView.applyAIEdits([AIReviewEdit(range: NSRange(location: 0, length: 5), replacement: "Omega")],
                              actionName: "Accept Suggestion")
        XCTAssertEqual(textView.string, "Omega beta gamma. Delta epsilon.")
    }

    func testMarksAreTemporaryAttributesOnly() throws {
        let textView = makeTextView()
        textView.applyDefaultTypography()
        let storage = try XCTUnwrap(textView.textStorage)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let before = NSAttributedString(attributedString: storage)
        let mark = NSRange(location: 18, length: 14)

        textView.aiMarkRanges = [mark]
        XCTAssertEqual(NSAttributedString(attributedString: storage), before, "the text storage is never touched")
        let wash = layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 20, effectiveRange: nil) as? NSColor
        let theme = Theme.theme(for: textView.appliedReadingProfile)
        XCTAssertEqual(wash, HistoryPalette.tint(for: theme))
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 2, effectiveRange: nil))

        textView.aiMarkRanges = []
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 20, effectiveRange: nil))
        XCTAssertEqual(NSAttributedString(attributedString: storage), before)
    }

    func testTypingDismissesMarks() {
        let textView = makeTextView()
        var commands: [AITextCommand] = []
        textView.aiCommandHandler = { commands.append($0) }
        textView.aiMarkRanges = [NSRange(location: 0, length: 5)]
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commands, [.dismissMarks])
        XCTAssertTrue(textView.string.contains("aAlpha"))
        XCTAssertEqual(textView.aiMarkRanges, [])
    }

    /// Review fix: the keystroke that ends a review must be typed, not refused by the read-only
    /// backstop — SwiftUI has not yet pushed the controller's new state when it arrives.
    func testTypingDuringReviewEndsReviewAndTypes() async {
        let text = "The big dog ran far away from home."
        let textView = makeTextView(text)
        let controller = makeController(replacing: ["big": "large"])
        controller.editor = textView
        controller.run(.rewrite, range: NSRange(location: 0, length: (text as NSString).length), text: text)
        await controller.runTask?.value
        guard case .reviewing = controller.state else { return XCTFail("expected a review") }
        textView.isAIReviewActive = true   // what the representable pushed for `.reviewing`
        // The reviewed passage is still selected in the editor, as it is in the app.
        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))

        controller.handle(.typed("x"))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(textView.isAIReviewActive)
        XCTAssertEqual(textView.string, text + "x", "the passage is intact; the key lands at its end")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (text as NSString).length + 1, length: 0))
    }

    /// Critical: Esc, Accept All and the last pill leave the caret at the passage's end — never the
    /// passage selected, which the next keystroke would replace.
    func testEndingAReviewCollapsesTheEditorSelection() async throws {
        let text = "Intro.\n\nThe big dog ran far away from home.\n\nOutro."
        let passage = range(of: "The big dog ran far away from home.", in: text)
        for ending in ["esc", "acceptAll", "lastPill"] {
            let textView = makeTextView(text)
            let controller = makeController(replacing: ["big": "large", "far": "near"])
            controller.editor = textView
            controller.run(.rewrite, range: passage, text: text)
            await controller.runTask?.value
            textView.setSelectedRange(passage)
            switch ending {
            case "esc": controller.handle(.end)
            case "acceptAll": controller.handle(.acceptRemaining)
            default:
                controller.handle(.accept(0))
                controller.handle(.reject(1))
            }
            XCTAssertEqual(controller.state, .idle, ending)
            let end = NSMaxRange(range(of: ending == "esc" ? "from home." : "home.", in: textView.string))
            XCTAssertEqual(textView.selectedRange(), NSRange(location: end, length: 0), ending)
        }
    }

    /// Hand-test fix 3: a review started from a triple-click (the line WITH its line ending): the
    /// key that ends it lands at the end of that line's text, never at the start of the next line.
    func testTypedKeyAfterALineSelectionReviewLandsBeforeTheLineEnding() async {
        for ending in ["\n", "\r\n"] {
            let text = "The big dog ran far.\(ending)Next line."
            let line = NSRange(location: 0, length: ("The big dog ran far." + ending as NSString).length)
            let textView = makeTextView(text)
            let controller = makeController(replacing: ["big": "large"])
            controller.editor = textView
            controller.run(.rewrite, range: line, text: text)
            await controller.runTask?.value
            guard case .reviewing = controller.state else { return XCTFail("expected a review") }
            textView.isAIReviewActive = true
            textView.setSelectedRange(line)
            controller.handle(.typed("x"))
            XCTAssertEqual(textView.string, "The big dog ran far.x\(ending)Next line.", ending.debugDescription)
        }
    }

    func testCollapseIsClampedAndStaysOnACharacterBoundary() {
        let textView = makeTextView("A👍🏽b")
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        textView.collapseSelectionForAI(at: 2)   // inside 👍🏽
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
        textView.collapseSelectionForAI(at: 99)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
        textView.collapseSelectionForAI(at: -3)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testHistoryEditsPassTheReviewBackstop() {
        let textView = makeTextView()
        textView.isAIReviewActive = true
        textView.applyHistoryEdit(HistoryEdit(range: NSRange(location: 0, length: 5), replacement: "Omega"))
        XCTAssertEqual(textView.string, "Omega beta gamma. Delta epsilon.")
    }

    func testInsertTypedTextTypesAtTheSelection() {
        let textView = makeTextView()
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertTypedText("!")
        XCTAssertEqual(textView.string, "Alpha! beta gamma. Delta epsilon.")
    }
}

