# Table Authoring Help — Design

**Date:** 2026-07-26
**Status:** Design approved, not started.
**Source:** Item 3 of `docs/research/2026-07-25-feature-backlog.md`.

---

## Problem

Lineform renders GFM pipe tables well — `NSTextTable`, per-column alignment, ragged rows
padded to the delimiter's column count (`docs/architecture/rendering.md`). It offers nothing
for *writing* one. `MarkdownFormattingCommand` is title / section / bold / italic /
inlineCode / strikethrough / blockquote / unorderedList / orderedList / link. Authoring a
table means typing every pipe by hand and then hand-padding the columns so the source is
readable.

## Verified starting state

Read on 2026-07-26 from source, no build run:

1. **No table command exists.** `MarkdownFormattingCommand` (`Lineform/Editor/MarkdownFormattingCommand.swift:81`)
   has ten cases, none of them table-related.
2. **A parser already exists and is pure.** `MarkdownTableParser`
   (`Lineform/Preview/MarkdownBlockGrouping.swift:90`) supplies `looksLikeRow`,
   `isDelimiterRow`, `cells(in:)`, `alignment(of:)`, and `parse(header:delimiter:body:)`.
   It lives in `Preview/` but has no rendering dependencies.
3. **The renderer's table-detection rules live at `MarkdownBlockGrouping.swift:427-444`:**
   a row line, followed by a delimiter row, with *equal cell counts*; the body is the run of
   consecutive `looksLikeRow` lines that follows.
4. **One key intercept exists**, `LineformTextView.insertNewline`
   (`Lineform/Editor/LineformTextView.swift:401`), added for list continuation. Tab is
   untouched and currently inserts a literal tab everywhere.
5. **⌥⌘T is unavailable.** The app's View menu carries `toggleToolbarShown:`
   (`Lineform/App/MainMenuIconDecorator.swift:173`), which owns ⌥⌘T, and ⌘T is New Tab
   (`AppCommands.swift:549`). The app defines no `.control`-modified shortcuts at all.

## Scope

Three commands:

- **Format ▸ Insert Table** (⌃⌘T) — inserts a fixed 3-column × 2-body-row skeleton.
- **Format ▸ Reformat Table** (⌃⌘R) — pads the pipes of the table under the caret.
- **Tab / Shift-Tab** — move between cells when, and only when, the caret is inside a table.

Explicitly **not** in scope: alignment commands (setting a column to `:-:` stays a
two-character hand edit, which Reformat then respects), automatic reformat-as-you-type, and
a size picker for Insert.

### Why a fixed size and not a picker

Every other Format command is a single verb that acts immediately. A modal size sheet would
be the only formatting command that stops the writer to ask a question, against a stated
product value. iA Writer, Bear, and Obsidian all insert a starter table; the size-picker
idiom belongs to Word and Numbers, where the table *is* the document. Once Reformat exists,
gaining a fourth column is typing a pipe and pressing ⌃⌘R — cheaper than any dialog.

---

## Architecture

### `Lineform/Editor/MarkdownTableEditing.swift` (new)

Pure over `(text, selectedRange)` — no AppKit, no view state — so the whole decision surface
is testable in the default test plan without a window. Same shape and same rationale as
`MarkdownListContinuation`.

```
struct TableRegion {
    var range: NSRange          // whole table block in the document, no trailing newline
    var table: MarkdownTable    // parsed, via MarkdownTableParser
    var lineRanges: [NSRange]   // one per source line: header, delimiter, body…
}

enum TabOutcome: Equatable {
    case select(NSRange)                        // pure selection move, edits nothing
    case appendRow(insertion: String, at: Int, selecting: NSRange)
    case stay                                   // consume the key, do nothing
}

enum MarkdownTableEditing {
    static func locate(in text: String, at location: Int) -> TableRegion?
    static func insertion(in text: String, selectedRange: NSRange) -> MarkdownEdit
    static func reformat(in text: String, selectedRange: NSRange) -> MarkdownEdit?
    static func tabTarget(in text: String, selectedRange: NSRange, forward: Bool) -> TabOutcome?
}
```

`reformat` and `tabTarget` return `nil` when there is no table under the caret or a guard
refuses; the caller then does nothing (Reformat) or falls through to `super` (Tab).

### `locate` reuses the renderer's rules

