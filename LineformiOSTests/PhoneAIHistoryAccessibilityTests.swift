import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// Accessibility of the AI review (overlay and cards), Connect Your AI, History mode and the
/// editor's drawn affordances: the overlay speaks the current change in words, the cards keep 44 pt
/// targets and stack at accessibility sizes, a message waits for VoiceOver, the editor vends rotors
/// for misspellings, Mark's sentences and History's passages, History mode's commands are custom
/// actions, and Connect Your AI's inks are readable.
@MainActor
final class PhoneAIHistoryAccessibilityTests: XCTestCase {
    private var window: UIWindow?
    private var suites: [String] = []
    private var hosts: [PhoneAccessibilityHost] = []

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        hosts.forEach { $0.tearDown() }
        hosts = []
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }

    // MARK: - Overlay: the change in words

    /// "Hello wrold" with "wrold" struck and "world" inserted after it.
    private func composition() -> AIReviewComposition {
        AIReviewComposition(
            string: "Hello wrold world again.",
            removedRanges: [3: [NSRange(location: 6, length: 5)]],
            replacementRanges: [3: [NSRange(location: 12, length: 5)]],
            changeRanges: [3: NSRange(location: 6, length: 11)],
            documentRanges: [3: NSRange(location: 6, length: 5)],
            insertions: []
        )
    }

    func testOverlaySpeaksCurrentChangeAsReplaceWith() throws {
        let spoken = try XCTUnwrap(AIReviewOverlayTextView.spokenChange(in: composition(), currentID: 3))
        XCTAssertTrue(spoken.contains("wrold") && spoken.contains("world"), spoken)
        XCTAssertNotEqual(spoken, composition().string, "never the struck and new text as one run")
        // The only change is spoken even without a current id.
        XCTAssertEqual(AIReviewOverlayTextView.spokenChange(in: composition(), currentID: nil), spoken)

        let overlay = AIReviewOverlayTextView.make()
        overlay.present(composition(), currentID: 3, profile: .original)
        XCTAssertEqual(overlay.accessibilityValue, spoken)
        XCTAssertEqual(overlay.accessibilityLabel, AIReviewCardPresentation.reviewCardLabel)

        try skipUnlessEnglishInterface()
        XCTAssertEqual(spoken, "Replace “wrold” with “world”")
    }

    func testOverlaySpeaksInsertAndDelete() throws {
        try skipUnlessEnglishInterface()
        let insertion = AIReviewComposition(
            string: "One more two.", removedRanges: [:], replacementRanges: [1: [NSRange(location: 4, length: 4)]],
            changeRanges: [1: NSRange(location: 4, length: 4)], documentRanges: [:], insertions: []
        )
        XCTAssertEqual(AIReviewOverlayTextView.spokenChange(in: insertion, currentID: 1), "Insert “more”")
        let deletion = AIReviewComposition(
            string: "One very two.", removedRanges: [1: [NSRange(location: 4, length: 4)]], replacementRanges: [:],
            changeRanges: [1: NSRange(location: 4, length: 4)], documentRanges: [:], insertions: []
        )
        XCTAssertEqual(AIReviewOverlayTextView.spokenChange(in: deletion, currentID: 1), "Delete “very”")
        XCTAssertNil(AIReviewOverlayTextView.spokenChange(in: .empty, currentID: nil))
    }

    func testOverlayEscapeEndsReview() {
        let overlay = AIReviewOverlayTextView.make()
        var commands: [AIReviewCommand] = []
        overlay.commandHandler = { command in commands.append(command) }
        XCTAssertTrue(overlay.accessibilityPerformEscape())
        XCTAssertEqual(commands, [.end])
    }

    // MARK: - The AI sheet

    /// The conversation in the sheet, at the default and the largest accessibility size, while a
    /// request runs, after a notice, with Find's marks and with a suggestion pending: inside the
    /// window, every control labelled and 44 pt (the version arrows are the mockup's 28 pt, and
    /// do not appear here).
    func testAISheetAtDefaultAndAccessibilitySizes() async throws {
        for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            for state in ["running", "message", "marks", "review"] {
                let (selection, ai, editor) = try makeAI(client: client(for: state))
                try await drive(state, ai: ai, editor: editor, selection: selection)
                let host = try await PhoneAccessibilityHost(
                    AISheetView(conversation: selection.conversation, profile: .original),
                    contentSize: size
                )
                hosts.append(host)
                await host.settle()
                host.assertElementsInsideWindow()
                host.assertInteractiveElementsAreLabelledAndLargeEnough()
                if state == "review" {
                    for title in [AIConversationPresentation.acceptTitle, AIConversationPresentation.rejectTitle,
                                  AIConversationPresentation.tryAgainTitle] {
                        XCTAssertNotNil(host.elements().first { $0.name == title }, "\(title): \(host.elements())")
                    }
                }
                host.tearDown()
                hosts.removeAll()
                ai.abandon()
            }
        }
    }

    // MARK: - Connect Your AI

    func testConnectAnnouncements() {
        XCTAssertEqual(ConnectAISection.connectAnnouncement(connected: true, error: nil), ConnectAIPresentation.connectedText)
        XCTAssertEqual(ConnectAISection.connectAnnouncement(connected: false, error: .missingKey), AIConnectError.missingKey.message)
    }

    /// At AX5 the providers are rows that keep the window's width (no segmented control that would
    /// truncate four names), and the consent button wraps rather than running off the side.
    func testConnectPageAtAccessibilitySize() async throws {
        let store = try makeStore(connected: false)
        let page = ConnectAISection(store: store)
            .environment(\.wordMenuPalette, WordMenuPalette(isDark: false))
        let host = try await PhoneAccessibilityHost(page, contentSize: .accessibilityExtraExtraExtraLarge)
        hosts.append(host)
        let provider = try XCTUnwrap(host.elements().first { $0.identifier == "connectAI.provider.claude" }, "\(host.elements())")
        let window = host.windowFrameOnScreen.insetBy(dx: -0.5, dy: -0.5)
        XCTAssertTrue(provider.frame.minX >= window.minX && provider.frame.maxX <= window.maxX, "keeps the width: \(provider)")
        XCTAssertTrue(provider.traits.contains(.button))
        XCTAssertTrue(provider.traits.contains(.selected), "the picked provider reads as selected")
    }

    // MARK: - Editor rotors

    func testRotorTargetSteps() {
        let ranges = [NSRange(location: 20, length: 3), NSRange(location: 2, length: 4), NSRange(location: 2, length: 10)]
        XCTAssertEqual(LineformTextView.rotorTarget(in: ranges, from: nil, caret: 0, forward: true), NSRange(location: 2, length: 10))
        XCTAssertEqual(LineformTextView.rotorTarget(in: ranges, from: NSRange(location: 2, length: 10), caret: 0, forward: true),
                       NSRange(location: 2, length: 4), "the inner range after its outer one")
        XCTAssertEqual(LineformTextView.rotorTarget(in: ranges, from: NSRange(location: 2, length: 4), caret: 0, forward: true),
                       NSRange(location: 20, length: 3))
        XCTAssertNil(LineformTextView.rotorTarget(in: ranges, from: NSRange(location: 20, length: 3), caret: 0, forward: true))
        XCTAssertEqual(LineformTextView.rotorTarget(in: ranges, from: NSRange(location: 20, length: 3), caret: 0, forward: false),
                       NSRange(location: 2, length: 4))
        XCTAssertEqual(LineformTextView.rotorTarget(in: ranges, from: nil, caret: 15, forward: false), NSRange(location: 2, length: 4))
        XCTAssertEqual(LineformTextView.rotorTarget(in: ranges, from: nil, caret: 15, forward: true), NSRange(location: 20, length: 3))
    }

    func testMisspellingRotorWalksTheSpellCheckResults() throws {
        let editor = makeEditor("Teh cat sat on teh mat.")
        editor.spellCheck.misspelledRanges = [NSRange(location: 0, length: 3), NSRange(location: 15, length: 3)]
        let rotor = try XCTUnwrap(editor.accessibilityCustomRotors?.first { $0.systemRotorType == .misspelledWord },
                                  "the system checker is off, so the app vends the rotor")
        let first = try XCTUnwrap(search(rotor, in: editor, from: nil, forward: true))
        XCTAssertEqual(first, NSRange(location: 0, length: 3))
        XCTAssertEqual(search(rotor, in: editor, from: first, forward: true), NSRange(location: 15, length: 3))
        XCTAssertNil(search(rotor, in: editor, from: NSRange(location: 15, length: 3), forward: true))
        XCTAssertEqual(editor.textStorage.string, "Teh cat sat on teh mat.", "a rotor never edits")
    }

    func testMarkedSentencesRotorOnlyWhileMarksShow() throws {
        let editor = makeEditor("One. Two is here. Three.")
        let name = LineformTextView.markedSentencesRotorName
        XCTAssertFalse(editor.accessibilityCustomRotors?.contains { $0.name == name } ?? false)
        editor.applyAIMarkRanges([NSRange(location: 5, length: 12)])
        let rotor = try XCTUnwrap(editor.accessibilityCustomRotors?.first { $0.name == name })
        XCTAssertEqual(search(rotor, in: editor, from: nil, forward: true), NSRange(location: 5, length: 12))
        editor.applyAIMarkRanges([])
        XCTAssertFalse(editor.accessibilityCustomRotors?.contains { $0.name == name } ?? false)
    }

    // MARK: - History: passages without a tap

    func testHistoryPassagesReachableWithoutTapping() async throws {
        let (controller, editor) = try makeHistory()
        XCTAssertTrue(editor.historyAccessibilityActions().isEmpty, "no History actions outside History mode")
        XCTAssertTrue(controller.enterHistoryMode(text: editor.text))
        editor.historyDisplayDidChange()
        XCTAssertNil(controller.selectedPassageID)
        XCTAssertEqual(controller.located.count, 2)

        // The custom actions: Select Next Passage selects the first, in text order.
        let names = editor.historyAccessibilityActions().map(\.name)
        XCTAssertEqual(names, [HistoryCardModel.nextPassageTitle, HistoryCardModel.previousPassageTitle, HistoryCardModel.exitTitle])
        perform(HistoryCardModel.nextPassageTitle, on: editor)
        let first = try XCTUnwrap(controller.selectedPassageID)
        XCTAssertEqual(first, controller.located.first?.id)
        XCTAssertEqual(editor.historyAccessibilityActions().count, 5, "versions can be stepped once one is selected")
        perform(HistoryCardModel.nextPassageTitle, on: editor)
        XCTAssertEqual(controller.selectedPassageID, controller.located[1].id)
        perform(HistoryCardModel.nextPassageTitle, on: editor)
        XCTAssertEqual(controller.selectedPassageID, controller.located[1].id, "clamped at the end, as on the Mac")
        perform(HistoryCardModel.previousPassageTitle, on: editor)
        XCTAssertEqual(controller.selectedPassageID, first)

        // The card's navigator is the same path.
        controller.select(nil)
        let model = HistoryCardModel(controller: controller)
        XCTAssertTrue(model.navigator.move(by: -1))
        XCTAssertEqual(controller.selectedPassageID, controller.located.last?.id)

        // The rotor lands on a passage and selects it (it starts from the caret).
        controller.select(nil)
        editor.selectedRange = NSRange(location: 0, length: 0)
        let rotor = try XCTUnwrap(editor.accessibilityCustomRotors?.first { $0.name == LineformTextView.historyPassagesRotorName })
        let landed = try XCTUnwrap(search(rotor, in: editor, from: nil, forward: true))
        XCTAssertEqual(landed, controller.located.first?.range)
        // The selection follows on the next turn of the run loop, after VoiceOver has the item,
        // and quietly: VoiceOver is reading the passage, so the card does not announce over it.
        XCTAssertNil(controller.selectedPassageID, "not inside the rotor's search")
        for _ in 0..<20 where controller.selectedPassageID == nil { await Task.yield() }
        XCTAssertEqual(controller.selectedPassageID, controller.located.first?.id)
        XCTAssertFalse(HistoryCardModel(controller: controller).announcesChanges)
        // Any later change (a step, Select Next Passage) is announced again.
        perform(HistoryCardModel.nextPassageTitle, on: editor)
        XCTAssertTrue(HistoryCardModel(controller: controller).announcesChanges)

        perform(HistoryCardModel.exitTitle, on: editor)
        XCTAssertFalse(controller.isHistoryModeActive)
        editor.historyDisplayDidChange()
        XCTAssertFalse(editor.accessibilityCustomRotors?.contains { $0.name == LineformTextView.historyPassagesRotorName } ?? true)
    }

    func testHistoryClosedIsSaidUnlessTypingLeftHistory() throws {
        let (controller, editor) = try makeHistory()
        let original = ChromeAnnouncer.post
        var said: [String] = []
        ChromeAnnouncer.post = { notification, argument in
            if notification == .announcement, let text = argument as? String { said.append(text) }
        }
        defer { ChromeAnnouncer.post = original }

        XCTAssertTrue(controller.enterHistoryMode(text: editor.text))
        controller.exitHistoryMode(text: editor.text)
        XCTAssertEqual(said, [LineformTextView.historyClosedAnnouncement], "Done, Exit History: said")

        said.removeAll()
        XCTAssertTrue(controller.enterHistoryMode(text: editor.text))
        editor.exitHistoryModeBeforeUserEdit()
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertTrue(said.isEmpty, "typing left History: the typed text is heard, not \(said)")
    }

    func testHistoryCardAtDefaultAndAccessibilitySizes() async throws {
        let (controller, editor) = try makeHistory()
        XCTAssertTrue(controller.enterHistoryMode(text: editor.text))
        for selects in [false, true] {
            if selects { controller.moveSelection(by: 1) } else { controller.select(nil) }
            for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                let card = HistoryCard(model: HistoryCardModel(controller: controller), profile: .original,
                                       onSelectLevel: { _ in }, onSelectVersion: { _ in }, onDeleteVersion: { _ in },
                                       onAddReplacement: { _, _ in }, onReplacementFieldOpened: {}, onDone: {})
                let host = try await PhoneAccessibilityHost(VStack { Spacer(); card }.padding(16), contentSize: size)
                hosts.append(host)
                host.assertElementsInsideWindow()
                // Version rows are 40 pt rows on a 42 pt pitch at the default size (the whole row
                // is the target); they grow with Dynamic Type.
                host.assertInteractiveElementsAreLabelledAndLargeEnough(
                    allowlist: size.isAccessibilityCategory ? [] : ["history.versionRow"]
                )
                let elements = host.elements()
                XCTAssertNotNil(elements.first { $0.identifier == "history.done" }, "\(elements)")
                // The card's commands are on the title, where VoiceOver lands (a container's
                // named actions do not reach its elements).
                let title = try XCTUnwrap(elements.first { $0.label == HistoryCardModel.title && $0.traits.contains(.header) },
                                          "\(elements)")
                let actions = title.object.accessibilityCustomActions?.map(\.name) ?? []
                for name in [HistoryCardModel.nextPassageTitle, HistoryCardModel.previousPassageTitle, HistoryCardModel.exitTitle] {
                    XCTAssertTrue(actions.contains(name), "\(name) on the title: \(actions)")
                }
                if selects {
                    let add = try XCTUnwrap(elements.first { $0.identifier == "history.add" }, "\(elements)")
                    XCTAssertGreaterThanOrEqual(add.frame.height, 44)
                    XCTAssertGreaterThanOrEqual(add.frame.width, 44)
                }
                host.tearDown()
                hosts.removeAll()
            }
        }
        controller.exitHistoryMode(text: editor.text)
    }

    func testStringsInEnglish() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(LineformTextView.historyClosedAnnouncement, "History closed")
        XCTAssertEqual(HistoryCardModel.nextPassageTitle, "Select Next Passage")
        XCTAssertEqual(LineformTextView.markedSentencesRotorName, "Marked sentences")
        XCTAssertEqual(LineformTextView.historyPassagesRotorName, "Passages")
    }

    // MARK: - Helpers

    private func makeEditor(_ text: String) -> LineformTextView {
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            host.view.addSubview(editor)
            window.isHidden = false
            self.window = window
        }
        editor.layoutIfNeeded()
        return editor
    }

    /// Two passages: "beta" and "theta", each kept with a replacement.
    private func makeHistory() throws -> (PhoneHistoryController, LineformTextView) {
        let text = "Alpha beta gamma. Epsilon zeta theta."
        let controller = PhoneHistoryController(
            store: MemoryHistoryStore(), now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pruneQueue: DispatchQueue(label: "PhoneAIHistoryAccessibilityTests"), notificationCenter: NotificationCenter()
        )
        controller.open(url: nil, text: text)
        let editor = makeEditor(text)
        controller.attach(editor)
        for (needle, replacement) in [("beta", "BETA"), ("theta", "THETA")] {
            let found = (editor.text as NSString).range(of: needle)
            XCTAssertTrue(editor.performReplaceWith(found))
            let id = try XCTUnwrap(controller.selectedPassageID)
            XCTAssertNotNil(controller.addReplacement(replacement, text: editor.text, for: id))
            controller.exitHistoryMode(text: editor.text)
        }
        editor.historyDisplayDidChange()
        return (controller, editor)
    }

    private func perform(_ name: String, on editor: LineformTextView, file: StaticString = #filePath, line: UInt = #line) {
        guard let action = editor.historyAccessibilityActions().first(where: { $0.name == name }) else {
            return XCTFail("no action \(name)", file: file, line: line)
        }
        XCTAssertTrue(action.actionHandler?(action) ?? false, file: file, line: line)
    }

    /// Runs `rotor` once from `current` (nil: from the caret), as VoiceOver would.
    private func search(_ rotor: UIAccessibilityCustomRotor, in editor: LineformTextView,
                        from current: NSRange?, forward: Bool) -> NSRange? {
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = forward ? .next : .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(
            targetElement: editor, targetRange: current.flatMap { editor.accessibilityTextRange(for: $0) }
        )
        guard let result = rotor.itemSearchBlock(predicate), let range = result.targetRange else { return nil }
        return NSRange(location: editor.offset(from: editor.beginningOfDocument, to: range.start),
                       length: editor.offset(from: range.start, to: range.end))
    }

    private func makeStore(connected: Bool) throws -> AIConnectionStore {
        let suite = "PhoneAIHistoryAccessibilityTests-\(UUID().uuidString)"
        suites.append(suite)
        let store = AIConnectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychain: InMemoryAIKeychain())
        if connected { XCTAssertNil(store.connect(.claude, key: "sk-test")) }
        return store
    }

    private func client(for state: String) -> FakeAIClient {
        switch state {
        case "running": FakeAIClient(.suspend)
        case "marks": FakeAIClient(.reply(#"{"sentences":[2]}"#))
        default: FakeAIClient(FakeAIClient.revising { _, segment in segment.uppercased() })
        }
    }

    private func makeAI(client: FakeAIClient) throws -> (SelectionController, AIActionController, LineformTextView) {
        let store = try makeStore(connected: true)
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        let selection = SelectionController(connectionStore: { store }, aiController: ai)
        let editor = makeEditor("One short line. Two is here. Three ends it.\n")
        selection.attach(editor)
        return (selection, ai, editor)
    }

    /// Puts the AI in `state`: running, message, marks or review.
    private func drive(_ state: String, ai: AIActionController, editor: LineformTextView,
                       selection: SelectionController) async throws {
        let range = NSRange(location: 0, length: 43)
        editor.selectedRange = range
        switch state {
        case "message":
            ai.refuseWholeDocument()
        case "marks":
            ai.run(.markWeakest, range: range, text: editor.string)
        default:
            ai.run(.rephrase, range: range, text: editor.string)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            switch (state, selection.aiState) {
            case ("running", .running), ("message", .message), ("marks", .marking), ("review", .reviewing): return
            default: try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTFail("the AI never reached \(state): \(selection.aiState)")
    }
}
