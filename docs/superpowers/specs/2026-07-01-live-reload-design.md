# Spec 1 — Live Reload (watch)

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 1)
Source feature: F3 in `lineform-agent-reader-spec.md`.

## Goal

An open document refreshes itself when its file changes on disk. The agent writes the
`.md`; the open Lineform window updates without the user touching anything. This is the
first dogfoodable piece of the Agent-Reader release: "where you read and edit what your
agent wrote."

This is the app's **default** behavior — there is no watch toggle. It matches the app's
existing "the file on disk is the truth" posture (autosave already writes through to the
real file as the user types).

## Architecture reality (important deviation from the source spec)

The source spec says "Implement/verify `NSFilePresenter` conformance **on the document
type**." That assumes an AppKit `NSDocument`. Lineform is **not** built that way:

- `LineformDocument` is a SwiftUI **`FileDocument`** — a value-type `struct`
  (`Lineform/Documents/LineformDocument.swift:10`). A value type cannot conform to
  `NSFilePresenter`, and SwiftUI `DocumentGroup` provides no `NSDocument` subclass to
  override (`LineformApp.swift:14`). The framework creates an internal `NSDocument`,
  reachable only via `window.windowController?.document`.
- SwiftUI `FileDocument` does **not** auto-reload on external change, and there is **no**
  file-change observation anywhere in the app today (confirmed: zero matches for
  `NSFilePresenter`/`DispatchSource`/`FSEvents`/`presentedItemDidChange`).

**Decision:** implement `NSFilePresenter` on a **dedicated presenter object**
(`DocumentFileWatcher`) registered via `NSFileCoordinator.addFilePresenter(_:)`, keyed to
the current document's on-disk URL. This satisfies the source spec's intent (NSFilePresenter
reload) via the only mechanism the SwiftUI architecture allows. This is a deliberate,
documented deviation — not a shortcut.

**Why NSFilePresenter and not a `DispatchSource` vnode watch:** agents (and many editors)
save by atomic replace — write a temp file, then `rename` it over the target. A vnode
file-descriptor watch is bound to the original inode and goes **deaf** after the first
atomic replace. NSFilePresenter is path/coordination-based and keeps firing across atomic
replaces (and reports moves), which is exactly the agent-write pattern this feature exists
to serve.

## Behavior (from F3, made precise for this codebase)

On an external file change to the currently-open document's file:

1. **Clean document (no unsaved edits):** reload the text from disk, preserve scroll
   position by **proportional offset**, preserve the current display mode
   (Write/Read/Preview), and show a brief, quiet **"Updated"** indicator in the status bar
   (not a banner). Respect Reduce Motion — no animation is required.
2. **Dirty document (has unsaved edits):** do **nothing custom**. Leave the in-memory edits
   alone and defer to standard document behavior. **No merge logic.**
3. **Burst writes:** debounce reloads at **~300 ms trailing** so a rapid series of agent
   writes collapses into one reload.
4. **Applies to every open document.** No toggle. Each editor window watches its own file.
5. **Deleted / moved file:** do not crash and do not silently blank the editor. Keep the
   current in-memory text; defer to existing document handling. On a move, retarget the
   watcher to the new URL.

### The dirty gate is authoritative, and so is content comparison

- "Has unsaved edits" is read from the framework document:
  `window.windowController?.document?.isDocumentEdited`
  (`OutlineSidebarView.swift:1158` shows this bridge). **Not** `DocumentSaveStatus`, which
  is only a last-saved *timestamp* for the status bar.
- Even when clean, compare disk text to the current in-memory text and **skip the reload if
  they are equal.** This is what prevents the app's own autosave (which our presenter is
  also notified about) from causing a pointless reload/scroll churn. It also makes the
  reload idempotent.

### After a reload, keep the framework document consistent

After pushing new text in, update the framework `NSDocument` so it does not later raise its
own "file changed by another application" conflict on the next save:
`fileModificationDate = <new disk mod date>` and `updateChangeCount(.changeCleared)`, and
`DocumentSaveStatus.shared.markSaved(documentID:at:)`. This mirrors what the sidebar file
swap already does (`OutlineSidebarView.swift:1120-1131`).

## Where it attaches (seams)

