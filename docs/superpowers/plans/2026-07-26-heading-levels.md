# Heading Levels 1–6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make heading level something set on a line — fixing the shipped ⌘1/⌘2 stacking and mid-line bugs — and expose levels 3–6 plus a return to body text.

**Architecture:** One new pure unit, `MarkdownHeadingEditing`, computes a whole-text edit for "set these lines to level N (or body)". `MarkdownFormattingCommand` loses `.title` / `.section` / `prefixSelection` and gains `.heading(Int)` / `.body`, both routed through that unit. `LineformTextView` gains four `@objc` actions; `AppCommands` gains a Heading submenu.

**Tech Stack:** Swift, AppKit (`NSTextView`), SwiftUI `CommandMenu`, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-26-heading-levels-design.md`

## Global Constraints

- Pure logic stays AppKit-free so it runs in the DEFAULT test plan (`Lineform.xctestplan`). No `NSWindow`, no `NSTextView` in these tests.
- A no-op returns `nil` and never reaches `applyWholeTextReplacement` — an empty undo step is a defect (the `reformatMarkdownTable` precedent).
- One `applyWholeTextReplacement` per command, so one ⌘Z.
- Never call `MarkdownRangeAnalyzer.ranges(in:)` or `MarkdownWritingToolsProtection.ignoredRanges` — both whole-document. `isInsideCodeOrFrontMatter(location:in:)` is the allowed entry point.
- The Format menu is gated on `activeTextFormat == .markdown`; new rows go inside that gate.
- Every new main-menu row needs a `MainMenuIconDecorator.symbolsByTitle` entry (iconed-menu invariant).
- Existing labels `Title` (⌘1) and `Section` (⌘2) do not change text, position, or key.
- Verification command: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`

---

## File Structure

- **Create** `Lineform/Editor/MarkdownHeadingEditing.swift` — all heading-level logic. Pure.
- **Create** `LineformTests/MarkdownHeadingEditingTests.swift` — tests for the above.
- **Modify** `Lineform/Editor/MarkdownListContinuation.swift` — promote `LinePrefix` to internal.
- **Modify** `Lineform/Editor/MarkdownFormattingCommand.swift` — replace `.title`/`.section` with `.heading(Int)`/`.body`; delete `prefixSelection`.
- **Modify** `Lineform/Editor/LineformTextView.swift` — route existing actions, add four new ones.
- **Modify** `Lineform/App/AppCommands.swift` — Heading submenu.
- **Modify** `Lineform/App/MainMenuIconDecorator.swift` — symbols for new rows.
- **Modify** `LineformTests/MarkdownFormattingCommandTests.swift` — update the two heading call sites to the new case names; assertions stay identical.
- **Modify** `Lineform/Resources/Help.md`, `docs/architecture/editor-behavior.md`, `docs/research/2026-07-25-feature-backlog.md` — docs, final task.
- **Modify** `Lineform.xcodeproj/project.pbxproj` — register the two new files (hand-rolled IDs, 4 sections, sequential `1F0000xx`).

---

### Task 1: `MarkdownHeadingEditing` — line classification

**Files:**
- Create: `Lineform/Editor/MarkdownHeadingEditing.swift`
- Create: `LineformTests/MarkdownHeadingEditingTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location:in:) -> Bool`
- Produces: `MarkdownHeadingEditing.Line` (internal), `MarkdownHeadingEditing.classify(line:) -> Line`

- [ ] **Step 1: Write the failing tests**

In `LineformTests/MarkdownHeadingEditingTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MarkdownHeadingEditingTests: XCTestCase {
    func testClassifiesPlainProseAsEditableAtBodyLevel() {
        let line = MarkdownHeadingEditing.classify(line: "Lineform")
        XCTAssertEqual(line, .editable(indent: "", level: nil, contentOffset: 0))
    }

    func testClassifiesHeadingWithItsLevelAndContentOffset() {
        let line = MarkdownHeadingEditing.classify(line: "### Notes")
        XCTAssertEqual(line, .editable(indent: "", level: 3, contentOffset: 4))
    }

    func testClassifiesEmptyHeadingMarkerAsAHeading() {
        // MarkdownHeadingParser.heading(in:) returns nil here because the title is empty.
        // Treating it as prose would prepend a second marker and yield "## ## ".
        let line = MarkdownHeadingEditing.classify(line: "##")
        XCTAssertEqual(line, .editable(indent: "", level: 2, contentOffset: 2))
    }

    func testClassifiesEmptyHeadingMarkerWithTrailingSpaceAsAHeading() {
        let line = MarkdownHeadingEditing.classify(line: "## ")
        XCTAssertEqual(line, .editable(indent: "", level: 2, contentOffset: 3))
    }

    func testSevenHashesIsNotAHeading() {
        let line = MarkdownHeadingEditing.classify(line: "####### Notes")
        XCTAssertEqual(line, .editable(indent: "", level: nil, contentOffset: 0))
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let line = MarkdownHeadingEditing.classify(line: "#Notes")
        XCTAssertEqual(line, .editable(indent: "", level: nil, contentOffset: 0))
    }

    func testPreservesUpToThreeSpacesOfIndent() {
        let line = MarkdownHeadingEditing.classify(line: "  ## Notes")
        XCTAssertEqual(line, .editable(indent: "  ", level: 2, contentOffset: 5))
    }

    func testFourSpacesIsAnIndentedCodeBlock() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "    let x = 1"), .skipped)
    }

    func testBlankLineIsSkipped() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "   "), .skipped)
    }

    func testListItemsAndBlockquotesAreSkipped() {
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "- groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "* groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "1. groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "- [ ] groceries"), .skipped)
        XCTAssertEqual(MarkdownHeadingEditing.classify(line: "> quoted"), .skipped)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHeadingEditingTests`
Expected: FAIL — `cannot find 'MarkdownHeadingEditing' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Lineform/Editor/MarkdownHeadingEditing.swift`:

```swift
import Foundation

/// Setting the ATX heading level of the lines a selection touches.
///
/// Pure and AppKit-free so it tests in the default plan, matching `MarkdownListContinuation`
/// and `MarkdownTableEditing`.
///
/// Heading detection is deliberately LOCAL rather than reusing
/// `MarkdownHeadingParser.heading(in:)`: that parser requires a non-empty title, so it reports
/// `nil` for `"## "` — a heading whose text has not been typed yet. Treating that as prose
/// would prepend a second marker and produce `"## ## "`, which is the exact stacking bug this
/// type exists to remove. The two agree on every line that has content.
///
/// See `docs/superpowers/specs/2026-07-26-heading-levels-design.md`.
enum MarkdownHeadingEditing {
    /// The maximum ATX heading level. A seventh `#` is not a heading.
    static let maximumLevel = 6

    enum Line: Equatable {
        /// Blank, a list item, a blockquote, or an indented code block: left byte-identical.
        case skipped
        /// Prose or an existing heading. `level` is `nil` for body text. `contentOffset` is
        /// the NSString offset where the line's own text begins, after indent and marker.
        case editable(indent: String, level: Int?, contentOffset: Int)
    }

    static func classify(line: String) -> Line {
        let ns = line as NSString
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let hash = UInt16(UnicodeScalar("#").value)

        var cursor = 0
        while cursor < ns.length, ns.character(at: cursor) == space || ns.character(at: cursor) == tab {
            cursor += 1
        }

        // Blank, or an indented code block (4+ spaces of leading whitespace).
        guard cursor < ns.length, cursor < 4 else {
            return .skipped
        }

        // A list marker or blockquote arrow wins: those lines are never rewritten.
        if LinePrefix(line: line) != nil {
            return .skipped
        }

        let indent = ns.substring(with: NSRange(location: 0, length: cursor))

        var hashes = 0
        var scan = cursor
        while scan < ns.length, ns.character(at: scan) == hash {
            hashes += 1
            scan += 1
        }

        // A heading is 1...6 hashes followed by a space or the end of the line.
        if hashes > 0, hashes <= maximumLevel, scan == ns.length || ns.character(at: scan) == space {
            let contentOffset = scan < ns.length ? scan + 1 : scan
            return .editable(indent: indent, level: hashes, contentOffset: contentOffset)
        }

        return .editable(indent: indent, level: nil, contentOffset: cursor)
    }
}
```

- [ ] **Step 4: Register both files in the Xcode project**

`Lineform.xcodeproj/project.pbxproj` is hand-rolled (objectVersion 56, no synced groups). Add each file to all four sections with the next sequential `1F0000xx` IDs: `PBXBuildFile`, `PBXFileReference`, the group's `children`, and the target's `PBXSourcesBuildPhase`. Put `MarkdownHeadingEditing.swift` beside `MarkdownListContinuation.swift` in the Editor group and `MarkdownHeadingEditingTests.swift` in the LineformTests group.

- [ ] **Step 5: Promote `LinePrefix` to internal**

In `Lineform/Editor/MarkdownListContinuation.swift:86`, change `private struct LinePrefix` to `struct LinePrefix` and add to its doc comment:

```swift
/// Also used by `MarkdownHeadingEditing` to recognise the lines a heading command must not
/// touch — one definition of "what markers start a line", rather than two that can drift.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHeadingEditingTests`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add Lineform/Editor/MarkdownHeadingEditing.swift LineformTests/MarkdownHeadingEditingTests.swift Lineform/Editor/MarkdownListContinuation.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Classify lines for heading-level editing"
```

---

### Task 2: `setLevel` — the transform

**Files:**
- Modify: `Lineform/Editor/MarkdownHeadingEditing.swift`
- Modify: `LineformTests/MarkdownHeadingEditingTests.swift`

**Interfaces:**
- Consumes: `MarkdownHeadingEditing.classify(line:)`, `MarkdownEdit(text:selectedRange:)`
- Produces: `MarkdownHeadingEditing.setLevel(_ level: Int?, in text: String, selectedRange: NSRange) -> MarkdownEdit?`

- [ ] **Step 1: Write the failing tests**

Append to `LineformTests/MarkdownHeadingEditingTests.swift`:

```swift
extension MarkdownHeadingEditingTests {
    func testSetsLevelOnProseAndKeepsTheTextSelected() {
        // The contract the shipped Title command already had: selection stays on the text.
        let edit = MarkdownHeadingEditing.setLevel(1, in: "Lineform", selectedRange: NSRange(location: 0, length: 8))
        XCTAssertEqual(edit?.text, "# Lineform")
        XCTAssertEqual(edit?.selectedRange, NSRange(location: 2, length: 8))
    }

