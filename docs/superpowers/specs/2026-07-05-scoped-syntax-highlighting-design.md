# Scoped Write-mode syntax highlighting — design

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Task 2** from `docs/audits/2026-07-04-audit-decisions.md` (the WAIT-tier perf task; gate
satisfied 2026-07-04). Own fresh session, own branch `work-2026-07-05-2-scope-highlighting`.

## Problem

Write mode re-colors the **entire document** on every typing-pause. `MarkdownSyntaxHighlighter.highlight(textView:profile:)` does, over the full range:

1. `storage.setAttributes(baseAttributes, fullRange)` — reset every character to base.
2. `analyzer.ranges(in: textView.string)` — re-tokenize the whole document.
3. a per-token `addAttributes` loop.

Step 2 was measured at **~121 ms/pass on a 2.5 MB doc** (audit, 2026-07-04), firing 80 ms
after each typing pause (`Coordinator.scheduleMarkdownHighlighting` → `perform(_:afterDelay: 0.08)`).
That whole-document re-tokenize, on top of a full-range `setAttributes` + relayout, is the
felt typing stutter in large documents. Task 1 already coalesced the stats/outline/search
derived pass; the highlighter is the remaining cost. This is Write-mode only — the Read/Preview
renderer is a separate path and already grouped by block.

## Goal

Bound the per-typing-pass highlight cost to the **on-screen region plus a margin**, so
large-doc typing is smooth, while keeping:

- **small-doc / no-scroll-view highlighting byte-identical** (existing tests, `⌘U`),
- **document layout stable everywhere** (line heights must not depend on what is currently
  tokenized), and
- **all existing highlight behavior** (marker/code/link colors, theme colors) unchanged for
  the region actually on screen.

## Key code fact — refines the audit's "load-bearing fence scan"

The audit's step 2 called for a "cheap are-we-inside-a-fenced-code-block scan from the top"
before coloring, treating it as load-bearing. Reading the actual analyzer changes that:

`MarkdownRangeAnalyzer.ranges(in:)` is **entirely line-local / intra-line**. Every token is
computed within one line:

