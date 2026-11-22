import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The editing rules in the iPhone editor: list continuation on Return, table Tab, headings and
/// the formatting commands. Every rule edit is one undo step and reaches the binding (so
/// `OpenDocument` autosaves); a rule that changes nothing adds no undo step.
@MainActor
final class EditingRulesTests: XCTestCase {
    private var boundText = ""
    private var coordinator: MarkdownEditor.Coordinator!
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        coordinator = nil
        super.tearDown()
    }

    // MARK: - Return

    func testReturnContinuesBulletList() {
        let textView = makeEditor("- one")
        pressReturn(textView)
        XCTAssertEqual(textView.text, "- one\n- ")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(boundText, "- one\n- ", "the edit reaches the binding, so autosave sees it")
    }

    func testReturnOnEmptyItemEndsList() {
        let textView = makeEditor("- one\n- ")
        pressReturn(textView)
        XCTAssertEqual(textView.text, "- one\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(boundText, "- one\n")
    }

    func testReturnInCRLFDocumentInsertsCRLF() {
        let prose = makeEditor("Line one\r\nLine two")
        pressReturn(prose)
        XCTAssertEqual(prose.text, "Line one\r\nLine two\r\n", "a document with no list keeps its CRLF")
        XCTAssertEqual(boundText, "Line one\r\nLine two\r\n")

        let list = makeEditor("- a\r\n- b")
        pressReturn(list)
        XCTAssertEqual(list.text, "- a\r\n- b\r\n- ", "list continuation inserts CRLF, never a bare LF")
    }

    func testReturnInLFDocumentIsTheSystemNewline() {
        let textView = makeEditor("Plain prose")
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n"),
                      "an ordinary Return in an LF document is left to the system")
    }

    func testReturnInsideCodeFenceDoesNotContinue() {
        let textView = makeEditor("```\n- a")
        pressReturn(textView)
        XCTAssertEqual(textView.text, "```\n- a\n")
    }

    func testReturnDuringMarkedTextIsNotIntercepted() throws {
        let textView = makeEditor("- one")
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(textView.markedTextRange)
        let before = textView.text
        let undo = try XCTUnwrap(textView.undoManager)
        let couldUndo = undo.canUndo

        let allowed = coordinator.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n")

        XCTAssertTrue(allowed, "Return confirms the candidate; the system handles it")
        XCTAssertEqual(textView.text, before, "no list continuation mid-composition")
        XCTAssertNotNil(textView.markedTextRange, "the composition is untouched")
        XCTAssertEqual(undo.canUndo, couldUndo)
        textView.setHeadingLevel(1)
        textView.apply(.bold)
        XCTAssertEqual(textView.text, before, "no rule edits while composing")
    }

    // MARK: - Tables

    func testTabMovesToNextCellAndReformats() throws {
        let table = "| a | b |\n| --- | --- |\n| c | d |"
        let textView = makeEditor(table)
        textView.selectedRange = NSRange(location: 2, length: 0) // in cell "a"
        let undo = try XCTUnwrap(textView.undoManager)
        settle()

        XCTAssertTrue(textView.canPerformAction(#selector(LineformTextView.tableTabForward(_:)), withSender: nil))
        textView.tableTabForward(nil)
        XCTAssertEqual((table as NSString).substring(with: textView.selectedRange), "b", "Tab selects the next cell")
        XCTAssertFalse(undo.canUndo, "moving between cells edits nothing")

        textView.tableTabBackward(nil)
        XCTAssertEqual((table as NSString).substring(with: textView.selectedRange), "a", "Shift-Tab goes back")

        textView.selectedRange = NSRange(location: (table as NSString).length - 2, length: 0) // in "d"
        textView.tableTabForward(nil)
        XCTAssertTrue(textView.text.hasPrefix(table + "\n|"), "Tab off the last cell appends a row")
        XCTAssertEqual(boundText, textView.text)
        settle()
        undo.undo()
        XCTAssertEqual(textView.text, table, "the new row is one undo step")

        let ragged = "| a | bbbb |\n| - | - |\n| cc | d |"
        let reformat = makeEditor(ragged)
        reformat.selectedRange = NSRange(location: 2, length: 0)
        reformat.reformatTable()
        let lines = reformat.text.components(separatedBy: "\n")
        XCTAssertEqual(Set(lines.map { ($0 as NSString).length }).count, 1, "Reformat aligns every row: \(lines)")
        XCTAssertEqual(boundText, reformat.text)
    }

    func testTabOutsideTableIsDefault() {
        let textView = makeEditor("Just prose")
        XCTAssertFalse(textView.canPerformAction(#selector(LineformTextView.tableTabForward(_:)), withSender: nil),
                       "outside a table the Tab key command declines, so Tab inserts a tab as usual")
        XCTAssertFalse(textView.canPerformAction(#selector(LineformTextView.tableTabBackward(_:)), withSender: nil))
        let tab = textView.keyCommands?.first { $0.input == "\t" && $0.modifierFlags.isEmpty }
        XCTAssertNotNil(tab, "Tab is a key command, never a raw key handler")
        XCTAssertEqual(tab?.wantsPriorityOverSystemBehavior, true)
    }

    func testReformatOutsideTableAddsNoUndo() throws {
        let textView = makeEditor("Just prose")
        let undo = try XCTUnwrap(textView.undoManager)
        settle()
        textView.reformatTable()
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(textView.text, "Just prose")
    }

    // MARK: - Headings and formatting

    func testHeadingLevelNoOpAddsNoUndo() throws {
        let textView = makeEditor("Title")
        let undo = try XCTUnwrap(textView.undoManager)
        settle()
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: Self.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        textView.setHeadingLevel(nil) // body text is already body text

        XCTAssertEqual(textView.text, "Title")
        XCTAssertFalse(undo.canUndo, "a heading edit that changes nothing adds no undo step")
        XCTAssertEqual(changes, 0, "and posts no change")

        let list = makeEditor("- item")
        let listUndo = try XCTUnwrap(list.undoManager)
        settle()
        list.setHeadingLevel(2) // a list line is left alone
        XCTAssertEqual(list.text, "- item")
        XCTAssertFalse(listUndo.canUndo)
        XCTAssertEqual(changes, 0)

        let heading = makeEditor("Title")
        let headingUndo = try XCTUnwrap(heading.undoManager)
        settle()
        heading.setHeadingLevel(2)
        XCTAssertEqual(heading.text, "## Title")
        XCTAssertEqual(changes, 1)
        settle()
        headingUndo.undo()
        XCTAssertEqual(heading.text, "Title")
    }

    func testBoldCommandWrapsSelection() {
        let textView = makeEditor("make this bold")
        textView.selectedRange = NSRange(location: 5, length: 4)
        textView.apply(.bold)
        XCTAssertEqual(textView.text, "make **this** bold")
        XCTAssertEqual((textView.text as NSString).substring(with: textView.selectedRange), "this", "the word stays selected")
        XCTAssertEqual(boundText, "make **this** bold")
    }

    func testKeyCommandsMatchTheMacShortcuts() {
        let textView = makeEditor("")
        let commands = textView.keyCommands ?? []
        func has(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> Bool {
            commands.contains { $0.input == input && $0.modifierFlags == flags && $0.action == action }
        }
        XCTAssertTrue(has("b", .command, #selector(LineformTextView.toggleBoldMarkdown(_:))))
        XCTAssertTrue(has("i", .command, #selector(LineformTextView.toggleItalicMarkdown(_:))))
        XCTAssertTrue(has("`", .command, #selector(LineformTextView.toggleInlineCodeMarkdown(_:))))
        XCTAssertTrue(has("x", [.command, .shift], #selector(LineformTextView.toggleStrikethroughMarkdown(_:))))
        XCTAssertTrue(has("1", .command, #selector(LineformTextView.toggleTitleMarkdown(_:))))
        XCTAssertTrue(has("2", .command, #selector(LineformTextView.toggleSectionMarkdown(_:))))
        XCTAssertTrue(has("6", .command, #selector(LineformTextView.toggleHeading6Markdown(_:))))
        XCTAssertTrue(has("0", .command, #selector(LineformTextView.toggleBodyMarkdown(_:))))
        XCTAssertTrue(has("t", [.command, .control], #selector(LineformTextView.insertMarkdownTable(_:))))
        XCTAssertTrue(has("r", [.command, .control], #selector(LineformTextView.reformatMarkdownTable(_:))))
        XCTAssertTrue(commands.filter { $0.input != "\t" }.allSatisfy { $0.wantsPriorityOverSystemBehavior })
    }

    func testEachRuleIsOneUndoStep() throws {
        let textView = makeEditor("one")
        let undo = try XCTUnwrap(textView.undoManager)
        settle()

        textView.setHeadingLevel(2)
        XCTAssertEqual(textView.text, "## one")
        settle()
        textView.selectedRange = NSRange(location: 3, length: 3)
        textView.apply(.italic)
        XCTAssertEqual(textView.text, "## _one_")
        settle()

        undo.undo()
        XCTAssertEqual(textView.text, "## one", "one undo reverses the italic")
        XCTAssertEqual(boundText, "## one", "undo reaches the binding too")
        settle()
        undo.undo()
        XCTAssertEqual(textView.text, "one", "one undo reverses the heading")
        settle()
        undo.redo()
        XCTAssertEqual(textView.text, "## one")
        settle()
        undo.redo()
        XCTAssertEqual(textView.text, "## _one_")

        let list = makeEditor("- one")
        let listUndo = try XCTUnwrap(list.undoManager)
        settle()
        pressReturn(list)
        XCTAssertEqual(list.text, "- one\n- ")
        settle()
        listUndo.undo()
        XCTAssertEqual(list.text, "- one", "one undo reverses the newline and its marker together")
        XCTAssertEqual(boundText, "- one")
    }

    // MARK: - Helpers

    private static let didChange = Notification.Name("EditingRulesTests.didChange")

    /// An editor wired to the real `MarkdownEditor.Coordinator`, whose binding writes `boundText`.
    private func makeEditor(_ text: String) -> LineformTextView {
        boundText = text
        let binding = Binding<String>(
            get: { [unowned self] in boundText },
            set: { [unowned self] in
                boundText = $0
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        )
        let editor = MarkdownEditor(text: binding, profile: .original)
        let coordinator = editor.makeCoordinator()
        self.coordinator = coordinator
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText(text)
        textView.delegate = coordinator
        // In a window and first responder, as while typing.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window?.isHidden = true
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            host.view.addSubview(textView)
            window.isHidden = false
            self.window = window
            textView.becomeFirstResponder()
        }
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textView.undoManager?.removeAllActions()
        return textView
    }

    /// Return as the keyboard delivers it: the delegate is asked first, and the system inserts
    /// the newline only when the delegate allows it. (`insertText` alone skips the delegate.)
    private func pressReturn(_ textView: LineformTextView) {
        if coordinator.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n") {
            textView.insertText("\n")
        }
    }

    /// Lets the run loop close the undo manager's per-event group, as between two keystrokes.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