`locate` must apply the *same* header/delimiter/equal-column-count test as
`MarkdownBlockGrouping.swift:427-444`, calling `MarkdownTableParser` rather than
reimplementing it. This is the `FileIdentity` lesson: if the editor's definition of "a table"
and the renderer's definition diverge, Tab intercepts a construct that does not render as a
table, and Reformat rewrites something the reader never saw as one.

`locate` scans up from the caret line to the block's first line and down to its last, so a
caret anywhere in the table — including the delimiter row — finds the whole region.

---

## Undo: two different paths, deliberately

- **Insert and Reformat** are one-shot commands. They go through
  `applyWholeTextReplacement` (`LineformTextView.swift:1669`), exactly like Bold and Link.
  One ⌘Z reverses the whole thing.
- **Tab is a per-keystroke edit.** Per the invariant in `CLAUDE.md`, it must use the
  localized `replaceCharacters` path and never `applyWholeTextReplacement`, which rewrites
  the entire document. Most Tabs edit nothing at all — `.select` is a pure selection move.
  Only `.appendRow` writes, and it writes one localized insertion.

The key overrides are `insertTab(_:)` and `insertBacktab(_:)`, the same command family as the
existing `insertNewline` override — **never `keyDown`**, which fires before input-method
handling.

---

## Guards

Ordered cheap-to-expensive, because Tab runs on every keystroke of that key. This is the same
ordering `MarkdownListContinuation` uses and for the same reason.

1. **Line-local:** the caret's line must satisfy `MarkdownTableParser.looksLikeRow`. This
   fails for essentially all prose, and it is the only work an ordinary Tab pays for. On
   failure, `super.insertTab`, and a literal tab is inserted as it is today.
2. **Block-local:** `locate` must find a complete table (delimiter row present, column counts
   equal). A lone pipe-containing line is not a table.
3. **Whole-document, only after 1 and 2 pass:**
   `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter` — a pipe table inside a fenced
   code block is code, and neither Tab nor Reformat may touch it.
4. **Reformat only — refuse on `\|` or any backtick inside the region.**
   `MarkdownTableParser.cells(in:)` splits on every pipe; escaped pipes are a documented v1
   limitation. That limitation is harmless while rendering, but Reformat *rewrites the file*,
   so the same wrong split would permanently destroy `a \| b` or `` `a|b` ``. The backtick
   half of the test is deliberately over-broad: it refuses on some tables it could safely
   reformat, and it never corrupts one.

A refused Reformat is a silent no-op — no edit, no undo step, no alert. A refused Tab falls
through to `super` and inserts a literal tab.

---

## Reformat rules

For each column, width = the maximum grapheme count across the header cell, the body cells,
and 3 (a delimiter cell needs at least `---`). Output is:

```
| Fruit | Colour | In season |
| ----- | ------ | --------- |
| Plum  | purple | August    |
```

- Leading and trailing pipes are always emitted, whether or not the input had them.
- Cell content is trimmed, then padded on the right to the column width.
- The delimiter row preserves each column's existing alignment colons: `---`, `:--`, `--:`,
  `:-:`. Alignment is read via `MarkdownTableParser.alignment(of:)` and re-emitted, so
  Reformat never silently changes how a column renders.
- Ragged rows are padded or truncated to the delimiter's column count — the same `fit`
  behaviour the renderer already applies, now made visible in the source.
- Line indentation preceding the table is preserved on every emitted line.

**Reformat is idempotent**, expressed as: it returns `nil` when the table is already aligned.
That is stronger than equality — it means a second ⌃⌘R is a true no-op that registers no undo
step at all, rather than a redundant rewrite. It is a test, not a hope.

### Known cosmetic limitation

Grapheme count is not display width: CJK and emoji cells will be under-padded. More
importantly, **the editor font may be proportional, in which case padded pipes do not
visually line up inside Lineform itself.** The payoff is the file — aligned source is
readable in any monospace editor and produces clean Git diffs, which is the "real files"
product thesis. This is worth stating plainly in the docs so Reformat does not read as
broken.

---

## Insert placement

- Caret on a blank line → the table is written at that line.
- Otherwise → the table is inserted after the caret's line, separated by one blank line, so
  it always forms its own block. A trailing blank line is added when the following line is
  non-empty.
- The caret lands as a zero-length selection in the first header cell.

The skeleton, 3 columns × 2 body rows, all columns left-aligned:

