# List Continuation on Return — Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing Return after a Markdown list marker, checkbox, or blockquote continues it; pressing Return on an empty marker ends the construct.

**Architecture:** A pure value type (`MarkdownListContinuation`) decides what a Return should do given `(text, selectedRange)`, returning `nil` when the text view should behave normally. A ~20-line `doCommandBy(_:)` override on `LineformTextView` applies that decision through the localized `shouldChangeText → replaceCharacters → didChangeText` edit path. All parsing logic is testable with no AppKit object graph.

**Tech Stack:** Swift, AppKit (`NSTextView`), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-26-list-continuation-design.md`

## Global Constraints

- **Never route this edit through `applyWholeTextReplacement`** (`LineformTextView.swift:1350`). It calls `setAttributedString` over the entire document — a full-document rewrite per Return, feeding the known large-document typing performance problem. Use the localized path from `LineformTextView+ImageInsertion.swift:246-248`.
- **Hook `doCommandBy(_:)`, never `keyDown`.** `keyDown` fires before input-method handling and would swallow Return during IME composition and fight the spelling-correction popup.
- **Fence/front-matter detection comes from `MarkdownWritingToolsProtection.ignoredRanges`.** `MarkdownRangeAnalyzer` is strictly line-local by load-bearing invariant and cannot see fences.
- **`ignoredRanges` scans the whole document on every call.** Only call it after a line-local prefix match has already succeeded, so Returns on ordinary prose never pay for it.
- Ordered lists **increment only** — never renumber items below the insertion point.
- Checkbox continuation **always emits `- [ ]`**, never inheriting `[x]`.
- Tab / Shift-Tab behavior is **unchanged**. Do not add an `insertTab` intercept.
- New tests go in the **default** test plan. Do not add an `NSWindow` anywhere — a bare `NSTextView` needs no window and works headless (verified 2026-07-26).
- New files must be registered in `Lineform.xcodeproj/project.pbxproj` by hand across four sections (objectVersion 56, no synced groups). Next free sequential IDs: **84** and **85**.

---

### Task 1: `MarkdownListContinuation` — the decision type

**Files:**
- Create: `Lineform/Editor/MarkdownListContinuation.swift`
- Create: `LineformTests/MarkdownListContinuationTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (four sections, IDs 84 + 85)

**Interfaces:**
- Consumes: `MarkdownWritingToolsProtection.ignoredRanges(in:enclosingRange:)` — existing, `internal`.
- Produces:
  ```swift
  enum MarkdownListContinuation.Outcome: Equatable {
      case `continue`(insertion: String)
      case terminate(clearing: NSRange)
  }
  static func MarkdownListContinuation.outcome(for text: String, selectedRange: NSRange) -> Outcome?
  ```

- [ ] **Step 1: Write the failing tests**

Cover, at minimum: each bullet character preserved (`-`, `*`, `+`); ordered increment across `.` and `)` with multi-digit rollover (`9.` → `10.`); checkbox never inheriting `[x]`; blockquote; leading-whitespace preservation; the `> -` composite; empty-marker termination per marker type; mid-line caret split; caret before the marker returning `nil`; non-empty selection; suppression inside a fence and inside front matter; `nil` for prose, headings, and empty text.

```swift
import XCTest
@testable import Lineform

final class MarkdownListContinuationTests: XCTestCase {
    private func outcome(_ text: String, _ location: Int, length: Int = 0) -> MarkdownListContinuation.Outcome? {
        MarkdownListContinuation.outcome(
            for: text,
            selectedRange: NSRange(location: location, length: length)
        )
    }

    func testContinuesHyphenBullet() {
        XCTAssertEqual(outcome("- milk", 6), .continue(insertion: "\n- "))
    }

    func testPreservesAsteriskBulletCharacter() {
        XCTAssertEqual(outcome("* milk", 6), .continue(insertion: "\n* "))
    }

    func testIncrementsOrderedItem() {
        XCTAssertEqual(outcome("3. third", 8), .continue(insertion: "\n4. "))
    }

    func testOrderedItemRollsOverToTwoDigits() {
        XCTAssertEqual(outcome("9. ninth", 8), .continue(insertion: "\n10. "))
    }

    func testCheckedCheckboxContinuesUnchecked() {
        XCTAssertEqual(outcome("- [x] done", 10), .continue(insertion: "\n- [ ] "))
    }

    func testEmptyBulletTerminates() {
        XCTAssertEqual(outcome("- ", 2), .terminate(clearing: NSRange(location: 0, length: 2)))
    }

    func testCaretBeforeMarkerDoesNotContinue() {
        XCTAssertNil(outcome("- milk", 0))
    }

    func testSuppressedInsideFencedCode() {
        XCTAssertNil(outcome("```\n- milk", 10))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownListContinuationTests`
Expected: compile failure — `MarkdownListContinuation` does not exist.

- [ ] **Step 3: Implement the type**

