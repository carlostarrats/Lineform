import XCTest
import AppKit
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

    /// Enabled only while connected, outside History mode, not mid-request or mid-review, and with
    /// an editor on screen (Write or Split).
    func testMenuEnablement() {
        func enabled(connected: Bool = true, history: Bool = false, state: AIActionController.State = .idle,
                     mode: EditorDisplayMode = .write) -> Bool {
            AskAICommand.isEnabled(isConnected: connected, isHistoryModeActive: history, state: state, displayMode: mode)
        }
        XCTAssertTrue(enabled())
        XCTAssertTrue(enabled(mode: .split))
        XCTAssertTrue(enabled(state: .message("x")))
        XCTAssertTrue(enabled(state: .marking([])))
        XCTAssertFalse(enabled(connected: false))
        XCTAssertFalse(enabled(history: true))
        XCTAssertFalse(enabled(state: .running(.rephrase, .claude)))
        let session = AIReviewSession(action: .rephrase, changes: [], selectionRange: NSRange(location: 0, length: 1),
                                      originalSelection: "a")
        XCTAssertFalse(enabled(state: .reviewing(session)))
        XCTAssertFalse(enabled(mode: .read))
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
        XCTAssertTrue(privacy.contains("from your Mac"))
        XCTAssertFalse(privacy.contains("The rest of your document and its file name are never sent."))

        let web = try String(contentsOf: repoRoot.appendingPathComponent("web/privacy.html"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(web.contains("the passage you select, or the whole document when you choose Ask AI for the whole"))
        XCTAssertFalse(web.contains("only the prose of that selection goes"))
        XCTAssertTrue(web.contains("Its file name is never sent."))

        let help = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "Help", withExtension: "md")), encoding: .utf8)
        XCTAssertTrue(help.contains("or of the whole document when you choose Ask AI for the whole document"))

        let claude = try String(contentsOf: repoRoot.appendingPathComponent("Claude.md"), encoding: .utf8)
        XCTAssertTrue(claude.contains("the passage they select, or the whole document when they choose Ask AI for it"))

        // Still true with whole-document AI, so unchanged.
        XCTAssertTrue(ConnectAIPresentation.privacyNote.contains("only the text you act on"))
    }
}
