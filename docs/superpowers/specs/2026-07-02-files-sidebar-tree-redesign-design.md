# Files Sidebar Tree Redesign

**Date:** 2026-07-02
**Status:** Approved, ready for implementation
**Area:** `Lineform/Outline/OutlineSidebarView.swift` (Files tab only)

## Problem

The Files sidebar's two group roots ("Lineform iCloud", "Workspace") and their file/folder rows use two different, half-overlapping indentation systems:

- A **root row** is `[chevron] [title]` — no type-icon, no depth indent.
- A **tree row** is `[chevron] [icon] [name]`, indented `depth × 14pt`, with direct children at depth 0 (zero indent).

Because direct children start at zero indent, a subfolder's chevron lands at the *same x* as its root's chevron, so a child folder (e.g. "Test Folder") reads as a **sibling** of the root ("Workspace") rather than as its contents. Roots also lack a container icon, so they don't read as folders. Labels are static and the workspace action button ("Replace") sounds destructive.

Sibling rows aligning at the same level is correct and stays. The only structural bug is *child aligning with its own root*.

## Goals

1. Make nesting unambiguous: a root's contents clearly belong to that root.
2. Give each root a container icon so it reads as the top of its group.
3. Clearer, calmer labels and a non-destructive workspace action.
4. Keep the change scoped to the Files tab; do not touch the Outline tab, the store's scanning/iCloud/bookmark logic, or file-open behavior.

Non-goals: no change to `maximumTreeDepth`, scanning, iCloud entitlement/laziness, security-scoped bookmarks, hidden-folders behavior, or the Outline tab.

## Design

### 1. One consistent indent grid with a per-open-folder guide line

> **Superseded 2026-07-02 (same day):** the vertical guide lines described below were shipped, then removed. In use they fragmented into short disconnected segments at each depth and read as noise against the app's calm/native grain. The tree now conveys nesting with **indentation + disclosure chevrons alone** — the native macOS source-list convention (Finder, Notes, Mail) — at a **14pt** indent step (not the 10–12pt below, which only worked because the lines carried the signal). `filesTreeIndentStep` is the sole geometry constant; the `guideLine` view and the `filesGuideLineInset` helpers no longer exist.

Treat each root as the top folder of a single grid. Indent one gentle step per nesting level; a **single faint vertical guide line** runs down the direct children of each *open* folder (root or subfolder), connecting them to their parent. This is the "one line per open folder" model, not a stacked per-level ladder.

- **Indent step:** ~10–12pt per level (down from 14). The guide line carries most of the "this is nested" signal, so the horizontal step can be gentler.
- **Direct children of a root** indent **one step** past the root (they no longer sit at zero indent). This is the fix for the child-aligns-with-root bug: a subfolder's chevron now sits clearly to the right of its root's chevron.
- **Guide line:** a thin vertical rule (~1pt) in the secondary text color at low opacity, positioned in the indent gutter to the left of each open folder's direct-child rows, spanning their vertical extent. One line per open folder — an open subfolder inside an open root draws its own single line for *its* children; there is no full ladder of stacked lines back to the root.
- Depth is still bounded by `maximumTreeDepth = 4`, so the deepest file sits ~4 steps in — comfortable in the sidebar width.

Files and folders at the same level continue to share the same left edge (siblings align — unchanged and intended).

### 2. Root rows get a container icon and join the grid

Root rows adopt the same leading structure as tree rows: `[chevron] [type-icon] [title] … [trailing action/status]`.

- **iCloud root:** type-icon `icloud`, title **"Lineform"** (was "Lineform iCloud").
- **Workspace root:** type-icon `folder`, dynamic title (see §4).
- Roots remain collapsible (chevron present) **except** where §3 removes it.
- `filesRootRowsShowLeadingIcons` (currently `false`) is enabled for this rendering; the root row renders `root.systemImage`.

### 3. Empty / unavailable iCloud root: dimmed, no chevron

