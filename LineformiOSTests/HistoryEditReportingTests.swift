import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The editor tells History about every character change through ONE text-storage hook, in
/// pre-change coordinates; History's own edits are never reported back; a whole-text set or an
/// edit over 1 000 UTF-16 units is a whole-text replacement; typing in History mode leaves it.
/// Real `LineformTextView`s, built through `make(profile:)`.
@MainActor
final class HistoryEditReportingTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let sentence = "Alpha beta gamma delta."
    private let accepted = "Alpha BETA gamma delta."
    private var window: UIWindow?
    private var coordinator: MarkdownEditor.Coordinator?
    private var boundText = ""

    override func tearDown() {
        window?.isHidden = true
        window = nil
        coordinator = nil
        super.tearDown()
    }

    func testTypingInsideAPassageGrowsIt() throws {
        let (controller, textView) = makeEditorWithPassage(prefix: "")
        let at = (textView.text as NSString).range(of: "BETA")
        textView.applyRuleEdit(replacing: NSRange(location: NSMaxRange(at), length: 0), with: "X")

        XCTAssertTrue(controller.enterHistoryMode(text: textView.text), "the edited passage is still found")
        let passage = try XCTUnwrap(controller.located.first)
        XCTAssertEqual((textView.text as NSString).substring(with: passage.range), "Alpha BETAX gamma delta.",
                       "the passage grew with the typing (a literal search could not have found it)")
    }

    /// Minor 5: an edit reported over a wide range (an undo, a grouped rule edit) whose text only
    /// changed outside the passage is trimmed to the minimal span first, so it no longer straddles
    /// the passage and the passage survives (the Mac's `HistoryUndoCollapse.minimalEdit` rule).
    func testAWideEditIsTrimmedToWhatChanged() throws {
        let (controller, textView) = makeEditorWithPassage(prefix: "")
        let text = textView.text as NSString
        let wholeTextReports = controller.wholeTextReplacementCountForTesting
        XCTAssertTrue(controller.hasHistory)
        textView.applyRuleEdit(replacing: NSRange(location: 0, length: text.length),
                               with: text.replacingOccurrences(of: "Epsilon", with: "Epsilons"))
        XCTAssertEqual(textView.text, "Alpha BETA gamma delta. Epsilons.")
        XCTAssertEqual(controller.wholeTextReplacementCountForTesting, wholeTextReports, "trimmed, not a whole-text report")
        XCTAssertTrue(controller.hasHistory, "the trimmed edit does not straddle the only passage")
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        let passage = try XCTUnwrap(controller.located.first)
        XCTAssertEqual((textView.text as NSString).substring(with: passage.range), accepted)
    }

    func testReturnContinuationMovesPassagesAfterIt() throws {
        let (controller, textView) = makeEditorWithPassage(prefix: "- item\n")
        let before = controller.reportedEditCountForTesting
        // Return at the end of "- item": the list continues ("\n- ").
        textView.selectedRange = NSRange(location: 6, length: 0)
        XCTAssertTrue(textView.handlesChange(in: textView.selectedRange, replacementText: "\n"))
        XCTAssertEqual(textView.text, "- item\n- \nAlpha BETA gamma delta. Epsilon.")
        XCTAssertEqual(controller.reportedEditCountForTesting, before + 1, "the rule edit was reported once")

        // Typing inside the moved passage only lands on it if its live range moved too.
        let at = (textView.text as NSString).range(of: "BETA")
        textView.applyRuleEdit(replacing: NSRange(location: NSMaxRange(at), length: 0), with: "X")
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        let passage = try XCTUnwrap(controller.located.first)
        XCTAssertEqual(passage.range.location, 10)
        XCTAssertEqual((textView.text as NSString).substring(with: passage.range), "Alpha BETAX gamma delta.")
    }

    func testUndoOfATypedEditIsReported() throws {
        let (controller, textView) = makeEditorWithPassage(prefix: "")
        let undo = try XCTUnwrap(textView.undoManager)
        let at = NSMaxRange((textView.text as NSString).range(of: "BETA"))
        textView.applyRuleEdit(replacing: NSRange(location: at, length: 0), with: "X")
        settle()
        textView.applyRuleEdit(replacing: NSRange(location: at + 1, length: 0), with: "Y")
        settle()
        let before = controller.reportedEditCountForTesting

        undo.undo()

        XCTAssertEqual(controller.reportedEditCountForTesting, before + 1, "the undo is an edit History hears")
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        let passage = try XCTUnwrap(controller.located.first)
        XCTAssertEqual((textView.text as NSString).substring(with: passage.range), "Alpha BETAX gamma delta.")
    }

    func testSetDocumentTextReportsAWholeTextReplacement() {
        let (controller, textView) = makeEditorWithPassage(prefix: "")
        let edits = controller.reportedEditCountForTesting
        let wholes = controller.wholeTextReplacementCountForTesting

        textView.setDocumentText("Something else entirely.")

        XCTAssertEqual(controller.wholeTextReplacementCountForTesting, wholes + 1)
        XCTAssertEqual(controller.reportedEditCountForTesting, edits, "not reported as an edit")
    }

    func testHistoryOwnEditIsNotReported() throws {
        let (controller, textView) = makeEditorWithPassage(prefix: "Intro. ")
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        let id = try XCTUnwrap(controller.located.first?.id)
        controller.select(id)
        let edits = controller.reportedEditCountForTesting

        let edit = try XCTUnwrap(controller.step(by: -1, text: textView.text))

        XCTAssertEqual(controller.reportedEditCountForTesting, edits, "History's own edit is not reported back")
        XCTAssertEqual(textView.text, "Intro. Alpha beta gamma delta. Epsilon.")
        let passage = try XCTUnwrap(controller.located.first)
        XCTAssertEqual(passage.range, NSRange(location: edit.range.location, length: (sentence as NSString).length),
                       "the live range moved once, by the engine")
        XCTAssertTrue(controller.isHistoryModeActive)
    }

    func testLongEditReportsAWholeTextReplacement() {
        let (controller, textView) = makeEditorWithPassage(prefix: "")
        let edits = controller.reportedEditCountForTesting
        let wholes = controller.wholeTextReplacementCountForTesting
        let end = (textView.text as NSString).length

        textView.applyRuleEdit(replacing: NSRange(location: end, length: 0), with: String(repeating: "x", count: 1001))

        XCTAssertEqual(controller.wholeTextReplacementCountForTesting, wholes + 1)
        XCTAssertEqual(controller.reportedEditCountForTesting, edits)
    }

    func testTypingInHistoryModeExitsFirstThenTypes() throws {
        let (controller, textView) = makeEditorWithPassage(prefix: "")
        let editor = MarkdownEditor(
            text: Binding(get: { [unowned self] in boundText }, set: { [unowned self] in boundText = $0 }),
            profile: .original
        )
        let coordinator = editor.makeCoordinator()
        self.coordinator = coordinator
        textView.delegate = coordinator
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        controller.select(controller.located.first?.id)
        controller.step(by: -1, text: textView.text)
        XCTAssertFalse(try XCTUnwrap(textView.undoManager).canUndo, "History mode vends an empty undo manager")
        settle()

        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: end, replacementText: "!"))

        XCTAssertFalse(controller.isHistoryModeActive, "typing leaves History mode first")
        XCTAssertEqual(textView.text, "Alpha beta gamma delta. Epsilon.", "the session's text stays")
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo, "the collapse is on the real stack")
    }

    // MARK: - Helpers

    /// `prefix` + "Alpha BETA gamma delta. Epsilon." in an editor, with the sentence recorded as a
    /// two-version passage ("beta" → "BETA").
    private func makeEditorWithPassage(prefix: String) -> (PhoneHistoryController, LineformTextView) {
        let original = prefix + "Alpha beta gamma delta. Epsilon."
        let date = fixedDate
        let controller = PhoneHistoryController(store: MemoryHistoryStore(), now: { date },
                                                pruneQueue: DispatchQueue(label: "HistoryEditReportingTests"))
        controller.open(url: nil, text: original)
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText(original)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            host.view.addSubview(textView)
            window.isHidden = false
            self.window = window
        }
        controller.attach(textView)
        let beta = (textView.text as NSString).range(of: "beta")
        textView.applyRuleEdit(replacing: beta, with: "BETA")
        let edited = textView.text ?? ""
        let range = (edited as NSString).range(of: accepted)
        controller.recordAccepted(range: range, original: sentence, accepted: accepted, text: edited)
        textView.undoManager?.removeAllActions()
        settle()
        return (controller, textView)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
