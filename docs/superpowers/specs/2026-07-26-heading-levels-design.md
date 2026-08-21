# Heading Levels 1–6 — Design

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Date:** 2026-07-26
**Backlog item:** `docs/research/2026-07-25-feature-backlog.md` §5 ("Heading shortcuts beyond two")
**Status:** designed, not implemented

---

## Why

The backlog framed this as "add ⌘3–⌘6." Scoping it found that the two heading commands
Lineform already ships are broken on their main path, and that fixing them is the same change.

`MarkdownFormattingCommand.title` / `.section` route through `prefixSelection`, which prepends
`"# "` to the **raw selection** — `applyFormattingCommand` passes `selectedRange()` through
untouched (`LineformTextView.swift:1704`). Two consequences today:

1. **Headings stack.** ⌘1 on `## Section` yields `# ## Section`. That is not a heading in any
   Markdown dialect: it renders as literal `## Section` text inside an H1, and
   `MarkdownHeadingParser` cannot see it, so **the line disappears from the outline sidebar**.
   Changing the level of a line that is already a heading is the most common heading motion
   there is, and it silently damages the document's structure.
2. **Mid-line insertion.** Caret mid-word + ⌘1 inserts `# ` at the caret, splitting the word.

So the work is: make heading level something that is *set on a line*, then expose the four
missing levels and a way back to body text. The new shortcuts are the cheap part.

## Decisions

Settled with the user on 2026-07-26:

- **⌘1–⌘6 set that exact level; ⌘0 returns the line to body text.** Matches Obsidian, Typora,
  Bear, and Notion. Rejected: a raise/lower cycle pair (fewer keys, but no direct jump and
  nothing in the menu tells you what level you are on) and shipping both (eight menu rows for
  one concept).
- **Pressing the level a line already has toggles it back to body.** ⌘2 on `## Notes` gives
  `Notes`; ⌘2 again restores it. ⌘2 on `### Notes` changes the level rather than toggling.
  This matches ⌘B on bold text, the idiom the rest of the Format menu already sets.
- **Non-prose lines are skipped, not transformed.** List items, blockquotes, fenced code,
  front matter, and indented code blocks are left byte-identical; prose lines in the same
  selection are still changed. Rejected: converting a list item to a heading (destroys a
  marker the user did not ask to touch) and refusing the whole command (one stray list item
  in a selection makes ⌘2 do nothing, which reads as broken).
- **Menu shape: `Title` ⌘1 and `Section` ⌘2 stay exactly as they are**, followed by a
  `Heading` submenu holding Heading 3–6 (⌘3–⌘6), a divider, and `Body` (⌘0). No existing
  label, position, or key changes. Rejected: a flat seven-row list (retires the `Title` /
  `Section` names, or reads inconsistently if it keeps them).

## Conflict audit

Verified by grep over `Lineform/` and `LineformTests/` on 2026-07-26, not assumed:

- **⌘3, ⌘4, ⌘5, ⌘6, ⌘0 are unclaimed.** The only plain-digit shortcuts in the app are ⌘1, ⌘2
  (Format), ⇧⌘7, ⇧⌘8 (lists), and ⌥⌘0 (Toggle Outline). Tabs use ⌘[ / ⌘], **not** ⌘1–⌘9.
  There is no Actual Size / zoom-reset command competing for ⌘0.
- **`prefixSelection` has exactly two callers**, `.title` and `.section`. Deleting it is safe.
- **`.title` / `.section` have exactly two call sites** (`LineformTextView.swift:493,497`) plus
  two context-menu rows.
- **The Format menu is already gated on `activeTextFormat == .markdown`**, so the new keys are
  unbound in plain-text documents for free.
- **No user-facing shortcut tables go stale.** `Lineform/Resources/` has no shortcut listing;
  `Help.md` is prose bullets.

## Architecture

One new unit, pure and AppKit-free so it tests in the default plan — the same shape as
`MarkdownListContinuation` and `MarkdownTableEditing`:

`Lineform/Editor/MarkdownHeadingEditing.swift`

```swift
enum MarkdownHeadingEditing {
    /// `level: nil` means body text. Returns nil when nothing would change.
    static func setLevel(_ level: Int?, in text: String, selectedRange: NSRange) -> MarkdownEdit?
}
```

Returning `nil` on a no-op follows `reformatMarkdownTable`: bailing before
`applyWholeTextReplacement` is what keeps a dead keypress out of the undo stack.

