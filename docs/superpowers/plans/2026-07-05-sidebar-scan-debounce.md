# Plan — Files-sidebar scan debounce (Task 5)

Spec: `docs/superpowers/specs/2026-07-05-sidebar-scan-debounce-design.md`.
One file of production change + focused tests. TDD.

## Step 1 — Tests first (default plan, `LineformTests/OutlineSidebarViewTests.swift`)
- Update the two existing monitor tests (`testWatcherRescansRootsWhenDirectoryEventsFireAndStopsOnEnd`,
  `testWatcherCoversWorkspaceRootViaHeldBookmark`) to inject `directoryRescanDebounce: 0`
  → they keep asserting synchronously (proves fast-path preserves old behavior).
- Add `testWatcherDebouncesMonitorDrivenRescans`: non-zero interval; fire `onChange()`, assert
  root UNCHANGED synchronously (deferral); pump runloop past interval via `waitUntil`, assert
  root reflects the new file (eventual correctness).
- Add `testEndWatchingCancelsPendingDebouncedRescan`: fire `onChange()`, call
  `endWatchingForExternalChanges()`, pump past interval, assert root UNCHANGED (cancelled).
- Add a `waitUntil` poll helper local to the test file (mirror
  `DocumentReloadControllerTests`), or reuse if visible.

## Step 2 — Production (`Lineform/Outline/OutlineSidebarView.swift`, `OutlineFileBrowserStore`)
- Add `static let directoryRescanDebounceInterval: TimeInterval = 0.75` with the
  "must exceed `DirectoryEventMonitor.coalescingLatency`" comment.
- Add `private let directoryRescanDebounce: TimeInterval`, `private var pendingWorkspaceRescan:
  DispatchWorkItem?`, `private var pendingICloudRescan: DispatchWorkItem?`.
- Add `directoryRescanDebounce: TimeInterval = Self.directoryRescanDebounceInterval` as the
  LAST init param; store it.
- Add `private func scheduleWorkspaceRescan()` / `scheduleICloudRescan()` (canonical idiom,
  `> 0` fast-path, cancel-before-schedule, clear the slot inside the work item).
- Route the two monitor `onChange` closures in `beginWatchingForExternalChanges()` through the
  schedulers.
- Cancel both pending work items in `endWatchingForExternalChanges()` and `deinit`.

## Step 3 — Verify
- `xcodebuild build` (build-only; no TCC prompt).
- Run the default test plan (warn re: TCC — may block on the Documents prompt while user away).
- Review (subagent) + fix loop until green.

## Step 4 — Docs + close out
- CLAUDE.md Files-sidebar bullet: note the monitor-driven rescan is trailing-debounced.
- Check the tracker box in `docs/audits/2026-07-04-audit-decisions.md` (Task 5) with date +
  branch, and record the as-built + the Option-1 follow-up note.
- Commit.
