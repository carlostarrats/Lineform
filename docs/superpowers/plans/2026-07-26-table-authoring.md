# Table Authoring Help Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Lineform three table-authoring affordances — Insert Table, Reformat Table, and Tab between cells — built on the GFM parser the renderer already uses.

**Architecture:** One new pure enum, `MarkdownTableEditing`, answers every question over `(text, selectedRange)` with no AppKit involvement, exactly like `MarkdownListContinuation`. `LineformTextView` gains two thin key overrides (`insertTab` / `insertBacktab`) and two thin `@objc` actions, each of which parses via `MarkdownTableEditing` and then applies the result through one of the text view's two existing edit paths.

**Tech Stack:** Swift, AppKit (`NSTextView`), SwiftUI (`CommandMenu`), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-26-table-authoring-design.md`

## Global Constraints

- Insert Table is ⌃⌘T; Reformat Table is ⌃⌘R. ⌥⌘T is taken by `toggleToolbarShown:` and ⌘T by New Tab.
- Key intercepts hook `insertTab` / `insertBacktab`, **never `keyDown`**.
- Per-keystroke edits (Tab) use the localized `replaceCharacters` path, **never `applyWholeTextReplacement`**.
- One-shot commands (Insert, Reformat) use `applyWholeTextReplacement`, giving one ⌘Z.
- Table detection must reuse `MarkdownTableParser` and match `MarkdownBlockGrouping.swift:427-444` exactly.
- The whole-document guard `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter` runs only after the cheap line-local checks pass.
- Reformat refuses on `\|` or any backtick inside the table region.
- Every main-menu row needs an SF Symbol in `MainMenuIconDecorator`.
- New files must be registered in all four relevant `project.pbxproj` sections with sequential `1F0000..` IDs.
- All new tests belong to the DEFAULT test plan — no `NSWindow` anywhere in them.

---

### Task 1: `MarkdownTableEditing.locate` and the region model

**Files:**
- Create: `Lineform/Editor/MarkdownTableEditing.swift`
- Create: `LineformTests/MarkdownTableEditingTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (four sections)

**Interfaces:**
- Consumes: `MarkdownTableParser.looksLikeRow`, `.isDelimiterRow`, `.cells(in:)`, `.parse(header:delimiter:body:)`, `MarkdownTable`, `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location:in:)`.
- Produces: `MarkdownTableRegion` (`range`, `lineRanges`, `table`, `indent`) and `MarkdownTableEditing.locate(in:at:) -> MarkdownTableRegion?`, used by every later task.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest
@testable import Lineform

final class MarkdownTableEditingTests: XCTestCase {
    private let simple = """
    | A | B |
    | - | - |
    | 1 | 2 |
    """

    private func locate(_ text: String, _ location: Int) -> MarkdownTableRegion? {
        MarkdownTableEditing.locate(in: text, at: location)
    }

    func testLocatesTableFromHeaderRow() {
        let region = locate(simple, 2)
        XCTAssertEqual(region?.range, NSRange(location: 0, length: (simple as NSString).length))
        XCTAssertEqual(region?.table.headers, ["A", "B"])
        XCTAssertEqual(region?.lineRanges.count, 3)
    }

    func testLocatesTableFromDelimiterRow() {
        XCTAssertEqual(locate(simple, 11)?.table.headers, ["A", "B"])
    }

    func testLocatesTableFromBodyRow() {
        XCTAssertEqual(locate(simple, 22)?.table.rows, [["1", "2"]])
    }

    func testStopsAtSurroundingProse() {
        let text = "intro\n\n\(simple)\n\noutro"
        let region = locate(text, 9)
        XCTAssertEqual(region?.range, NSRange(location: 7, length: (simple as NSString).length))
    }

    func testParagraphLineWithPipeAboveTableIsNotPartOfIt() {
        let text = "see a|b below\n\(simple)"
        XCTAssertEqual(locate(text, 20)?.table.headers, ["A", "B"])
        XCTAssertNil(locate(text, 2))
    }

    func testBarePipeLineWithoutDelimiterIsNotATable() {
        XCTAssertNil(locate("| A | B |", 3))
    }

    func testMismatchedColumnCountsAreNotATable() {
        XCTAssertNil(locate("| A | B |\n| - |", 3))
    }

    func testSetextRuleUnderPipeLineIsNotATable() {
        XCTAssertNil(locate("a|b\n---", 1))
    }

    func testTableInsideFencedCodeIsNotATable() {
        XCTAssertNil(locate("```\n\(simple)\n```", 8))
    }