- `headingMarker`, `listMarker`, `checkbox`, `blockquoteMarker`, `codeFence` (the ` ``` `
  marker only) come from per-line regexes in `lineTokens(in:lineRange:)`.
- `codeSpan` uses `` `[^`\n]+` `` — newline-excluded, so it cannot span lines.
- `linkText` / `linkDestination` use `\[([^\]\n]+)\]\(([^\)\n]+)\)` — also newline-excluded
  (tightened during review from `[^\]]`/`[^)]`, which could match across lines), so links are
  strictly single-line too.

There is **no cross-line token state**. (The one construct that *does* carry fence state —
`markdownBlockSpacingLineIndexes` — is used only by the **Preview** renderer, never by the
Write-mode text view.) Consequences:

- The current highlighter does **not** suppress markup inside fenced code blocks — a `#`
  inside a ` ``` ` fence is already colored as a heading marker today. Scoping does not change
  that.
- Because tokens are line-local, **tokenizing a window snapped to line boundaries yields
  exactly the same tokens for those lines as a whole-document pass**. Byte-identity holds
  **without** any fence-state scan.

We therefore deliberately **do not** add the fence scan, and deliberately **do not** add
fence-content suppression (that would be a behavior change, out of scope for a perf task).
This is a documented refinement of the audit plan, made from the code.

## Design

Split highlighting into two operations with different scopes:

### Base pass (whole-document)

`storage.setAttributes(baseAttributes(for: profile), fullRange)` — establishes uniform font,
paragraph style (line height / spacing), kern, and text color across the **entire** document.
This is what makes layout correct and stable everywhere regardless of what is tokenized. It is
a single attribute-run set (cheap relative to tokenization — TextKit lays out lazily, only the
visible glyphs) and runs only on the infrequent "everything changed" paths:

- initial load / view construction,
- reading-profile change (`applyTypography`),
- full-text replacement (live reload, plain-text conversion, Find-&-Replace-All via
  `applyExternalReplacement`).

It is **never** on the per-keystroke path.

### Token pass (scoped)

For a **target range** = the visible character range expanded by a fixed margin and snapped to
line boundaries (fallback: the full range when there is no enclosing scroll view or layout is
not ready yet):

1. `storage.setAttributes(baseAttributes, target)` — clear stale token colors in the target.
2. tokenize just the target substring and apply token attributes, offset back to absolute
   positions.

Bounded to the target, so cost is independent of document size.

### Entry points

| Trigger | Base pass | Token pass |
|---|---|---|
| `refreshMarkdownHighlighting()` (load / profile / replacement) | whole-doc | scoped to visible |
| typing-pause (`refreshMarkdownHighlightingAfterTypingDelay`) | — (base already whole-doc; edits preserve attributes) | scoped to visible |
| **scroll-settle (new)** | — | scoped to newly-visible window |

Off-screen text keeps correct **base** attributes (so layout/line-height is right and total
document height is stable) but its **token colors** fill in when it scrolls into view. This is
the audit's "off-screen self-heals on scroll" model.

### Scroll handling (new)

- The text view observes its clip view's `NSView.boundsDidChangeNotification`
  (`postsBoundsChangedNotifications = true`), set up when it is placed in a scroll view.
- On a bounds change it schedules a **coalesced** token pass via the existing
  `NSObject.cancelPreviousPerformRequests` + `perform(_:afterDelay:)` pattern (debounce
  ≈ 0.05 s), so rapid scrolling does at most one pass on settle.
- A lightweight **"already covered" guard**: the view remembers the last-tokenized range; if
  the current visible-plus-margin window is still inside it, the pass is skipped. Ordinary
  small scrolls within the margin therefore do no work. Any text edit or full refresh resets
  the remembered range.

### Constants (tunable)

- **Margin** ≈ 3,000 characters each side of the visible range (a few hundred words), snapped
  to line boundaries — smooths the scroll seams. Tokenizing ~6 KB extra is sub-millisecond.
- **Scroll-settle debounce** ≈ 0.05 s.

## Testable seams

- `MarkdownSyntaxHighlighter.scopedTokenRange(visibleRange:margin:in:)` (pure): margin
  expansion + line-boundary snap + clamp to `[0, length]`. Unit-tested directly (no view).
- `MarkdownSyntaxHighlighter.tokens(in:scope:)` (or the scoped-tokenize helper) proven
  **byte-identical**: a test asserts scoped tokens == whole-doc tokens intersected with the
  window, on a representative multi-construct large doc (the line-locality guarantee, incl. a
  window whose boundary sits inside a fenced code block and inside a heading/list run).
- Existing tests (`LineformTextViewWritingToolsTests` color-at-0/6, `LargeDocumentPerformance`
  source-preservation) pass unchanged via the no-scroll-view full-range fallback.
- **Scroll geometry (the visible-rect → sub-range computation and the boundsDidChange →
  coalesced-refresh wiring) is verified by in-app QA, not an automated test.** An initial
  attempt hosted a real `NSWindow`/`NSScrollView` and drove a programmatic scroll; that
  crash-looped the XCTest host on teardown — the exact SwiftUI/AppKit-window-in-XCTest
  over-release the project quarantines rather than patches (CLAUDE.md, hosted-plan section).
  Rather than add another crashing hosted-window test, the geometry is left to manual QA; the
  scoping *mechanism* it drives (`highlight(tokenScope:)` colors only in-scope, `refreshTokens`
  scoping, the `range(_:covers:)` guard, the whole-doc fallback) is fully covered by the pure
  default-plan tests above.

## Non-goals

- No visible-region scoping in Read/Preview mode (separate renderer, already block-scoped).
- No fenced-code-content suppression (behavior change, out of scope).
- No background threading (explicitly rejected for this area per Task 3b / Task 5 decisions).
- No change to search highlights, reading ruler, typewriter centering, or Writing-Tools
  protection (all drawn/computed separately from token text attributes; `setAttributes` on the
  scoped range does not touch them).

## Risks & mitigations

- **Flash of un-colored (but correctly laid-out) text** when scrolling fast past the margin
  before the settle pass: acceptable, self-heals within the debounce; the generous margin makes
  it rare. Base attributes are always present so there is no layout jump, only a momentary lack
  of marker/code color.
- **Coalescing must fire on settle**: uses the same proven perform-after-delay pattern already
  used for typing; the range math is unit-tested independently of timing.
- **Programmatic scrolls** (typewriter mode, `scrollRangeToVisible`, reload restore) also emit
  bounds changes → coalesced, bounded, harmless (and usually covered by the "already covered"
  guard).
- **Byte-identity**: guaranteed by line-locality + line-boundary snap + the full-range fallback
  when no scroll view; asserted by tests.