```
|     |     |     |
| --- | --- | --- |
|     |     |     |
|     |     |     |
```

Two body rows rather than one so the shape of the construct is legible the moment it lands.

---

## Tab behaviour

Operates on the line containing `selectedRange.location`. If the selection spans more than
one line, Tab falls through to `super`.

- **Tab** → select the next cell's content. **Shift-Tab** → the previous cell's.
- "Next cell" walks left-to-right across a row, then to the first cell of the next row,
  crossing the header → delimiter boundary by *skipping the delimiter row* — nobody wants to
  Tab into `---`.
- The selected range is the cell's *trimmed content*, so typing replaces it. An empty cell
  yields a zero-length selection positioned one space after its opening pipe.
- **Tab in the last cell of the last row** appends a new empty row, padded to the current
  column widths, and selects its first cell. This is `.appendRow`, the only Tab that edits.
- **Shift-Tab in the first header cell** is a consumed no-op (`.stay`). Inserting a literal tab
  at the head of a table would corrupt it, and moving focus out of the editor would be worse.

---

## Menu wiring

Two new entries in the existing `CommandMenu("Format")` block
(`Lineform/App/AppCommands.swift:361`), in their own `Section` below the list commands,
posting notifications the same way every other Format item does. They do **not** become
`MarkdownFormattingCommand` cases: that enum's `apply` returns a non-optional `MarkdownEdit`,
and Reformat must be able to decline. Instead the text view gains one small entry point that
asks `MarkdownTableEditing` for an edit and returns early on `nil`, then hands any real edit
to the same `applyWholeTextReplacement` the formatting commands use.
`MainMenuIconDecorator` gains SF Symbols for both rows (`tablecells` and
`tablecells.badge.ellipsis`), per the requirement that every main-menu row carries an icon.

Reformat is a silent no-op when there is no table under the caret rather than a disabled menu
item. Disabling would require `validateMenuItem:` plumbing through the responder chain for a
command whose only failure mode is "nothing happened"; that plumbing can be added later if
the silence proves confusing.

---

## Testing

All four entry points are pure, so everything below runs in the **default** test plan with no
`NSWindow`. New file `LineformTests/MarkdownTableEditingTests.swift`.

**Detection, including the near-misses that must NOT be treated as tables:**
- a bare `---` under a pipe-containing line (setext heading / thematic break)
- header and delimiter rows with mismatched column counts
- a single pipe line with no delimiter row
- a table inside a fenced code block, and inside YAML front matter
- caret on the delimiter row, first line, and last line of a real table

**Reformat:**
- pads a ragged table to aligned columns
- idempotence
- preserves `:--`, `--:`, `:-:` alignment
- pads and truncates rows to the delimiter's column count
- preserves leading indentation
- refuses (returns `nil`) on `\|` and on a backtick anywhere in the region
- returns `nil` when the caret is not in a table

**Insert:**
- on a blank line, at end of document, mid-paragraph, and on the first line of the document
- resulting caret sits in the first header cell

**Tab:**
- forward and backward across a row
- wraps to the next row and skips the delimiter row in both directions
- last cell appends a row with the correct column count and padding
- Shift-Tab in the first header cell is a no-op
- returns `nil` outside a table, and inside a fenced code block

The `LineformTextView` overrides stay thin — parse, then apply through one of the two
existing edit paths — so they carry no logic of their own to test.

## Manual QA

Pure tests cannot show that the key actually arrives. In a Debug build, launched with
`open -a "$BUILT_PRODUCTS_DIR/Lineform.app" file.md`:

1. ⌃⌘T on a blank line inserts the skeleton with the caret in the first header cell.
2. Tab walks the cells; Tab off the last cell adds a row.
3. Tab in ordinary prose still inserts a literal tab.
4. ⌘Z after Insert removes the whole table in one step; ⌘Z after an appended row removes just
   that row.
5. ⌃⌘R on a hand-typed ragged table aligns it; a second ⌃⌘R changes nothing.
6. ⌃⌘R inside a fenced code block containing a pipe table does nothing.
7. The rendered Read mode output is unchanged before and after a Reformat.

## Risk

Low–medium. The genuinely risky piece is Tab: it is the editor's second key intercept, it
lands in the same undo/autosave/visual-anchor machinery documented in
`docs/architecture/editor-behavior.md`, and its `.select` outcome touches selection state —
the area that produced a defect in the spell-check work. Read that file before implementing.
