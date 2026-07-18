# Cross-File Search (All Files search scope) — design spec

Status: brainstormed and approved via chat 2026-07-17, including live in-app demos of the
three candidate entry points.
Date: 2026-07-17. Branch: `work-2026-07-18-4`.

## Goal

Let a user search the *contents* of every file in the Workspace and iCloud roots — "where
did I write about X → take me there" — without leaving the app or turning Lineform into a
notes database. This is read-only navigation, the workspace-sized sibling of ⌘K Jump to
File: ⌘K finds files by *name*; this finds files by what's *in* them.

## Locked decisions (from brainstorming, in the user's words where it matters)

- **The entry point is the existing native search field.** Users expect "search" to live in
  the search field; a hidden keyboard-shortcut-only feature was explicitly rejected ("a
  command button that's hidden is not a good user experience").
- **Entry UI is SwiftUI's native `.searchScopes`** on the existing
  `.searchable(text:placement:prompt:)` field: two scopes, **This File** (default) and
  **All Files**. This was chosen after seeing all three candidates rendered live in the
  real toolbar:
  - `.searchSuggestions` row ("Search all files for '…'") — **rejected, hard no**: looks
    like a label, not a button; implies it's already searching.
  - A custom toolbar button beside the search field — **rejected** ("that's terrible"):
    it can only sit *outside* the field, and it's permanent new chrome.
  - The system scope bar — **accepted**: plain but genuinely native (the same control Mail
    and Finder show), appears only while search is active, vanishes when search ends.
  - The scope bar is system-drawn: **no color, font, shape, or placement customization is
    possible and none should be attempted.** The search field itself is never rebuilt,
    wrapped, or replaced with AppKit — that is a hard constraint.
- **All Files results render as a transient, read-only page over the current tab's
  content area** — NOT a floating card/palette hovering over text (rejected as
  "convoluted"), not a HUD, and not its own pseudo-document tab. Same reading column,
  theme, and typography family as the editor. The document underneath is untouched and
  cannot be edited while the page is up.
- **Selecting a result opens that file exactly like a sidebar click** — reuse
  `EditorContainerView.openSidebarFile(_:)` (new tab, or switch to the existing tab if the
  file is already open). The originating tab is never closed or navigated away.
- **All search state clears on jump.** After a result opens: the query is empty, no
  highlights, no scope bar, no results page anywhere — including back on the originating
  tab. The scope resets to This File, so the next search is plain in-file search unless
  the user deliberately flips it again. (The user called this out explicitly: leftover
  query text must not carry into the new tab, and clearing the search must also make the
  scope buttons go away — the latter is automatic `.searchScopes` behavior.)
- **Backing out (Esc, clearing the query, dismissing search) restores the document view
  exactly as it was** — no navigation, no residue.

## Not in scope / deliberately skipped

- **No cross-file replace.** Ever, per the Find & Replace spec's boundary — bulk mutation
  is the notes-database line this feature must not cross.
- **No persisted index, no database, no background indexer, no FSEvents watcher of its
  own.** Search reads the files on demand; the candidate list is whatever
  `OutlineFileBrowserStore` last scanned (same caveat as ⌘K: a file created after the last
  scan is invisible until the Files tab re-scans).
- **No saved searches, no tags, no regex, no case-sensitivity toggle** — matching mirrors
  in-file search exactly.
- **No new menu item or keyboard shortcut in v1.** The scope bar is the entry point the
  user chose; accelerators can be added later if asked for. (⌘F already focuses search,
  which is the path to the scope bar.)
- **iCloud-evicted (dataless) files are skipped in v1** — searching them would force
  downloads of the whole container. Files iCloud has materialized locally search fine.
- **Inherits the 80-files-per-folder sidebar cap** and `excludedDirectoryNames` /
  `supportedFileExtensions` filters — same universe as the sidebar and ⌘K, same
  pre-existing blind spots.
- **Keyboard navigation of the results page (↑/↓/Return) is deferred.** v1 is
  click-to-open + Esc-to-dismiss. (Return in the search field keeps its existing
  next-match meaning in This File scope; in All Files scope it does nothing in v1.)

## UX

### Entry and flow

1. User clicks into the toolbar search field (or ⌘F). The native scope bar appears with
   **This File | All Files**, This File selected. In-file search behaves exactly as today.
2. User selects **All Files** and types (or had already typed — same result). In-file
   highlight machinery stops; instead, the current tab's content area shows the
   **results page**: a scrollable, read-only list in the reading column, one row/card per
   matching file, updating live (debounced) as the query changes.
3. Each result row shows: **filename** (primary), relative path within its root + root
   title (muted secondary, the ⌘K disambiguation pattern), a one-line **snippet** of the
   first matching line with the match visually emphasized, and a **match count**.
4. Clicking a row opens the file via `openSidebarFile(_:)` (new tab / switch to existing
   tab), then all search state everywhere is cleared (query, matches, results page, scope
   back to This File — the scope bar disappears because search is no longer active).
5. Esc, clearing the query, switching scope back to This File, or dismissing search tears
   the results page down and reveals the untouched document.

### Results page states

- Empty query in All Files scope: quiet hint ("Type to search all files…").
- Non-empty query, zero matches: quiet "No matches in any file."
- Scan/read in progress: results stream in as files are checked; no spinner for the common
  fast case. (First-ever use in a window may trigger the deferred iCloud scan, same as ⌘K.)
- The page is theme-aware (light/dark chrome follows `currentTheme` like every other
  surface) and read-only — it never grabs edit focus; typing continues to go to the
  search field.

### Display-mode interplay

The results page overlays the content area in **any** display mode (Write/Read/Preview) —
no forced mode switch (unlike Find & Replace, which needs Write). The mode is exactly as
the user left it when the page dismisses.

## Data flow / architecture

### Candidate files

Reuse `QuickOpenIndex.flatten(iCloudRoot:workspaceRoot:)` — the already-tested flattener
over the store's scanned trees. Same deferred-scan trigger as ⌘K: if a root is unscanned
this window session when All Files activates, call `refreshWorkspace()` /
`refreshICloud()` once (guarded on root state, never per keystroke). The iCloud-laziness
invariant holds: nothing scans at launch/construction; All Files activation is an explicit
user gesture.

Eviction filter: before reading, check `URLResourceValues.ubiquitousItemDownloadingStatus`;
skip files that are not `.current`/local (dataless). Non-iCloud files have no such status
and are always read.

### Pure logic — `CrossFileSearchResolver` (new, tested, no UI, no I/O)

New file `Lineform/Editor/CrossFileSearchResolver.swift` (beside `EditorSearchResolver`,
whose pure-logic-beside-UI pattern it follows):

```swift
struct CrossFileSearchResult: Identifiable, Equatable {
    let id: String            // full URL path (the OutlineFileTreeItem.id rule)
    let url: URL
    let name: String
    let relativePath: String
    let rootTitle: String
    let matchCount: Int
    let snippet: CrossFileSearchSnippet   // line text + the match's range within it
}

enum CrossFileSearchResolver {
    // Matches one file's text against the query using EditorSearchResolver.matches —
    // literal, case- AND diacritic-insensitive, so cross-file search agrees with in-file
    // search by construction. Returns nil when there are no matches; otherwise the count
    // and the first match's snippet (its line, trimmed/elided around the match).
    static func result(for entry: QuickOpenEntry, text: String, query: String) -> CrossFileSearchResult?

    // Ordering for display: descending matchCount, then name, then relativePath
    // (stable, deterministic — the QuickOpenIndex tie-break style).
    static func ranked(_ results: [CrossFileSearchResult]) -> [CrossFileSearchResult]
}
```

### Async orchestration — `CrossFileSearchModel` (new, `ObservableObject`)

Owned by `EditorContainerView` (the `OutlineFileBrowserStore` hoisting pattern). Holds
`@Published var results: [CrossFileSearchResult]`, `@Published var isSearching: Bool`.

- `search(query:entries:)` debounces (~0.3s after the last keystroke), then runs a
  `Task` that reads each candidate file's UTF-8 text **off the main thread**, feeds it
  through `CrossFileSearchResolver`, and publishes ranked results back on the main actor.
- **Latest-wins generation guard** (the `ICloudSettingViewModel` pattern): every new query
  bumps a generation; stale tasks check it before publishing and self-cancel. Fast typing
  never queues overlapping scans.
- Per-file guards: unreadable/non-UTF-8 files are skipped silently; files over a size cap
  (1 MB of text — far beyond any real Markdown document) are skipped so one giant stray
  file can't stall the scan.
- The model touches no `NSTextView` and starts no watcher; it is constructed lazily on
  first All Files activation.

### `EditorContainerView` wiring

- New `@State private var searchScope: EditorSearchScope = .thisFile` (a small app enum,
  `thisFile | allFiles`) bound via `.searchScopes($searchScope) { … }` directly under the
  existing `.searchable` modifier.
- `onChange(of: searchQuery)` and `onChange(of: searchScope)`: in `.allFiles`, clear
  `searchMatches`/`activeSearchIndex` (no in-file highlights) and forward the query to
  `CrossFileSearchModel`; in `.thisFile`, existing behavior, and reset the model.
- The results page (`CrossFileSearchResultsView`, new, in `Lineform/Editor`) is presented
  in the content ZStack **above the editor, below the modal scrim layer**, shown when
  `searchScope == .allFiles && isSearchActive`. It is an opaque theme-background layer —
  content-area-only, so it never touches the top edge (the toolbar-sampling rule is
  irrelevant by construction, same reasoning as the Find & Replace card).
- Row click → `openSidebarFile(result.url)` → `clearAllSearchState()` (a helper that
  empties `searchQuery`, `searchMatches`, resets `searchScope = .thisFile`, resets the
  model, and resigns search focus). `resetTransientDocumentState` (the document-swap
  cleanup that already clears `searchQuery`) additionally resets `searchScope` and the
  model, which is what guarantees the originating tab comes back clean.
- Esc handling: the results page's `.onExitCommand` (and the existing search-dismissal
  paths) route to the same `clearAllSearchState()`.

