# Files-sidebar scan debounce — design spec (Task 5)

Date: 2026-07-05. Branch: `worktree-task5-sidebar-scan` (fresh worktree, per the audit's
DO-LAST process gate). Companion to `docs/audits/2026-07-04-audit-decisions.md` (Task 5).

This is the LAST and highest-care item in the audit: the file-list scan area has two past
production incidents (a bricked release; a broken file-access release) and is entangled with
iCloud + sandbox rules. The audit mandate is explicit: **spec the fix shape first, weigh the
cheaper options (not just "background thread"), and skip the fanciest optimizations in v1.**

## Symptom & root cause (confirmed in code, not guessed)

On a workspace with many files, typing hitches ~every half-second. Cause, traced through the
code:

- `DirectoryEventMonitor` (`Lineform/Outline/DirectoryEventMonitor.swift`) delivers coalesced
  FSEvents callbacks **on the main queue** (`FSEventStreamSetDispatchQueue(stream, .main)`),
  coalesced by `coalescingLatency = 0.5s`.
- Each callback runs the store's `refreshWorkspaceRoot()` / `refreshICloudRoot()`
  (`OutlineSidebarView.swift:862-870`), which perform a **synchronous recursive directory
  walk** (`OutlineFileBrowserStore.items(in:)`, `contentsOfDirectory` + `resourceValues` per
  child, up to depth 4, 80/folder) **on the main thread** — the same lane as typing.
- Own-process FSEvents are deliberately **not** filtered (no `IgnoreSelf`) so a Date-Modified
  sort stays correct while the user edits. So autosave-while-typing writes to disk → FSEvents
  fires → a full main-thread tree walk **~every 0.5s while typing** = the hitch.

## Options weighed (the audit listed four; this decides among them)

1. **Move the scan off-main.** Directly removes the stall regardless of tree size. The audit
   flags it as the **highest concurrency risk**, and this is the incident-prone area. Needs an
   overlap/latest-wins generation guard, changes init/launch timing (init currently scans the
   workspace synchronously so the first render is populated), and could perturb the hosted
   editor-motion tests. `items(in:)` is already a **pure static function**, so this stays a
   well-contained *follow-up* if ever needed — but it is not needed to remove the reported
   *during-typing* hitch.
2. **Coalesce/debounce the rescans.** The audit's own words: *"simple, low-risk, could kill
   most of the hitch."* A trailing debounce on the monitor-driven rescan collapses a burst of
   change-pings (continuous autosave churn) into a single rescan that fires only after the
   user pauses.
3. **Scope the rescan to the changed folder** (use the FSEvent paths). Addresses per-scan
   cost, but requires reworking `items(in:)` into an incremental subtree updater and splicing
   FSEvents paths back into the live tree — exactly the *"subtle, hard-to-repro"* complexity
   the audit warns against. The current callback also discards the changed-paths array
   entirely, so this is a real rewrite, not a tweak.
4. **Cheapen the 80-cap.** Already largely done: `items(in:)` sorts+caps the *shallow* pass
   first and recurses **only into the retained ~80** (see its in-code comment), so a folder
   with thousands of subdirectories does not build thousands of subtrees. The residual cost
   (one `resourceValues` per child before capping) is inherent to a date-sorted cap and
   marginal. Nothing worth doing.

## Decision — Option 2 (trailing debounce), v1 only

