# Spec 2 — Hidden Folder Visibility

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 2)
Source feature: F4 in `lineform-agent-reader-spec.md`.

## Goal

The Files sidebar gains a **Show hidden folders** toggle (default **off**). When on,
dot-directories (`.claude/`, `.agents/`, `.github/`, …) and their `.md`/`.markdown`/`.txt`
files appear in the tree, visually **de-emphasized** (secondary label color), so the default
calm sidebar stays calm for everyone else. This makes agent-written markdown that lives in
hidden folders reachable — a core Agent-Reader need.

## Behavior (from F4, made precise for this codebase)

1. **Toggle**, default off, **persisted per app** (not per folder).
2. **On** → dot-directories and their supported files appear, styled with the existing
   secondary label color so they read as secondary.
3. **`node_modules` and other non-text noise stay excluded regardless of the toggle** — the
   toggle governs dot-folders only.
4. Files inside hidden folders **open, watch (live reload), and render identically** to any
   other file. (They flow through the same tree nodes, so no extra work is needed for this.)
5. **Off** → behavior is identical to today (dot-folders hidden).

## Architecture reality (grounding)

Everything lives in `Lineform/Outline/OutlineSidebarView.swift` (the tree model, the
`OutlineFileBrowserStore`, and the browser views are all in this one file):

- **Single filter point:** `OutlineFileBrowserStore.items(in:fileManager:depth:)`
  (`:731-778`) is the *only* place enumeration + filtering happens; both the iCloud root
  (`:633`) and the workspace root (`:693`) call it, and it recurses at `:765`. Today it uses
  `FileManager.contentsOfDirectory(..., options: [.skipsHiddenFiles])` (`:744`) — that single
  option is what hides dot-folders today — plus an extension whitelist (`md`/`markdown`/`txt`,
  `supportedFileExtensions` at `:449`) and volume caps (depth 4, 80 children).
- **Node type:** `OutlineFileTreeItem` (`:11-18`) is `Codable` and **persisted** as a JSON
  snapshot. It has no styling flag today. Adding `isHidden` must not break decoding of old
  snapshots (see Persistence below).
- **The store keeps only the *filtered* result** (`lastICloudItems`/`lastWorkspaceItems`,
  the snapshots, and the root trees). Hidden entries are never enumerated, so **toggling the
  option requires a re-scan** — it cannot be a cheap re-filter of cached data.
- **Row rendering:** `OutlineFileTreeNodeView` (`:976-1064`) renders each row's icon
  (`:1019-1022`) and name (`:1024-1027`) with
  `OutlineSidebarView.primaryTextColor(usesDarkChrome:)`. A de-emphasized row swaps to the
  existing `OutlineSidebarView.secondaryTextColor(usesDarkChrome:)` (`:238-243`).
- **Preferences idiom:** injected `UserDefaults` + a namespaced key (e.g. the store's
  `"Lineform.outline.*"` keys at `:444-446`). The store already holds `self.defaults`
  (`:466`) and loads persisted state in `init` (`:484-486`). No `@AppStorage` is used anywhere
  — follow the injected-defaults pattern.
- **Files sidebar header:** the tab picker (`:161-168`) is shared with the Outline tab, so a
  **Files-only** toggle belongs at the top of `OutlineFileBrowserView.body` (`:787-799`), not
  in the shared tab picker.

## Design

### Filtering (`items(in:fileManager:depth:)`)

Add a `showsHiddenFolders: Bool` parameter (threaded from the two call sites and the
recursion). Also add an `inheritedHidden: Bool` parameter (default false) so descendants of a
hidden folder inherit the de-emphasis.

- **Always** exclude a small directory **blocklist** by `lastPathComponent`, regardless of the
  toggle: `node_modules`, `.git`. (This realizes F4's "continue excluding node_modules and
  other non-text noise." It slightly changes today's behavior only in the rare case a
  `node_modules` contained supported files — an intentional, product-aligned improvement.)
  Keep the list small, conservative, and named (`excludedDirectoryNames`).
- **When `showsHiddenFolders` is false:** keep `options: [.skipsHiddenFiles]` — behavior
  identical to today (plus the blocklist above).
- **When `showsHiddenFolders` is true:** drop `.skipsHiddenFiles`; add `.isHiddenKey` to the
  requested resource keys. Include an item when its name is dot-prefixed
  (`name.hasPrefix(".")`), but still **exclude genuinely OS-hidden, non-dot items** (read
  `.isHidden`) so system junk doesn't leak in. The extension whitelist and caps are unchanged,
  so a hidden folder shows only its supported files and subfolders.
