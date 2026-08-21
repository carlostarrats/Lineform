# Read-mode rendering — Wave 1 Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax.
> Spec: `docs/superpowers/specs/2026-07-04-read-mode-rendering-design.md`.
> Waves 2 (interactive checkboxes) and 3 (tables) get their own plans after this ships.

**Goal:** Introduce a block-grouping renderer layer (behavior-preserving) and use it to
render strikethrough, horizontal rules, blockquotes, lists, and an image placeholder in
Read/Preview modes — each with its Info-modal syntax row, accessibility, and (where
expected) a menu authoring command.

**Architecture:** A pure `MarkdownBlockGrouping` pass splits the document into lines
**once** and groups them into typed `MarkdownBlock`s. `MarkdownPreviewRenderer` renders
each block, reusing the existing heading / inline / mermaid / math emitters unchanged.
The single split folds in Task 4 (double-split cleanup). New constructs are added as new
block cases (or, for strikethrough, a new inline token) on top of the byte-identical
refactor.

**Tech Stack:** Swift, AppKit (`NSAttributedString`, `NSParagraphStyle`,
`NSTextAttachment`), XCTest.

## Global Constraints

- Read/Preview render; **Write always shows source** (unchanged).
- Read mode **keeps its themes** — never force white/black (that is PDF-only, Task 7).
- No network, account, analytics, or upload. Image placeholder never opens the file or
  network.
- Existing renderer output stays **byte-identical** through the refactor (Task 1 gate).
- Verification during dev = **build-only** (`xcodebuild build`), because a CLI *test* run
  re-signs ad-hoc and triggers a blocking TCC "access Documents" prompt. Run the full
  suite **once at the end** (warn the user; they click Allow). Default gate command:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`.
- Keep UI native/restrained; follow existing patterns (`MarkdownFormattingCommand`,
  `MarkdownBasicsModal`, `BlockRenderedAttachment`).
- New pbxproj files: add via the 4 pbxproj sections with sequential `1F0000xx` IDs
  (objectVersion 56, no synced groups).

---

### Task 1: Block-grouping layer (behavior-preserving refactor) — also Task 4

**Files:**
- Create: `Lineform/Preview/MarkdownBlockGrouping.swift`
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (route `render` through blocks)
- Test: `LineformTests/MarkdownBlockGroupingTests.swift`
- Modify (pbxproj): `Lineform.xcodeproj/project.pbxproj` (add the 2 new files)

**Interfaces:**
- Produces: `enum MarkdownBlock` with the current-behavior cases and
  `func markdownBlocks(in text: String) -> [MarkdownBlock]`.
  Initial cases (only what exists today, so the refactor changes nothing):
  ```
  enum MarkdownBlock: Equatable {
      case lines([String])          // consecutive body/heading lines rendered per-line as today
      case fencedCode([String])     // includes the fence delimiters, rendered in code style
      case mermaid(source: String)
      case mathBlock(latex: String, closed: Bool)   // closed=false when the $$ never closed
  }
  ```
  Rendering each case must emit **exactly** the bytes the current line loop emits,
  including the inter-line `\n` join and the "no trailing newline after the last line"
  rule. The simplest behavior-preserving grouping keeps most content in `.lines` (the
  existing per-line path) and only splits out the three block accumulators the current
  loop already treats specially (fenced code, mermaid, `$$` math). This is the minimal
  change that removes the second `components(separatedBy:)` and gives later tasks a seam.

**Note:** the current renderer interleaves fenced-code lines with body lines in one pass.
To stay byte-identical, `.lines` carries a maximal run of non-special lines and is
rendered by the existing per-line logic (heading vs inline-with-math), and the special
accumulators are rendered by the existing `appendMermaidBlock`/`appendMathBlock`. The
newline-between-blocks logic must reproduce today's "append `\n` unless this is the last
source line" behavior — assert it in tests.

- [ ] **Step 1: Write the failing grouping tests**

```swift
import XCTest
@testable import Lineform

final class MarkdownBlockGroupingTests: XCTestCase {
    func testPlainLinesAreOneLinesBlock() {
        XCTAssertEqual(markdownBlocks(in: "a\nb\nc"), [.lines(["a", "b", "c"])])
    }

    func testFencedCodeIsItsOwnBlockKeepingDelimiters() {
        let blocks = markdownBlocks(in: "before\n```\ncode\n```\nafter")
        XCTAssertEqual(blocks, [
            .lines(["before"]),
            .fencedCode(["```", "code", "```"]),
            .lines(["after"])
        ])
    }