`MarkdownFormattingCommand.title` / `.section` and `prefixSelection` are deleted, and the text
view's heading actions call `setLevel` directly. That is what fixes ⌘1 and ⌘2, not just the new
keys.

Headings do **not** get replacement cases in `MarkdownFormattingCommand`. `apply` returns a
non-optional `MarkdownEdit`, so a heading no-op there would have to be an identity edit, and
routing that through `applyFormattingCommand` pushes an empty step onto the undo stack — the
one thing `setLevel`'s `nil` return exists to prevent.

### Line classification

**Heading detection is local to this unit and does NOT reuse
`MarkdownHeadingParser.heading(in:)`.** That parser requires a non-empty title and trims
closing hashes, so it reports `nil` for `"## "` — a heading whose text has not been typed yet.
Reusing it would make ⌘2 on `"## "` prepend a second marker and produce `"## ## "`, which is
the exact stacking bug this change exists to remove. The local scanner instead counts up to
six leading `#` and requires the next character to be a space **or end of line**. The two agree
on every line that has content, which is the case the outline sidebar sees.

Everything else is reused:

- **Fenced code and front matter:** `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location:in:)`.
  `MarkdownListContinuation` already calls this on every Return keypress, so the cost is proven
  on a path far hotter than a menu command.
- **List markers and blockquotes:** `LinePrefix` in `MarkdownListContinuation.swift`, promoted
  from `private` to internal. One definition of "what markers start a line," rather than a
  second one drifting out of sync.
- **Indented code blocks:** four or more leading spaces. Cheap, and correct per CommonMark.
  Leading whitespace of one to three spaces is preserved and the marker written after it.

### The transform

1. Expand `selectedRange` to whole lines.
2. Classify each line. Skip blank lines and every non-prose kind above.
3. If **every** surviving line is already at the requested level, strip all of them to body.
   Otherwise set all of them to the requested level. All-or-nothing decides the toggle
   direction, so a multi-line selection never half-toggles.
4. If no line survived, or nothing would change, return `nil`.

### Selection and caret

The existing contract keeps the selection on the user's **text**, shifted past the markers —
`"Lineform"` selected `(0,8)` becomes `"# Lineform"` selected `(2,8)`. That generalizes:
shift the selection start by the first line's marker delta, and adjust its length by the deltas
of the lines inside it. A bare caret is preserved by its offset **within the line's text**, so
it does not drift when the `#` count changes under it.

One `applyWholeTextReplacement`, so one ⌘Z.

## Menu wiring

- `AppCommands.swift`: `Title` ⌘1 and `Section` ⌘2 unchanged; a `Heading` submenu after them
  with Heading 3–6 (⌘3–⌘6), a divider, and `Body` (⌘0).
- `MainMenuIconDecorator.symbolsByTitle` needs entries for the new rows, or they render bare
  against the iconed-menu invariant.
- The right-click menu keeps only `Title` and `Section`. A seven-row heading section in a
  context menu is noise.

## Testing

Default plan, against the pure unit:

- Set a level on prose; set a level on a heading of a different level.
- Re-pressing the current level toggles to body; ⌘0 from each of the six levels.
- **Regression, named for the bug:** ⌘1 on `## Section` gives `# Section`, never `# ## Section`.
- **Regression:** ⌘2 on `"## "` (empty heading) does not produce `"## ## "`.
- Caret mid-word is preserved and no marker is inserted mid-line.
- Mixed multi-line selection: prose, a list item, a blockquote, and a fenced block interleaved —
  only the prose lines change, the rest are byte-identical.
- All-or-nothing toggle direction across a multi-line selection.
- No-op returns `nil` (no empty undo step).
- The two existing `MarkdownFormattingCommandTests` heading cases must still pass **unchanged** —
  they encode the sane path, and this change must not move it.

## Out of scope

- **Setext headings** (`===` / `---` underlines) are neither recognized nor converted.
  Lineform's outline parser does not see them today, so this changes nothing.
- **Closing hashes** (`## Section ##`) are left alone.
- Renumbering, indent/outdent, or any other list behavior.

## Risks

1. **⌘1/⌘2 behavior changes for two cases** — stacking and mid-line insertion. Both are
   defects, but both are shipped. Accepted deliberately.
2. **A selection made entirely of non-prose lines is a silent no-op.** Consistent with Reformat
   Table's silent refusal, but "consistent" is not "obvious." Accepted; the alternative is
   mangling structure the user did not select for.
