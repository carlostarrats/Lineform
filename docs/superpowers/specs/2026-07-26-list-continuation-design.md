# List Continuation on Return — Design

**Date:** 2026-07-26
**Status:** Design approved, not started.
**Source:** Item 1 of `docs/research/2026-07-25-feature-backlog.md` (ranked highest everyday impact).

---

## Problem

Pressing Return after `- milk` yields a bare empty line. The writer retypes `- ` for every
item of every list. The same holds for numbered lists, task checkboxes, and blockquotes.

Every comparable editor — Bear, iA Writer, Byword, Obsidian, and every GitHub comment box —
continues the marker. Its absence reads as unfinished to anyone arriving from another editor,
and a new user meets it within the first minute of typing.

## Verified starting state

The backlog doc flagged this as a static-read claim needing confirmation in a real build.
It was confirmed on 2026-07-26 by two independent checks, so **it is no longer an open
assumption and does not need re-testing before implementation.**

1. **No key intercept exists.** `grep` for `doCommandBy`, `insertNewline`, `keyDown`,
   `insertTab`, `shouldChangeTextIn`, and `performKeyEquivalent` across `Lineform/Editor/`
   and `Lineform/App/` returns exactly one hit: the `ManualSaveIntentMonitor` ⌘S observer in
   `AppCommands.swift:19`, which is pure observation and returns every event unchanged.
   This feature would be the editor's first keyboard intercept.

2. **AppKit supplies nothing for free.** A standalone AppKit probe configured to match
   `configureForMarkdownEditing()` (`LineformTextView.swift:583-590`) called
   `insertNewline(nil)` against each marker type. Every case appended a bare `\n`:

   | Input | Result |
   |---|---|
   | `- milk` | `- milk\n` |
   | `* milk` | `* milk\n` |
   | `1. first` | `1. first\n` |
   | `- [x] done` | `- [x] done\n` |
   | `> quoted` | `> quoted\n` |
   | `- ` (empty marker) | `- \n` |

   A control probe with `isRichText = true` behaved identically, confirming that AppKit's
   list continuation is driven by `NSTextList` paragraph attributes, not by text content.
   Lineform sets `isRichText = false` (`LineformTextView.swift:585`), so those attributes can
   never be present. There is no configuration flag being missed.

## Scope

**In:**

- Return continues bullets (`-` `*` `+`), ordered items (`1.` / `1)`), task checkboxes
  (`- [ ]` / `- [x]`), and blockquotes (`>`).
- Return on a marker with no content after it clears the marker — this is how the writer
  exits a list.
- Ordered lists increment only.

**Out, deliberately:**

- **Tab / Shift-Tab indent and outdent.** Tab keeps inserting a literal tab everywhere.
  This is the only part of the original backlog scope that would *remove* existing behavior,
  and Tab is also a standard accessibility focus key. It can be added later against a proven
  Return path; nesting remains possible by typing leading spaces.
- **Renumbering the remainder of a list.** Inserting an item mid-list leaves the numbers below
  it untouched. Renumbering is a multi-line edit that must stay one undo step and must not
  disturb the caret; GFM renders `1. 2. 2.` as 1, 2, 3 regardless, so the cost is cosmetic and
  confined to the source text.
- **A separate escape hatch** (⌥Return / ⇧Return for an uncontinued newline). The
  empty-marker exit already covers "I want a plain line" with a key the writer is pressing
  anyway. A second mechanism is redundant surface.

## Behavior

| Line containing the caret | Return produces |
|---|---|
| `- milk` | `- ` |
| `* milk` | `* ` — the line's own marker character is preserved |
| `+ milk` | `+ ` |
| `3. third` | `4. ` |
| `3) third` | `4) ` — the line's own separator is preserved |
| `- [ ] todo` | `- [ ] ` |
| `- [x] done` | `- [ ] ` — **always unchecked, never inherits the mark** |
| `> quoted` | `> ` |
| `    - nested` | `    - ` — leading whitespace is preserved verbatim |
| `> - item` | `> - ` — composite prefixes are preserved as a unit |
| `- ` (marker only, or marker + trailing whitespace) | marker cleared; blank line; caret at line start |
| Caret mid-line, e.g. `- mi‸lk` | splits into `- mi` and `- lk` |
| Non-empty selection, e.g. `- mi[lk se]lection` | selection is replaced by the continuation, same as any typed character replacing a selection; the decision is made from the line containing the selection's **start** |
| Any other line | a normal blank line, exactly as today |

### Exiting a list

The exit is the same key the writer is already pressing:

```
- milk⏎
- eggs⏎
- bread⏎
- ‸              ← empty bullet
   ⏎             ← Return again
‸                ← marker gone, blank line, list ended
```

This rule is not a nicety, it is half the feature. Without it every list ends with an
unwanted marker the writer must backspace away twice — which is worse than no continuation
at all. It applies mid-document too: two Returns move from a list into a plain paragraph.

"Empty" means the marker plus optional trailing whitespace and nothing else. `- `, `-`,
`1. `, and `- [ ] ` all qualify.

