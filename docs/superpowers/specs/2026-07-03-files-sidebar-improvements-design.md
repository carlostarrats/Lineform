# Files Sidebar Improvements — Design

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

Date: 2026-07-03
Status: Approved by user (conversation), pending spec review

## Context

The Files sidebar (`Lineform/Outline/OutlineSidebarView.swift`, ~1,530 lines: store + views + opener) currently:

- Does **no** directory watching. `OutlineFileBrowserStore` scans once; re-scans happen only when the Files tab appears (and that refreshes **iCloud only**, never the workspace root), when Show Hidden Folders is toggled, or when the workspace folder is re-chosen. A file added in Finder while the sidebar is visible never appears. Confirmed user-facing bug.
- Has **no context menu** on file or folder rows, and no rename/delete capability anywhere in the app.
- Sorts with a **hard-coded** order (folders first, then natural name order) applied inside the scan (`OutlineSidebarView.swift:1011-1018`). No preference.
- Has **thin accessibility**: file rows carry only an `.isSelected` trait — no labels or identifiers.
- Uses stock `NSDocument.canClose` when switching files via the sidebar; the Save / Cancel / Delete sheet is Apple's standard unsaved-changes prompt and should appear only for dirty documents. The user may have seen it on a file they don't believe they edited — needs investigation.

## Goals

1. Sidebar reflects external file-system changes (files added/renamed/deleted in Finder or by agents) within ~1 second while visible.
2. Right-click Rename… / Delete… / Show in Finder on files; Rename… / Show in Finder on folders (no folder delete).
3. Muse-style native confirmation dialogs for rename and delete; delete moves to Trash only.
4. Per-section sort control (Name / Date Created / Date Modified) for the iCloud section and the workspace section, persisted separately.
5. File-menu Rename… / Delete… commands acting on the currently open file, same behavior as the context menu.
6. Verify a clean existing file never triggers the unsaved-changes sheet on sidebar switching; fix any spurious dirtying found.
7. Real accessibility on all of the above.

## Non-Goals

