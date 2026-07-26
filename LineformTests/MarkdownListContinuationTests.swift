import AppKit
import XCTest
@testable import Lineform

final class MarkdownListContinuationTests: XCTestCase {
    private func outcome(
        _ text: String,
        _ location: Int,
        length: Int = 0
    ) -> MarkdownListContinuation.Outcome? {
        MarkdownListContinuation.outcome(
            for: text,
            selectedRange: NSRange(location: location, length: length)
        )
    }

    // MARK: - Bullets

    func testContinuesHyphenBullet() {
        XCTAssertEqual(outcome("- milk", 6), .continue(insertion: "\n- "))
    }

    func testPreservesAsteriskBulletCharacter() {
        XCTAssertEqual(outcome("* milk", 6), .continue(insertion: "\n* "))
    }

    func testPreservesPlusBulletCharacter() {
        XCTAssertEqual(outcome("+ milk", 6), .continue(insertion: "\n+ "))
    }

    func testPreservesLeadingIndentation() {
        XCTAssertEqual(outcome("    - nested", 12), .continue(insertion: "\n    - "))
    }

    func testHorizontalRuleIsNotABullet() {
        XCTAssertNil(outcome("---", 3))
    }

    func testHyphenWithoutSpaceIsNotABullet() {
        XCTAssertNil(outcome("-word", 5))
    }

    // MARK: - Ordered items

    func testIncrementsOrderedItem() {
        XCTAssertEqual(outcome("3. third", 8), .continue(insertion: "\n4. "))
    }

    func testOrderedItemRollsOverToTwoDigits() {
        XCTAssertEqual(outcome("9. ninth", 8), .continue(insertion: "\n10. "))
    }

    func testPreservesParenthesisSeparator() {
        XCTAssertEqual(outcome("3) third", 8), .continue(insertion: "\n4) "))
    }

    func testDoesNotRenumberItemsBelowTheCaret() {
        // Increment-only by design: the "2." below stays "2." and GFM still renders 1, 2, 3.
        let text = "1. first\n2. second"
        XCTAssertEqual(outcome(text, 8), .continue(insertion: "\n2. "))
    }

    // MARK: - Task checkboxes

    func testContinuesUncheckedCheckbox() {
        XCTAssertEqual(outcome("- [ ] todo", 10), .continue(insertion: "\n- [ ] "))
    }

    func testCheckedCheckboxContinuesUnchecked() {
        XCTAssertEqual(outcome("- [x] done", 10), .continue(insertion: "\n- [ ] "))
    }

    func testUppercaseCheckedCheckboxContinuesUnchecked() {
        XCTAssertEqual(outcome("- [X] done", 10), .continue(insertion: "\n- [ ] "))
    }

    // MARK: - Blockquotes

    func testContinuesBlockquote() {
        XCTAssertEqual(outcome("> quoted", 8), .continue(insertion: "\n> "))
    }

    func testContinuesNestedBlockquote() {
        XCTAssertEqual(outcome("> > deeply quoted", 17), .continue(insertion: "\n> > "))
    }

    func testContinuesListInsideBlockquote() {
        XCTAssertEqual(outcome("> - item", 8), .continue(insertion: "\n> - "))
    }

    // MARK: - Termination

    func testEmptyBulletTerminates() {
        XCTAssertEqual(outcome("- ", 2), .terminate(clearing: NSRange(location: 0, length: 2)))
    }

    func testEmptyOrderedItemTerminates() {
        XCTAssertEqual(outcome("1. ", 3), .terminate(clearing: NSRange(location: 0, length: 3)))
    }

    func testEmptyCheckboxTerminates() {
        XCTAssertEqual(outcome("- [ ] ", 6), .terminate(clearing: NSRange(location: 0, length: 6)))
    }

    func testEmptyBlockquoteTerminates() {
        XCTAssertEqual(outcome("> ", 2), .terminate(clearing: NSRange(location: 0, length: 2)))
    }

    func testEmptyNestedBulletClearsTheWholeLineIncludingIndent() {
        XCTAssertEqual(outcome("    - ", 6), .terminate(clearing: NSRange(location: 0, length: 6)))
    }

    func testTerminationClearsOnlyTheCurrentLine() {
        let text = "- milk\n- "
        XCTAssertEqual(outcome(text, 9), .terminate(clearing: NSRange(location: 7, length: 2)))
    }

    // MARK: - Caret and selection

    func testCaretBeforeMarkerDoesNotContinue() {
        XCTAssertNil(outcome("- milk", 0))
    }

    func testCaretInsideMarkerDoesNotContinue() {
        XCTAssertNil(outcome("- milk", 1))
    }

    func testCaretMidLineSplitsAndContinues() {
        XCTAssertEqual(outcome("- milk", 4), .continue(insertion: "\n- "))
    }

    func testNonEmptySelectionContinues() {
        XCTAssertEqual(outcome("- milk world", 2, length: 4), .continue(insertion: "\n- "))
    }

    func testNonEmptySelectionNeverTerminates() {
        // A selection is about to be replaced; clearing a range it does not cover would
        // delete text the writer never selected.
        XCTAssertEqual(outcome("- ", 2, length: 0), .terminate(clearing: NSRange(location: 0, length: 2)))
        if case .terminate = outcome("- milk", 2, length: 4) {
            XCTFail("A non-empty selection must never terminate the list")
        }
    }

