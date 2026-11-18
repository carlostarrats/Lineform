# Launch restores the last document (future change)

Noted 2026-11-16 while testing a TestFlight build.

**Status: fixed 2026-11-17** (branch `feature/selection-toolbar`). The cause was a no-op: `applicationShouldRestoreApplicationState` is not an `NSApplicationDelegate` method on macOS, so it never ran. Document windows are now `isRestorable = false`; see `docs/architecture/app-integration.md` (cold launch).

## What happened

After quitting Lineform (and shutting the Mac down), opening the TestFlight build reopened the
document that was open last, instead of starting empty.

## Wanted behavior

A fresh launch after a quit should open to a clean state: the normal empty untitled window, not
the last-open document(s).

## Likely cause (unverified)

Lineform does not opt out of macOS window restoration anywhere (`grep` for `restor`,
`NSQuitAlwaysKeepsWindows`, `isRestorable` in `Lineform/App` finds nothing relevant), so this is
probably the system's Resume / `NSDocumentController` state restoration reopening the previous
session's documents. The System Settings option "Close windows when quitting an application" being
off would make this happen for every document-based app.

## Things to check when this is picked up

- Confirm it is system restoration, not something of ours (e.g. the workspace bookmark or tab store).
- Decide the opt-out point: `NSQuitAlwaysKeepsWindows = false` in defaults registration,
  `applicationShouldRestoreWindows` / `isRestorable = false` on document windows, or
  `NSDocumentController` restoration hooks.
- Keep the cold-launch guards intact (CLAUDE.md, "Build config and app shell"): an untitled document
  is created only when there are no visible windows, no open documents, and no first-launch intro.
  Turning restoration off changes which branch of that logic runs at launch.
- Opening a file from Finder (or via the default-handler path) must still open that file.
- The Files sidebar workspace is separate and should keep persisting; only the reopened documents go.
