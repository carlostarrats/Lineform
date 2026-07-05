# Find & Replace — design spec (Task 8)

Status: spec-light, approved-intent (see `docs/audits/2026-07-04-audit-decisions.md` → Task 8).
Date: 2026-07-04. Branch: `work-2026-07-04-11`.

## Goal

Add find-and-replace to the editor: swap a word or replace-all in the **currently
open file**. This sits *on top of* the existing, settled search UX — it does **not**
redesign search. The find term keeps living in the native `.searchable` toolbar field;
we add a replace field + Replace / Replace All beside it.

## Locked requirements (from the decision doc)

- **Single-file only.** No cross-file / whole-folder replace (that drifts toward a notes
  database, against positioning).
- **Write-mode only.** Replace mutates the editor's text, which only exists in Write and
  Split. Read mode has no editor.
- **Additive.** Do not redesign the toolbar search field, highlights, or Return-to-next.
- **Replace All = one ⌘Z** (a single undo step, not one per word).
- **Replace matches the same way search matches** — same case-sensitivity. Search today is
  case- **and** diacritic-insensitive (`EditorSearchResolver.matches`); replace reuses that
  exact function, so consistency is automatic, not re-implemented.

## Not in scope / deliberately skipped

- **No Markdown Basics / Info-modal entry.** That modal teaches Markdown *syntax the user
  types to get a rendered outcome* (Task 6's cross-cutting rule). Find & Replace is an
  editor command, not syntax — nothing to teach there. (Don't add just to add.)
- **No case-sensitivity toggle.** Search has none; matching stays insensitive, and replace
  matches identically. Adding a toggle would be redesigning search.
- **No regex.** Plain-substring replace, matching search.

## UX

### Activation

- New **Edit ▸ Find & Replace…** menu command, shortcut **⌥⌘F** (the macOS standard —
  TextEdit/Pages). Placed in the same `CommandGroup(after: .pasteboard)` as the existing
  **Find** (⌘F), directly after it.
- The command posts a window-scoped notification `showFindReplace` (mirrors `focusSearch`).
- The active window's `EditorContainerView` handles it: if in Read mode, switch to Write
  first (replace needs the editor — mirrors search's existing Read→Write auto-switch);
  reveal the replace bar; focus the toolbar search field so the user can type the find term.

### The replace panel

**(Revised during QA, 2026-07-05 — the original "bar at the top of the editor shell
VStack" design was scrapped.)** A laid-out full-width strip at the top edge turned out to
recolor the window's navigation: the translucent unified toolbar takes its color from the
content directly beneath it, so the bar's background — whether `.bar` material, a theme
color, or fully transparent — visibly changed the header the moment it opened, in every
theme. No color choice fixes that; the strip's *existence at the top edge* is the cause.

Final design: a compact **floating card** overlaid on the top-trailing corner of the page
(Safari-⌘F style) — an overlay in `editorPrimaryShell`'s ZStack, never a layout row, so
the top-edge view hierarchy is identical whether the panel is open or closed and the
header provably cannot change. The card uses the app's fixed card chrome in **two
variants** keyed on `Theme.usesDarkChrome` (user-requested): the Muse-modal light card on
light themes; a dark card (white 0.15 fill, faint light border) on Quiet/Night, with the
control appearance pinned to match so labels/borders always read. Shown only when
`isShowingFindReplace` **and** the editor is present (`.write`/`.split`). Contents,
left→right:

- A `TextField` for the **replacement** text (placeholder "Replace").
- **Replace** button — replaces the current active match, then advances to the next match
  ("Replace & find next"). Disabled when there is no active match.
- **Replace All** button — replaces every match in one undo step. Disabled when zero matches.
- A quiet match-count label ("N found" / "No matches") — directly informs the Replace-All
  decision; lives on the replace bar, not in the search field, so search UI is untouched.
- A close (✕) button. Esc while focused in the replace field also dismisses.

The find term is whatever is in the existing native search field (`searchQuery`). We do
**not** add a second find field — literally just a replace field beside search.

## Data flow / architecture

### Pure logic — `EditorSearchResolver` (tested, no UI)

```swift
struct ReplacementResult: Equatable {
    let text: String            // new full document text
    let selectedRange: NSRange  // caret/selection to place afterward
    let replacedCount: Int
}

// Replace ALL matches of `query` in `text` with `replacement`, one pass.
// Reuses matches(in:query:) so matching == search matching. nil when no matches.
static func replaceAll(in text: String, query: String, replacement: String) -> ReplacementResult?

// Replace the single match occupying `matchRange` with `replacement`.
// selectedRange = the inserted replacement's range (so it reads as selected). nil if range invalid.
static func replaceMatch(in text: String, matchRange: NSRange, replacement: String) -> ReplacementResult?
```

- `replaceAll` walks the `matches(...)` ranges **back-to-front** so earlier ranges stay
  valid as it rewrites (replacement length may differ). It does **not** re-scan the text it
  just wrote, so a replacement that contains the query cannot loop or cascade. Caret lands at
  the end of the last (top-most, after the back-to-front pass) replacement.
- Both are pure `String`/`NSRange` functions — unit-testable without a text view.

### The edit application — single undo step

The **one proven single-⌘Z path** in this codebase is
`LineformTextView.applyWholeTextReplacement(_:)` (the same path ⌘B/⌘I use):
`shouldChangeText → textStorage.setAttributedString → didChangeText`. `didChangeText`
fires the coordinator's `textDidChange`, which syncs `document.text`. So one call = one
undo step **and** the binding stays consistent. Replace routes through this, **not** a raw
`document.text =` (whose `textView.string =` path is not guaranteed undoable).

A new channel mirrors the existing `requestedSelection` binding on
`MarkdownTextViewRepresentable`:

- Add `@Binding var requestedReplacement: MarkdownEdit?` (reuse the existing
  `MarkdownEdit { text; selectedRange }` value type).
- In `updateNSView`, **before** the `if textView.string != text` sync, if
  `requestedReplacement` is non-nil: call `textView.applyExternalReplacement(edit)` (wraps
  `applyWholeTextReplacement` + `scrollRangeToVisible(edit.selectedRange)`), then clear the
  binding async. This replaces (not supplements) the plain string-sync for that cycle, so
  the text is applied exactly once, through the undoable path.

### `EditorContainerView` orchestration

New state: `@State private var isShowingFindReplace = false`,
`@State private var replaceText = ""`, `@State private var requestedReplacement: MarkdownEdit?`,
`@FocusState private var isReplaceFocused: Bool`.

- **Replace All:** `result = replaceAll(in: document.text, query: searchQuery, replacement: replaceText)`.
  If non-nil, set `requestedReplacement = MarkdownEdit(text: result.text, selectedRange: result.selectedRange)`.
  Do **not** touch `document.text` (the edit path drives it). After the binding syncs,
  `onChange(document.text)` recomputes matches (fewer/none) — no special handling.
- **Replace (single):** guard an active match; `matchRange = searchMatches[activeSearchIndex]`.
  `result = replaceMatch(...)`. Compute the **next** match synchronously from `result.text`
  (first match at location ≥ `matchRange.location`, else wrap to first), and set the edit's
  `selectedRange` to that next-match range so the caret lands on the next occurrence; set
  `searchMatches`/`activeSearchIndex` to match. Apply via `requestedReplacement`.
- On document swap (`resetTransientDocumentState`): also clear `isShowingFindReplace`,
  `replaceText`, `requestedReplacement`.

## Menu / notification wiring

- `AppMenuConfiguration.findReplaceCommandTitle = "Find & Replace…"`,
  `findReplaceCommandKeyEquivalent = "f"` (modifiers `[.command, .option]`).
- `LineformAppNotification.showFindReplace` → `"Lineform.showFindReplace"`.
- `AppCommands`: Button after Find, posts `showFindReplace` with `activeWindowPayload()`.

## Accessibility

Standard SwiftUI controls (TextField, Buttons) are natively accessible. Add
`accessibilityLabel`s ("Replacement text", "Replace", "Replace all", "Close find and
replace"). The match-count label is real text, read as-is.

## Tests

Pure-logic tests beside the existing `testEditorSearch...` set:

- `replaceAll`: multiple matches; case-insensitive match count == `matches(...).count`;
  diacritic-insensitive; replacement longer/shorter than query; empty replacement (delete);
  replacement containing the query (no cascade); no matches → nil; whitespace/empty query → nil.
- `replaceMatch`: replaces exactly the given range; selectedRange spans the insertion;
  invalid range → nil.
- Menu wiring: `testFindReplaceCommand...` asserts title/key/notification name (mirrors
  `testFindCommandFocusesToolbarSearch`).

The "one undo step" property is inherent to `applyWholeTextReplacement` (already single-⌘Z
for formatting commands) and is verified by **in-app QA** (Replace All then one ⌘Z reverts).

## Risks / tradeoffs

- Replace runs a whole-document `setAttributedString` (like every formatting command). Fine
  at document scale; consistent with existing behavior.
- The floating panel overlays the top-trailing corner of the content (the preview pane in
  Split); document text can sit beneath it. Accepted — same trade-off as Safari's floating
  find bar, and the panel is compact and dismissable.
- If the user edits between typing the find term and pressing Replace, `searchMatches` is
  kept fresh by the existing debounced recompute; Replace reads the current `document.text`,
  so it always operates on live text.
