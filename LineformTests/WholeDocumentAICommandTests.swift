import XCTest
import AppKit
import SwiftUI
@testable import Lineform
@testable import LineformCore

/// Edit ▸ Ask AI… (2026-11-22). With a selection it opens the selection toolbar's comment card for
/// it, exactly as the toolbar's Ask button does; with nothing selected it opens the same card for
/// the whole document, after `WholeDocumentAIPolicy` (confirm over 1,500 words, refuse past
/// `AILimits`). The card itself needs a window, so it is checked by hand; the decisions, the
/// command routing and the wording are checked here.
@MainActor
final class WholeDocumentAICommandTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ") + "."
    }

    private func makeController(connected: Bool = true, replacing words: [String: String] = [:])
        -> (AIActionController, FakeAIClient) {
        suiteName = "WholeDocumentAICommandTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        if connected { XCTAssertNil(store.connect(.claude, key: "test-key-not-real")) }
        let fake = FakeAIClient(FakeAIClient.revising { _, segment in
            var result = segment
            for (old, new) in words { result = result.replacingOccurrences(of: old, with: new) }
            return result
        })
        return (AIActionController(connectionStore: store) { _ in fake }, fake)
    }

    // MARK: - The command's decision

    /// A selection goes the way it always went: the selection's comment card, no length policy
    /// (the controller's own limit message still applies when it runs).
    func testMacAskAIWithSelectionUnchanged() async throws {
        let text = "The big dog ran.\n\n" + words(5_000)
        let selection = (text as NSString).range(of: "The big dog ran.")
        XCTAssertEqual(AskAICommand.plan(selection: selection, text: text), .selection(selection))
        let everything = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertEqual(AskAICommand.plan(selection: everything, text: text), .selection(everything),
                       "a long selection is still a selection")

        // The comment card's Send runs on that range, as before.
        let (controller, fake) = makeController(replacing: ["big": "small"])
        let textView = LineformTextView()
        textView.string = text
        controller.editor = textView
        MarkdownTextViewRepresentable.perform(.run(.rephrase, selection, note: "warmer"), on: controller, text: text)
        await controller.runTask?.value
        guard case .reviewing(let session) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(session.selectionRange, selection)
        XCTAssertEqual(FakeAIClient.segments(in: fake.prompts[0]), ["The big dog ran."])
    }

    func testMacAskAIWithoutSelectionTargetsWholeDocument() async throws {
        let caret = NSRange(location: 3, length: 0)
        let short = "# Notes\n\nThe big dog ran."
        XCTAssertEqual(AskAICommand.plan(selection: caret, text: short), .wholeDocument)
        XCTAssertEqual(AskAICommand.plan(selection: caret, text: words(1_600)), .confirmWholeDocument(words: 1_600))
        XCTAssertEqual(AskAICommand.plan(selection: caret, text: words(5_000)), .refuseWholeDocument)

        // The whole-document card's Send runs on the whole document.
        let (controller, fake) = makeController(replacing: ["big": "small"])
        let textView = LineformTextView()
        textView.string = short
        controller.editor = textView
        MarkdownTextViewRepresentable.perform(.runWholeDocument(.rephrase, note: nil), on: controller, text: short)
        await controller.runTask?.value
        guard case .reviewing(let session) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(session.selectionRange, NSRange(location: 0, length: (short as NSString).length))
        XCTAssertEqual(FakeAIClient.segments(in: fake.prompts[0]), ["Notes", "The big dog ran."])
        controller.handle(.acceptCurrent)
        XCTAssertEqual(textView.string, "# Notes\n\nThe small dog ran.")

        // Refused: the controller's message card says so, and nothing runs.
        let (refusing, refusingFake) = makeController()
        refusing.refuseWholeDocument()
        XCTAssertEqual(refusing.state, .message("Select a part of the document — about 4,000 words at most."))
        XCTAssertTrue(refusingFake.prompts.isEmpty)
    }

    /// Enabled only while connected, outside History mode, not mid-request or mid-review, with
    /// an editor on screen (Write or Split), and an editable document with text in it (a request or review in progress only opens the drawer): with
    /// nothing to send, the command is not offered (fix after the step 8 review).
    func testMenuEnablement() {
        func enabled(connected: Bool = true, history: Bool = false, state: AIActionController.State = .idle,
                     mode: EditorDisplayMode = .write, editable: Bool = true, hasText: Bool = true) -> Bool {
            AskAICommand.isEnabled(isConnected: connected, isHistoryModeActive: history, state: state, displayMode: mode,
                                   isEditable: editable, hasText: hasText)
        }
        XCTAssertFalse(enabled(editable: false), "a document that cannot be edited cannot take a suggestion")
        XCTAssertFalse(enabled(hasText: false), "an empty document has nothing to send")
        XCTAssertFalse(AskAICommand.hasText(""))
        XCTAssertFalse(AskAICommand.hasText("  \n\n"))
        XCTAssertTrue(AskAICommand.hasText("A"))
        XCTAssertTrue(enabled())
        XCTAssertTrue(enabled(mode: .split))
        XCTAssertTrue(enabled(state: .message("x")))
        XCTAssertTrue(enabled(state: .marking([])))
        XCTAssertFalse(enabled(connected: false))
        XCTAssertFalse(enabled(history: true))
        XCTAssertTrue(enabled(state: .running(.rephrase, .claude)), "it only opens the drawer, where the request is")
        let session = AIReviewSession(action: .rephrase, changes: [], selectionRange: NSRange(location: 0, length: 1),
                                      originalSelection: "a")
        XCTAssertTrue(enabled(state: .reviewing(session)))
        XCTAssertFalse(enabled(mode: .read))
    }

    /// The AI drawer and Reading Experience share the inspector slot, one at a time: a button opens
    /// its content, switches to it, or closes it when it is already showing.
    func testInspectorSlotIsSharedOneAtATime() {
        let closed = EditorInspectorContent.toggled(.ai, isOpen: false, showing: .readingExperience)
        XCTAssertEqual(closed.isOpen, true)
        XCTAssertEqual(closed.content, .ai)
        let switched = EditorInspectorContent.toggled(.ai, isOpen: true, showing: .readingExperience)
        XCTAssertEqual(switched.isOpen, true)
        XCTAssertEqual(switched.content, .ai)
        let shut = EditorInspectorContent.toggled(.ai, isOpen: true, showing: .ai)
        XCTAssertEqual(shut.isOpen, false)
        let back = EditorInspectorContent.toggled(.readingExperience, isOpen: true, showing: .ai)
        XCTAssertEqual(back.isOpen, true)
        XCTAssertEqual(back.content, .readingExperience)
    }

    /// One conversation per open document: a closed tab or a replaced document drops it.
    func testConversationsLiveWithTheirDocument() {
        let store = AIConversationStore()
        let a = AIConversationStore.Key(tab: UUID(), document: UUID())
        let b = AIConversationStore.Key(tab: UUID(), document: UUID())
        let first = store.conversation(for: a)
        XCTAssertTrue(store.conversation(for: a) === first)
        _ = store.conversation(for: b)
        XCTAssertEqual(store.count, 2)
        store.keepOnly([a])
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.conversation(for: a) === first)
    }

    /// The confirmation: Send and Cancel, Cancel the default (Return), Send never on Return.
    func testConfirmationAlert() {
        let alert = AskAICommand.confirmationAlert(words: 1_600, recipient: "Claude")
        XCTAssertEqual(alert.messageText, "Send the whole document (1,600 words) to Claude?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Send", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "Cancel is the default")
    }

    /// No shortcut (none of the free keys is an obvious one); the title has an icon and is a
    /// localized catalog key.
    func testMenuTitle() throws {
        XCTAssertEqual(AppMenuConfiguration.askAICommandTitle, "Ask AI…")
        XCTAssertTrue(AppMenuConfiguration.allEnglishTitleKeys.contains("Ask AI…"))
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            XCTAssertNotEqual(String(localized: "Ask AI…", bundle: bundle), "Ask AI…", language)
        }
    }

    // MARK: - Menu state at launch (fix after the step 8 review)

    /// Edit ▸ Ask AI… is enabled at launch when an AI is already connected: the window's state is
    /// published when the editor appears, not only when it changes or the window becomes key.
    func testAskAIMenuEnabledOnAppearWhenConnected() async throws {
        suiteName = "WholeDocumentAICommandTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let controller = AIActionController(connectionStore: store) { _ in FakeAIClient(.suspend) }
        let textView = LineformTextView()
        textView.string = "The big dog ran."
        controller.editor = textView
        let history = DocumentHistoryController(store: NullPassageHistoryStore())
        LineformAIMenuState.shared.setCanAskAI(false)
        defer { LineformAIMenuState.shared.setCanAskAI(false) }

        let view = Color.clear.frame(width: 100, height: 100).modifier(AskAIMenuHandlers(
            windowNumber: nil, openDrawer: {}, aiController: controller, historyController: history, connectionStore: store,
            displayMode: .write, documentHasText: true, isKeyWindow: { true }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(2)
        while !LineformAIMenuState.shared.canAskAI, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(LineformAIMenuState.shared.canAskAI, "enabled once the editor appears, already connected")
    }

    // MARK: - The whole-document card (fix after the step 8 review)

    /// The whole-document comment card carries a quiet "Whole document" subtitle, so the writer
    /// knows what Send sends; a selection's card does not.
    func testWholeDocumentCardSaysWholeDocument() {
        XCTAssertEqual(SelectionToolbarPresentation.wholeDocumentSubtitle, "Whole document")
        func height(wholeDocument: Bool) -> CGFloat {
            let model = SelectionToolbarModel()
            model.mode = .comment
            model.aiName = "Claude"
            model.isWholeDocument = wholeDocument
            return NSHostingView(rootView: SelectionToolbarRoot(model: model)).fittingSize.height
        }
        XCTAssertGreaterThan(height(wholeDocument: true), height(wholeDocument: false), "the subtitle takes a line")

        let textView = LineformTextView()
        textView.string = "Some text."
        textView.selectionToolbar.model.isWholeDocument = true
        textView.selectionToolbar.isWholeDocument = true
        textView.hideSelectionToolbar()
        XCTAssertFalse(textView.selectionToolbar.model.isWholeDocument, "closing the card clears it")
    }

    // MARK: - Wording

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Whole-document AI made "only the selection is sent" false. Every place that promised it
    /// now names both cases, and still says the file name is never sent.
    func testPrivacyWordingNamesWholeDocument() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "Privacy", withExtension: "md"))
        let privacy = try String(contentsOf: bundled, encoding: .utf8)
        XCTAssertTrue(privacy.contains("the passage you select, or the whole document when you choose Ask AI for the whole document"))
        XCTAssertTrue(privacy.contains("Its file name is never sent."))
        // Both apps (fix after the step 8 review): no platform named where both apply.
        XCTAssertTrue(privacy.contains("directly from your device to that provider"))
        XCTAssertTrue(privacy.contains("your device's Keychain"))
        XCTAssertTrue(privacy.contains("Connect Your AI (Lineform ▸ Connect Your AI… on Mac, Menu ▸ Settings on iPhone)"))
        XCTAssertFalse(privacy.contains("from your Mac to that provider"))
        XCTAssertFalse(privacy.contains("your Mac's Keychain"))
        // Find on the whole document sends every sentence of its prose.
        XCTAssertTrue(privacy.contains("for Find on the whole document, every sentence of its prose"))
        XCTAssertFalse(privacy.contains("The rest of your document and its file name are never sent."))

        let web = try String(contentsOf: repoRoot.appendingPathComponent("web/privacy.html"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(web.contains("the passage you select, or the whole document when you choose Ask AI for the whole"))
        XCTAssertFalse(web.contains("only the prose of that selection goes"))
        XCTAssertTrue(web.contains("Its file name is never sent."))
        XCTAssertTrue(web.contains("straight from your device to the provider"))
        XCTAssertTrue(web.contains("Your key stays in your device's Keychain."))
        XCTAssertTrue(web.contains("Connect Your AI (Lineform ▸ Connect Your AI… on Mac, Menu ▸ Settings on iPhone)"))
        XCTAssertTrue(web.contains("or every sentence of the document"))
        XCTAssertFalse(web.contains("your Mac's Keychain"))

        let help = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "Help", withExtension: "md")), encoding: .utf8)
        XCTAssertTrue(help.contains("or of the whole document when you choose Ask AI for the whole document"))
        XCTAssertTrue(help.contains("(for Find, each whole sentence your selection touches, or every sentence of the document)"))

        let claude = try String(contentsOf: repoRoot.appendingPathComponent("Claude.md"), encoding: .utf8)
        XCTAssertTrue(claude.contains("the passage they select, or the whole document when they choose Ask AI for it"))

        // Still true with whole-document AI, so unchanged.
        XCTAssertTrue(ConnectAIPresentation.privacyNote.contains("only the text you act on"))
    }
}
