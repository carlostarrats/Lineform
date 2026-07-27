import AppKit
import XCTest
@testable import Lineform

final class MarkdownHeadingEditingTests: XCTestCase {

    // MARK: - Line classification

    func testClassifiesPlainProseAsEditableAtBodyLevel() {
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "Lineform"),
            .editable(indent: "", level: nil, contentOffset: 0)
        )
    }

    func testClassifiesHeadingWithItsLevelAndContentOffset() {
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "### Notes"),
            .editable(indent: "", level: 3, contentOffset: 4)
        )
    }

    /// `MarkdownHeadingParser.heading(in:)` returns nil here because the title is empty.
    /// Treating it as prose would prepend a second marker and yield `"## ## "`.
    func testClassifiesEmptyHeadingMarkerAsAHeading() {
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "##"),
            .editable(indent: "", level: 2, contentOffset: 2)
        )
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "## "),
            .editable(indent: "", level: 2, contentOffset: 3)
        )
    }

    func testSevenHashesIsNotAHeading() {
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "####### Notes"),
            .editable(indent: "", level: nil, contentOffset: 0)
        )
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "#Notes"),
            .editable(indent: "", level: nil, contentOffset: 0)
        )
    }

    func testPreservesUpToThreeColumnsOfIndent() {
        XCTAssertEqual(
            MarkdownHeadingEditing.classify(line: "  ## Notes"),
            .editable(indent: "  ", level: 2, contentOffset: 5)
        )
    }

    /// The OPENING fence is not "inside" the block it opens, so it needs its own line-local
    /// skip or it takes a marker and breaks the block.
    func testFenceDelimitersAreSkipped() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "```"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "```swift"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "~~~"), .skipped)
    }

    func testFourSpacesIsAnIndentedCodeBlock() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "    let x = 1"), .skipped)
    }

    /// A tab is four columns, so one tab already opens an indented code block.
    func testATabIndentIsAnIndentedCodeBlock() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "\tlet x = 1"), .skipped)
    }

    func testSkipsProtectedLinesWithoutRescanningPerLine() {
        let text = """
        ---
        title: Notes
        ---
        Intro
        """
        let edit = MarkdownHeadingEditing.setLevel(
            2,
            in: text,
            selectedRange: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(edit?.text, """
        ---
        title: Notes
        ---
        ## Intro
        """)
    }

    func testBlankLineIsSkipped() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: ""), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "   "), .skipped)
    }

    func testListItemsAndBlockquotesAreSkipped() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "- groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "* groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "+ groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "1. groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "- [ ] groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "> quoted"), .skipped)
    }

    // MARK: - Setting a level

    /// The contract the shipped Title command already had: the selection stays on the text.
    func testSetsLevelOnProseAndKeepsTheTextSelected() {
        let edit = MarkdownHeadingEditing.setLevel(1, in: "Lineform", selectedRange: NSRange(location: 0, length: 8))
        XCTAssertEqual(edit?.text, "# Lineform")
        XCTAssertEqual(edit?.selectedRange, NSRange(location: 2, length: 8))
    }

    /// Regression: the shipped `prefixSelection` produced `"# ## Section"`, which is not a
    /// heading in any dialect and which `MarkdownHeadingParser` cannot see — the line silently
    /// disappeared from the outline sidebar.
    func testChangesTheLevelOfAnExistingHeadingInsteadOfStacking() {
        let edit = MarkdownHeadingEditing.setLevel(1, in: "## Section", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.text, "# Section")
    }

    /// Regression: the outline parser reports nil for an empty heading, so reusing it here
    /// would yield `"### ## "`.
    func testDoesNotStackOnAnEmptyHeadingMarker() {
        let edit = MarkdownHeadingEditing.setLevel(3, in: "## ", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(edit?.text, "### ")
    }

    func testRepeatingTheCurrentLevelTogglesToBody() {
        let edit = MarkdownHeadingEditing.setLevel(2, in: "## Notes", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.text, "Notes")
    }

    func testBodyStripsAnyLevel() {
        for level in 1...MarkdownHeadingEditing.maximumLevel {
            let text = String(repeating: "#", count: level) + " Notes"
            let edit = MarkdownHeadingEditing.setLevel(nil, in: text, selectedRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(edit?.text, "Notes", "level \(level)")
        }
    }

    /// Regression: `prefixSelection` inserted `"# "` at the caret, splitting the word.
    func testCaretMidWordIsPreservedAndNoMarkerIsInsertedMidLine() {
        let edit = MarkdownHeadingEditing.setLevel(1, in: "Lineform", selectedRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.text, "# Lineform")
        XCTAssertEqual(edit?.selectedRange, NSRange(location: 6, length: 0))
    }

    func testCaretInsideTheMarkersIsClampedToTheContentStart() {
        let edit = MarkdownHeadingEditing.setLevel(nil, in: "## Notes", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(edit?.text, "Notes")
        XCTAssertEqual(edit?.selectedRange, NSRange(location: 0, length: 0))
    }

    func testSkipsNonProseLinesInAMixedSelection() {
        let text = """
        Intro
        - groceries
        > quoted
        ```
        let x = 1
        ```
        Outro
        """
        let edit = MarkdownHeadingEditing.setLevel(
            2,
            in: text,
            selectedRange: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(edit?.text, """
        ## Intro
        - groceries
        > quoted
        ```
        let x = 1
        ```
        ## Outro
        """)
    }

    func testTogglesAllOrNothingAcrossAMultiLineSelection() {
        let mixed = "## One\nTwo"
        let raised = MarkdownHeadingEditing.setLevel(
            2,
            in: mixed,
            selectedRange: NSRange(location: 0, length: (mixed as NSString).length)
        )
        XCTAssertEqual(raised?.text, "## One\n## Two")

        let uniform = "## One\n## Two"
        let cleared = MarkdownHeadingEditing.setLevel(
            2,
            in: uniform,
            selectedRange: NSRange(location: 0, length: (uniform as NSString).length)
        )
        XCTAssertEqual(cleared?.text, "One\nTwo")
    }

    func testReturnsNilWhenNothingWouldChange() {
        XCTAssertNil(MarkdownHeadingEditing.setLevel(nil, in: "Lineform", selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertNil(MarkdownHeadingEditing.setLevel(2, in: "- groceries", selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertNil(MarkdownHeadingEditing.setLevel(7, in: "Lineform", selectedRange: NSRange(location: 0, length: 0)))
    }

    func testPreservesIndentAndSelectionAcrossLines() {
        let text = "  One\nTwo"
        let edit = MarkdownHeadingEditing.setLevel(3, in: text, selectedRange: NSRange(location: 2, length: 7))
        XCTAssertEqual(edit?.text, "  ### One\n### Two")
        XCTAssertEqual(edit?.selectedRange, NSRange(location: 6, length: 11))
    }

    func testSkipsAHeadingInsideAFencedBlock() {
        let text = "```\n## not a heading\n```"
        XCTAssertNil(MarkdownHeadingEditing.setLevel(3, in: text, selectedRange: NSRange(location: 6, length: 0)))
    }

    func testLeavesTheFinalLineWithoutATerminator() {
        let edit = MarkdownHeadingEditing.setLevel(1, in: "One\nTwo", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit?.text, "One\n# Two")
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

    func testEveryHeadingActionIsWiredToItsLevel() {
        let expected = [
            (#selector(LineformTextView.toggleTitleMarkdown(_:)), "# Notes"),
            (#selector(LineformTextView.toggleSectionMarkdown(_:)), "## Notes"),
            (#selector(LineformTextView.toggleHeading3Markdown(_:)), "### Notes"),
            (#selector(LineformTextView.toggleHeading4Markdown(_:)), "#### Notes"),
            (#selector(LineformTextView.toggleHeading5Markdown(_:)), "##### Notes"),
            (#selector(LineformTextView.toggleHeading6Markdown(_:)), "###### Notes"),
        ]

        for (selector, result) in expected {
            let textView = makeTextView("Notes", caret: 0)
            XCTAssertTrue(textView.responds(to: selector), "\(selector) is not implemented")
            textView.perform(selector, with: nil)
            XCTAssertEqual(textView.string, result, "\(selector)")
        }
    }

    func testBodyActionStripsTheHeading() {
        let textView = makeTextView("#### Notes", caret: 6)
        textView.toggleBodyMarkdown(nil)
        XCTAssertEqual(textView.string, "Notes")
    }

    func testChangingLevelIsASingleUndoStep() {
        let vendor = UndoManagerVendor()
        let textView = makeTextView("## Section", caret: 4)
        textView.delegate = vendor

        textView.toggleTitleMarkdown(nil)
        XCTAssertEqual(textView.string, "# Section")

        XCTAssertTrue(vendor.manager.canUndo, "The heading change registered no undo action")
        vendor.manager.undo()

        XCTAssertEqual(textView.string, "## Section")
        XCTAssertFalse(vendor.manager.canUndo, "Changing a heading level must be ONE undo step")
    }

    /// A keypress that would change nothing must not leave an empty step on the undo stack.
    func testANoOpRegistersNoUndoStep() {
        let vendor = UndoManagerVendor()
        let textView = makeTextView("- groceries", caret: 5)
        textView.delegate = vendor

        textView.toggleSectionMarkdown(nil)

        XCTAssertEqual(textView.string, "- groceries")
        XCTAssertFalse(vendor.manager.canUndo, "A no-op heading command registered an undo step")
    }
}
