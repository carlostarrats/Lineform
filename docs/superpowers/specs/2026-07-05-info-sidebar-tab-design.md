# Info Sidebar Tab — Design

**Date:** 2026-07-05
**Status:** Approved design, pending implementation plan

## Problem

The Markdown syntax reference (the "Info" content) is presented as a blocking,
scrim-backed Muse-style modal (`MarkdownBasicsModal` / `MarkdownBasicsOverlay`).
It has three problems for its actual job — being a reference you consult *while
writing*:

1. **It blocks.** The scrim dims the editor and traps focus; you must dismiss it
   to type. There is no way to see the reference and your document at once.
2. **Back-and-forth.** Every lookup is open → read → close → write → reopen.
3. **Cramped.** The fixed-width card scrolls a lot, and not everyone has the
   syntax memorized, so the round-trips add up.

This content wants to be *reference-while-writing*, not *stop-and-read*.

## Decision

Move the reference into a **third sidebar tab, "Info"**, beside Outline and
Files. The left sidebar is already a persistent, in-window panel next to the
writing surface, so the reference can stay visible while you type — flip to Info
to check syntax, flip back to Outline. This keeps the app's deliberate
one-window restraint (the same reason Settings is an in-window modal rather than
a macOS `Settings {}` scene) and reuses existing sidebar chrome. The blocking
modal and its toolbar button are removed.

### Approaches considered

- **A. Third sidebar tab (chosen).** In-window, persistent-while-writing, reuses
  the sidebar, no new window management. Cost: narrower column forces a stacked
  (not two-column) layout and tighter copy; you see one sidebar tab at a time.
- **B. Floating utility panel (NSPanel).** A real draggable window, placeable on
  a second monitor. Rejected: it reintroduces the window-management surface the
  app deliberately avoids (Settings was made in-window for exactly this reason),
  for flexibility most users won't need.
- **C. Non-blocking, draggable in-window modal card.** Smallest change, but the
  card still floats *over* the text, so it never solves "see both at once." A
  half-measure. Rejected.

## Scope

Only the changes below. No sidebar width/resize changes, no new preferences, no
new color palette, no changes to unrelated modals.

### 1. New tab

- Add `case info = "Info"` to `OutlineSidebarTab` (in
  `Lineform/Outline/OutlineSidebarView.swift`). `tabTitles` and the segmented
  control pick up the third label automatically from `allCases`.
- In `OutlineSidebarSegmentedControl.updateNSView`, the two existing
  `setWidth(0, forSegment:)` calls become three (segments 0/1/2) so the third
  segment distributes equally. At the 220pt minimum column width the three short
  labels ("Outline / Files / Info") fit.
- The tab-content branch in `OutlineSidebarView.body` changes from
  `if selectedTab == .outline { … } else { … }` to a three-way `switch` over
  `.outline` / `.files` / `.info`.
- `selectedTab` stays per-window `@State` (as today) — not persisted; new windows
  open on Outline.

### 2. Info content view

A new lightweight SwiftUI view (e.g. `OutlineInfoTabView`) rendered when
`selectedTab == .info`. It is **static content** — no file scan, no FSEvents, no
laziness concern (unlike the Files tab). It holds a scrolling stack of sections.

**Layout — stacked, not two-column:**

- Each entry is two lines: **monospaced syntax on top**, plain-English
  **explanation beneath** (the modal's side-by-side label/detail columns don't
  fit a ~220–300pt sidebar).
- Sections in the current order: **Markdown Basics · Diagrams · Math · Search**,
  each with a semibold section title.
- **Hairline rule between sections** (theme-aware low-opacity separator — see
  Theming), matching the modal's existing between-row divider treatment.
- Explanations **wrap, never truncate**, so the content stays readable at the
  narrow width and at larger text sizes.

### 3. Theming (first-class)

The modal used `MuseModalChrome.primaryTextColor` / `secondaryTextColor`, which
are **fixed light-chrome** colors (`usesThemeIndependentLightChrome = true`) —
always dark ink on a light card. Those are wrong for the sidebar, which follows
the reader theme (system / Quiet / Night) and can be dark.

- Syntax line → `OutlineSidebarView.primaryTextColor(usesDarkChrome:)`
- Explanation → `OutlineSidebarView.secondaryTextColor(usesDarkChrome:)`
- Section rule → the sidebar primary color at low opacity, or a theme-aware
  separator, so it's visible on both light and dark backgrounds (not the modal's
  fixed light divider).

These are the **same theme-aware colors Outline/Files rows already use**, so the
"two colors — reference vs. explanation" requirement is satisfied by the
sidebar's existing two-tone scheme, and the tab flips correctly across all
themes with no new palette. `usesDarkChrome` is derived from the environment
`colorScheme` exactly as the rest of the sidebar does.

### 4. Accessibility (first-class)

- **VoiceOver rows:** each row exposes a single combined accessibility label so
  VO reads a coherent phrase rather than spelling out Markdown punctuation
  character-by-character — e.g. label "Bold, syntax **bold**" (explanation +
  syntax), with the two visible `Text`s combined via
  `.accessibilityElement(children: .combine)` or an explicit
  `.accessibilityLabel`.