- No folder delete.
- No manual/custom ordering (no drag-to-reorder; Muse's "Manual" mode is deliberately omitted).
- No moving files between folders.
- No change to Apple's standard wording on the untitled-document sheet ("Save… / Cancel / Delete") — it appears exactly and only when leaving a started-but-never-saved document, which is the accepted behavior.

## Design

### 1. External-change refresh (approach C: watcher + reconcile-on-appear)

- **Watcher**: one recursive `FSEventStream` per visible root (workspace, iCloud container), owned by `OutlineFileBrowserStore`, running **only while the window's Files tab is visible** (started/stopped from the same lifecycle that currently drives `refreshICloud()` on `.onAppear`, plus a matching teardown on disappear). Events are debounced (~0.5 s) into a re-scan of the affected root, published as a new tree.
- **Reconcile on appear**: when the Files tab appears, re-scan **both** roots — this also fixes the existing asymmetry where only iCloud refreshes on appearance.
- **Invariants preserved**: the expensive iCloud scan still never runs for windows on the Outline tab or with the sidebar collapsed (watcher lifecycle is tied to Files-tab visibility, same as today's `refreshICloud()` deferral). The workspace security scope stays held by the store for its lifetime — the watcher does not introduce transient start/stop of security-scoped access.
- Existing caps (depth 4, 80 children per folder, md/markdown/txt, `node_modules`/`.git` excluded, hidden-folder rules) are unchanged; a re-scan is just the existing scan re-run.
- Expanded/collapsed state and selection are preserved across re-scans (keyed by URL).

### 2. Save-prompt investigation

- Reproduce: open a clean existing file, switch to another file via the sidebar, confirm no sheet.
- Audit for spurious `updateChangeCount`/dirtying on the open path (e.g., programmatic text-view mutation during document swap, syntax-highlight passes, reading-profile application). Any found is a bug: fix so opening/rendering never dirties a document.
- Add a regression test: opening a document and running the editor bridge's initial layout/highlight leaves `isDocumentEdited == false`.
- If nothing spurious is found, conclude the sheet the user saw reflected a real edit; document that in the PR/summary. No wording changes to Apple's sheet.

### 3. File context menu

Right-click on a file row offers:

- **Rename…** — opens a native alert-style dialog (`NSAlert` with accessory text field), Muse-style: title "Rename File", body "Renames the file. Its contents are kept.", text field pre-filled with the filename **without extension** and pre-selected, buttons Cancel / Rename. The extension is preserved automatically. Rename happens via `FileManager.moveItem` in the same directory.
- **Delete…** — matching dialog: title "Delete 'Name.md'?", body "It will be moved to the Trash.", buttons Cancel / Delete (Cancel is the default button; Delete is marked destructive, per macOS convention). Confirmed deletes use `FileManager.trashItem` (Trash only — never permanent removal).
- **Show in Finder** — `NSWorkspace.activateFileViewerSelecting`.

Interactions with the open document:

- Renaming the currently open file: the existing `DocumentReloadController`/`NSFilePresenter` machinery already tracks external renames of the open document; verify the document follows the new URL and the sidebar selection highlight updates (`currentFileURL`).
- Deleting the currently open file: standard `NSDocument` behavior — the document stays in memory as unsaved content; nothing is lost without the user's say-so. The sidebar row disappears via the watcher re-scan.

Failure handling: rename collisions (target name exists), permission errors, or trash failures show a plain `NSAlert` with the system-provided error description; the file system is never left half-changed (single atomic `moveItem`/`trashItem` calls).

### 4. Folder context menu

- **Rename…** — same dialog pattern, title "Rename Folder", body "Renames the folder. Its files are kept."
- **Show in Finder**.
- No delete.

Renaming a folder that contains the open document: the open document's file presenter tracks the moved path (verify; if `NSFilePresenter` misses ancestor renames, reconcile via the watcher re-scan and `currentFileURL` re-resolution).

### 5. Per-section sort

- A small "Sort: Name ▾" row rendered above each section's contents — one for the iCloud section, one for the workspace section — styled to match the sidebar's quiet typography (secondary color, small size), implemented as a borderless `Menu`/pop-up.
- Options: **Name** (A→Z, `localizedStandardCompare`, current behavior), **Date Created** (newest first), **Date Modified** (newest first). No Manual.
- Folders always group before files; both groups sort by the chosen key.
- Persisted per section in `UserDefaults` (two keys, e.g. `sidebarSortOrder.icloud`, `sidebarSortOrder.workspace`), default Name. Stored snapshots re-sort on load so a changed preference applies to cached trees.
- Date metadata (`creationDate`, `contentModificationDate`) is captured during the existing scan via the resource-keys fetch already used there; `OutlineFileTreeItem` gains the two optional dates (Codable-compatible with old snapshots).

### 6. Menu bar commands

- **File → Rename…** and **File → Delete…**, acting on the currently open sidebar file (`currentFileURL`), presenting exactly the same dialogs as the context menu.
- Disabled when there is no current real file (untitled document, or no document).
- Wired through the existing `LineformAppNotification` pattern (as Show Hidden Folders is), so the key window's store/actions handle it.
- No keyboard shortcut for Delete… (avoids accidental destructive shortcut); Rename… may take the standard no-shortcut slot. Note: macOS document apps also allow renaming via the title bar — the File menu item complements it.

### 7. Accessibility

- File and folder rows get `accessibilityLabel` (file/folder name) and sensible identifiers; existing `.isSelected` trait kept.
- Rename and Delete exposed as **VoiceOver custom actions** (`accessibilityAction(named:)`) on rows, so right-click is not the only path.
- Sort row is a proper accessible pop-up ("Sort order, Name" / value changes announced).
- Dialogs: text field labeled; destructive Delete button marked appropriately; alerts use standard `NSAlert` so VoiceOver behavior is inherited.
- Menu bar items are inherently accessible; they also make the actions discoverable system-wide (Help menu search).

## Architecture

- **`OutlineFileBrowserStore`** (existing): gains the FSEvents watcher lifecycle, per-root sort preference, date capture in the scan, and re-scan reconciliation. Watcher behind a small protocol (`DirectoryEventSource` or similar) so tests can inject synthetic events without real FSEvents latency.
- **New `SidebarFileActions`** (small type, likely in `Lineform/Outline`): rename/trash/reveal operations behind a protocol (`FileManaging`-style) for unit testing; presents the dialogs (AppKit `NSAlert`, since the Muse-style look is exactly a native alert with accessory view).
- **Views**: context menus via `.contextMenu` on the existing row views; sort row as a new small view above each root's children in `OutlineFileRootRow`.
- **Menu commands**: `AppCommands.swift` + `LineformAppNotification`, following the Show Hidden Folders pattern.
- No responsibilities move across directories. `OutlineSidebarView.swift` is already ~1,530 lines; the actions type and dialogs go in a new file rather than growing it further.

## Testing

- **Store unit tests**: synthetic directory events trigger a re-scan; both roots re-scan on appear; sort orders (name/created/modified, folders-first) with injected dates; snapshot decode with missing dates; sort preference persistence per section.
- **Actions unit tests**: rename preserves extension, collision surfaces error, delete calls trash (never remove), via injected file-manager protocol.
- **Regression test**: freshly opened document remains `isDocumentEdited == false` after editor setup (section 2).
- **Hosted-view tests**: follow existing `OutlineSidebarViewTests` patterns for the new sort row and row accessibility labels.
- **Manual verification** (running app): add a file in Finder while the Files tab is visible → appears within ~1 s; rename/delete dialogs; deleting the open file; VoiceOver pass over rows, sort control, and dialogs; File-menu commands enabled/disabled states.