    func testContinuesOnASecondLine() {
        let text = "intro\n- milk"
        XCTAssertEqual(outcome(text, 12), .continue(insertion: "\n- "))
    }

    // MARK: - Suppression

    func testSuppressedInsideUnclosedFencedCode() {
        XCTAssertNil(outcome("```\n- milk", 10))
    }

    func testSuppressedInsideClosedFencedCode() {
        let text = "```\n- milk\n```"
        XCTAssertNil(outcome(text, 10))
    }

    func testNotSuppressedAfterAClosedFence() {
        let text = "```\ncode\n```\n- milk"
        XCTAssertEqual(outcome(text, 19), .continue(insertion: "\n- "))
    }

    func testSuppressedInsideFrontMatter() {
        let text = "---\n- a\n---\n"
        XCTAssertNil(outcome(text, 7))
    }

    func testNotSuppressedAfterFrontMatter() {
        let text = "---\ntitle: x\n---\n- item"
        XCTAssertEqual(outcome(text, 23), .continue(insertion: "\n- "))
    }

    // MARK: - Non-list lines

    func testPlainProseReturnsNil() {
        XCTAssertNil(outcome("hello", 5))
    }

    func testHeadingReturnsNil() {
        XCTAssertNil(outcome("# Title", 7))
    }

    func testEmptyTextReturnsNil() {
        XCTAssertNil(outcome("", 0))
    }

    func testEmptyLineReturnsNil() {
        XCTAssertNil(outcome("- milk\n", 7))
    }

    func testOutOfBoundsRangeReturnsNil() {
        XCTAssertNil(outcome("- milk", 99))
    }

    // MARK: - Text view integration

    /// Vends an `UndoManager` the way `MarkdownTextViewRepresentable.undoManager(for:)` does in
    /// production. Without it a windowless `NSTextView` resolves `undoManager` through the
    /// responder chain, finds nothing, and silently registers no undo actions at all.
    private final class UndoManagerVendor: NSObject, NSTextViewDelegate {
        let manager: UndoManager

        override init() {
            manager = UndoManager()
            super.init()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            manager
        }
    }

    private func makeTextView(_ text: String, caret: Int) -> LineformTextView {
        let textView = LineformTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    func testReturnInsertsContinuationMarkerInTextView() {
        let textView = makeTextView("- milk", caret: 6)

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "- milk\n- ")
        XCTAssertEqual(textView.selectedRange().location, 9)
    }

    func testReturnOnEmptyMarkerClearsItInTextView() {
        let textView = makeTextView("- milk\n- ", caret: 9)

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "- milk\n")
        XCTAssertEqual(textView.selectedRange().location, 7)
    }

    func testReturnOnProseStillInsertsAPlainNewline() {
        let textView = makeTextView("hello", caret: 5)

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "hello\n")
    }

    func testReturnContinuationIsASingleUndoStep() {
        let vendor = UndoManagerVendor()
        let textView = makeTextView("- milk", caret: 6)
        textView.delegate = vendor

        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- milk\n- ")

        XCTAssertTrue(vendor.manager.canUndo, "The continuation registered no undo action")
        vendor.manager.undo()

        XCTAssertEqual(textView.string, "- milk", "One undo must remove the newline and its marker together")
        XCTAssertFalse(vendor.manager.canUndo, "The continuation must be ONE undo step, not two")
    }

    func testTerminationIsASingleUndoStep() {
        let vendor = UndoManagerVendor()
        let textView = makeTextView("- milk\n- ", caret: 9)
        textView.delegate = vendor

        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- milk\n")

        vendor.manager.undo()

        XCTAssertEqual(textView.string, "- milk\n- ")
        XCTAssertFalse(vendor.manager.canUndo, "Clearing an empty marker must be ONE undo step")
    }

    // MARK: - Large documents

    /// 4,000 lines of mixed prose and list items, ~730 KB.
    private static let largeDocument: String = {
        let paragraph = String(repeating: "Some ordinary prose about writing calmly. ", count: 5)
        var lines: [String] = (0..<4000).map { $0 % 7 == 0 ? "- item \($0)" : paragraph }
        lines.append("- final item")
        return lines.joined(separator: "\n")
    }()

    func testContinuesCorrectlyAtTheEndOfALargeDocument() {
        let text = Self.largeDocument
        let caret = (text as NSString).length

        XCTAssertEqual(
            MarkdownListContinuation.outcome(for: text, selectedRange: NSRange(location: caret, length: 0)),
            .continue(insertion: "\n- ")
        )
    }

    func testSuppressionStillWorksInAFenceLateInALargeDocument() {
        let text = Self.largeDocument + "\n```\n- inside code"
        let caret = (text as NSString).length

        XCTAssertNil(MarkdownListContinuation.outcome(
            for: text,
            selectedRange: NSRange(location: caret, length: 0)
        ))
    }

    /// Guards the reason `isInsideCodeOrFrontMatter` exists instead of `ignoredRanges`: the
    /// latter runs a per-line inline-math regex over the whole document and measured 18 ms on
    /// this input, against ~1 ms here. No hard threshold — wall-clock assertions are flaky
    /// under CI load — but a regression shows up immediately in the benchmark.
    func testBenchmarkReturnOnAListLineInALargeDocument() {
        let text = Self.largeDocument
        let caret = (text as NSString).length

        measure(metrics: [XCTClockMetric()]) {
            _ = MarkdownListContinuation.outcome(for: text, selectedRange: NSRange(location: caret, length: 0))
        }
    }
}