Parse order, all line-local and cheap: locate the line containing `selectedRange.location`; match leading whitespace, then zero or more `>` quote markers, then an optional list marker (bullet `[-*+]` / ordered `\d+[.)]`), then an optional `[ ]`/`[x]` checkbox. Return `nil` if neither a quote nor a list marker matched, or if the caret sits at or before the end of the prefix. Only after a prefix matches, consult `MarkdownWritingToolsProtection.ignoredRanges` for the line's start and return `nil` if it is protected. If the line's content after the prefix is empty or whitespace and the selection is empty, `terminate` clearing the whole line; otherwise `continue` with `"\n"` plus the rebuilt prefix.

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: all tests pass.

- [ ] **Step 5: Register both files in the pbxproj and rebuild**

Add `PBXBuildFile` + `PBXFileReference` + group child + `Sources` phase entries for each file, using ID suffixes 84 (source) and 85 (test), matching the existing `MarkdownFormattingCommand` entries at pbxproj lines 87 / 280 / 477 / 836 and 15 / 199 / 570 / 910.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/MarkdownListContinuation.swift LineformTests/MarkdownListContinuationTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add MarkdownListContinuation decision type"
```

---

### Task 2: Wire it into the text view

**Files:**
- Modify: `Lineform/Editor/LineformTextView.swift` (new `doCommandBy(_:)` override)
- Modify: `LineformTests/MarkdownListContinuationTests.swift` (adapter tests)

**Interfaces:**
- Consumes: `MarkdownListContinuation.outcome(for:selectedRange:)` from Task 1.
- Produces: no new public API — behavior only.

- [ ] **Step 1: Write the failing adapter tests**

A bare `NSTextView` subclass needs no window, so these belong in the default plan.

```swift
func testReturnInsertsContinuationMarkerInTextView() {
    let textView = LineformTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    textView.string = "- milk"
    textView.setSelectedRange(NSRange(location: 6, length: 0))

    textView.insertNewline(nil)

    XCTAssertEqual(textView.string, "- milk\n- ")
    XCTAssertEqual(textView.selectedRange().location, 9)
}

func testReturnContinuationIsASingleUndoStep() {
    let textView = LineformTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    textView.string = "- milk"
    textView.setSelectedRange(NSRange(location: 6, length: 0))

    textView.insertNewline(nil)
    textView.undoManager?.undo()

    XCTAssertEqual(textView.string, "- milk")
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — `textView.string` is `"- milk\n"`, no marker.

- [ ] **Step 3: Implement the override**

```swift
override func doCommand(by selector: Selector) {
    guard selector == #selector(insertNewline(_:)),
          let outcome = MarkdownListContinuation.outcome(for: string, selectedRange: selectedRange())
    else {
        super.doCommand(by: selector)
        return
    }

    switch outcome {
    case let .continue(insertion):
        applyListContinuationEdit(replacing: selectedRange(), with: insertion)
    case let .terminate(clearing):
        applyListContinuationEdit(replacing: clearing, with: "")
    }
}
```

with a private helper using the localized edit path:

```swift
private func applyListContinuationEdit(replacing range: NSRange, with replacement: String) {
    guard shouldChangeText(in: range, replacementString: replacement) else { return }
    textStorage?.replaceCharacters(in: range, with: replacement)
    didChangeText()
    setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    refreshMarkdownHighlighting()
    scrollRangeToVisible(selectedRange())
}
```

- [ ] **Step 4: Run to verify they pass**

- [ ] **Step 5: Run the full default test plan**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: no regressions. Report exact pass/fail counts.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/LineformTextView.swift LineformTests/MarkdownListContinuationTests.swift
git commit -m "Continue Markdown list markers on Return"
```

---

### Task 3: Documentation

**Files:**
- Modify: `docs/architecture/editor-behavior.md`
- Modify: `CLAUDE.md` (one feature line only)
- Modify: `docs/research/2026-07-25-feature-backlog.md` (mark item 1 shipped)

Update only what the change actually invalidates. Do not add entries for their own sake. The `doCommandBy`-not-`keyDown` choice and the must-not-use-`applyWholeTextReplacement` rule belong in `editor-behavior.md` — both are "do not retry this" notes. User-facing bundled docs in `Lineform/Resources/` get a line only if they already enumerate editing behaviors.

- [ ] **Step 1: Update the docs, then commit**

---

## Self-Review

**Spec coverage:** every behavior-table row maps to a Task 1 test; suppression to Task 1 Step 3; the edit path, undo, and save-status constraints to Task 2 Step 3; testing to Task 1/2; docs to Task 3. The spec's hosted-plan test is intentionally dropped — the 2026-07-26 probe proved `NSTextView` works headless, so it runs in the default plan and no test-plan quarantine lists change (keeping `TestPlanGuardTests` green without edits).

**Type consistency:** `Outcome.continue(insertion:)` and `Outcome.terminate(clearing:)` are used identically in Tasks 1 and 2. `outcome(for:selectedRange:)` matches in both.