    func testPreservesLeadingIndentation() {
        XCTAssertEqual(locate("  | A | B |\n  | - | - |", 4)?.indent, "  ")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownTableEditingTests`
Expected: build failure — `cannot find 'MarkdownTableEditing' in scope`.

- [ ] **Step 3: Implement `locate`**

```swift
import Foundation

/// A GFM pipe table located in the source text: the block's character range, the range of each
/// of its lines, the parsed table, and the indentation its lines share.
struct MarkdownTableRegion: Equatable {
    /// The whole table block, with no trailing newline.
    var range: NSRange
    /// One range per source line — header, delimiter, then body — each excluding its terminator.
    var lineRanges: [NSRange]
    var table: MarkdownTable
    /// Leading whitespace of the header line, re-emitted on every rewritten line.
    var indent: String

    /// The index into `lineRanges` of the delimiter row, which is never a navigable row.
    static let delimiterLineIndex = 1
}

/// Table authoring: locating the table under the caret, inserting a skeleton, aligning the
/// pipes, and moving between cells on Tab.
///
/// Pure over `(text, selectedRange)` — no AppKit, no view state — so the whole decision surface
/// is testable without a window. `LineformTextView` is the only caller.
///
/// Detection deliberately delegates to `MarkdownTableParser`, the same parser the renderer uses
/// (`MarkdownBlockGrouping.swift:427-444`). If the editor's definition of "a table" and the
/// renderer's ever diverge, Tab intercepts a construct the reader never saw as a table and
/// Reformat rewrites it.
enum MarkdownTableEditing {
    static func locate(in text: String, at location: Int) -> MarkdownTableRegion? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }

        let caretLine = lineRange(in: ns, at: location)
        guard MarkdownTableParser.looksLikeRow(ns.substring(with: caretLine)) else { return nil }

        // Maximal run of consecutive pipe-bearing lines around the caret. A blank line or a
        // pipe-free line ends the run, exactly as it ends the renderer's paragraph accumulation.
        var runLines = [caretLine]
        var cursor = caretLine.location
        while cursor > 0 {
            let previous = lineRange(in: ns, at: cursor - 1)
            guard MarkdownTableParser.looksLikeRow(ns.substring(with: previous)) else { break }
            runLines.insert(previous, at: 0)
            cursor = previous.location
        }
        cursor = NSMaxRange(caretLine)
        while cursor < ns.length {
            let next = lineRange(in: ns, at: cursor + 1)
            guard next.location > cursor,
                  MarkdownTableParser.looksLikeRow(ns.substring(with: next)) else { break }
            runLines.append(next)
            cursor = NSMaxRange(next)
        }

        // Within the run, the table starts at the FIRST line whose successor is a matching
        // delimiter row — the same line the renderer's sequential scan would settle on. Lines
        // before it are an ordinary paragraph that happens to contain a pipe.
        guard let header = (0..<max(0, runLines.count - 1)).first(where: { index in
            let headerLine = ns.substring(with: runLines[index])
            let delimiterLine = ns.substring(with: runLines[index + 1])
            return MarkdownTableParser.isDelimiterRow(delimiterLine)
                && MarkdownTableParser.cells(in: headerLine).count
                    == MarkdownTableParser.cells(in: delimiterLine).count
        }) else { return nil }

        let lines = Array(runLines[header...])
        guard let first = lines.first, let last = lines.last else { return nil }
        guard location >= first.location, location <= NSMaxRange(last) else { return nil }

        // Only now, after two cheap line-local checks have passed, pay for the whole-document
        // fence scan. Tab on ordinary prose never reaches this.
        guard !MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
            location: first.location,
            in: text
        ) else { return nil }

