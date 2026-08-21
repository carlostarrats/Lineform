# Post-release health & security review — 2026-07-06

> **HISTORICAL REVIEW RECORD.** Findings and scope reflect the codebase on the date above. Use
> `AGENTS.md` and `docs/architecture/` for current behavior and invariants.

Scope: everything merged since `v1.1.1` (96 commits; ~33 source files, ~4,300 new lines —
Tasks 1–8: keystroke debounce, save-state status bar, read-mode rendering waves 1–3,
PDF/print export, find & replace, scoped syntax highlighting, settings modal, files-sidebar
file management). Reviewed on branch `work-2026-07-05-3` via five parallel subsystem passes
(editor, preview/rendering, files sidebar, app/settings/documents, security/entitlements).

Default test plan green after the fixes below: **507 tests, 0 failures**.

## Fixed

1. **PDF export: wide tables could still overflow the page** —
   `MarkdownPreviewRenderer.fitColumnPercentages`. The per-column floor was applied as
   `max(floor, share)` *after* proportional shares were computed against the full budget, so
   several narrow columns beside one wide column summed past the 88% budget (and past 100%),
   clipping the table off the right margin — the exact failure the fit path exists to prevent.
   Now reserves the floor for every column first, then splits the remaining budget
   proportionally, so the total is exactly the budget. Regression test:
   `testFitColumnPercentagesStayUnderBudgetWithManyNarrowColumns`.

2. **Sidebar rename accepted `.` / `..`** — `SidebarFileRenaming.validatedDestination`. The
   validator blocked `/` and `:` but not the reserved relative components. For a folder rename
   (no extension appended) `..` resolved the destination to the parent directory — a move
   disguised as a rename that the file system rejects with a confusing raw error. Now rejected
   up front. Sandbox-confined and it already failed safely (EINVAL), so this is UX + hardening,
   not a security hole. Regression test: `testValidatedDestinationRejectsDotAndDotDot`.

3. **Two `ensureLayout(for:)` sites left unwrapped by the 2026-07-05 re-entrancy crash fix** —
   `LineformTextView.rectsForCharacterRange` and `laidOutContentHeight`. The stack-overflow fix
   wrapped only two of the four whole-container `ensureLayout` sites in
   `runLayoutSensitiveEnsureLayout`. These two (reached from search-highlight drawing and the
   live-reload scroll-restore path) now use the same guard, closing the inconsistency. Hardening
   against a crash class that actually shipped; no confirmed overflow at HEAD, but cheap and
   consistent with the established pattern.

## Reviewed and deliberately left as-is (documented tradeoffs / too narrow to justify risk)

- **Cross-window "Saved" vs "Autosaved" classification** (`DocumentSaveStatus.pendingManualSave`
  is a process-global one-shot flag). A ⌘S in a clean window that produces no write can leave the
  flag set for another window's next autosave to consume, flashing "Saved" instead of "Autosaved."
  Purely cosmetic (wrong status *word*), requires two windows + specific timing. The one-shot flag
  is a deliberate, documented design; a correct fix needs per-document-ID intent plumbing through
  the app-global NSEvent monitor, whose risk outweighs a cosmetic edge. Left.

- **Search highlights lag body edits by ~0.2s** while typing (the yellow rectangles paint at
  pre-edit offsets until the derived-refresh debounce re-resolves). This is the deliberate Task 1
  keystroke-debounce tradeoff; ranges are clamped so there is no crash, and it self-corrects. Left.

- **Checkbox toggle stale range in Split mode** — within the 120 ms preview debounce, a click can
  in principle land on the wrong checkbox after an offset-shifting edit. `CheckboxToggle.toggledText`
  already re-verifies the 3 target chars so a stale range is a safe no-op, never a corrupting write;
  Read mode is immune. Very narrow race; left.

## Confirmed clean

- **Security:** no new network egress (only in-process `NotificationCenter` posts); no new
  entitlements beyond the expected `com.apple.security.print` in both entitlement files; iCloud
  entitlement still Release-only; no telemetry, no content/path logging; all new Markdown regexes
  are linear-time (negated classes, `\n`-excluded, digit runs capped) — ReDoS-safe; delete stays
  trash-only.
- **FSEvents / security scope:** `DirectoryEventMonitor` ownership is balanced (no stream leak,
  no use-after-free, callbacks on main); workspace security scope held for the store's lifetime
  (no transient start/stop regression); the iCloud-laziness invariant holds (no ubiquity scan at
  init/construction).
- **Documents:** load/reload use `markSaved` (never flash "Saved"); only real writes `recordWrite`;
  `DocumentReloadController.noteMoved` preserves the reload baseline; PDF-export deletion of the old
  `pdfData()` path is fully dereferenced.
- **Settings store:** `Published(initialValue:)` backing-storage init (no spurious didSet writes);
  tri-state collapse choice persists/`removeObject`s correctly; iCloud probe runs off-main only from
  the modal.
- **EditorSearchResolver** replace/replace-all/next-index logic (self-containing replacement,
  wrap path) verified correct; `MarkdownRangeAnalyzer` confirmed strictly line-local (scoped-highlight
  byte-identical invariant holds).
