# Jump to File (⌘K quick-open palette) — design spec

Status: spec-light, brainstormed and approved via chat 2026-07-17.
Date: 2026-07-17. Branch: `work-2026-07-18-3`.

## Goal

Add a keyboard-driven "jump to any file" palette, bound to **⌘K**, so a user can switch
to any file in the Workspace or iCloud roots without opening the Files sidebar and
hunting through nested folders. Value is specifically for two situations that are common
in "calm writing" usage: the sidebar is closed while drafting, and/or the workspace has
deep nested folders where tree-hunting is slower than typing a few fuzzy characters.

## Locked requirements (from brainstorming)

- **Files on disk only.** Searches the same universe as the Files sidebar (Workspace +
  iCloud roots, filtered by `OutlineFileBrowserStore.supportedFileExtensions` and
  `excludedDirectoryNames`). Does **not** include currently-open untitled/unsaved tabs —
  those have no file on disk, so they're out of scope by definition of "files on disk only."
- **⌘K is reassigned to this feature.** It's currently bound to Format ▸ Link
  (`AppCommands.swift:369-372`, `.keyboardShortcut("k", modifiers: .command)`). That moves
  to **⌘L** (`.keyboardShortcut("l", modifiers: .command)`); the button title, action
  (`toggleLinkMarkdown(_:)`), and menu position are otherwise unchanged. No other menu item
  currently claims ⌘L.
- **Empty query shows a hint, not a list.** No "recently opened" surface — that would need
  new persisted MRU tracking that doesn't exist anywhere in the app today. Keep scope to
  filename search only.
- **Selecting a result behaves exactly like clicking it in the Files sidebar** — reuse
  `EditorContainerView.openSidebarFile(_:)` (`EditorContainerView.swift:834-851`) directly,
  not a new/parallel open path. That function already does the "select existing tab if
  open, else load and open a new tab" behavior via `tabStore.tabIndex(for:)` /
  `tabStore.openTab(document:fileURL:)`. (Note: `LineformSidebarFileOpener` in
  `OutlineSidebarView.swift` is a *different* code path used for in-place document
  replacement and cross-window opens — not what sidebar row clicks in a window actually
  use today. Do not reuse it for this feature; it would behave differently.)

## Not in scope / deliberately skipped

- **No app-action palette** (e.g. "New Tab", "Export as PDF"). Filenames only, per the
  brainstormed scope decision — a full command palette is a bigger, separate feature.
- **No heading-level jump** (e.g. jumping into a specific `## Section` inside a file). Files
  only. Could be a natural follow-up once file-jump ships, but not bundled in here.
- **No fix for the existing 80-files-per-folder display cap**
  (`OutlineFileBrowserStore.maximumChildrenPerFolder`, `OutlineSidebarView.swift:848`). The
  palette searches whatever the store has already scanned, so a folder with more than 80
  files has the same blind spot in the palette that it already has in the sidebar. Fixing
  that cap is out of scope for this feature.

## UX

### Activation

- New **File ▸ Jump to File…** menu command, placed in the same `CommandGroup(after:
  .newItem)` group as **New Tab** (`AppCommands.swift:436-441`) — both are "get to a
  document" actions, distinct from the Save As/Rename/Delete group that acts on the
  *current* file. Shortcut **⌘K**.
- Posts a new window-scoped notification, `LineformAppNotification.showQuickOpen`, using
  the exact same `activeWindowPayload()` pattern as `showFindReplace`
  (`AppCommands.swift:425-431`).
- `EditorContainerView` handles it via `.onReceive(... showQuickOpen.name)`, guarded by the
  existing `notificationMatchesActiveWindow(_:)` helper (mirrors the `showFindReplace`
  wiring at `EditorContainerView.swift:224-236`), setting a new
  `@State private var isShowingQuickOpen = false` to `true`. No display-mode auto-switch is
  needed (unlike Find & Replace, which needs Write mode) — jumping to a file works from any
  mode, including Read.