    func testMermaidFenceBecomesMermaidBlockWithoutDelimiters() {
        let blocks = markdownBlocks(in: "```mermaid\ngraph TD;A-->B;\n```")
        XCTAssertEqual(blocks, [.mermaid(source: "graph TD;A-->B;")])
    }

    func testDisplayMathFenceBecomesMathBlock() {
        XCTAssertEqual(markdownBlocks(in: "$$\nx^2\n$$"), [.mathBlock(latex: "x^2", closed: true)])
    }

    func testUnclosedMathIsMarkedNotClosed() {
        XCTAssertEqual(markdownBlocks(in: "$$\nx^2"), [.mathBlock(latex: "x^2", closed: false)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail** — `markdownBlocks` undefined.

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: compile error (symbol not found in test target).

- [ ] **Step 3: Implement `MarkdownBlockGrouping.swift`**

Port the current `render` loop's block-detection (fenced code toggle, mermaid opening,
`$$` single-line and fenced) into a pure grouping function that splits **once** on `\n`.
Match the exact predicates already used: `MermaidFence.isMermaidOpening`,
`MermaidFence.isFenceDelimiter`, `MathBlockFence.blockDelimiterOnly`,
`MathBlockFence.singleLineBlock`. Non-special lines accumulate into `.lines`.

- [ ] **Step 4: Route `MarkdownPreviewRenderer.render` through the blocks**

Replace the inline `while` loop's block bookkeeping with: `for block in markdownBlocks(in:
text)` → a `render(block:...)` switch that calls the **existing** private emitters. Keep
`reportRegistry.reset()`, the block-spacing line-index logic, and the inter-block newline
rule. Delete the now-dead second `components(separatedBy:)` if present (Task 4).

- [ ] **Step 5: Run the full existing renderer tests — must stay green (byte-identical)**

Because this needs the test target, defer to the end-of-wave suite run; for now
`xcodebuild build` must succeed. The gate: `MarkdownPreviewRendererTests`,
`MarkdownPreviewRendererMathTests`, `MarkdownPreviewRendererBackgroundTests`, and the
new grouping tests all pass unchanged in the final suite run.

- [ ] **Step 6: Commit** — `Task 6 Wave 1: block-grouping renderer layer (behavior-preserving; folds Task 4)`

---

### Task 2: Strikethrough `~~text~~`

**Files:**
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (new inline token `.strikethrough`)
- Modify: `Lineform/Editor/MarkdownFormattingCommand.swift` (`.strikethrough` wrap toggle)
- Modify: `Lineform/Editor/LineformTextView.swift` (`@objc toggleStrikethroughMarkdown`)
- Modify: `Lineform/App/AppCommands.swift` (Format menu button, ⌘⇧X)
- Modify: `Lineform/Editor/EditorChromeAndControls.swift` (`MarkdownBasicsModal` row)
- Test: `LineformTests/MarkdownPreviewRendererTests.swift`, `MarkdownFormattingCommandTests.swift`

**Interfaces:**
- Consumes: existing `InlineToken` / `nextInlineToken` machinery.
- Produces: `InlineToken.Kind.strikethrough`; `MarkdownFormattingCommand.strikethrough`.

- [ ] **Step 1: Failing render test**

```swift
func testReadModeRendersStrikethroughAndHidesMarkers() throws {
    let rendered = MarkdownPreviewRenderer().render("done ~~old~~ text", profile: .original)
    XCTAssertEqual(rendered.string, "done old text")
    let style = rendered.attribute(.strikethroughStyle,
        at: ("done " as NSString).length, effectiveRange: nil) as? Int
    XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
}
```

- [ ] **Step 2: Failing formatting-command test**

```swift
func testStrikethroughWrapsAndUnwrapsSelection() {
    let edit = MarkdownFormattingCommand.strikethrough.apply(to: "old", selectedRange: NSRange(location: 0, length: 3))
    XCTAssertEqual(edit.text, "~~old~~")
}
```

- [ ] **Step 3: Run to verify fail** — `xcodebuild build` compile error (no `.strikethrough`).

- [ ] **Step 4: Implement**

- Add `strikethrough` regex `#"~~([^~\n]+)~~"#` and a `.strikethrough` case; in `nextInlineToken`
  `consider(...)` it; in `InlineToken.attributes` set
  `attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue`.
- Add `case strikethrough` to `MarkdownFormattingCommand`, mapping to
  `toggleMarkers("~~", ...)`.
- Add `@objc func toggleStrikethroughMarkdown(_:)` → `applyFormattingCommand(.strikethrough)`.
- Add Format-menu `Button("Strikethrough")` with `.keyboardShortcut("x", modifiers: [.command, .shift])`.
- Add `Example(label: "Strikethrough", syntax: "~~text~~")` to `MarkdownBasicsModal.examples`.

- [ ] **Step 5: Run to verify pass** (final suite) — build green now.

- [ ] **Step 6: Commit** — `Task 6 Wave 1: strikethrough (render + ⌘⇧X + Info)`

---

### Task 3: Horizontal rule `---` / `***` / `___`

**Files:**
- Modify: `Lineform/Preview/MarkdownBlockGrouping.swift` (`.horizontalRule` case + detection)
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (render the rule)
- Create: `Lineform/Preview/HorizontalRuleAttachment.swift` (thin divider attachment)
- Modify: `Lineform/Editor/EditorChromeAndControls.swift` (Info row)
- Test: `MarkdownBlockGroupingTests.swift`, `MarkdownPreviewRendererTests.swift`
- Modify (pbxproj): add `HorizontalRuleAttachment.swift`

**Interfaces:**
- Produces: `MarkdownBlock.horizontalRule`; `HorizontalRuleAttachment: BlockRenderedAttachment`.

- [ ] **Step 1: Failing grouping tests (with the two gotchas)**

```swift
func testStandaloneDashesAreHorizontalRule() {
    XCTAssertEqual(markdownBlocks(in: "a\n\n---\n\nb"),
        [.lines(["a", ""]), .horizontalRule, .lines(["", "b"])])
}
func testFrontMatterDashesAreNotARule() {
    // Leading `---` at the very top delimiting front matter is not a rule.
    let blocks = markdownBlocks(in: "---\ntitle: x\n---\nbody")
    XCTAssertFalse(blocks.contains(.horizontalRule))
}
func testSetextUnderlineDashesAreNotARule() {
    // `---` directly under a text line is a heading underline, not a rule.
    let blocks = markdownBlocks(in: "Heading\n---\nbody")
    XCTAssertFalse(blocks.contains(.horizontalRule))
}
```

- [ ] **Step 2: Failing render test**

```swift
func testHorizontalRuleRendersAsAttachment() throws {
    let rendered = MarkdownPreviewRenderer().render("a\n\n---\n\nb", profile: .original)
    var hasRule = false
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { v, _, _ in
        if v is HorizontalRuleAttachment { hasRule = true }
    }
    XCTAssertTrue(hasRule)
}
```

- [ ] **Step 3: Run to verify fail** — build error.

- [ ] **Step 4: Implement**

- Detection helper `MarkdownHorizontalRule.isRule(_ trimmed:)` = `^([-*_])\1{2,}$` after
  removing spaces; guard front-matter (first line, doc opens with `---`) and setext
  (previous non-empty line is text AND marker is `-`/`=`) in the grouping pass, where the
  surrounding lines are known.
- `HorizontalRuleAttachment` draws a 1pt low-contrast line; sized to column width so
  `BlockAttachmentRefit` handles resize (it is a `BlockRenderedAttachment`). Color from
  the theme text color at low alpha (contrast-safe on every theme by construction).
- Render `.horizontalRule` → the attachment + trailing `\n` per the inter-block rule.
- Info row: `Row(label: "---", detail: "A horizontal divider on its own line.")`.

- [ ] **Step 5: Verify pass** (final suite); build green.

- [ ] **Step 6: Commit** — `Task 6 Wave 1: horizontal rule (render + Info; front-matter/setext-safe)`

---

### Task 4: Blockquote `> quote` (incl. nested `>>`)

**Files:**
- Modify: `Lineform/Preview/MarkdownBlockGrouping.swift` (`.blockquote(depth:lines:)`)
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (indent + left bar)
- Modify: `Lineform/Editor/MarkdownFormattingCommand.swift` (`.blockquote` line-prefix)
- Modify: `Lineform/Editor/LineformTextView.swift` + `AppCommands.swift` (menu, no default shortcut)
- Modify: `Lineform/Editor/EditorChromeAndControls.swift` (Info row)
- Test: `MarkdownBlockGroupingTests.swift`, `MarkdownPreviewRendererTests.swift`, `MarkdownFormattingCommandTests.swift`

**Interfaces:**
- Produces: `MarkdownBlock.blockquote(depth: Int, lines: [String])` (lines with the
  leading `>`/spaces stripped, one depth level per run for v1 — nested `>>` raises depth).

- [ ] **Step 1: Failing grouping test**

```swift
func testBlockquoteGroupsContiguousQuotedLinesStrippingMarkers() {
    XCTAssertEqual(markdownBlocks(in: "> a\n> b\nafter"),
        [.blockquote(depth: 1, lines: ["a", "b"]), .lines(["after"])])
}
func testNestedBlockquoteRaisesDepth() {
    XCTAssertEqual(markdownBlocks(in: ">> deep"),
        [.blockquote(depth: 2, lines: ["deep"])])
}
```

- [ ] **Step 2: Failing render test**

```swift
func testBlockquoteIndentsAndHidesMarker() throws {
    let rendered = MarkdownPreviewRenderer().render("> quoted", profile: .original)
    XCTAssertEqual(rendered.string, "quoted")
    let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertGreaterThan(style.headIndent, 0)
    XCTAssertGreaterThan(style.firstLineHeadIndent, 0)
}
```

- [ ] **Step 3: Run to verify fail** — build error.

- [ ] **Step 4: Implement**

- Grouping: a line matching `^\s*>` starts/continues a quote; count leading `>` for depth;
  strip markers + one optional space. Inner lines rendered with the existing
  inline-with-math path so bold/links/etc. work inside quotes.
- Render: paragraph style with `firstLineHeadIndent`/`headIndent = depth * indentStep`
  (indentStep from the reading profile / a small constant), plus a left vertical bar via
  a leading `HorizontalRuleAttachment`-style vertical rule OR a `.paragraphStyle`
  left-border draw. Keep quote text contrast-safe if dimmed (use theme text color, not a
  hardcoded grey).
- `MarkdownFormattingCommand.blockquote` = `prefixSelectedLines("> ", ...)`.
- Menu `Button("Blockquote")` (no default shortcut); `@objc toggleBlockquoteMarkdown`.
- Info row: `Row(label: "> quote", detail: "A quiet indented quote block.")`.

- [ ] **Step 5: Verify pass**; build green.

- [ ] **Step 6: Commit** — `Task 6 Wave 1: blockquote (render + menu + Info; nested)`

---

### Task 5: Lists — bulleted (`-`/`*`/`+`) and numbered (`1.`)

**Files:**
- Modify: `Lineform/Preview/MarkdownBlockGrouping.swift` (`.list(ordered:items:)`)
- Create: `Lineform/Preview/MarkdownListRendering.swift` (hanging-indent paragraph styles + item model)
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (render list block)
- Modify: `MarkdownFormattingCommand.swift` + `LineformTextView.swift` + `AppCommands.swift` (ordered-list command)
- Modify: `Lineform/Editor/EditorChromeAndControls.swift` (Info row)
- Test: `MarkdownBlockGroupingTests.swift`, `MarkdownListRenderingTests.swift` (new), `MarkdownPreviewRendererTests.swift`
- Modify (pbxproj): add the 2 new files

**Interfaces:**
- Produces:
  ```
  struct MarkdownListItem: Equatable { var text: String; var indentLevel: Int; var ordinal: Int? }
  case list(ordered: Bool, items: [MarkdownListItem])
  ```
  `ordinal` = the display number for ordered items (resolved during grouping so nested
  levels count independently); nil for bullets.

- [ ] **Step 1: Failing grouping tests**

```swift
func testUnorderedListGroupsItems() {
    XCTAssertEqual(markdownBlocks(in: "- one\n- two"),
        [.list(ordered: false, items: [
            .init(text: "one", indentLevel: 0, ordinal: nil),
            .init(text: "two", indentLevel: 0, ordinal: nil)])])
}
func testOrderedListNumbersSequentially() {
    XCTAssertEqual(markdownBlocks(in: "1. a\n2. b"),
        [.list(ordered: true, items: [
            .init(text: "a", indentLevel: 0, ordinal: 1),
            .init(text: "b", indentLevel: 0, ordinal: 2)])])
}
func testNestedListRaisesIndentLevel() {
    let blocks = markdownBlocks(in: "- top\n  - nested")
    XCTAssertEqual(blocks, [.list(ordered: false, items: [
        .init(text: "top", indentLevel: 0, ordinal: nil),
        .init(text: "nested", indentLevel: 1, ordinal: nil)])])
}
```

- [ ] **Step 2: Failing render test (hanging indent)**

```swift
func testListItemHasHangingIndent() throws {
    let rendered = MarkdownPreviewRenderer().render("- item", profile: .original)
    XCTAssertTrue(rendered.string.contains("item"))
    XCTAssertTrue(rendered.string.contains("\u{2022}"))  // bullet glyph rendered
    let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertGreaterThan(style.headIndent, style.firstLineHeadIndent) // wraps hang under text
}
```

- [ ] **Step 3: Run to verify fail** — build error.

- [ ] **Step 4: Implement**

- `MarkdownListRendering` builds each item string as `<marker>\t<text>` with an
  `NSParagraphStyle` carrying a tab stop and `headIndent` at the text column so wrapped
  lines hang; `firstLineHeadIndent` at the indent column; indentLevel multiplies a step.
  Bullets use `•`; ordered uses `\(ordinal).`. Lean on reading-profile spacing for
  tight/loose (blank line between items → block spacing).
- Grouping: detect `^(\s*)([-*+]|\d+[.)])\s+`; indentLevel from leading-space width
  buckets; ordered vs unordered from the marker; resolve ordinals per level.
- `MarkdownFormattingCommand.orderedList` = `prefixSelectedLines("1. ", ...)`; menu
  `Button("Numbered List")` ⌘⇧7 (bulleted stays ⌘⇧8).
- Info row: `Row(label: "1. item", detail: "A numbered list; \"- item\" makes a bullet.")`.

- [ ] **Step 5: Verify pass**; build green.

- [ ] **Step 6: Commit** — `Task 6 Wave 1: lists bulleted+numbered (hanging indent, nesting) + Info`

---

### Task 6: Image placeholder `![alt](url)`

**Files:**
- Modify: `Lineform/Preview/MarkdownBlockGrouping.swift` OR inline token (decide: image
  can appear mid-line, so treat as an **inline token** `.image` in the tokenizer, like link)
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (render placeholder)
- Modify: `Lineform/Editor/EditorChromeAndControls.swift` (Info row)
- Test: `MarkdownPreviewRendererTests.swift`

**Interfaces:**
- Produces: `InlineToken.Kind.image` — captures alt text; renders `🖼 <alt>` in a subtle
  caption color; **never** touches the file or network.

- [ ] **Step 1: Failing render test**

```swift
func testImageRendersQuietPlaceholderWithAltTextAndNoStrayBang() {
    let rendered = MarkdownPreviewRenderer().render("![a cat](cat.png)", profile: .original)
    XCTAssertTrue(rendered.string.contains("a cat"))
    XCTAssertTrue(rendered.string.contains("\u{1F5BC}"))  // 🖼
    XCTAssertFalse(rendered.string.contains("!"))
    XCTAssertFalse(rendered.string.contains("cat.png")) // URL not shown, file never touched
}
```

- [ ] **Step 2: Run to verify fail** — build error / assertion fail.

- [ ] **Step 3: Implement**

- Add image regex `#"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#`; it must be considered **before**
  the link regex (image `![` starts with `!` so ranges differ, but ensure the link regex
  doesn't swallow the `[...]` — the `!` precedes, so link starts one char later; ordering
  by position handles it). Emit `🖼 ` + alt in a caption color (theme text at ~0.6 alpha),
  no URL, no attachment, no file access.
- Info row: `Row(label: "![alt](url)", detail: "Images show as a labelled placeholder (files aren't opened).")`.

- [ ] **Step 4: Verify pass**; build green.

- [ ] **Step 5: Commit** — `Task 6 Wave 1: image placeholder (file-free, network-free) + Info`

---

### Task 7: Full-suite verification + docs + tracker

- [ ] **Step 1:** Run the full default test suite once (warn user re TCC Allow prompt):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`.
  Report exact pass/fail counts. Fix any red; re-run.
- [ ] **Step 2:** Update `CLAUDE.md` Main Features (Read-mode now renders strikethrough,
  HR, blockquote, lists, image placeholder) — only if the behavior summary needs it.
- [ ] **Step 3:** Check the "Task 6 Wave 1" box in
  `docs/audits/2026-07-04-audit-decisions.md` with date + branch/commit.
- [ ] **Step 4:** Commit docs + tracker.

## Self-Review

- **Spec coverage:** strikethrough ✓ (T2), HR ✓ (T3), blockquote ✓ (T4), lists ✓ (T5),
  image placeholder ✓ (T6), block layer + Task 4 ✓ (T1), Info modal per construct ✓,
  menu affordances ✓ (strikethrough/blockquote/ordered-list), accessibility via native
  attributes (`.strikethroughStyle`, separator attachment, paragraph indent, list
  structure). Checkboxes/tables are Waves 2–3 (out of this plan by design).
- **Placeholders:** none — every step has concrete code/commands.
- **Type consistency:** `MarkdownBlock`, `markdownBlocks(in:)`, `MarkdownListItem`,
  `InlineToken.Kind` additions, and command cases are named consistently across tasks.