        let texts = lines.map { ns.substring(with: $0) }
        let table = MarkdownTableParser.parse(
            header: texts[0],
            delimiter: texts[1],
            body: Array(texts.dropFirst(2))
        )
        return MarkdownTableRegion(
            range: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
            lineRanges: lines,
            table: table,
            indent: String(texts[0].prefix(while: { $0 == " " || $0 == "\t" }))
        )
    }

    /// `NSString.lineRange(for:)` includes the terminator; every caller here measures against the
    /// line's own text, so the terminator is trimmed off.
    static func lineRange(in ns: NSString, at location: Int) -> NSRange {
        let clamped = min(max(location, 0), ns.length)
        let paragraph = ns.lineRange(for: NSRange(location: clamped, length: 0))
        var end = NSMaxRange(paragraph)
        while end > paragraph.location {
            let character = ns.substring(with: NSRange(location: end - 1, length: 1))
            guard character == "\n" || character == "\r" else { break }
            end -= 1
        }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }
}
```

- [ ] **Step 4: Register both files in `project.pbxproj`**

Add four entries per file, following the `MarkdownListContinuation` precedent at
`project.pbxproj:16, 91, 205, 289, 488, 583, 852, 928`. Use the next free sequential IDs
(`1F00000100000000000004B3` / `1F00000200000000000004B3` for the source file,
`…4B4` for the test file — verify they are unused with
`grep -c 1F00000200000000000004B3 Lineform.xcodeproj/project.pbxproj`).

Per file: one `PBXBuildFile`, one `PBXFileReference`, one entry in the owning `PBXGroup`
(`Lineform/Editor` group for the source, `LineformTests` group for the test), and one entry in
the target's `PBXSourcesBuildPhase` (app target for the source, test target for the test).

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownTableEditingTests`
Expected: 10 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/MarkdownTableEditing.swift LineformTests/MarkdownTableEditingTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Locate the GFM table under the caret"
```

---

### Task 2: Cell geometry and column widths

**Files:**
- Modify: `Lineform/Editor/MarkdownTableEditing.swift`
- Modify: `LineformTests/MarkdownTableEditingTests.swift`

**Interfaces:**
- Consumes: `MarkdownTableRegion` from Task 1.
- Produces: `MarkdownTableEditing.contentRanges(ofLine:in:) -> [NSRange]` (document-coordinate ranges of each cell's trimmed content on one line) and `MarkdownTableEditing.columnWidths(for:) -> [Int]`. Task 3 uses `columnWidths`; Task 4 uses both.

- [ ] **Step 1: Write the failing tests**

Append to `MarkdownTableEditingTests`:

```swift
    // MARK: - Cell geometry

    func testContentRangesCoverTrimmedCells() {
        let text = "| Fruit | Colour |\n| - | - |"
        let region = locate(text, 2)!
        let ranges = MarkdownTableEditing.contentRanges(ofLine: 0, in: region, text: text)
        XCTAssertEqual(ranges, [NSRange(location: 2, length: 5), NSRange(location: 10, length: 6)])
    }

    func testContentRangeOfEmptyCellSitsOneSpaceAfterThePipe() {
        let text = "|     |  |\n| - | - |"
        let region = locate(text, 2)!
        let ranges = MarkdownTableEditing.contentRanges(ofLine: 0, in: region, text: text)
        XCTAssertEqual(ranges, [NSRange(location: 1, length: 0), NSRange(location: 8, length: 0)])
    }

    func testContentRangesHandleMissingOuterPipes() {
        let text = "A | B\n- | -"
        let region = locate(text, 1)!
        let ranges = MarkdownTableEditing.contentRanges(ofLine: 0, in: region, text: text)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
    }

    func testColumnWidthsTakeTheWidestCell() {
        let text = "| A | Colour |\n| - | - |\n| Plum | x |"
        XCTAssertEqual(MarkdownTableEditing.columnWidths(for: locate(text, 2)!), [4, 6])
    }

    func testColumnWidthsHaveAFloorOfThree() {
        let text = "| A | B |\n| - | - |"
        XCTAssertEqual(MarkdownTableEditing.columnWidths(for: locate(text, 2)!), [3, 3])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run the same `-only-testing` command.
Expected: build failure — `type 'MarkdownTableEditing' has no member 'contentRanges'`.

- [ ] **Step 3: Implement**

Add to `MarkdownTableEditing`:

```swift
    /// Document-coordinate ranges of each cell's TRIMMED content on one line of the region.
    ///
    /// Mirrors `MarkdownTableParser.cells(in:)` — optional outer pipes dropped, split on every
    /// remaining pipe — but keeps the positions the parser throws away, which is what Tab needs
    /// in order to select a cell.
    ///
    /// An all-whitespace cell yields a zero-length range one character past its opening pipe, so
    /// Tab into an empty cell puts the caret where a writer would expect to type.
    static func contentRanges(ofLine index: Int, in region: MarkdownTableRegion, text: String) -> [NSRange] {
        guard region.lineRanges.indices.contains(index) else { return [] }
        let lineRange = region.lineRanges[index]
        let ns = text as NSString
        let line = ns.substring(with: lineRange)
        let lineNS = line as NSString

        var start = 0
        while start < lineNS.length, isWhitespace(lineNS.character(at: start)) { start += 1 }
        var end = lineNS.length
        while end > start, isWhitespace(lineNS.character(at: end - 1)) { end -= 1 }
        guard start < end else { return [] }

        let pipe = UInt16(UnicodeScalar("|").value)
        if lineNS.character(at: start) == pipe { start += 1 }
        if end - 1 > start, lineNS.character(at: end - 1) == pipe { end -= 1 }
        guard start <= end else { return [] }

        var boundaries: [Int] = [start]
        for offset in start..<end where lineNS.character(at: offset) == pipe {
            boundaries.append(offset)
            boundaries.append(offset + 1)
        }
        boundaries.append(end)

        var ranges: [NSRange] = []
        for pair in stride(from: 0, to: boundaries.count, by: 2) {
            let segmentStart = boundaries[pair]
            let segmentEnd = boundaries[pair + 1]
            var contentStart = segmentStart
            var contentEnd = segmentEnd
            while contentStart < contentEnd, isWhitespace(lineNS.character(at: contentStart)) { contentStart += 1 }
            while contentEnd > contentStart, isWhitespace(lineNS.character(at: contentEnd - 1)) { contentEnd -= 1 }

            if contentStart == contentEnd {
                let anchor = segmentStart + min(1, segmentEnd - segmentStart)
                ranges.append(NSRange(location: lineRange.location + anchor, length: 0))
            } else {
                ranges.append(NSRange(
                    location: lineRange.location + contentStart,
                    length: contentEnd - contentStart
                ))
            }
        }
        return ranges
    }

    /// Per-column render width: the widest cell in that column, floored at 3 so every delimiter
    /// cell can still spell `---`, `:--`, `--:`, or `:-:`.
    ///
    /// Width is measured in Characters (grapheme clusters), not display width, so CJK and emoji
    /// cells under-pad. Pipe alignment is a source-readability nicety, not a layout guarantee.
    static func columnWidths(for region: MarkdownTableRegion) -> [Int] {
        let rows = [region.table.headers] + region.table.rows
        return (0..<region.table.columnCount).map { column in
            rows.reduce(3) { widest, row in
                guard row.indices.contains(column) else { return widest }
                return max(widest, row[column].count)
            }
        }
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == UInt16(UnicodeScalar(" ").value) || character == UInt16(UnicodeScalar("\t").value)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same `-only-testing` command.
Expected: 15 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownTableEditing.swift LineformTests/MarkdownTableEditingTests.swift
git commit -m "Add table cell geometry and column widths"
```

---

### Task 3: Insert Table and Reformat Table

**Files:**
- Modify: `Lineform/Editor/MarkdownTableEditing.swift`
- Modify: `LineformTests/MarkdownTableEditingTests.swift`

**Interfaces:**
- Consumes: `locate`, `columnWidths`, `MarkdownEdit` (`Lineform/Editor/MarkdownFormattingCommand.swift:3`, fields `text` and `selectedRange`).
- Produces: `MarkdownTableEditing.insertion(in:selectedRange:) -> MarkdownEdit` and `MarkdownTableEditing.reformat(in:selectedRange:) -> MarkdownEdit?`. Task 5 calls both.

**Note on idempotence:** `reformat` returns `nil` when the table is already aligned. That is
what makes a second ⌃⌘R a true no-op rather than a redundant undo step, and it is how the
spec's idempotence requirement is tested.

- [ ] **Step 1: Write the failing tests**

Append to `MarkdownTableEditingTests`:

```swift
    // MARK: - Insert

    private static let skeleton = """
    |     |     |     |
    | --- | --- | --- |
    |     |     |     |
    |     |     |     |
    """

    func testInsertsSkeletonIntoAnEmptyDocument() {
        let edit = MarkdownTableEditing.insertion(in: "", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.text, Self.skeleton)
        XCTAssertEqual(edit.selectedRange, NSRange(location: 2, length: 0))
    }

    func testInsertsAfterAParagraphWithABlankLineBetween() {
        let edit = MarkdownTableEditing.insertion(in: "intro", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.text, "intro\n\n\(Self.skeleton)")
        XCTAssertEqual(edit.selectedRange, NSRange(location: 9, length: 0))
    }

    func testInsertsOnABlankLineWithoutAddingAnother() {
        let edit = MarkdownTableEditing.insertion(in: "intro\n\n", selectedRange: NSRange(location: 7, length: 0))
        XCTAssertEqual(edit.text, "intro\n\n\(Self.skeleton)")
    }

    func testSeparatesFromFollowingProse() {
        let edit = MarkdownTableEditing.insertion(in: "intro\noutro", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.text, "intro\n\n\(Self.skeleton)\n\noutro")
    }

    // MARK: - Reformat

    func testReformatAlignsRaggedColumns() {
        let text = "| Fruit | Colour |\n|-|-|\n| Plum | purple |"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, """
        | Fruit | Colour |
        | ----- | ------ |
        | Plum  | purple |
        """)
    }

    func testReformatReturnsNilWhenAlreadyAligned() {
        let text = "| Fruit | Colour |\n| ----- | ------ |\n| Plum  | purple |"
        XCTAssertNil(MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0)))
    }

    func testReformatPreservesAlignmentColons() {
        let text = "| A | B | C |\n|:-|-:|:-:|"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, "| A   | B   | C   |\n| :-- | --: | :-: |")
    }

    func testReformatPadsAndTruncatesRowsToTheDelimiterWidth() {
        let text = "| A | B |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, "| A | B |\n| - | - |\n| 1 |   |\n| 1 | 2 |")
    }

    func testReformatPreservesIndentation() {
        let text = "  | A | B |\n  |-|-|"
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.text, "  | A | B |\n  | - | - |")
    }

    func testReformatKeepsTheCaretInItsCell() {
        let text = "| Fruit | Colour |\n|-|-|\n| Plum | purple |"
        // Caret inside "purple", two characters in.
        let caret = (text as NSString).range(of: "purple").location + 2
        let edit = MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: caret, length: 0))
        let reformatted = edit!.text as NSString
        XCTAssertEqual(edit?.selectedRange.location, reformatted.range(of: "purple").location + 2)
    }

    func testReformatRefusesOnEscapedPipe() {
        let text = "| A | B |\n| - | - |\n| a \\| b | c |"
        XCTAssertNil(MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0)))
    }

    func testReformatRefusesOnBacktick() {
        let text = "| A | B |\n| - | - |\n| `a|b` | c |"
        XCTAssertNil(MarkdownTableEditing.reformat(in: text, selectedRange: NSRange(location: 2, length: 0)))
    }

    func testReformatReturnsNilOutsideATable() {
        XCTAssertNil(MarkdownTableEditing.reformat(in: "just prose", selectedRange: NSRange(location: 2, length: 0)))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run the same `-only-testing` command.
Expected: build failure — `no member 'insertion'`.

- [ ] **Step 3: Implement**

Add to `MarkdownTableEditing`:

```swift
    static let insertedColumnCount = 3
    static let insertedBodyRowCount = 2

    /// A 3×2 starter table, written as its own block. Fixed size by design: every other Format
    /// command acts immediately, and gaining a column is one pipe plus Reformat — cheaper than
    /// any size dialog.
    static func insertion(in text: String, selectedRange: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let caretLine = lineRange(in: ns, at: selectedRange.location)
        let lineIsBlank = ns.substring(with: caretLine).trimmingCharacters(in: .whitespaces).isEmpty
        let replaced = lineIsBlank ? caretLine : NSRange(location: NSMaxRange(caretLine), length: 0)

        let before = ns.substring(to: replaced.location)
        let after = ns.substring(from: NSMaxRange(replaced))
        let leading = before.isEmpty || before.hasSuffix("\n\n") ? "" : (before.hasSuffix("\n") ? "\n" : "\n\n")
        let trailing = after.isEmpty || after.hasPrefix("\n\n") ? "" : (after.hasPrefix("\n") ? "\n" : "\n\n")

        let widths = Array(repeating: 3, count: insertedColumnCount)
        var lines = [row(cells: Array(repeating: "", count: insertedColumnCount), widths: widths, indent: "")]
        lines.append(row(
            cells: widths.map { String(repeating: "-", count: $0) },
            widths: widths,
            indent: ""
        ))
        for _ in 0..<insertedBodyRowCount {
            lines.append(row(cells: Array(repeating: "", count: insertedColumnCount), widths: widths, indent: ""))
        }

        let replacement = leading + lines.joined(separator: "\n") + trailing
        var edited = text
        if let swiftRange = Range(replaced, in: edited) {
            edited.replaceSubrange(swiftRange, with: replacement)
        }

        // Caret in the first header cell: past the leading blank lines, the opening pipe, and
        // its following space.
        let caret = replaced.location + (leading as NSString).length + 2
        return MarkdownEdit(text: edited, selectedRange: NSRange(location: caret, length: 0))
    }

    /// Pads the pipes of the table under the caret so its columns line up in the source.
    ///
    /// Returns `nil` — a silent no-op, no undo step — when there is no table under the caret,
    /// when the table is already aligned, or when rewriting it would be unsafe.
    ///
    /// The safety refusal is load-bearing. `MarkdownTableParser.cells(in:)` splits on EVERY
    /// pipe; escaped pipes are a documented v1 limitation. That is harmless while rendering,
    /// but Reformat rewrites the file, so the same wrong split would permanently destroy
    /// `a \| b` or `` `a|b` ``. The backtick half of the test is deliberately over-broad: it
    /// declines some tables it could safely rewrite, and it never corrupts one.
    static func reformat(in text: String, selectedRange: NSRange) -> MarkdownEdit? {
        guard let region = locate(in: text, at: selectedRange.location) else { return nil }

        let ns = text as NSString
        let original = ns.substring(with: region.range)
        guard !original.contains("\\|"), !original.contains("`") else { return nil }

        let widths = columnWidths(for: region)
        var lines = [row(cells: region.table.headers, widths: widths, indent: region.indent)]
        lines.append(row(
            cells: zip(region.table.alignments, widths).map(delimiterCell(for:width:)),
            widths: widths,
            indent: region.indent
        ))
        lines.append(contentsOf: region.table.rows.map { row(cells: $0, widths: widths, indent: region.indent) })

        let replacement = lines.joined(separator: "\n")
        guard replacement != original else { return nil }

        var edited = text
        guard let swiftRange = Range(region.range, in: edited) else { return nil }
        edited.replaceSubrange(swiftRange, with: replacement)

        return MarkdownEdit(
            text: edited,
            selectedRange: NSRange(
                location: caretAfterReformat(
                    region: region,
                    text: text,
                    replacement: replacement,
                    caret: selectedRange.location
                ),
                length: 0
            )
        )
    }

    /// Keeps the caret in the same cell, at the same offset into that cell's content, so
    /// Reformat never yanks the writer somewhere else in the table.
    private static func caretAfterReformat(
        region: MarkdownTableRegion,
        text: String,
        replacement: String,
        caret: Int
    ) -> Int {
        guard let line = region.lineRanges.firstIndex(where: {
            caret >= $0.location && caret <= NSMaxRange($0)
        }) else { return region.range.location }

        let cells = contentRanges(ofLine: line, in: region, text: text)
        guard let cell = cells.firstIndex(where: { caret <= NSMaxRange($0) }) else {
            return region.range.location
        }
        let offset = max(0, caret - cells[cell].location)

        let rebuilt = MarkdownTableRegion(
            range: NSRange(location: region.range.location, length: (replacement as NSString).length),
            lineRanges: lineRanges(of: replacement, startingAt: region.range.location),
            table: region.table,
            indent: region.indent
        )
        var rebuiltText = text
        if let swiftRange = Range(region.range, in: rebuiltText) {
            rebuiltText.replaceSubrange(swiftRange, with: replacement)
        }
        let rebuiltCells = contentRanges(ofLine: line, in: rebuilt, text: rebuiltText)
        guard rebuiltCells.indices.contains(cell) else { return region.range.location }
        return min(rebuiltCells[cell].location + offset, NSMaxRange(rebuiltCells[cell]))
    }

    private static func lineRanges(of block: String, startingAt origin: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = origin
        for line in block.components(separatedBy: "\n") {
            let length = (line as NSString).length
            ranges.append(NSRange(location: location, length: length))
            location += length + 1
        }
        return ranges
    }

    /// `| a   | b   |` — always with outer pipes, cells right-padded to the column width.
    static func row(cells: [String], widths: [Int], indent: String) -> String {
        let padded = widths.enumerated().map { index, width -> String in
            let content = cells.indices.contains(index) ? cells[index] : ""
            return content.padding(toLength: max(width, content.count), withPad: " ", startingAt: 0)
        }
        return indent + "| " + padded.joined(separator: " | ") + " |"
    }

    private static func delimiterCell(for alignment: MarkdownTableAlignment, width: Int) -> String {
        switch alignment {
        case .left:
            return String(repeating: "-", count: width)
        case .right:
            return String(repeating: "-", count: width - 1) + ":"
        case .center:
            return ":" + String(repeating: "-", count: width - 2) + ":"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same `-only-testing` command.
Expected: 28 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownTableEditing.swift LineformTests/MarkdownTableEditingTests.swift
git commit -m "Add table insertion and pipe alignment"
```

---

### Task 4: Tab between cells

**Files:**
- Modify: `Lineform/Editor/MarkdownTableEditing.swift`
- Modify: `LineformTests/MarkdownTableEditingTests.swift`

**Interfaces:**
- Consumes: `locate`, `contentRanges`, `columnWidths`, `row`.
- Produces: `MarkdownTableEditing.TabOutcome` (`.select(NSRange)`, `.appendRow(insertion: String, at: Int, selecting: NSRange)`, `.none`) and `MarkdownTableEditing.tabTarget(in:selectedRange:forward:) -> TabOutcome?`. Task 5 switches over it.

- [ ] **Step 1: Write the failing tests**

Append to `MarkdownTableEditingTests`:

```swift
    // MARK: - Tab

    private let grid = "| A | B |\n| - | - |\n| 1 | 2 |"

    private func tab(_ text: String, _ location: Int, forward: Bool = true, length: Int = 0)
        -> MarkdownTableEditing.TabOutcome? {
        MarkdownTableEditing.tabTarget(
            in: text,
            selectedRange: NSRange(location: location, length: length),
            forward: forward
        )
    }

    func testTabMovesToTheNextCellInTheRow() {
        XCTAssertEqual(tab(grid, 2), .select(NSRange(location: 6, length: 1)))
    }

    func testTabSkipsTheDelimiterRowOnItsWayToTheBody() {
        XCTAssertEqual(tab(grid, 6), .select(NSRange(location: 22, length: 1)))
    }

    func testShiftTabMovesBackwards() {
        XCTAssertEqual(tab(grid, 6, forward: false), .select(NSRange(location: 2, length: 1)))
    }

    func testShiftTabSkipsTheDelimiterRowGoingBack() {
        XCTAssertEqual(tab(grid, 22, forward: false), .select(NSRange(location: 6, length: 1)))
    }

    func testShiftTabInTheFirstHeaderCellIsAConsumedNoOp() {
        XCTAssertEqual(tab(grid, 2, forward: false), .stay)
    }

    func testTabInTheLastCellAppendsARow() {
        let outcome = tab(grid, 26)
        XCTAssertEqual(
            outcome,
            .appendRow(
                insertion: "\n|   |   |",
                at: (grid as NSString).length,
                selecting: NSRange(location: (grid as NSString).length + 2, length: 0)
            )
        )
    }

    func testAppendedRowMatchesCurrentColumnWidths() {
        let wide = "| Fruit | B |\n| ----- | - |\n| Plum  | 2 |"
        guard case let .appendRow(insertion, _, _)? = tab(wide, (wide as NSString).length - 2) else {
            return XCTFail("expected an appended row")
        }
        XCTAssertEqual(insertion, "\n|       |   |")
    }

    func testTabOutsideATableIsNotIntercepted() {
        XCTAssertNil(tab("just prose", 4))
    }

    func testTabInsideFencedCodeIsNotIntercepted() {
        XCTAssertNil(tab("```\n\(grid)\n```", 8))
    }

    func testTabWithAMultiLineSelectionIsNotIntercepted() {
        XCTAssertNil(tab(grid, 2, length: 20))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run the same `-only-testing` command.
Expected: build failure — `no member 'TabOutcome'`.

- [ ] **Step 3: Implement**

Add to `MarkdownTableEditing`:

```swift
    enum TabOutcome: Equatable {
        /// Pure selection move — edits nothing, so it costs no undo step.
        case select(NSRange)
        /// Tab off the last cell: the only Tab that writes. One localized insertion.
        case appendRow(insertion: String, at: Int, selecting: NSRange)
        /// Consume the key and do nothing — Shift-Tab at the head of a table. Inserting a
        /// literal tab there would corrupt the table.
        ///
        /// Named `stay`, not `none`: `tabTarget` returns `TabOutcome?`, and a bare `return .none`
        /// there would silently resolve to `Optional.none` — "fall through and insert a literal
        /// tab", the exact opposite of what this case means.
        case stay
    }

    /// `nil` means "not a table cell" — the text view should fall through to `super` and insert
    /// an ordinary tab, exactly as it does today.
    static func tabTarget(in text: String, selectedRange: NSRange, forward: Bool) -> TabOutcome? {
        guard let region = locate(in: text, at: selectedRange.location) else { return nil }
        // An explicit multi-line selection is the writer's, not ours to reinterpret.
        guard NSMaxRange(selectedRange) <= NSMaxRange(region.range),
              selectedRange.length == 0
                || lineRange(in: text as NSString, at: selectedRange.location)
                    == lineRange(in: text as NSString, at: NSMaxRange(selectedRange)) else { return nil }

        let navigable = region.lineRanges.indices.filter { $0 != MarkdownTableRegion.delimiterLineIndex }
        var cells: [(line: Int, range: NSRange)] = []
        for line in navigable {
            for range in contentRanges(ofLine: line, in: region, text: text) {
                cells.append((line, range))
            }
        }
        guard !cells.isEmpty else { return nil }

        let caret = selectedRange.location
        let current = cells.lastIndex(where: { $0.range.location <= caret }) ?? 0
        let target = forward ? current + 1 : current - 1

        if target < 0 { return .stay }
        if target < cells.count { return .select(cells[target].range) }

        let widths = columnWidths(for: region)
        let insertion = "\n" + row(
            cells: Array(repeating: "", count: region.table.columnCount),
            widths: widths,
            indent: region.indent
        )
        let at = NSMaxRange(region.range)
        return .appendRow(
            insertion: insertion,
            at: at,
            selecting: NSRange(location: at + 1 + (region.indent as NSString).length + 2, length: 0)
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same `-only-testing` command.
Expected: 38 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownTableEditing.swift LineformTests/MarkdownTableEditingTests.swift
git commit -m "Move between table cells on Tab"
```

---

### Task 5: Wire the text view and the Format menu

**Files:**
- Modify: `Lineform/Editor/LineformTextView.swift` (key overrides near `insertNewline` at :401; `@objc` actions near :435; helper beside `applyFormattingCommand` at :1635)
- Modify: `Lineform/App/AppCommands.swift:361-420` (Format menu)
- Modify: `Lineform/App/MainMenuIconDecorator.swift` (title→symbol map near :270)

**Interfaces:**
- Consumes: `MarkdownTableEditing.insertion`, `.reformat`, `.tabTarget`, `TabOutcome`.
- Produces: `@objc func insertMarkdownTable(_:)` and `@objc func reformatMarkdownTable(_:)` on `LineformTextView`, targeted by `NSApp.sendAction` from the Format menu.

- [ ] **Step 1: Add the key overrides**

Insert directly below `applyListContinuationEdit` (`LineformTextView.swift:433`):

```swift
    /// Moves between the cells of the GFM table under the caret. Outside a table — which is
    /// almost everywhere — this falls straight through and Tab inserts a literal tab, exactly
    /// as it did before. That fall-through is why Tab could be claimed here at all when list
    /// continuation deliberately left it alone.
    ///
    /// `insertTab` / `insertBacktab` for the same reason `insertNewline` is overridden rather
    /// than `keyDown`: they are reached only after the input context has resolved the keypress.
    override func insertTab(_ sender: Any?) {
        guard let outcome = MarkdownTableEditing.tabTarget(
            in: string,
            selectedRange: selectedRange(),
            forward: true
        ) else {
            super.insertTab(sender)
            return
        }
        applyTableTabOutcome(outcome)
    }

    override func insertBacktab(_ sender: Any?) {
        guard let outcome = MarkdownTableEditing.tabTarget(
            in: string,
            selectedRange: selectedRange(),
            forward: false
        ) else {
            super.insertBacktab(sender)
            return
        }
        applyTableTabOutcome(outcome)
    }

    /// `.select` edits nothing at all, so most Tabs inside a table cost no undo step and no
    /// document write. `.appendRow` uses the same localized `replaceCharacters` path as list
    /// continuation — NOT `applyWholeTextReplacement`, which would rewrite the whole document
    /// on a keystroke.
    private func applyTableTabOutcome(_ outcome: MarkdownTableEditing.TabOutcome) {
        switch outcome {
        case .stay:
            return
        case let .select(range):
            setSelectedRange(range)
            scrollRangeToVisible(range)
        case let .appendRow(insertion, at, selecting):
            let range = NSRange(location: at, length: 0)
            guard shouldChangeText(in: range, replacementString: insertion) else { return }
            textStorage?.replaceCharacters(in: range, with: insertion)
            didChangeText()
            setSelectedRange(selecting)
            scrollRangeToVisible(selecting)
        }
    }
```

- [ ] **Step 2: Add the two menu actions**

Insert below `toggleUnorderedListMarkdown` (`LineformTextView.swift:470`):

```swift
    @objc func insertMarkdownTable(_ sender: Any?) {
        applyWholeTextReplacement(MarkdownTableEditing.insertion(in: string, selectedRange: selectedRange()))
        scrollRangeToVisible(selectedRange())
    }

    /// Silently does nothing when the caret is not in a table, when the table is already
    /// aligned, or when the region holds an escaped pipe or a backtick — see
    /// `MarkdownTableEditing.reformat`. Bailing before `applyWholeTextReplacement` is what keeps
    /// a no-op ⌃⌘R from registering an empty undo step.
    @objc func reformatMarkdownTable(_ sender: Any?) {
        guard let edit = MarkdownTableEditing.reformat(in: string, selectedRange: selectedRange()) else {
            return
        }
        applyWholeTextReplacement(edit)
    }
```

Note: `applyWholeTextReplacement` is currently `private` (`LineformTextView.swift:1669`). It is
used from within the same type, so no access change is needed.

- [ ] **Step 3: Add the Format menu entries**

In `AppCommands.swift`, immediately after the `Button("Link")` block and its
`.keyboardShortcut(...)`, and before the `Divider()` that closes the markdown section:

```swift
                Divider()

                Button("Insert Table") {
                    NSApp.sendAction(#selector(LineformTextView.insertMarkdownTable(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .control])

                Button("Reformat Table") {
                    NSApp.sendAction(#selector(LineformTextView.reformatMarkdownTable(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
```

- [ ] **Step 4: Add the menu icons**

In `MainMenuIconDecorator.swift`, add to the lowercased-title map beside the existing entries
near line 270:

```swift
        "insert table": "tablecells",
        "reformat table": "tablecells.badge.ellipsis",
```

- [ ] **Step 5: Build and run the FULL default test plan**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
```
Expected: the whole suite passes, with the 38 new tests included. Report exact counts.

Warn the user before running: a CLI test run re-signs the host ad-hoc and can raise a TCC
prompt for Documents access, which blocks the run.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/LineformTextView.swift Lineform/App/AppCommands.swift Lineform/App/MainMenuIconDecorator.swift
git commit -m "Add Insert Table and Reformat Table commands"
```

---

### Task 6: Manual QA in a Debug build

**Files:** none — this task changes nothing unless it finds a defect.

Pure tests prove the parsing. They cannot prove the key arrives, the menu item is enabled, the
undo step is single, or the icons render. Build and launch the freshly built Debug app by its
full `BUILT_PRODUCTS_DIR` path — never a bare `open file.md`, which hands the file to whatever
Lineform Launch Services prefers, usually an installed release, and reads exactly like the fix
failing.

- [ ] **Step 1: Build and launch**

```sh
xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Debug -destination 'platform=macOS' build
# then, with the resolved BUILT_PRODUCTS_DIR:
killall Lineform 2>/dev/null
open -a "$BUILT_PRODUCTS_DIR/Lineform.app" /tmp/table-qa.md
```

- [ ] **Step 2: Walk the checklist**

1. ⌃⌘T on a blank line inserts the 3×2 skeleton, caret in the first header cell.
2. Tab walks header → body cells, skipping the delimiter row.
3. Tab off the last cell appends a row and lands in its first cell.
4. Shift-Tab walks back and stops at the first header cell without inserting a tab.
5. Tab in ordinary prose still inserts a literal tab.
6. ⌘Z once removes the whole inserted table; ⌘Z after an appended row removes just that row.
7. ⌃⌘R on a hand-typed ragged table aligns it; a second ⌃⌘R changes nothing.
8. ⌃⌘R with the caret inside a fenced code block containing a pipe table does nothing.
9. Read mode renders the table identically before and after Reformat.
10. Format ▸ Insert Table and ▸ Reformat Table both show their SF Symbol.

- [ ] **Step 3: Fix anything the checklist finds, with a regression test where the defect is testable, and re-run Task 5 Step 5.**

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (Main Features list; Load-Bearing Invariants only if warranted)
- Modify: `docs/architecture/editor-behavior.md`
- Modify: `docs/research/2026-07-25-feature-backlog.md` (status line and item 3)

- [ ] **Step 1: Add one feature line to `CLAUDE.md`**

Beside the existing list-continuation line, one line only: Insert Table / Reformat Table and
Tab-between-cells, with Reformat's refusal on escaped pipes and backticks noted.

- [ ] **Step 2: Extend the existing Tab sentence in the Load-Bearing Invariants**

The editor invariant block already says keyboard intercepts hook `insertNewline` / `doCommandBy`
and never `keyDown`. Extend it to name `insertTab` / `insertBacktab`, and add the one rule that
is genuinely new and unrecoverable if broken: **Reformat must refuse on `\|` and backticks,
because it rewrites the file through a parser that splits on every pipe.**

Add nothing else here — the file is loaded every session and stays lean.

- [ ] **Step 3: Write the implementation narrative into `docs/architecture/editor-behavior.md`**

Cover: why detection delegates to `MarkdownTableParser` rather than reimplementing it; the two
different undo paths and why Tab must not use the whole-document one; the guard ordering and
its per-keystroke cost; the `\|`/backtick refusal; that Reformat returns `nil` when already
aligned so a second ⌃⌘R is a true no-op; and the honest cosmetic limitation that a proportional
editor font will not visually align the padded pipes even though the file is now clean.

- [ ] **Step 4: Update the backlog**

Mark item 3 SHIPPED with the date, note what was and was not built (no alignment commands, no
size picker), and update the `**Status:** 2 of 6 shipped` line to 3 of 6.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/architecture/editor-behavior.md docs/research/2026-07-25-feature-backlog.md
git commit -m "Document table authoring"
```
