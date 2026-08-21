# Review Follow-ups (2026-07-18)

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

Four items surfaced in a past code review. This spec addresses three with contained
fixes and records the fourth as a documented known limitation. A fifth item from the
review — the hovered inactive tab title's contrast (~3.8:1 in light mode) — is **already
resolved** by the 2026-07-18 tab redesign and its guard test
(`testTabColorsMeetAAAgainstTheirFillsInEveryTheme`, all four states ≥4.5:1 across every
theme), so it is out of scope here.

## 1. Tab close button — VoiceOver accessibility

**Problem.** The close × on a document tab is a real `Button` with a "Close tab"
accessibility label, but it is mounted in the view tree only while the tab is hovered
(`showsClose = tabStore.tabCount > 1 && isHovered` in `TabBarView.tabButton`). A
pointer hover is the only way to bring it into existence, so VoiceOver, Switch Control,
and keyboard-only users never encounter a per-tab close affordance. (⌘⇧W closes the
*selected* tab, so this is a discoverability / background-tab gap, not a total lockout.)

**Decision.** Preserve the deliberate "no × at rest" visual design exactly. Add an
accessibility **custom action** named "Close tab" to each tab's selection `Button`, so
assistive technologies expose a per-tab close through the rotor / actions menu with no
visual change whatsoever.

**Design.**
- On the selection `Button` in `TabBarView.tabButton`, attach
  `.accessibilityAction(named: Text("Close tab")) { onCloseTab(tab.id) }`.
- Gate it the same way the visible × is gated — only when `tabStore.tabCount > 1` — so a
  lone tab exposes no close action (closing the last tab is not a tab operation). Apply
  the modifier conditionally; when `tabCount == 1`, the action is absent.
- No change to `showsClose`, the visible × geometry, hover behavior, or any color.

**Testing.** `TabBarView`'s accessibility wiring is not currently unit-tested and SwiftUI
accessibility actions are not readily introspectable from XCTest. The visible-× gating
logic (`tabCount > 1`) is the load-bearing condition and is shared with the new action;
assert that condition in a small pure helper if one is introduced, otherwise this is a
structural change verified by reading and by VoiceOver in the running app. No existing
test regresses (colors/metrics untouched).

## 2. Undo resets on tab switch — documented limitation

**Problem.** Switching tabs clears the undo stack: `activateSelectedTab` calls
`backingDocument.undoManager?.removeAllActions()`. A user who edits tab A, switches to
tab B, then back to A cannot ⌘Z their earlier edits.

**Decision.** Document only. Preserving a separate live undo stack per tab across
activations is a large, regression-prone change to the shared window undo manager and is
not justified by this review. Record it as a known limitation.

**Design.**
- Add a short comment at the `removeAllActions()` call site in
  `EditorContainerView.activateSelectedTab` explaining that undo history is intentionally
  not carried across tab activations (shared window undo manager) and pointing at this
  spec.
- Add a one-line "Known limitation" note to the multi-document tabs bullet in `CLAUDE.md`
  so future agents don't treat the reset as a bug to be "fixed" blindly.
- No behavior change.

## 3. All Files search — stale results during the first iCloud/workspace scan

**Problem.** Entering the All Files search scope for the first time in a window session
triggers the deferred `refreshICloud()` / `refreshWorkspace()` scans and then
*immediately* runs `updateCrossFileSearch()` against the roots as they stand — which are
still the empty/cached snapshot, because the scans are asynchronous. Results stay stale
until the user edits the query (which re-invokes `updateCrossFileSearch` after the roots
have populated).

**Decision.** Re-run the cross-file search when the scanned roots change, while the All
Files scope is active with a live query. `OutlineFileBrowserStore.iCloudRoot` and
`workspaceRoot` are already `@Published`, so the view can observe them.

**Design.**
- In `EditorContainerView`, add `.onChange(of: fileBrowserStore.iCloudRoot)` and
  `.onChange(of: fileBrowserStore.workspaceRoot)` observers (or one observer keyed on a
  combined value) that call `updateCrossFileSearch()` **only when**
  `searchScope == .allFiles` and the trimmed `searchQuery` is non-empty.
- `CrossFileSearchModel.search` is already debounced, cancellable, and latest-wins, so a
  burst of root republishes during a scan collapses to a single fresh scan — no extra
  guarding needed. An empty query already resets the model, so the guards above simply
  avoid needless work.
- `OutlineFileRoot` is already `Identifiable, Equatable`
  (`Lineform/Outline/OutlineSidebarView.swift`), so `.onChange(of:)` works directly with
  no new conformance.