## Accessibility

Result rows are plain SwiftUI `Button`s: label combines filename, relative path, and match
count ("roadmap.md, projects, 4 matches"). The page announces itself ("All files search
results"). The scope bar is system-provided and accessible for free.

## Tests

Pure-logic tests, default plan, no hosting:

- `CrossFileSearchResolver.result`: finds literal matches; case-insensitive; diacritic-
  insensitive (agrees with `EditorSearchResolver.matches` on the same inputs); nil on no
  match; correct match count; snippet contains the match and comes from the first matching
  line; snippet elision around long lines.
- `CrossFileSearchResolver.ranked`: match-count ordering; deterministic tie-breaks.
- `CrossFileSearchModel`: generation guard (a stale search never publishes); debounce
  fast-path for tests (interval 0 → synchronous, the `directoryRescanDebounce` pattern);
  size-cap and unreadable-file skips (temp-dir fixtures); eviction skip via an injected
  status provider (the `UbiquitousItemDownloader` protocol pattern).
- Scope-state helpers: `clearAllSearchState` resets everything (assert via a pure
  reducer-style helper if extracted, else covered in QA).

View-level behavior (scope bar appearance, results page over each display mode, click →
new tab → clean state everywhere, Esc restore) is **manual in-app QA**, consistent with
Find & Replace and ⌘K.

## Risks / tradeoffs

- **Scope bar aesthetics are fixed by the OS.** Accepted explicitly ("plainness is the
  price of it being genuinely system UI"). If a future macOS restyles it, we inherit that.
- **Scope-bar placement quirk:** in the live demo the scope control rendered at the
  toolbar's far *left* rather than under the field. Native behavior; accepted. Re-verify
  during implementation QA on the narrow-window toolbar (compact mode below 840pt).
- **Read-every-file-on-demand scales with workspace size.** Tens-to-hundreds of Markdown
  files read in well under a second off-main; the 80-per-folder cap bounds the corpus.
  No index means no staleness and no app-owned storage — the trade is deliberate.
- **Results reflect the last scan**, not live disk state (no new watcher). Same accepted
  caveat as ⌘K.
- **Skipped evicted files can silently hide a match** on a Mac that has offloaded old
  files. v1 accepts this; a "some iCloud files weren't searched" hint line is a possible
  refinement if QA shows it matters.