### Suppression

No continuation inside fenced code blocks or YAML front matter. A `- foo` line inside a
```` ``` ```` fence is code, not a list.

## Architecture

Two pieces, split so that all the logic is testable without a window.

### 1. `Lineform/Editor/MarkdownListContinuation.swift` — new file, pure Swift, no AppKit

```swift
struct MarkdownListContinuation {
    enum Outcome: Equatable {
        /// Replace the selection with this string, e.g. "\n- " or "\n4. ".
        case `continue`(insertion: String)
        /// Clear an empty marker: replace this range with "".
        case terminate(clearing: NSRange)
    }

    static func outcome(for text: String, selectedRange: NSRange) -> Outcome?
}
```

`nil` means "not a continuable line — let the text view behave normally." All parsing lives
here: prefix detection, marker and separator preservation, indentation preservation, ordered
increment, the empty-marker test, and fence / front-matter suppression.

Being a pure value type over `(String, NSRange)`, it is exhaustively testable with no AppKit
object graph and no window.

### 2. A `doCommandBy(_:)` override on `LineformTextView` — roughly fifteen lines

Intercepts `insertNewline(_:)` only. Asks the struct; applies the outcome; calls `super` for
every other selector and whenever the struct returns `nil`.

Three constraints this design exists to protect. Each corresponds to a documented failure
mode in this repo:

**It hooks `doCommandBy`, not `keyDown`.** `keyDown` fires before input-method handling, so it
would swallow Return while a Japanese or Chinese IME is committing a composition, and it would
fight the spelling-correction popup if backlog item 2 (live spell check) ships.
`doCommandBy` runs after both. Cheap to get right now, painful to retrofit.

**It must NOT reuse `applyWholeTextReplacement`.** Every existing formatting command routes
through it (`LineformTextView.swift:1350`), doing `setAttributedString` across the *entire*
document. On a per-Return keystroke that is a full-document rewrite per press, feeding
directly into the known large-document typing performance problem. Copying the nearest
formatting command is the obvious wrong move and should be called out in review.

The correct seam already exists: the localized
`shouldChangeText → replaceCharacters → didChangeText` path established by
`LineformTextView+ImageInsertion.swift:246-248`. It yields undo registration, the
`document.text` binding sync, re-highlighting, and correct per-tab undo managers
(`MarkdownTextViewRepresentable.swift:294`) without further work.

**Fence detection comes from `MarkdownWritingToolsProtection`, not `MarkdownRangeAnalyzer`.**
The analyzer is strictly line-local by load-bearing invariant and structurally cannot know
whether a line sits inside a fence. `MarkdownWritingToolsProtection.fencedCodeRanges` and
`frontMatterRange` scan the whole text and already compute exactly these regions. Backlog
item 2 needs the same seam.

### Undo

The whole operation is a single `replaceCharacters` over one range, so one ⌘Z reverses the
Return together with its inserted marker. The backlog's "must be a single undoable edit"
requirement falls out of the edit shape rather than needing explicit undo grouping.

### Save status

The continuation edit reaches `document.text` through the ordinary `didChangeText` typing
path, so it flashes "Autosaved" exactly as normal typing does. It must not call `recordWrite`
itself — the invariant that only real writes flash is preserved by doing nothing special.

## Testing

**Default test plan** (`Lineform.xctestplan` — the everyday gate). `MarkdownListContinuation`
is a pure struct needing no `NSWindow`, and it carries essentially all the risk. Roughly
thirty cases:

- each bullet character (`-`, `*`, `+`), preserved rather than normalized
- ordered increment across `.` and `)` separators, including multi-digit rollover (`9.` → `10.`)
- checkbox continuation never inheriting `[x]`
- leading-whitespace preservation
- the `> -` composite prefix
- empty-marker termination for every marker type
- mid-line caret splitting
- non-empty selection replaced then continued
- suppression inside a fenced code block
- suppression inside YAML front matter
- `nil` for ordinary prose, headings, and an empty document

**Hosted plan** (`LineformHosted.xctestplan`): one test that a real Return through a real
text view produces exactly one undo step and leaves the caret after the inserted marker.
The `doCommandBy` override is a thin adapter, so this is the only part needing a live view.

## Risks

| Risk | Mitigation |
|---|---|
| First keyboard intercept in the editor | `doCommandBy` only, `insertNewline` only, `super` for everything else |
| Whole-document rewrite per keystroke | Use the localized image-insertion edit path; never `applyWholeTextReplacement` |
| Markers continued inside code fences | Suppress via `MarkdownWritingToolsProtection` |
| Undo granularity | Single `replaceCharacters` over one range |
| IME / correction-popup interference | Correct hook level, chosen for this reason |

## Related

- `docs/research/2026-07-25-feature-backlog.md` — item 1; item 2 (live spell check) shares the
  `MarkdownWritingToolsProtection` seam and should be sequenced with this.
- `docs/architecture/editor-behavior.md` — undo, autosave, visual-anchor machinery. Read
  before implementing.