When the iCloud root is `.unavailable` **or** `.available` with `items.isEmpty`, render the root dimmed (existing `filesUnavailableRootOpacity`) with **no chevron** (nothing to expand) and no child area. The existing "Unavailable" pill still shows only for the `.unavailable` state. The `.available`-but-empty case shows no pill and no "No Markdown files" line — just the quiet dimmed header.

- Roots with files (`.available`, non-empty) and the `.disconnected` workspace fallback keep their chevron and expand normally.
- This is presentation-only in the view; the store's states are unchanged. The view derives "empty" from `root.items.isEmpty`.

### 4. Dynamic workspace title

The workspace root title reflects the chosen folder:

- **`.unassigned`:** "Workspace".
- **`.available` / `.disconnected`:** the chosen folder's display name (its `URL.lastPathComponent`), so a disconnected folder still shows its last known name.

Implementation: set `workspaceRoot.title` from the resolved `workspaceURL.lastPathComponent` in `refreshWorkspaceRoot()` (falling back to "Workspace" when there is no URL). No new persisted state is required — the folder name derives from the bookmarked URL the store already resolves; the disconnected path already resolves the bookmark URL before checking existence, so its `lastPathComponent` is available there too.

### 5. Workspace action button: "Change", direct swap

- Label: **"Choose"** when `.unassigned`, **"Change"** when assigned (was "Replace").
- Behavior when assigned: tapping **"Change"** calls `chooseWorkspaceFolder()` directly (opens the folder picker and swaps in place via the existing `setWorkspaceURL` → bookmark-overwrite path). Cancelling the picker leaves the current folder untouched (the existing `runModal() == .OK` guard returns early).
- The old two-step unassign path (`clearWorkspaceAssignment`) is no longer wired to the button. Keep the method if it is used elsewhere; otherwise it may be removed if unreferenced. (Verify references before deleting.)
- `replaceWorkspaceButtonTitle` constant renamed/retargeted to "Change".

## Files touched

- `Lineform/Outline/OutlineSidebarView.swift`:
  - `OutlineFileRootRow` — render leading type-icon; conditional chevron (drop when unavailable/empty); "Change"/"Choose" title; button calls `chooseWorkspaceFolder` when assigned.
  - `OutlineFileTreeNodeView` — indent step change; direct children indent one step past root; add per-open-folder vertical guide line.
  - `OutlineFileBrowserView.rootView` — pass a starting depth so direct children indent one step; guide-line gutter for the root's own children; empty/unavailable dimmed-no-chevron handling; remove/repoint the `.padding(.leading, 28)` empty-state line as needed.
  - Constants: `replaceWorkspaceButtonTitle` → "Change"; enable `filesRootRowsShowLeadingIcons`; indent-step constant if extracted.
  - Store: `iCloudRoot.title` "Lineform iCloud" → "Lineform" (initializer + the refresh paths that rebuild the root); `refreshWorkspaceRoot()` sets dynamic title from `workspaceURL.lastPathComponent`. Update every `OutlineFileRoot(title:)` site that hardcodes the old titles.

## Testing

- Update/extend `LineformTests` covering the store roots: iCloud root title is "Lineform"; workspace title equals the assigned folder's name and reverts to "Workspace" when unassigned; disconnected workspace retains the folder name.
- Keep view rendering verifications light (indent/guide line are visual); assert the data-model/title/state logic that drives them where practical (e.g. a helper that computes whether a root shows a chevron given state + emptiness).
- Full gate: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO` (quit Xcode first, per AGENTS.md).

## Risks

- The guide-line geometry must line up with the indent gutter across depths; get the gutter x from the same indent-step constant the rows use to avoid drift.
- Enabling root leading icons must not shift trailing action/status layout — verify the "Change"/"Choose" pill and "Unavailable" pill still align.
- Dynamic title must not fight the store's snapshot/disconnected fallback (title is derived at refresh, not persisted).
