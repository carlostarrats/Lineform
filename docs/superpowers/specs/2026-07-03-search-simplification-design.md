# Search Simplification Design

**Date:** 2026-07-03
**Status:** Proposed

## Problem

Today's in-document search behaves oddly: typing a term selects the current
match in blue and paints *every other* match in yellow — but there is no way to
move from one match to the next. The blue selection sits on the first match and
never advances, so the yellow highlights imply a navigation feature that does
not exist. It reads as half-finished, because it is.

The cause is that search is a **custom layer** bolted onto the text view rather
than the text view's normal behavior:

- A custom `EditorSearchResolver` scans for matches.
- Custom drawing in `LineformTextView` paints the blue-current / yellow-others
  overlay (`drawSearchHighlightsIfNeeded` + `setSearchHighlights`).
- Dead `nextIndex` / `previousIndex` / `selectSearchMatch` code exists but was
  never wired to anything.

## Goal

Keep the search bar in the toolbar. Make it work like a normal search. Remove
the custom code that makes it weird. No new UI, no arrows, no extra features —
less code, not more.

## What the user experiences after this change

- The toolbar search field stays exactly where it is, always present.
- Typing a term finds it in the current document and shows the match using the
  text view's **normal selection** (the standard blue selection), scrolled into
  view.
- Pressing **Return** in the field advances to the next occurrence — the ordinary
  behavior of a search field. (No visible next/previous arrows.)
- The stray yellow highlighting of all other matches is gone. There is no
  half-state implying navigation that isn't there.
- Works directly in Write and the Split editor pane. In Read mode, searching
  reveals the match by switching to Write and selecting it — this is the existing
  behavior and is unchanged. (Making the read-only preview independently
  searchable in place is a larger change and is intentionally out of scope here;
  it would add code, not remove it.)

## What changes in code

**Removed (the custom junk):**

- The custom highlight overlay in `LineformTextView`:
  `drawSearchHighlightsIfNeeded()` and the `setSearchHighlights(_:activeRange:)`
  plumbing, plus the `MarkdownTextViewRepresentable` call that feeds it. This is
  the yellow-others / blue-current painting that creates the weird half-state.
- Any custom blue/yellow color logic for search matches (the match is shown by
  the text view's ordinary selection instead).

**Kept:**

- The toolbar search field itself (SwiftUI `.searchable`) — the always-present
  search bar the user wants.
- Enough of `EditorSearchResolver` to find a match so the field can select and
  scroll to it, including finding the *next* match after the current selection so
  Return can advance. Drop the parts only used by the removed overlay (e.g. the
  index/highlight-array bookkeeping) if they become unused.
- The single Find command / `focusSearch` wiring that puts focus in the field on
  ⌘F.

## Testing

- Update or remove any `EditorSearchResolver` tests that only covered the deleted
  overlay/index bookkeeping.
- Keep/add a focused test that typing a query selects the matching range in the
  document's text view (no overlay), and that Return advances the selection to the
  next occurrence and wraps.
- Run the standard serial test gate from `CLAUDE.md` and report exact counts.

## Non-goals

- No next/previous arrow controls in the search field.
- No slide-down native find bar.
- No "1 of N" match counter.
- No cross-file / library search.