    func testChangesTheLevelOfAnExistingHeadingInsteadOfStacking() {
        // Regression: the shipped prefixSelection produced "# ## Section", which the outline
        // parser cannot see.
        let edit = MarkdownHeadingEditing.setLevel(1, in: "## Section", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.text, "# Section")
    }

    func testDoesNotStackOnAnEmptyHeadingMarker() {
        // Regression: MarkdownHeadingParser reports nil here, which would yield "## ## ".
        let edit = MarkdownHeadingEditing.setLevel(2, in: "## ", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNil(edit)
    }

    func testRepeatingTheCurrentLevelTogglesToBody() {
        let edit = MarkdownHeadingEditing.setLevel(2, in: "## Notes", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.text, "Notes")
    }

    func testBodyStripsAnyLevel() {
        for level in 1...6 {
            let text = String(repeating: "#", count: level) + " Notes"
            let edit = MarkdownHeadingEditing.setLevel(nil, in: text, selectedRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(edit?.text, "Notes", "level \(level)")
        }
    }

    func testCaretMidWordIsPreservedAndNoMarkerIsInsertedMidLine() {
        // Regression: prefixSelection inserted "# " at the caret, splitting the word.
        let edit = MarkdownHeadingEditing.setLevel(1, in: "Lineform", selectedRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.text, "# Lineform")
        XCTAssertEqual(edit?.selectedRange, NSRange(location: 6, length: 0))
    }

    func testCaretIsClampedToTheContentStartWhenMarkersAreRemoved() {
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
        let edit = MarkdownHeadingEditing.setLevel(2, in: text, selectedRange: NSRange(location: 0, length: (text as NSString).length))
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
        // One line is already H2, one is not: everything goes TO H2 rather than half-toggling.
        let text = "## One\nTwo"
        let edit = MarkdownHeadingEditing.setLevel(2, in: text, selectedRange: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(edit?.text, "## One\n## Two")

        let all = "## One\n## Two"
        let toggled = MarkdownHeadingEditing.setLevel(2, in: all, selectedRange: NSRange(location: 0, length: (all as NSString).length))
        XCTAssertEqual(toggled?.text, "One\nTwo")
    }

    func testReturnsNilWhenNothingWouldChange() {
        XCTAssertNil(MarkdownHeadingEditing.setLevel(nil, in: "Lineform", selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertNil(MarkdownHeadingEditing.setLevel(2, in: "- groceries", selectedRange: NSRange(location: 0, length: 0)))
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHeadingEditingTests`
Expected: FAIL — `type 'MarkdownHeadingEditing' has no member 'setLevel'`.

- [ ] **Step 3: Write the implementation**

Append inside `enum MarkdownHeadingEditing` in `Lineform/Editor/MarkdownHeadingEditing.swift`:

```swift
    /// The edit that sets every editable line the selection touches to `level`, or to body
    /// text when `level` is `nil`.
    ///
    /// Returns `nil` when nothing would change — no editable line, or every line already
    /// reads that way. Bailing here is what keeps a dead keypress out of the undo stack.
    static func setLevel(_ level: Int?, in text: String, selectedRange: NSRange) -> MarkdownEdit? {
        let ns = text as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= ns.length else {
            return nil
        }
        if let level, level < 1 || level > maximumLevel {
            return nil
        }

        let block = ns.lineRange(for: selectedRange)
        var lines: [String] = []
        var lineStarts: [Int] = []
        var cursor = block.location
        while cursor < NSMaxRange(block) {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            lineStarts.append(lineRange.location)
            lines.append(ns.substring(with: lineRange))
            cursor = NSMaxRange(lineRange)
        }
        // A selection ending exactly at a line start still covers the preceding line only.
        if lines.isEmpty {
            return nil
        }

        // Terminators are carried through untouched so the last line of the file keeps
        // having none.
        let bodies = lines.map { line -> (content: String, terminator: String) in
            let ns = line as NSString
            let contentLength = ns.range(of: "\n", options: .backwards).location == ns.length - 1 ? ns.length - 1 : ns.length
            return (ns.substring(to: contentLength), ns.substring(from: contentLength))
        }

        var classifications: [Line] = []
        for (index, body) in bodies.enumerated() {
            let classified = classify(line: body.content)
            // Only pay for the whole-document fence scan once a cheap line-local match passed.
            if case .editable = classified,
               MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: lineStarts[index], in: text) {
                classifications.append(.skipped)
            } else {
                classifications.append(classified)
            }
        }

        let editableIndices = classifications.indices.filter {
            if case .editable = classifications[$0] { return true }
            return false
        }
        guard !editableIndices.isEmpty else {
            return nil
        }

        // All-or-nothing decides the toggle direction, so a multi-line selection never
        // half-toggles.
        let alreadyAtLevel = editableIndices.allSatisfy {
            guard case let .editable(_, existing, _) = classifications[$0] else { return false }
            return existing == level
        }
        let target: Int? = alreadyAtLevel ? nil : level
        if alreadyAtLevel && level == nil {
            return nil
        }

        var rebuilt: [String] = []
        var deltas: [Int] = []
        for (index, body) in bodies.enumerated() {
            guard case let .editable(indent, _, contentOffset) = classifications[index] else {
                rebuilt.append(body.content + body.terminator)
                deltas.append(0)
                continue
            }
            let content = (body.content as NSString).substring(from: contentOffset)
            let marker = target.map { String(repeating: "#", count: $0) + " " } ?? ""
            let line = indent + marker + content
            deltas.append((line as NSString).length - (body.content as NSString).length)
            rebuilt.append(line + body.terminator)
        }

        guard deltas.contains(where: { $0 != 0 }) else {
            return nil
        }

        var edited = text
        let replacement = rebuilt.joined()
        guard let swiftRange = Range(block, in: edited) else {
            return nil
        }
        edited.replaceSubrange(swiftRange, with: replacement)

        return MarkdownEdit(
            text: edited,
            selectedRange: adjustedSelection(
                selectedRange,
                lineStarts: lineStarts,
                bodies: bodies.map { $0.content },
                classifications: classifications,
                deltas: deltas
            )
        )
    }

    /// Keeps the user's TEXT selected rather than the rewritten lines: the start shifts by the
    /// first touched line's marker delta, the length by the deltas of the lines inside it. A
    /// caret keeps its offset within the line's own text, so it does not drift when the `#`
    /// count changes under it.
    private static func adjustedSelection(
        _ selection: NSRange,
        lineStarts: [Int],
        bodies: [String],
        classifications: [Line],
        deltas: [Int]
    ) -> NSRange {
        var startShift = 0
        var lengthShift = 0

        for index in lineStarts.indices {
            let lineStart = lineStarts[index]
            let contentEnd = lineStart + (bodies[index] as NSString).length
            let delta = deltas[index]
            guard delta != 0 else { continue }

            let markerEnd: Int
            if case let .editable(indent, _, contentOffset) = classifications[index] {
                markerEnd = lineStart + max((indent as NSString).length, contentOffset)
            } else {
                markerEnd = lineStart
            }

            if selection.location >= markerEnd {
                startShift += delta
            } else if selection.location > lineStart {
                // Caret sat inside the markers being rewritten: clamp it to the content start.
                startShift += markerEnd + delta - selection.location
            }

            if NSMaxRange(selection) > contentEnd || (selection.length > 0 && NSMaxRange(selection) > markerEnd) {
                lengthShift += delta
            }
        }

        let location = max(0, selection.location + startShift)
        let length = max(0, selection.length + lengthShift - (selection.length > 0 ? 0 : 0))
        return NSRange(location: location, length: selection.length == 0 ? 0 : length)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHeadingEditingTests`
Expected: PASS. If the selection arithmetic in `adjustedSelection` disagrees with a test, the TEST is the contract — fix the implementation, not the expectation.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownHeadingEditing.swift LineformTests/MarkdownHeadingEditingTests.swift
git commit -m "Set heading level across the lines a selection touches"
```

---

### Task 3: Route the formatting commands through it

**Files:**
- Modify: `Lineform/Editor/MarkdownFormattingCommand.swift:81-140`
- Modify: `Lineform/Editor/LineformTextView.swift:492-498`
- Modify: `LineformTests/MarkdownFormattingCommandTests.swift:5-24`

**Interfaces:**
- Consumes: `MarkdownHeadingEditing.setLevel(_:in:selectedRange:)`
- Produces: `MarkdownFormattingCommand.heading(Int)`, `MarkdownFormattingCommand.body`, `LineformTextView.toggleHeading3Markdown(_:)` … `toggleHeading6Markdown(_:)`, `toggleBodyMarkdown(_:)`

- [ ] **Step 1: Update the two existing tests to the new case names**

In `LineformTests/MarkdownFormattingCommandTests.swift`, change `MarkdownFormattingCommand.title` to `MarkdownFormattingCommand.heading(1)` and `.section` to `.heading(2)`. **Every assertion stays byte-identical** — those two cases encode the sane path and this change must not move it.

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownFormattingCommandTests`
Expected: FAIL — `type 'MarkdownFormattingCommand' has no member 'heading'`.

- [ ] **Step 3: Replace the cases**

In `Lineform/Editor/MarkdownFormattingCommand.swift`, replace `case title` / `case section` with:

```swift
    case heading(Int)
    case body
```

Replace their `apply` arms:

```swift
        case let .heading(level):
            return MarkdownHeadingEditing.setLevel(level, in: text, selectedRange: selectedRange)
                ?? MarkdownEdit(text: text, selectedRange: selectedRange)
        case .body:
            return MarkdownHeadingEditing.setLevel(nil, in: text, selectedRange: selectedRange)
                ?? MarkdownEdit(text: text, selectedRange: selectedRange)
```

Delete `prefixSelection` entirely — `.title` and `.section` were its only callers.

- [ ] **Step 4: Route the text view, and skip the no-op**

In `Lineform/Editor/LineformTextView.swift`, replace `toggleTitleMarkdown` / `toggleSectionMarkdown` bodies and add the new actions:

```swift
    @objc func toggleTitleMarkdown(_ sender: Any?) {
        applyHeadingLevel(1)
    }

    @objc func toggleSectionMarkdown(_ sender: Any?) {
        applyHeadingLevel(2)
    }

    @objc func toggleHeading3Markdown(_ sender: Any?) {
        applyHeadingLevel(3)
    }

    @objc func toggleHeading4Markdown(_ sender: Any?) {
        applyHeadingLevel(4)
    }

    @objc func toggleHeading5Markdown(_ sender: Any?) {
        applyHeadingLevel(5)
    }

    @objc func toggleHeading6Markdown(_ sender: Any?) {
        applyHeadingLevel(6)
    }

    @objc func toggleBodyMarkdown(_ sender: Any?) {
        applyHeadingLevel(nil)
    }

    /// Bails before `applyWholeTextReplacement` when nothing would change, so a dead keypress
    /// never registers an empty undo step — the `reformatMarkdownTable` precedent.
    private func applyHeadingLevel(_ level: Int?) {
        guard let edit = MarkdownHeadingEditing.setLevel(level, in: string, selectedRange: selectedRange()) else {
            return
        }
        applyWholeTextReplacement(edit)
    }
```

- [ ] **Step 5: Run the whole default plan**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: PASS. Anything referencing `.title` / `.section` as a formatting command is a compile error to fix here.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/MarkdownFormattingCommand.swift Lineform/Editor/LineformTextView.swift LineformTests/MarkdownFormattingCommandTests.swift
git commit -m "Route heading commands through MarkdownHeadingEditing"
```

---

### Task 4: Menu wiring

**Files:**
- Modify: `Lineform/App/AppCommands.swift:376-386`
- Modify: `Lineform/App/MainMenuIconDecorator.swift:190+`

**Interfaces:**
- Consumes: the `@objc` actions from Task 3.

- [ ] **Step 1: Add the Heading submenu**

In `Lineform/App/AppCommands.swift`, immediately after the `Section` button (keeping `Title` ⌘1 and `Section` ⌘2 exactly as they are):

```swift
                Menu("Heading") {
                    Button("Heading 3") {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading3Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("3", modifiers: .command)

                    Button("Heading 4") {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading4Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("4", modifiers: .command)

                    Button("Heading 5") {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading5Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("5", modifiers: .command)

                    Button("Heading 6") {
                        NSApp.sendAction(#selector(LineformTextView.toggleHeading6Markdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("6", modifiers: .command)

                    Divider()

                    Button("Body") {
                        NSApp.sendAction(#selector(LineformTextView.toggleBodyMarkdown(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }
```

- [ ] **Step 2: Add the menu icons**

In `Lineform/App/MainMenuIconDecorator.swift`, beside the existing `"title"` / `"section"` entries in `symbolsByTitle`:

```swift
        "heading": "textformat",
        "heading 3": "textformat.size.smaller",
        "heading 4": "textformat.size.smaller",
        "heading 5": "textformat.size.smaller",
        "heading 6": "textformat.size.smaller",
        "body": "textformat.size",
```

- [ ] **Step 3: Build and confirm the menu**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED. Then launch the built app by its full `BUILT_PRODUCTS_DIR` path (never `open -a Lineform`, which picks an installed copy) and confirm Format ▸ Heading shows five rows, each iconed, with ⌘3–⌘6 and ⌘0.

- [ ] **Step 4: Run the default plan**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/App/AppCommands.swift Lineform/App/MainMenuIconDecorator.swift
git commit -m "Add the Format Heading submenu"
```

---

### Task 5: Documentation

**Files:**
- Modify: `Lineform/Resources/Help.md`
- Modify: `docs/architecture/editor-behavior.md`
- Modify: `docs/research/2026-07-25-feature-backlog.md`
- Modify: `CLAUDE.md` (one feature line only)

Only update what the change actually invalidates — no additions for their own sake.

- [ ] **Step 1: `Help.md`** — one bullet beside the existing Format bullets: heading levels are ⌘1–⌘6, ⌘0 returns a line to body text, and pressing a line's current level toggles it off.

- [ ] **Step 2: `docs/architecture/editor-behavior.md`** — a subsection recording: why heading detection does not reuse `MarkdownHeadingParser.heading(in:)` (empty-title headings); the all-or-nothing toggle direction; the skip list; that `LinePrefix` is now shared; and that a no-op returns `nil` to protect the undo stack.

- [ ] **Step 3: `docs/research/2026-07-25-feature-backlog.md`** — mark item 5 SHIPPED with the date, note that the real content was fixing the stacking and mid-line bugs, and update the Status line at the top.

- [ ] **Step 4: `CLAUDE.md`** — extend the existing Markdown-formatting feature line to mention heading levels 1–6 and body. Add a Load-Bearing Invariant line ONLY for the empty-heading detection rule, which is the one thing that silently reintroduces the stacking bug if someone "simplifies" it to use the outline parser.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Resources/Help.md docs/architecture/editor-behavior.md docs/research/2026-07-25-feature-backlog.md Claude.md
git commit -m "Document heading levels 1-6"
```

Note: `CLAUDE.md` is tracked as `Claude.md` — `git add CLAUDE.md` stages nothing and silently drops the edit.