Interpose a **trailing debounce** between the FSEvents `onChange` and the actual rescan, on
the **monitor path only**. During a continuous typing burst, each autosave-driven FSEvents
tick resets the timer, so the expensive walk is deferred until the user pauses — converting
"fights you every 0.5s while typing" into a single **settle-after-pause**. This is the exact
model the audit blessed for Task 1 (*"a heartbeat after you stop instead of fighting you while
you type"*) and mirrors the app's existing, tested `DocumentReloadController` debounce.

**Explicitly NOT in v1** (per "skip the fanciest optimizations in v1"): Option 1 (off-main),
Option 3 (incremental scope-splice), Option 4 (cap micro-opt). Option 1 is recorded as the
sanctioned follow-up **if** a truly-huge-tree *pause-time* stall is later reported — cheap
because `items(in:)` is already pure.

### Why debounce is a real fix, not just relocation

The pause rescan on a very large tree is still a main-thread walk. But moving it to the pause
is a genuine, principled improvement (not "same hitch, later"): the during-typing case is
*repeated* disruption every 0.5s while the user is mid-flow; the pause case is a *single*
settle after the user has already stopped — the same trade-off the audit deliberately accepted
for Task 1. If that single pause-settle is ever itself felt on an extreme tree, that is the
trigger for the Option 1 follow-up, not a reason to widen v1.

## Fix shape (implementation contract)

Mirror `DocumentReloadController` exactly (`Lineform/Documents/DocumentReloadController.swift`):

- New injected `directoryRescanDebounce: TimeInterval` on `OutlineFileBrowserStore.init`,
  defaulting to a new constant `directoryRescanDebounceInterval`. Added as the **last** init
  parameter so every existing production/test call site is source-compatible.
- Two pending work-item slots (`pendingWorkspaceRescan`, `pendingICloudRescan`) — kept
  **separate** so a workspace change never triggers an iCloud rescan and vice versa
  (preserves current per-root semantics).
- Two private schedulers with the canonical idiom, including the synchronous fast-path:
  ```swift
  pendingWorkspaceRescan?.cancel()
  guard directoryRescanDebounce > 0 else { refreshWorkspaceRoot(); return }
  let work = DispatchWorkItem { [weak self] in
      self?.pendingWorkspaceRescan = nil
      self?.refreshWorkspaceRoot()
  }
  pendingWorkspaceRescan = work
  DispatchQueue.main.asyncAfter(deadline: .now() + directoryRescanDebounce, execute: work)
  ```
- The two monitor `onChange` closures in `beginWatchingForExternalChanges()` call the new
  schedulers instead of `refreshWorkspaceRoot()` / `refreshICloudRoot()` directly.
- `endWatchingForExternalChanges()` and `deinit` cancel both pending work items (tab hidden /
  store gone → any pending rescan is stale; the next tab-appear rescans anyway).

### Interval choice — a real constraint, documented

`directoryRescanDebounceInterval` MUST be **greater than** `DirectoryEventMonitor.coalescingLatency`
(0.5s). During continuous churn FSEvents delivers a callback roughly every `coalescingLatency`;
a debounce longer than that window is guaranteed to keep resetting (never fire) until the churn
stops. A value ≤ 0.5s could fire *between* coalesced callbacks and reintroduce a mid-typing
hitch. Chosen: **0.75s** (comfortable margin against jitter; an imperceptible delay for a
background file-tree refresh). The constant carries a comment stating this dependency.

## What must NOT change (invariants, incident-prone area)

- **Held security scope stays held for the store's lifetime.** No transient
  start/stop is introduced (that was the 1.1.1 file-access bug). The debounce touches only
  *when* a rescan runs, never *how* file access is granted.
- **iCloud-laziness invariant preserved.** The debounce wraps only the monitor path, which
  exists only after the Files tab began watching (post first deferred scan). Init still defers
  the iCloud scan; `refreshICloud()` on tab-appear is still direct/instant.
- **`items(in:)`, the publish-only-on-change guard, iCloud resolution, snapshot save, and
  `ensureDownloaded` are untouched.** `DirectoryEventMonitor.swift` (the FSEvents C-callback
  code) is untouched.
- **Own-process events still not filtered** — Date-Modified sort stays correct; those events
  simply coalesce into the pause rescan instead of a per-0.5s walk.
- **No flush-on-save needed** (unlike Task 1): the sidebar tree feeds no save/undo/document
  state — it is a view convenience. Dropping a pending rescan can never lose user work or
  corrupt a document; the worst case is the tree being ≤ one debounce interval stale, which
  the next event or tab-appear corrects.
- **Instant paths stay instant:** rename/delete broadcast (`refreshRoots(affecting:)`), sort
  change, hidden-folders toggle, `setWorkspaceURL`, init, tab-appear.

## Testing

Deterministic, in the pure default plan (no new hosted tests, no reliance on real FSEvents):

1. **Fast-path unchanged:** the two existing monitor tests
   (`testWatcherRescansRootsWhenDirectoryEventsFireAndStopsOnEnd`,
   `testWatcherCoversWorkspaceRootViaHeldBookmark`) inject `directoryRescanDebounce: 0` and
   keep their synchronous `onChange()` → immediate-assert style byte-for-byte. Proves the
   guard's `> 0` fast-path and that existing behavior is preserved when undebounced.
2. **Deferral:** with a small non-zero interval, firing `onChange()` does **not** rescan
   synchronously (the published root still shows the pre-change tree on the next line).
3. **Eventual correctness:** after pumping the runloop past the interval (the existing
   `waitUntil` poll idiom from `DocumentReloadControllerTests`), the root reflects the new
   tree — the single trailing rescan ran.
4. **Cancel on end:** a pending debounced rescan is cancelled by
   `endWatchingForExternalChanges()` — after firing `onChange()` then ending, pumping past the
   interval leaves the root unchanged (no late rescan).

Coalescing ("N rapid events → one walk, not N") is guaranteed by construction — each schedule
cancels the prior work item, identical to the already-trusted `DocumentReloadController`
mechanism — so it is not over-tested with a production-only rescan counter.

## Out of scope / residual risk (stated honestly)

- **Extreme-tree pause-settle** may still be briefly felt on a genuinely huge workspace; that
  is the documented trigger for the Option 1 (off-main) follow-up, not a v1 gap.
- **Felt-smoothness QA needs the user's hands** — automation cannot type into the app, and the
  reported symptom is a felt typing hitch on a large workspace. Unit tests prove the debounce
  mechanism (deferral / eventual correctness / cancel); the *felt* result must be confirmed
  in-app by the user on a many-file workspace.