- **Tab name:** the segmented control's "Info" segment is the accessible name;
  the tab content carries an appropriate `.accessibilityLabel` (e.g. "Markdown
  reference") rather than inheriting the outline's "Document outline" label.
- **Contrast:** a test asserts the explanation (muted secondary) color meets
  **WCAG AA** against every reader theme's sidebar background, modeled on the
  existing `testStatusStateColorsMeetAAAgainstEveryThemeBackground`. Because the
  Info tab reuses the sidebar's existing secondary text color, this also
  documents/guards that color's contrast for longer-form reading.
- **Wrapping** (above) keeps content legible at larger text sizes.

### 5. Remove the old entry point

- Delete the toolbar **Info** button: `EditorAuxiliaryPresentation.markdownBasics`
  and its inclusion in the toolbar item set
  (`EditorPresentation.swift` — `showsMarkdownBasics(in:)`, the
  `.markdownBasics` case in the auxiliary presentation/toolbar lists).
- Delete `isShowingMarkdownBasics` state and its `museModalLayer` presentation +
  animation in `EditorContainerView`, and the `.markdownBasics` toggle case.
- Delete `MarkdownBasicsModal` and `MarkdownBasicsOverlay`
  (`EditorChromeAndControls.swift`).
- **Keep** the shared Muse chrome (`MuseModalChrome`, `museModalCard`,
  `MuseModalHeader`) — Settings still uses it.
- Remove now-dead references (`markdownBasics` in `SettingsView.swift` if it only
  referenced the modal's chrome constants; verify each reference during
  implementation and remove only genuinely dead code).

### 6. Rewritten copy (shift *and replace*)

Modal-width prose is too wordy stacked in a narrow column. Trivial rows drop to a
word or a short phrase; dense rows compress while keeping the information.
Proposed set (final wording tunable during implementation):

**Markdown Basics**

| Syntax (mono) | Explanation |
|---|---|
| `# Title` | Top-level heading. |
| `## Section` | Smaller heading (more `#` = smaller). |
| `**bold**` | Bold. |
| `_italic_` | Italic. |
| `- bullet` | Bulleted list. |
| `1. item` | Numbered list. |
| `- [ ] to do` | Task, not done. |
| `- [x] done` | Task, done. Click to toggle. |
| `> quote` | Blockquote. |
| `~~text~~` | Strikethrough. |
| `` `code` `` | Inline code. |
| `---` | Divider. |
| `[text](url)` | Link. |
| `![alt](url)` | Image (shown as a placeholder). |
| `\| a \| b \|` | Table: header row, then `\|---\|---\|`, then rows. Colons set alignment. |
| Block Spacing | Adds space around blocks in Read and Preview. |

**Diagrams**

| Syntax (mono) | Explanation |
|---|---|
| ` ```mermaid ` | Fenced `mermaid` block renders as a diagram in Read/Preview. Write shows source. |

**Math**

| Syntax (mono) | Explanation |
|---|---|
| `$x^2 + y^2$` | Inline math. |
| `$$…$$` | Centered equation block. |
| `\frac{a}{b}` | LaTeX supported: fractions, roots, Greek, sums, integrals. |
| `it costs $5` | Plain dollar amounts stay as text. |

**Search**

| Syntax (mono) | Explanation |
|---|---|
| `Return` | While searching, jumps to the next match; wraps around. |

("Block Spacing" is a note, not literal syntax — kept in the Basics section as
today; its left-column text is not monospaced-as-code but a label.)

## Testing

Pure/default-plan tests only (no window motion, no modal → no hosted tests):

- `OutlineSidebarTab.allCases` includes `.info` with title "Info".
- The Info content model is present and non-empty for each section (Basics /
  Diagrams / Math / Search).
- **Concise-copy guard:** a length ceiling on the rewritten explanations so a
  future edit can't silently re-bloat the narrow column.
- **Contrast:** explanation (secondary) color meets WCAG AA against every reader
  theme's sidebar background (mirrors
  `testStatusStateColorsMeetAAAgainstEveryThemeBackground`).
- Removal is clean: no lingering references to the deleted
  `MarkdownBasicsModal` / `isShowingMarkdownBasics` / `markdownBasics` toolbar
  item (compile + a grep-guard in review).

## Files touched

- `Lineform/Outline/OutlineSidebarView.swift` — `.info` case, three-way content
  switch, third segment width; new `OutlineInfoTabView` (here or its own file in
  `Lineform/Outline`).
- `Lineform/Editor/EditorPresentation.swift` — remove `.markdownBasics` toolbar
  wiring.
- `Lineform/Editor/EditorContainerView.swift` — remove `isShowingMarkdownBasics`
  state, presentation, toggle case.
- `Lineform/Editor/EditorChromeAndControls.swift` — remove `MarkdownBasicsModal`
  / `MarkdownBasicsOverlay`; keep shared Muse chrome.
- `Lineform/App/SettingsView.swift` — verify/remove only genuinely dead
  `markdownBasics` references.
- `LineformTests/…` — new tests above; remove tests that only exercised the
  deleted modal.

## Out of scope

- Sidebar width / resize behavior (unchanged).
- Any new preference or persistence of the selected tab.
- A floating/detachable window (approach B).
- Reworking the Muse modal chrome used by Settings.