| Concern | Attach point |
|---|---|
| Inject reloaded text | Set `document.text` (+ clear `plainTextConversion`) on the `@Binding`; it flows through `MarkdownTextViewRepresentable.updateNSView` (`:56-59`). Follows the `replaceDocumentFromSidebar` precedent (`EditorContainerView.swift:283-290`). |
| Current file URL | `activeWindow?.windowController?.document?.fileURL` (`EditorContainerView.swift:292-298` resolves `activeWindow` from `windowNumber`). Authoritative even after a sidebar swap, which sets `backingDocument.fileURL` (`OutlineSidebarView.swift:1120`). |
| Dirty gate | `window.windowController?.document?.isDocumentEdited`. |
| Preserve scroll | New proportional helper on `LineformTextView`, reusing the low-level `setBoundsOrigin` + `reflectScrolledClipView` primitives (`LineformTextView.swift:794-809`). No proportional helper exists yet. |
| "Updated" indicator | New optional transient prop on `EditorStatusBar` (`EditorStatusPresentation.swift:68-80`), driven by new `@State` in `EditorContainerView`, auto-cleared after ~2 s. |
| Reduce Motion | `EditorMotionPolicy.animation(_:reduceMotion:)` (`EditorPresentation.swift:215-216`); `reduceMotion` already in `EditorContainerView.swift:7`. |
| Registration trigger | `.onChange(of: windowNumber)` (when the window/document resolve) registers the watcher; re-register inside the sidebar-swap path; deregister on disappear. |

## Testable design (pure decision seam)

Follow the existing `EditorSearchResolver.refreshState` / `EditorStatusFormatter` pattern
(pure value types unit-tested without a window):

- **`DocumentReloadPolicy`** — pure. `decide(isDocumentEdited:, diskText:, currentText:)
  -> ReloadOutcome`, where `ReloadOutcome ∈ { .reload, .ignoreDirty, .ignoreUnchanged }`.
  Directly XCTestable, no window, no files.
- **Proportional scroll math** — a pure function `proportionalOffset(originY:,
  documentHeight:, viewportHeight:) -> CGFloat` (ratio in `0...1`) and its inverse, so the
  scroll-preservation arithmetic is tested independently of AppKit.
- **Debounce interval** — a named constant (`~0.3 s`) asserted by a test so the value is
  pinned.
- **Integration** — via the existing `makeEditorDrawerHarness()`
  (`EditorDisplayModeTests.swift:711`): mount a real editor, invoke the watcher's internal
  "disk changed → text X" entry point directly (bypassing the real presenter/filesystem),
  assert `document.text` updates on a clean doc, does **not** update on a dirty doc, and
  that scroll offset is approximately preserved.

## Non-goals

- No folder/project watching beyond open documents (whole-release non-goal).
- No merge/conflict UI. Dirty documents defer entirely to existing behavior.
- No watch toggle, no per-file setting.
- No change to autosave, to the sidebar file-swap flow's semantics, or to Writing Tools
  protection.
- No banner/alert/toast — status-bar text only. (Consequence: because the status bar is
  hidden in **Read** mode (`EditorStatusBar.isVisible == mode != .read`), the "Updated"
  text is not shown while in Read mode. The content still reloads; only the textual
  confirmation is absent there. This is acceptable and keeps Read mode calm — do not add a
  banner to work around it.)

## Verification

1. **Deterministic suite** (serial, per CLAUDE.md; quit Xcode first):
   ```sh
   xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
     -destination 'platform=macOS' -parallel-testing-enabled NO
   ```
   New unit tests for `DocumentReloadPolicy`, the proportional-scroll math, the debounce
   constant, and the harness integration must pass; the full existing suite stays green.
   Report exact pass/fail counts.
2. **Build** clean for Debug and Release configs (no dangling references).
3. **Manual smoke:**
   - Open a saved `.md`; from Terminal run `echo "new line" >> file.md`; the window updates
     within ~½ s and shows "Updated" (in Write/Preview mode). Scroll position is roughly
     preserved.
   - Simulate a burst: a loop writing several times in <300 ms produces a single reload.
   - Type an unsaved edit, then change the file on disk externally → the in-memory edit is
     **not** clobbered (dirty gate holds; standard behavior applies).
   - Rename/delete the open file externally → no crash, editor keeps its text.
   - Sidebar-swap to another file, then change *that* file on disk → the watcher followed
     the swap and reloads the new file.

## Risk / notes

- **Self-write feedback loop:** the presenter is notified of the app's own autosave. The
  disk-vs-memory text comparison (`.ignoreUnchanged`) is the guard; it must be in place or
  the app will reload-churn on its own saves.
- **Sandbox reads:** reads go through `NSFileCoordinator` on a URL the app already has
  user-granted access to (the doc is open). Reuse the security-scoped access pattern from
  `LineformDocument(contentsOf:)` (`:47-61`) for the disk read.
- **`EditorDisplayModeTests` is load-sensitive** (CLAUDE.md harness-fragility note). The new
  integration test must not add flakiness; keep it to a direct entry-point call, not a real
  timed filesystem event. Quit Xcode before the full run.
- **Scroll on whole-text replacement:** the existing `VisualLayoutAnchor` machinery is
  character-range-based and is wrong for wholesale replacement (ranges shift). Use the new
  ratio-based helper instead; restore after layout settles (async), matching the existing
  deferred-restore idiom (`LineformTextView.swift:854-904`).