- **Mark nodes:** a node's `isHidden` = `inheritedHidden || name.hasPrefix(".")`. Recurse with
  `inheritedHidden: node.isHidden` so files under a hidden folder are also de-emphasized.

### Node model

Add `var isHidden: Bool = false` to `OutlineFileTreeItem`. Provide a **decode-tolerant**
`init(from:)` (`decodeIfPresent(Bool.self, forKey: .isHidden) ?? false`) so existing persisted
snapshots (which lack the key, and only ever contained non-hidden items) still decode. Keep
`Equatable`/`Identifiable` behavior; `id` stays `url.path`.

### Persistence

Add `showsHiddenFolders` to `OutlineFileBrowserStore`:
- `@Published var showsHiddenFolders: Bool` with a `didSet` that (a) persists to
  `defaults` under a new key `"Lineform.outline.showsHiddenFolders"` and (b) triggers a
  re-scan of both roots through the **existing refresh entry points** (which already run off
  the main thread — do not add a synchronous main-thread scan; preserve the CLAUDE.md laziness
  rule).
- Load the persisted value in `init` (default `false`), guarding against a re-scan/persist
  loop during initial load.

### UI

- A compact, restrained **Files-only** toggle at the top of `OutlineFileBrowserView.body`. Use
  an SF Symbol eye control (`eye` when showing / `eye.slash` when hidden) or a small labeled
  toggle, styled with the secondary color and a clear accessibility label ("Show hidden
  folders"). It binds to `store.showsHiddenFolders`. Keep it visually quiet — this is a power
  affordance, not a primary control.
- **De-emphasis:** in `OutlineFileTreeNodeView`, when `item.isHidden`, render the icon
  (`:1021`) and name (`:1026`) with `secondaryTextColor(...)` instead of `primaryTextColor`.
  Nothing else about the row changes (disclosure, open behavior, indentation stay identical).

## Non-goals

- No per-folder toggle; the preference is app-wide.
- No general dotfile browsing philosophy change — only dot-*directories* and their supported
  files, minus the blocklist.
- No pruning of empty directories (matches current behavior: directories show regardless of
  whether they contain supported files).
- No change to the extension whitelist, the volume caps, the iCloud/workspace root logic, or
  `ensureDownloaded` behavior (hidden files are materialized like any other, which is what
  makes "open/watch/render identically" true).
- No change to the Outline tab or the shared tab picker.

## Verification

1. **Deterministic suite** (serial, per CLAUDE.md; quit Xcode first):
   ```sh
   xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
     -destination 'platform=macOS' -parallel-testing-enabled NO
   ```
   New tests must pass; the full existing suite stays green (modulo the two documented
   load-sensitive `EditorDisplayModeTests`). Report exact counts.
2. **Unit tests** (mirroring `OutlineSidebarViewTests` temp-dir + injected-defaults idiom):
   - With a temp tree containing `Draft.md`, `.claude/notes.md`, `node_modules/readme.md`,
     `.git/x.md`, and `Image.png`:
     - Toggle **off** → only `Draft.md` (dotfolders + node_modules + non-supported excluded).
     - Toggle **on** → `Draft.md` and `.claude` (with `notes.md`) appear; `node_modules` and
       `.git` stay excluded; `Image.png` still excluded.
   - `.claude` and `notes.md` nodes have `isHidden == true`; `Draft.md` has `isHidden == false`.
   - Persistence: set `showsHiddenFolders = true`, construct a new store on the same defaults
     suite → value restored `true`.
   - Decode tolerance: an old snapshot JSON lacking `isHidden` decodes with `isHidden == false`.
3. **Manual smoke** (keep any scratch tree **outside `~/Documents`**, e.g. in the scratchpad,
   to avoid the app's Documents TCC prompt on freshly-signed debug builds): point the workspace
   root at a folder containing `.claude/plan.md`; toggle on → the folder appears de-emphasized
   and the file opens and live-reloads normally; toggle off → it disappears; relaunch → the
   toggle state persisted. If this manual GUI pass is not exercised, say so.

## Risk / notes

- **Re-scan on toggle** is required (hidden entries were never enumerated). Route it through
  the existing off-main refresh path; do not block the main thread.
- **Snapshot decode compatibility:** the decode-tolerant `init(from:)` avoids dropping users'
  cached snapshots when the new field ships. (Even the fallback — decode failure → re-scan —
  is only a cache miss, but tolerant decode is cleaner and is tested.)
- **`.git` in the blocklist:** dot-prefixed but pure noise; excluding it keeps the calm bar.
  The blocklist is intentionally small and named so it is easy to extend later.