- Guard the scan trigger on root state, not on "first open": if either root's `state`
  (`OutlineFileRoot.state`) still indicates it hasn't been scanned this window session,
  call `fileBrowserStore.refreshICloud()` / `refreshWorkspace()` before showing results.
  `refreshWorkspace()`/`refreshICloud()` are **not** debounced when called directly (only
  the FSEvents-monitor-driven rescan path is) — a real recursive directory walk runs
  synchronously each time they're called, so this must NOT fire on every ⌘K press, only
  when the root is genuinely unscanned. Once a root has data, later ⌘K opens in the same
  window reuse it without re-scanning (see the file-watcher note under Risks). This scan
  trigger is functionally the same one the Files tab's `.onAppear` uses, just reached via a
  different explicit user gesture — it does **not** weaken the iCloud-laziness invariant
  (never scan at launch/construction), since ⌘K is itself on-demand. If a scan is still in
  flight when results are needed, show a quiet "Scanning…" row (see Error handling below).

### The palette

Presented as a **centered floating card overlay** in `EditorContainerView`'s ZStack (an
overlay, never a layout row — keeps the top-edge toolbar-recoloring pitfall documented in
the Find & Replace spec irrelevant here, since a centered card doesn't touch the top edge
regardless). Unlike Find & Replace's small corner card, this is a modal-feeling, attention-
grabbing surface (Spotlight/Alfred-style), so it gets a dimming scrim behind it — reusing
`MuseModalScrim` (already shared with Settings) rather than inventing a second scrim
component. The card itself is new (no existing component matches "search field + live-
filtered list"); it borrows the same two-variant light/dark chrome approach Find & Replace
uses (`currentTheme.usesDarkChrome` switches between the light `MuseModalChrome
.backgroundWhiteComponent` fill and a dark `Color(white: 0.15)` fill), but at
`MuseModalChrome.cornerRadius` (18) to read as a proper modal-weight surface rather than a
small utility card.

Contents, top to bottom:

- A `TextField` at the top (placeholder "Jump to file…"), focused automatically on open.
- Below it, a live-filtered, ranked list of matches, capped to roughly the top 20 so the
  list stays scannable — each row shows the filename (primary text) and its relative path
  within its root (e.g. `projects/roadmap.md`, muted secondary text) to disambiguate
  same-named files in different folders or across the two roots.
- Empty query: the list area shows a quiet hint ("Type to search files…"), not a list.
- Zero matches for a non-empty query: a quiet "No matches" row.

Keyboard: type to filter live, ↑/↓ to move the highlighted row, Return to open the
highlighted result, Esc to dismiss. Clicking a row also opens it. Clicking the scrim
dismisses (mirrors Settings' outside-click dismissal).

## Data flow / architecture

### Pure logic — `QuickOpenIndex` (new, tested, no UI)

A new file, `Lineform/Outline/QuickOpenIndex.swift`, mirroring the pure-logic-beside-UI
pattern already used by `EditorSearchResolver`:

```swift
struct QuickOpenEntry: Identifiable, Equatable {
    let id: String       // full URL path, matches OutlineFileTreeItem.id
    let url: URL
    let name: String      // file name, e.g. "roadmap.md"
    let relativePath: String  // path within its root, e.g. "projects/roadmap.md"
    let rootTitle: String     // "Lineform" (iCloud) or the workspace folder's display name
}

enum QuickOpenIndex {
    // Recursively flattens both roots' item trees (OutlineFileTreeItem.children) into a
    // flat [QuickOpenEntry], files only (isDirectory == false). Pure, no I/O — operates on
    // already-scanned OutlineFileRoot.items.
    static func flatten(iCloudRoot: OutlineFileRoot, workspaceRoot: OutlineFileRoot) -> [QuickOpenEntry]

    // Fuzzy-filters and ranks entries against `query`. Empty query -> []. Subsequence match
    // (query characters must appear in order within `name`), with score bonuses for:
    // match starting at the beginning of the name, contiguous character runs, and exact
    // substring match. Results sorted by descending score; ties broken by shorter name
    // first. No third-party dependency.
    static func search(_ entries: [QuickOpenEntry], query: String, limit: Int = 20) -> [QuickOpenEntry]
}
```

Both functions are pure and testable without any view or window — same testing posture as
`EditorSearchResolver.matches`.

### `EditorContainerView` orchestration

New state: `@State private var isShowingQuickOpen = false`,
`@State private var quickOpenQuery = ""`, `@FocusState private var isQuickOpenFocused: Bool`.

- On `showQuickOpen` notification: if the store hasn't scanned this session, call
  `fileBrowserStore.refreshICloud()` / `refreshWorkspace()`; set `isShowingQuickOpen = true`
  and `isQuickOpenFocused = true`.
- The palette view computes `QuickOpenIndex.flatten(...)` from
  `fileBrowserStore.iCloudRoot` / `.workspaceRoot` (recomputed when the query changes or the
  store republishes — flatten is cheap relative to the scan itself, no need to cache it
  separately) and calls `QuickOpenIndex.search(entries, query: quickOpenQuery)` to get the
  displayed rows.
- Selecting a row (via Return or click) calls the existing private
  `openSidebarFile(url)` (`EditorContainerView.swift:834`) directly, then dismisses the
  palette (`isShowingQuickOpen = false`, clear `quickOpenQuery`).
- On document swap (`resetTransientDocumentState`, same cleanup site as
  `isShowingFindReplace`): also clear `isShowingQuickOpen` and `quickOpenQuery`.

## Menu / notification wiring

- `LineformAppNotification` gets a new case `showQuickOpen` → `Notification.Name
  ("Lineform.showQuickOpen")`, following the existing case list in
  `Lineform/App/LineformAppNotification.swift`.
- `AppCommands.swift`, inside the existing `CommandGroup(after: .newItem)` block
  (`AppCommands.swift:436-441`, alongside `Button("New Tab")`): new
  `Button("Jump to File…") { LineformAppNotification.showQuickOpen
  .post(object: LineformAppNotification.activeWindowPayload()) }
  .keyboardShortcut("k", modifiers: .command)`.
- `AppCommands.swift:369-372`: Format ▸ Link's `.keyboardShortcut("k", modifiers: .command)`
  changes to `.keyboardShortcut("l", modifiers: .command)`.
- `LineformTextView.swift:411`: the mirrored right-click context-menu item's `keyEquivalent`
  for Link updates from `"k"` to `"l"` to match (it's a hint/display string on the
  `NSMenuItem`, not a separate live binding, but should stay accurate).

## Accessibility

Standard SwiftUI controls (`TextField`, row buttons) are natively accessible.
`accessibilityLabel`s: "Jump to file", per-row label combining filename + relative path
("roadmap.md, projects/roadmap.md"), "Close jump to file" for the scrim/dismiss.

## Tests

Pure-logic tests (default plan, no hosting needed):

- `QuickOpenIndex.flatten`: nested folders flatten correctly; directories excluded; both
  roots merge into one list; empty roots → empty list.
- `QuickOpenIndex.search`: subsequence matching (e.g. "rdmp" matches "roadmap.md");
  start-of-name bonus ranks a prefix match above a mid-string match; empty query → empty
  results; no matches → empty results; result count respects `limit`.
- Menu wiring: `testJumpToFileCommand...` asserting title/shortcut/notification name,
  mirroring `testFindReplaceCommand...`; a companion assertion that Format ▸ Link's shortcut
  is now `"l"` not `"k"`.

View-level behavior (open/dismiss/keyboard nav, selecting a row opens the right tab) is
verified by **manual in-app QA** in this pass, consistent with how Find & Replace's "one
undo step" property was verified manually rather than via a hosted test — revisit only if
a specific regression shows up.

## Risks / tradeoffs

- **Cold-start latency on first use per window.** If a window's Files tab has never been
  shown, the first ⌘K triggers the iCloud scan inline, which can take a perceptible moment
  on a large container. This is identical to today's Files-tab-appear cost, just moved to a
  different trigger; accepted as consistent with existing behavior, not a regression.
- **Inherits the 80-files-per-folder cap** (see Not in scope, above) — a real but pre-
  existing limitation, not introduced by this feature.
- **Duplicate filenames across roots or folders are disambiguated only by the visible
  relative-path text**, not by any special grouping/section headers. Acceptable for a v1;
  could add root-grouping later if it proves confusing in practice.
- **The palette does not start its own FSEvents watcher.** `beginWatchingForExternalChanges()`
  / `endWatchingForExternalChanges()` are intentionally tied to Files-tab visibility today;
  quick-open reads whatever the store last scanned rather than adding a second watcher
  lifecycle. A file added or removed on disk after that scan won't appear/disappear in the
  palette until the Files tab is opened (which re-scans) or the window relaunches. Acceptable
  since quick-open is for fast navigation among already-known files, not a live filesystem
  monitor — but worth knowing if it comes up in QA as "the palette missed a file I just
  created."
