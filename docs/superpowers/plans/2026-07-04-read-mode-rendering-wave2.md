# Read-mode rendering — Wave 2 Implementation Plan (interactive checkboxes)

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> Spec: `docs/superpowers/specs/2026-07-04-read-mode-rendering-design.md` (Wave 2).
> Builds on Wave 1's list rendering.

**Goal:** Render `- [ ]` / `- [x]` task items as real checkboxes in Read/Preview, and make
clicking a box toggle it in the real document as a normal, undoable text edit.

**Architecture:** A task item is a list item whose text starts with `[ ]`/`[x]`. Grouping
records the checkbox state + the **source `NSRange`** of the `[ ]`/`[x]` in the document. The
renderer draws a check glyph carrying that range as a custom attribute. `MarkdownPreviewTextView`
maps a click on the glyph → the range → an `onCheckboxToggle` callback → `EditorContainerView`
mutates `document.text` (verifying the 3 chars first). Undo/autosave ride the normal binding.

## Global Constraints (from Wave 1 + spec)

- Read/Preview only; Write shows source. No network/analytics.
- Toggle is a normal `document.text` edit → dirty/autosave/undo "just work" (QA gate: single ⌘Z).
- Preserve scroll across the toggle re-render (glyph width is constant, so layout is unchanged).
- Dev = build-only; run full suite once at end (TCC Allow prompt).

## Tasks

### Task 1: Checkbox model + grouping (source range)
- `MarkdownBlockGrouping.swift`: add `struct MarkdownCheckbox { var isChecked: Bool; var sourceRange: NSRange }`
  and `MarkdownCheckbox.detect(in text:) -> (isChecked: Bool, remaining: String)?` matching
  `^\[([ xX])\]\s*(.*)$`. Add `checkbox: MarkdownCheckbox?` to `MarkdownListItem`; add `textColumn`
  to `MarkdownList.Parsed` (= `match.range(at: 3).location`). Compute `lineStartOffsets` (UTF-16)
  once in `markdownBlocks`; thread line index through list grouping; in `resolveListItems`, when an
  UNORDERED item's text is a checkbox, set `checkbox` (sourceRange = `lineStartOffsets[line] +
  textColumn`, length 3), strip the marker from display text, and give it no ordinal.
- Pure toggle helper `CheckboxToggle.toggledText(in:at:) -> String?` (nil if the range isn't
  `[ ]`/`[x]`).
- Tests: detection, source-range math, toggle helper.

### Task 2: Render the checkbox glyph + attribute
- `MarkdownPreviewRenderer.swift`: `NSAttributedString.Key.checkboxSourceRange` (value `NSValue`).
  In `appendList`, when `item.checkbox != nil`, emit a check glyph (☑ checked / ☐ unchecked) in
  place of the bullet, carrying `.checkboxSourceRange`, then a tab + the item text. Accessible via
  the glyph.
- Tests: glyph rendered, attribute present with the right range.

### Task 3: Click → toggle plumbing
- `MarkdownPreviewViewRepresentable.swift`: add `onCheckboxToggle: (NSRange) -> Void`; store on
  `MarkdownPreviewTextView`; override `mouseDown` → char index → read `.checkboxSourceRange` →
  fire callback (consume the click); else `super`.
- `DebouncedMarkdownPreviewView.swift`: pass `onCheckboxToggle` through.
- `EditorContainerView.swift`: in `.read`/`.split`, pass a handler that applies
  `CheckboxToggle.toggledText` to `document.text`.

### Task 4: Info modal + docs + suite + tracker
- Add `- [ ]` / `- [x]` rows to `MarkdownBasicsModal`; update its test.
- Full suite green; QA ⌘Z + scroll with the user; update CLAUDE.md + audit tracker; commit.