**Testing.** The observer wiring lives in the SwiftUI view and is not directly unit
-testable, but the underlying contract is: given populated entries, a re-issued
`search(query:entries:)` publishes non-stale results. Add/confirm a `CrossFileSearchModel`
test that a second `search` call with a larger entry set supersedes the first and
publishes results from the new set (latest-wins). Verify the end-to-end behavior in the
running app: first-ever All Files search shows results once the scan lands, without a
manual query edit.

## 4. Quick Look inline formatting

**Problem.** `QuickLookMarkdownRenderer` (in the `LineformQuickLook` extension) renders
block structure but performs no inline parsing, so `**bold**`, `*italic*`, `` `code` ``,
`[text](url)`, and `~~strike~~` appear with their literal markers in Finder/Spotlight
previews.

**Decision.** Add inline rendering for the full inline set: **bold**, *italic*, inline
`code`, links (clickable), and strikethrough — matching the constructs the app's own
inline tokenizer handles.

**Design.**
- Introduce a pure function
  `QuickLookMarkdownRenderer.applyInlineFormatting(to plain: String, baseAttributes:) ->
  NSAttributedString` that scans a single already-block-classified line's text and returns
  an attributed string with markers removed and inline attributes applied over the base
  (body/heading/list/blockquote/table-cell) attributes passed in.
- Constructs and their attributes (derived from `baseAttributes`' font so size/face are
  inherited):
  - `**x**` / `__x__` → bold trait added to the base font.
  - `*x*` / `_x_` → italic trait added to the base font. Emphasis parsing must not
    mis-handle `**bold**` as two italic runs; parse strong before emphasis, and treat `_`
    inside words conservatively (word-boundary only) to avoid `snake_case` false hits.
  - `` `x` `` → monospaced font at the base size + a faint background
    (`labelColor`-derived, low alpha), matching the app's inline-code feel. Code spans win
    over other inline parsing inside them (their contents are literal).
  - `[text](url)` → the `text` shown, `.link` attribute set to `url` (NSTextView is
    selectable, so links become clickable), plus the app's link styling (accent color +
    underline). Autolinks/bare URLs are out of scope.
  - `~~x~~` → strikethrough style over the base.
- Precedence mirrors the app: inline code is resolved first (its content is literal), then
  links, then strong, then emphasis, then strikethrough — so a marker inside a code span
  stays literal. Keep the scanner line-local (each block line is formatted independently),
  consistent with the block loop.
- Apply `applyInlineFormatting` at every site that currently appends plain body text:
  paragraphs (`flushParagraph`/`appendParagraph`), list item content, blockquote content,
  heading content, and table cell text. Preserve each site's existing paragraph style,
  color, and kern by passing them as the base attributes.
- Escaped markers: a backslash-escaped marker (`\*`, `` \` ``) renders literally with the
  backslash removed. Keep this minimal — only the markers this renderer consumes.

**Isolation & testability.** `QuickLookMarkdownRenderer` currently lives in
`LineformQuickLook/QuickLookPreviewProvider.swift` alongside `PreviewViewController`,
which imports `QuickLookUI` — so the file is in the extension target only and is not
reachable from `LineformTests` (dragging `QuickLookUI`/`QLPreviewingController` into the
unit-test host is undesirable). **Extract `QuickLookMarkdownRenderer` into its own
AppKit-only file** (`LineformQuickLook/QuickLookMarkdownRenderer.swift`, importing only
`AppKit`) and add that file to **both** the `LineformQuickLook` extension target and the
`LineformTests` target (the CommandLineTool pattern: pure logic compiled into the test
target, the extension-only entry point left behind). `PreviewViewController` keeps its
`QuickLookUI` import and stays extension-only. This is a mechanical pbxproj change
(hand-rolled `1F0000xx` IDs per the repo convention) with no behavior change. All new
inline logic is pure with no I/O.

**Testing.** With the renderer in the test target, add default-plan unit coverage for
`applyInlineFormatting` as a pure function: each construct in isolation, nesting/precedence
(marker inside code stays literal; `**bold**` is not two italics; `snake_case` is not
italic), a link's `.link` attribute value, and escaped markers. Also confirm existing
block-level output (headings, lists, tables, blockquotes, code fences) is unchanged after
the extraction and the inline pass.

## Out of scope / non-goals

- No per-tab undo stacks (item 2 is document-only).
- No visual change to the tab bar (item 1 is a11y-tree only).
- No new inline constructs beyond bold/italic/code/link/strikethrough in Quick Look; no
  images, tables-in-cells, autolinks, or footnotes.
- The already-resolved tab contrast finding is not revisited.
