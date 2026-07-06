# Audit Decisions — running do-list

Companion to `2026-07-03-perf-and-feature-audit.md`. Records which audit items we
decided to act on, in plain language, as we reviewed them together on 2026-07-04.
Citations in the audit were re-verified against branch `work-2026-07-04-5` before
these decisions (line numbers drifted from the original `e698bdc`, behaviors held).

Two corrections to the original audit found during re-verification:
- **Task 7:** PDF export already EXISTS (plain-text based, via `LineformDocument.pdfData()`).
  The real gap is Print/⌘P and rich-output export, not "no PDF export."
- **Task 4:** the O(n²) blank-line scan is short-circuited on the actual preview
  render path — it does not fire there. It's a cleanup, not a hot fix.

---

## ▶️ HOW TO EXECUTE — handoff guide (read this first)

**Workflow:** ONE task per FRESH chat (keeps each session small, focused, cheap). Never
hand a session more than one task. For each task:
1. Open a new Claude Code chat.
2. Paste the STARTER PROMPT below, filling in the ONE task name.
3. If the task is marked **spec-first**, the session writes a design spec and STOPS for
   sign-off before any code.
4. Implement on its own branch (Task 5 specifically: its own git worktree).
5. QA together in that chat.
6. **Mark the task DONE in the PROGRESS TRACKER below** (check the box; add date + branch/
   commit). This is how the NEXT fresh chat knows what's finished and what's next.
7. STOP. Start a new fresh chat for the next task.

**STARTER PROMPT (paste into the fresh chat, fill in [TASK]):**
> Read `CLAUDE.md` (repo root) and `docs/audits/2026-07-04-audit-decisions.md` in full,
> then do ONLY this one task: **[TASK]**. Follow the decisions recorded for it in that doc
> exactly, plus the global rules in both files.
> - If it's marked spec-first: write a design spec (see `docs/superpowers/specs/` for
>   precedent) and get my sign-off BEFORE writing any code. Do not start coding.
> - If it's a perf task: reproduce the symptom on a large test doc FIRST, then fix, then
>   confirm on the same doc.
> - Work on its own branch. When done, run the full serial test suite (Xcode quit; warn me
>   about the TCC Documents prompt) and report EXACT pass/fail counts, what you manually
>   QA'd, and what you did NOT exercise.
> - After I confirm QA passes, mark this task DONE in the PROGRESS TRACKER in that doc
>   (check its box; add today's date + the branch/commit). Then stop for my review — start
>   no other task.

**Global rules every session must honor** (also in CLAUDE.md): full suite runs serially
with Xcode quit (TCC prompt near the end — warn, never run unattended); don't weaken hosted
motion tests; preserve the iCloud laziness invariant; never revert the sidebar's held
security scope; keep UI native/restrained; no analytics, no uploads, no AI inside.

**RECOMMENDED ORDER (each = its own fresh chat):**
1. **Task 1** — keystroke debounce. [do-now; smallest, biggest felt win]
2. **Task 3a + resize nit + Task 3b diagram backgrounds** — all touch diagram/render code; can be
   one branch or split. [do-now] (Shipped: the fixed-card idea was iterated away during QA — see
   the tracker entry below for the final transparent/per-theme design.)
3. **Task 6 — SPEC first** (whole Read-mode rendering feature: all approved constructs +
   cross-cutting rules + the design decisions below). Get sign-off. THEN implement in waves,
   each wave its own fresh chat + QA:
   - Wave 1: easy styling — strikethrough, horizontal rule, blockquote, lists, + image
     placeholder.
   - Wave 2: interactive checkboxes.
   - Wave 3: tables (self-scrolling panel).
   - (fold **Task 4** double-split cleanup in while inside the renderer.)
4. **Task 7 — SPEC then build**: rich PDF export + Print/⌘P. AFTER Task 6 (reuses its
   rendering; images-in-PDF depends on it — but images are deferred, so PDF ships without
   them for now).
5. **Task 8 — spec-light then build**: Find & Replace (single-file). Independent — may slot
   any time after the do-now tier.
6. **Task 2** — ONLY if typing still stutters in large docs after Task 1 ships (measure
   first; may prove unnecessary).
7. **Task 5 — LAST.** Everything else committed AND merged first; fresh git worktree; SPEC
   the fix shape (weigh the cheaper options, not just "background thread") before any code.

## ✔️ PROGRESS TRACKER (each session checks its box after QA)

Order = top to bottom. A fresh session: find the first UNCHECKED box, that's the next task.
When done + QA'd, check it and append `— done YYYY-MM-DD, branch <name>`.

- [x] 1. Task 1 — keystroke debounce  — done 2026-07-04, branch `work-2026-07-04-7-keystroke-debounce` (commit 9128c41), suite 386/0, reviewed + fixed (reload/convert recompute-now). ✅ REVISION NOTE RESOLVED 2026-07-05: big-doc typing is now smooth (user-confirmed) after Task 2 + the caret-trail root-cause fix recorded under Task 2's entry (the per-keystroke whole-doc string compare in `updateNSView`, ~50 ms/key — plus the highlight debounce raised 0.08 s → 0.25 s, which is exactly the "revisit the debounce interval" this note anticipated).
- [x] 2. Task 3a + resize nit + Task 3b diagram backgrounds (diagram/render bundle) — done 2026-07-04, branch `work-2026-07-04-8`, suite 406/0, **QA'd in-app with the user (confirmed good, incl. dark)**. Final design (the "fixed card" from Task 3b was iterated away during QA — a card looked like a box on the themes it couldn't match; see below):
  - **Task 3b (diagrams/math backgrounds):** block **math** renders **transparent** (glyphs need no canvas) with a fixed light/dark ink (`DiagramPalette.ink`) → matches every theme, never re-renders on theme switch. Block **Mermaid**: **light** themes transparent (fixed ink draws crisp borders on the light page, no re-render among light); **dark** themes set the canvas to the theme's OWN page color so it still reads as no box (matches the page) but the node boxes get a visible fill — a transparent canvas CAN'T darken just the node boxes because Mermaid derives the node fill from the canvas (verified empirically). Dark Mermaid is thus per-theme (re-renders switching between the two dark themes), kept cheap by Task 3a's memory cache. Inline math unchanged (theme-aware).
  - **Task 3a:** both caches memory-sized (`NSCache.totalCostLimit` via `RasterImageCost`; `DiagramCacheBudget`/`MathCacheBudget`).
  - **Resize nit:** wide block diagrams/equations refit to the window on resize (`BlockAttachmentRefit`, scaling the cached raster with no re-render; runs on `setFrameSize`/`viewDidEndLiveResize`, deferred a tick during a live drag; only `BlockRenderedAttachment` block content is refit so inline math's baseline is untouched).
  - Colors live in `DiagramPalette` (`Lineform/Preview/DiagramCardStyle.swift`).
- [x] 3. Task 6 — SPEC (Read-mode rendering; sign-off before code) — done 2026-07-04, branch `work-2026-07-04-9` (commit cb06f71). Umbrella spec `docs/superpowers/specs/2026-07-04-read-mode-rendering-design.md`: block-grouping renderer layer + per-construct decisions + waves. (Sign-off was waived — user directed "write the spec, write the plan, action it and review" without stopping.)
- [x] 4. Task 6 Wave 1 — easy styling (strikethrough, HR, blockquote, lists) + image placeholder — done 2026-07-04, branch `work-2026-07-04-9`, suite **441/0**. Plan `docs/superpowers/plans/2026-07-04-read-mode-rendering-wave1.md`. Shipped:
  - **Block-grouping layer** (`MarkdownBlockGrouping.swift`): single pass → typed blocks; `MarkdownPreviewRenderer` renders block-by-block, reusing the existing per-line emission unchanged (**byte-identical** for headings/code/mermaid/math — verified line-by-line in review). **This folded in Task 4** (single split + `markdownBlockSpacingLineIndexes(inLines:)`).
  - **Strikethrough** `~~x~~` (inline token) + Format ▸ Strikethrough **⌘⇧X** + Info row.
  - **Horizontal rule** `---`/`***`/`___` → `HorizontalRuleAttachment` (self-sizing cell); front-matter + setext (incl. after list/quote) guards. Info row.
  - **Blockquote** `>` (nested `>>`) → indent + de-emphasis, markers hidden + Format ▸ Blockquote + Info row.
  - **Lists** bulleted (•) + numbered (renumbered, nested) with hanging indent + Format ▸ Numbered List **⌘⇧7** + Info row.
  - **Image placeholder** `![alt](url)` → 🖼 + alt, **file-free + network-free**, no stray `!`/URL. Info row.
  - Reviewed (2 parallel reviewers) + fixes applied (HR-after-list/quote; dedup baseAttributes).
  - ⚠️ **Residual risk / NOT yet exercised by me:** on-screen visual QA (build-only + 441 unit tests, no app run). Two items need your eyes: (1) the blockquote **left vertical bar is deferred** — it currently ships as indent + de-emphasis only (the drawn bar needs on-screen positioning); (2) HR thickness/spacing, list indent metrics, and blockquote dim were tuned blind. Please QA in Read/Split across a light + a dark theme.
- [x] 5. Task 6 Wave 2 — interactive checkboxes — done 2026-07-04, branch `work-2026-07-04-9`, suite **453/0**, **QA'd in-app with the user** (click toggles, persists to source, **⌘Z reverts**, scroll steady, no false toggles). Plan `docs/superpowers/plans/2026-07-04-read-mode-rendering-wave2.md`. Shipped: `- [ ]`/`- [x]` render a **☐/☑ Unicode glyph** (kept as raw text — selectable/copyable — over an SF-Symbol image, since a checkbox needn't be an image); clicking the glyph mutates `document.text` (`CheckboxToggle.toggledText`, verifies the 3 chars so a stale range is a no-op) → dirty/autosave/**undo all ride the normal binding** (auto-undo confirmed working; no manual registration needed). Source range computed absolutely via `lineStartOffsets`; hit-test is glyph-rect-only. GFM-correct (whitespace required after `]`). Info rows added.
- [x] 6. Task 6 Wave 3 — tables + Task 4 verify — done 2026-07-04, branch `work-2026-07-04-9`, suite **469/0**, **QA'd in-app with the user**. Plan `docs/superpowers/plans/2026-07-04-read-mode-rendering-wave2.md` covers the wave shape; tables landed as **native `NSTextTable`**, NOT the embedded self-scrolling panel (decision reversed during the wave — see below). Shipped:
  - **Native GFM tables** (`MarkdownTableParser` + `MarkdownPreviewRenderer.appendTable`): live selectable text, per-column alignment from the delimiter colons, distinguished header, quiet theme-derived gridlines; lays out responsively to the reading column and wraps cell text. Detection gated on GFM's header==delimiter column count (so a pipe line over a bare `---` stays a setext heading). Reviewed — that column-count bug was caught + fixed.
  - **Relative table text size:** cells render at **90%** of the reading font (`tableTextScale`) — denser per table convention, still scales with the user's size (accessibility preserved), eases the too-wide case. (Deliberate, gentle departure from the audit's "inherit exactly" note; user-approved.)
  - **Task 4** (double-split): already folded into Wave 1's block layer; **confirmed** still holds (no separate trip).
  - **Side task — "Full" Column Width:** the reading Column Width slider now extends to a **Full** stop (fills to the 40px margins on any window size) — a general widen-the-column pressure valve for wide tables. Applies to Write/Read/Split.
  - **⚠️ DEFERRED BY DECISION — self-scrolling table panel:** the audit's original pick. Native tables were chosen instead (live text/selection/copy, PDF-ready, low-risk) after weighing the TextKit-1 embedded-view cost. The trade-off is real and confirmed in QA: a **genuinely-too-wide table (e.g. 12 columns) shatters** (columns collapse to mid-word character breaks) rather than side-scrolling; **Full width + 90% text mitigate but do not solve it.** If wide tables become a real need, build the embedded self-scroll panel (spec the shape first — see the design spec's Tables section for the rejected/deferred reasoning).
- [x] 7. Task 7 — SPEC (rich PDF + Print; sign-off before code) — done 2026-07-04, branch `work-2026-07-04-10`. Spec `docs/superpowers/specs/2026-07-04-pdf-export-print-design.md` + plan `docs/superpowers/plans/2026-07-04-pdf-export-print.md`. (Sign-off waived — user directed "spec it, plan it, action it, review" in one pass, as with Task 6.)
- [x] 8. Task 7 — build (PDF export + Print/⌘P) — done 2026-07-04, branch `work-2026-07-04-10`, suite **476/0** (default) + hosted export **3/3**, **QA'd in-app with the user** (print works, export rich + white, tables & wide diagrams shrink-to-fit, math upright). Reviewed (subagent, clean — math-orientation shared change empirically verified no Retina/flip regression). Shipped:
  - **`DocumentExportRenderer`** (`Lineform/Preview/`): reuses the Read-mode `MarkdownPreviewRenderer` to build an offscreen TextKit-1 `NSTextView`, hosted in a borderless offscreen `NSWindow`, driven by `NSPrintOperation` for both **Print** and **PDF-to-file** (`.save` job). One path, two consumers.
  - **Print… (⌘P)** + **Export as PDF…** as `CommandGroup(replacing: .printItem)`, posting window-scoped notifications handled in `EditorContainerView` (established pattern). Export uses an `NSSavePanel` with a **paper-size accessory popup**.
  - **Sandbox `com.apple.security.print`** added to BOTH entitlements (Debug + Release) — without it a sandboxed app gets "This application does not support printing." (It's a plain boolean sandbox entitlement, satisfiable under ad-hoc signing, so Debug/CI still launch.)
  - **Fixed 12pt document body** (`bodyPointSize`), NOT the on-screen reading size — a PDF is a saved/shared artifact and reads like a normal document (user decision: "treat it as a fixed thing"). Font **face** + rhythm inherited; white page forced via an export profile pinned to the static `.system` theme (no renderer theme change).
  - **White page** painted by an `ExportTextView` subclass (NSTextView's `backgroundColor` isn't carried into the print context). Content area white; the 1" margins stay transparent (renders white in normal viewers; full-bleed white would need zero-margin pagination).
  - **Everything exports:** headings, inline styling, lists, blockquotes, tables, inline + block math, mermaid, fenced code. Image files stay the `🖼` placeholder (Task 6 deferral).
  - **Block math was upside-down** in the PDF (print-context flip) → fixed by `MathImageOrientation.cgImageBacked` (SHARED with on-screen; verified no regression).
  - **Tables shrink-to-fit** the page (export-only `fitTablesToWidth` → proportional percentage columns) so they don't run off the right edge; **wide mermaid diagrams** already cap at the content width. This realizes the audit's "PDF shrink-to-fit-the-page is acceptable" rule.
  - **Paper sizes:** US Letter / US Legal / Tabloid + A4 / A3 / A5.
  - The PDF-byte tests (invoke `NSPrintOperation`) live in the **hosted plan** (`DocumentExportPDFHostedTests`) — the print subsystem's cold start is environment-sensitive; pure logic + a print-free view test stay in the default plan.
  - Removed the old plain-text `pdfData()` / `.pdf` writable type (superseded).
  - ⚠️ Residual: interactive Print pre-builds for the default paper, so a mid-print paper-size change may slightly scale rasterized diagrams (prose/tables reflow fine); very wide tables on small paper (A5) can still overflow rather than side-scroll (documented tradeoff).
- [x] 9. Task 8 — Find & Replace (single-file; spec-light) — done 2026-07-05, branch `work-2026-07-04-11`, suite **493/0** (default), **QA'd in-app with the user** (final floating-panel design approved incl. the dark Quiet/Night card variant). Spec `docs/superpowers/specs/2026-07-04-find-and-replace-design.md`. Reviewed (3 parallel reviewers + verify passes); 3 correctness bugs found & fixed (single-Replace cascade when the replacement contains the query; a re-entrant-render double-undo race; a stale-range overwrite under the search debounce), each now covered by tests. Shipped:
  - **Additive to search:** find term stays in the native `.searchable` toolbar field; a compact **floating card** (replace field + **Replace** / **Replace All** + quiet "N found" hint + close) overlays the top-trailing corner of the page in Write/Split via **Edit ▸ Find & Replace… (⌥⌘F)**. Read auto-switches to Write. No second find field, no case toggle, no regex, no cross-file (single open file only).
  - **⚠️ UI lesson (cost several QA rounds):** the original top-of-shell BAR design recolored the window navigation on open — the translucent unified toolbar samples the content directly beneath it, so any full-width top strip (any background, even transparent) changes the header. Fixed structurally: the panel is an **overlay** in the shell ZStack (top-edge hierarchy identical open/closed → header provably unchanged). Two fixed card variants keyed on `usesDarkChrome` (light card / dark card for Quiet+Night, user-requested). Do not convert it back to a layout row.
  - **Matching reuses `EditorSearchResolver.matches`** → identical to search (case- + diacritic-insensitive), so "replace matches how search matches" is automatic, not re-implemented.
  - **Pure logic in `EditorSearchResolver`:** `replaceAll` (back-to-front rewrite, no self-cascade), `replaceMatch`, `nextActiveIndexAfterReplacement` (Replace-&-find-next; anchored past the insertion, skips matches inside the insertion forward AND on wrap).
  - **Single ⌘Z:** edit routed through a one-shot `requestedReplacement` binding → `LineformTextView.applyExternalReplacement` → the formatting-commands' `applyWholeTextReplacement` path (one undo step; syncs `document.text`). Idempotency guard (`guard string != edit.text`) prevents a re-entrant-render double-apply.
  - **No Info-modal entry** (deliberate — that modal teaches Markdown *syntax*, not editor commands; don't add just to add). CLAUDE.md Main-Features bullet added.
- [x] 10. Task 2 — scope syntax highlighting — done 2026-07-05, branch `work-2026-07-05-2-scope-highlighting`, suite **503/0** (default), reviewed (subagent, clean verdict + 3 minor fixes applied), **in-app visual QA done (highlighting renders correctly on a 281 KB / 47.6k-word doc, no regression)**. ⚠️ **Felt-smoothness + scroll-coloring QA still needs your hands** (I can't type via automation — the app is left open on the large test doc for you). Spec `docs/superpowers/specs/2026-07-05-scoped-syntax-highlighting-design.md`, plan `docs/superpowers/plans/2026-07-05-scoped-syntax-highlighting.md`. Shipped:
  - **Split `MarkdownSyntaxHighlighter.highlight` into two passes:** a whole-document **base pass** (`setAttributes(base, fullRange)` — uniform font/paragraph-style/kern/color → stable layout everywhere) and a **scoped token pass** (`refreshTokens(scope:)` — resets only the visible window to base + re-tokenizes it). The ~121 ms whole-doc re-tokenize is off the per-keystroke path: typing and a new coalesced **scroll-settle** handler only re-tokenize the visible window (+3000-char margin, line-snapped). Off-screen keeps correct base (layout) and its token colors fill in on scroll.
  - **Refined the audit's plan from the code:** the range analyzer is **line-local** (no cross-line token state), so a line-snapped window is **byte-identical** to a whole-doc pass — the audit's "load-bearing fenced-block state scan" is **unnecessary** and was NOT added. (Its premise — that fence contents are suppressed — is false; a `#` inside a ``` fence is highlighted as a heading today, unchanged.) The one non-line-local edge (the link regex could match across lines) was **tightened to exclude newlines** so the invariant is airtight.
  - **No enclosing scroll view → whole-document fallback**, so all existing highlighter tests (and any bare `LineformTextView`) stay byte-identical.
  - **Review fixes:** skip the scroll pass during IME/marked-text composition; rebind the scroll-bounds observer on reparent (remove-then-add, not a one-shot latch); line-local link regex.
  - **NOT scoped:** the initial open/mode-switch highlight is still whole-doc (one-time, matches old behavior — the felt problem was typing, not open). A crash-looping hosted NSWindow scroll test was **removed** (the exact hosted-window over-release the project quarantines); scroll geometry is covered by in-app QA, the scoping mechanism by pure default-plan tests.
  - **RESOLVED — caret trail root cause found & fixed (same day, after 2f40bba; user-confirmed "so much better"):** in-app CSV timing while the user typed (os_signpost proved unreadable from the sandboxed app via `log show`; a container-tmp CSV worked) + a **TextEdit control test** (same file, no lag → the cost was ours) pinned it: `updateNSView`'s `textView.string != text` guard walked the whole 280K-char doc (~11.4 ms p50; bridged-UTF-16 vs native storage misses the memcmp fast path) and ran 4-5× per keystroke ≈ **~50 ms main-thread stall per key**. (The 2026-07-04 audit had measured the bridge *assignment* ~0 ms — correct — but the *compare* was never on trial.) Fix: the coordinator records the exact String value last synced with the binding (`lastSyncedText`); the guard compares against that first (identical storage → ~0 ms) and only genuine external replacements (reload, sidebar swap, Read-mode checkbox toggle) pay the deep compare — measured 11.45 ms → 0.051 ms p50. Bonus: a mid-Writing-Tools body pass can no longer spuriously resync/clobber the session. Second fix: typing-pause highlight debounce **0.08 s → 0.25 s** — fast typing has 80-120 ms inter-key gaps, so the old delay fired BETWEEN keystrokes mid-burst, forcing a full-viewport repaint each time (180 passes/297 keys → 40/410). **This RESOLVES the Task 1 "MAY STILL NEED REVISION" note and the residual below** — the felt stutter is gone in-app on the 281 KB doc. All temp instrumentation removed; suite **505/0**.
  - **Follow-up same day (commit 2f40bba), from user QA + a crash report:** user confirmed scroll-in coloring is instant with no visible gaps, but a *very slight* caret trail remained during fast typing (caret briefly falls behind the typed character, full page only, blank doc fine). Measurement (not guessing) found the cause was NOT the SwiftUI whole-string bridge (~0 ms) and NOT the highlighter (debounced off the burst path) — it was **two forced full-viewport repaints on every keystroke** (`refreshReadingAssists` + `updateNSView → setSearchHighlights`, both `needsDisplay = true` unconditionally). Now gated: plain typing (no search highlights, no reading ruler, non-empty doc) forces no repaint. Chasing this ALSO surfaced (via my diagnostic test crashing the test host 3×; user supplied the .ips) a **pre-existing latent stack-overflow crash**: `setFrameSize` re-entering whole-container `ensureLayout` while AppKit's typesetter is mid-layout recurses once per remaining line fragment on a large un-laid-out doc (SIGSEGV at ~2,100 frames; reachable in principle by resizing a window on a large doc). Fixed with a re-entrancy guard (`isRunningLayoutSensitiveEnsureLayout` — typesetter-driven resizes take a plain `super.setFrameSize`); exact-repro regression test `LargeDocumentLayoutReentrancyTests`. Suite **504/0** after both. (These two alone did NOT resolve the caret feel — the actual root cause is the string-compare fix in the RESOLVED bullet above.)
- [x] 11. Task 5 — sidebar scan — done 2026-07-05, branch `worktree-task5-sidebar-scan` (fresh worktree, off `origin/main` = `ac5a039`, all prior work merged). Suite **510/0** (full default plan), reviewed (adversarial subagents on each stage — clean, no blocking; nits applied). **FELT-CONFIRMED by the user on the 4,321-file test workspace, folders fully expanded ("performs fine … works well").** Spec `docs/superpowers/specs/2026-07-05-sidebar-scan-debounce-design.md` (see its two UPDATE sections for the full journey), plan `docs/superpowers/plans/2026-07-05-sidebar-scan-debounce.md`.
  **⚠️ ROOT CAUSE WAS NOT THE SCAN.** The audit framed this as "the file-list scan freezes the app on big folders," so the first two fixes targeted the scan — and BOTH, though correct, failed the user's felt test:
  - **Fix 1 (debounce, Option 2)** — trailing-debounce the FSEvents-driven rescan. Shipped, tested, felt-tested → *still slow*.
  - **Fix 2 (off-main, Option 1)** — run the recursive `items(in:)` walk on a background queue, publish on main (generation-guarded, `nonisolated(unsafe)` at the one boundary). Shipped, tested, reviewed clean, felt-tested → *no change*.
  - **Then: measured instead of guessing.** A `sample` profile of the LIVE app during interaction showed **71% of main-thread time in SwiftUI view layout** (`NSHostingView.layout` → `ViewGraphRootValueUpdater.render` → `AG::Subgraph::update`), zero editor-text frames; a live user A/B (collapse folders → instantly fast) confirmed it. The real cost was **rendering the file tree**, not scanning it.
  - **Fix 3 (the real one) — virtualize the tree.** The sidebar rendered the tree with recursive **NON-lazy `VStack`s** and folders **default to expanded**, so a big workspace laid out ~3,840 rows at once and re-laid-them-all-out on every file switch (`currentFileURL` → every row re-checks `isSelected`) or store republish. Now `OutlineSidebarView.visibleFileRows(_:collapsedIDs:)` flattens the visible rows (depth-first, children only when expanded) into `[OutlineFileTreeFlatRow]`, rendered in a **`LazyVStack`** → only viewport rows lay out. `OutlineFileTreeNodeView` is a single flat row (recursion removed; keeps indentation/collapse/selection/hover/context-menu/accessibility). Pure `visibleFileRows` unit-tested. **This is what fixed the felt problem.**

  The scan work (debounce + off-main) is **retained** as correct hygiene (a 35ms main-thread scan on a typing pause / file switch is still worth avoiding), but it was never the felt bottleneck. Details of that scan work below (accurate, just not the fix):
  - **Root cause (traced in code, not guessed):** `DirectoryEventMonitor` delivers coalesced FSEvents callbacks **on the main queue** (`coalescingLatency` 0.5s); each callback ran the **synchronous recursive `items(in:)` directory walk on the main thread**. Own-process events are deliberately not filtered, so autosave-while-typing → FSEvents → a full main-thread tree walk ~every 0.5s = the large-workspace typing hitch.
  - **Fix:** the two FSEvents `onChange` closures in `beginWatchingForExternalChanges()` now route through `scheduleWorkspaceRescan`/`scheduleICloudRescan` — a **trailing debounce** (`DispatchWorkItem` + `asyncAfter`, cancel-before-reschedule, `guard interval > 0 else { runNow() }` fast-path) **mirroring `DocumentReloadController` exactly**. Continuous typing churn keeps resetting the timer, so the walk defers to a single **settle-after-pause** — the exact model blessed for Task 1. Interval `directoryRescanDebounceInterval = 0.75s`, **injectable** (tests pass 0), with a comment that it **MUST exceed** `DirectoryEventMonitor.coalescingLatency` (0.5s) so continuous churn never fires a mid-typing rescan.
  - **Surgical scope:** ONLY the monitor path is debounced. Every user-initiated / correctness-critical refresh stays instant — init, Files-tab appear (`refreshICloud`/`refreshWorkspace`), sort change, hidden-folders toggle, `setWorkspaceURL`, and the `refreshRoots(affecting:)` rename/delete broadcast. Pending work is cancelled in `endWatchingForExternalChanges()`, `deinit`, and `setWorkspaceURL` (the applied nit). `items(in:)`, the publish-only-on-change guard, iCloud resolution, snapshot save, `ensureDownloaded`, and `DirectoryEventMonitor.swift` are **untouched**. No flush-on-save needed (unlike Task 1) — the sidebar tree feeds no save/undo/document state, so a dropped pending rescan can never lose work; worst case is the tree ≤ one interval stale, corrected by the next event/tab-appear.
  - **Invariants preserved (incident-prone area):** held workspace security scope stays **lifetime-held** (no transient start/stop — the 1.1.1 bug shape avoided); iCloud-laziness invariant intact (debounce wraps only the post-first-scan monitor path; init still defers iCloud).
  - **Tests (pure default plan):** 2 existing monitor tests pinned to `directoryRescanDebounce: 0` (fast-path preserves old synchronous behavior); 2 new — `testWatcherDebouncesMonitorDrivenRescans` (deferral: no synchronous rescan; eventual correctness via `waitUntil` poll) and `testEndWatchingCancelsPendingDebouncedRescan` (cancellation). TDD: RED watched (both new tests failed for the right reason — synchronous rescan), then GREEN.
  - **Off-main (Fix 2) as-built:** injected `runsScanInBackground` (default false = synchronous, so the test suite is byte-identical and concurrency is opt-in at the one production site); `performScan` runs `items(in:)` on `scanQueue` and applies on main via a `nonisolated(unsafe)` boundary (verified: the scan touches no `self`, and apply runs only on main — with `Thread.isMainThread` asserts as fail-loud guards); per-root generation counters drop stale publishes; the held security scope (process-wide) covers the background read; a cached-snapshot seed prevents a first-frame "Choose folder" flash. Reviewed adversarially — no data-race/file-access defect.
  - **Not done:** Option 3 incremental scope-splice, Option 4 cap micro-opt — unnecessary (rendering, not scan cost, was the problem).
  - ✅ **Full default plan 510/0** (includes the 2 repo-file-reading meta classes `ReleaseResourceTests` + `TestPlanGuardTests`, which need a one-time TCC Documents **Allow** to run — unrelated to this change).
  - ✅ **Felt-smoothness CONFIRMED by the user** on the 4,321-file workspace with folders fully expanded — the case that was previously unusable now performs fine. (The lesson: **measure the live app before fixing a felt perf problem** — two scan-targeted fixes missed because the cost was in SwiftUI layout, found only by profiling.)

Everything below is the plain-language decision record, grouped by status.

---

## ✅ DO — approved

### Task 1 — Stop re-doing work on every keystroke
**Plain terms:** Today, every keystroke recounts words/characters, rebuilds the
heading outline, and re-runs search over the whole document. On big files this
makes typing feel sticky. Fix: wait for a brief typing pause (~1/5 second), then do
those three chores once — the same trick the syntax highlighting already uses.

**Gain:** Smooth typing in large documents; word count / outline update a heartbeat
after you stop instead of fighting you while you type.

**Risk:** Very low. Must ensure count/outline/search are correct at save and at a
mode switch (flush the pause then).

**Must stay instant (do NOT delay):** the "unsaved changes" flag and the
external-reload text tracking — cheap and must be accurate immediately.

**Undo:** Not affected. Task 1 never changes text, so Cmd-Z is untouched.

### Task 3a — Give the diagram/equation cache a bigger shelf
**Plain terms:** Diagrams (Mermaid) and equations are drawn as little pictures and
stashed for reuse. The stash caps at 50 diagrams / 100 equations, so a diagram-heavy
document constantly throws pictures away and re-draws them. Fix: make the shelf big
enough to hold a realistic document, ideally sized by memory used rather than a flat
count (a giant flowchart shouldn't count the same as a tiny equation).

**Gain:** Diagram/equation-heavy docs stop re-drawing the same pictures; snappier
scrolling/re-render on those docs. Invisible to docs without many diagrams.

**Risk:** Very low — essentially "raise a number." Bigger stash uses a bit more RAM,
kept in check by sizing on memory instead of count.

**Does NOT fix (by itself):** the theme-switch freeze — but see the Task 3b decision
below, which RETIRES that problem by design.

### Resize nit — Wide diagrams refit when you narrow the window
**Plain terms:** Drag the window narrower and a wide diagram overflows/clips instead of
shrinking, until you touch the document. The resize deliberately skips a redraw (keeps
resizing cheap), and a diagram's fitted width is only recalculated during a redraw.
Fix: on resize *end*, re-fit the diagram to the new width (no re-draw needed — the
picture scales; only the width number is stale).

**Gain:** Wide diagrams stay fitted while resizing instead of overflowing/clipping.
Small but visible glitch gone.

**Risk:** Low. Must trigger on resize END, not every drag tick, or it reintroduces the
churn the skip-redraw was added to avoid.

**Bundle with:** Task 3a (both touch diagram code). Cosmetic only.

---

## 📝 FEATURES — approved, spec-first

### Task 6 — Render more Markdown in Read mode (APPROVED, highest product value)
**Plain terms:** Read mode only formats headings, code, diagrams, math, and inline
bold/italic/code/link. These currently show as raw symbols and should render:
tables, images, lists, blockquotes, task checkboxes, horizontal rules, strikethrough.
Fixing this makes Read mode deliver on the "readable long-form text" promise — the most
user-visible improvement in the audit.

**Read mode KEEPS its themes** (sepia/dark/etc.) — do NOT force white/black there. The
white/black requirement is for PDF export only (see Task 7).

**Staging (waves):**
1. Easy wave first — lists, blockquotes, horizontal rules, task checkboxes,
   strikethrough (pure text styling, low risk, big visible win).
2. Tables (layout/alignment — more involved).
3. Images LAST — the hard one.

**GUIDING PRINCIPLE (user, 2026-07-04):** if standard Markdown supports it, we want it.
This pre-approves the normal constructs; the open question per item is *how* (esp.
images), not *whether*.

**CROSS-CUTTING REQUIREMENTS (apply to EVERY construct we render):**
1. **Info modal:** each construct is something the user TYPES to get an outcome, so
   whenever we add rendering for one, the in-app **Info / Markdown Basics modal** must be
   updated to teach its syntax (e.g. strikethrough `~~x~~`, a table, a task checkbox).
   Rendering without documenting the syntax leaves users seeing the result but not knowing
   how to make it. Ship the Info-modal update alongside each construct.
2. **Accessibility (VoiceOver):** each rendered construct must be accessible — struck text
   announced as deleted, HR as a separator, blockquote as a quote, lists with item
   structure, checkboxes announcing checked/unchecked, tables navigable by row/column,
   images reading alt text. Hold to the standard already in the app (math VoiceOver
   descriptions; search match-count announcements).
3. **Menu authoring affordances:** provide menu-bar commands where they'd be EXPECTED and
   make sense — the goal is covering the usability/interactivity bases that are standard
   among writing programs, NOT adding a menu item for every construct just because we can.
   Consistent with the existing bold (⌘B) / italic (⌘I) / link (⌘K) formatting commands
   (`MarkdownFormattingCommand`). Interaction shape VARIES: strikethrough = wrap-selection
   toggle; blockquote/list/checkbox = line-prefix; HR/table/image = insert. Add shortcuts
   only where a standard one exists (e.g. strikethrough ⌘⇧X). Judge per construct at spec.

**Per-construct decisions (walked through one-by-one, 2026-07-04):**
- **Strikethrough** — APPROVED. `~~text~~` → struck-through text, hide the `~~` marks
  (same family as existing bold/italic inline styling). Low risk. Extended-Markdown but
  universally expected. Info modal: add strikethrough syntax.
- **Horizontal rule** — APPROVED. `---` / `***` / `___` on its own line → a quiet, thin,
  low-contrast divider line with breathing room (calm, not a heavy bar); hide the dashes.
  Good for long-form scene/section breaks. Gotcha to handle: `---` also means front matter
  (top of doc) and a `---` UNDER text means "make that a heading" — only render a true
  standalone divider, not those two cases.
- **Blockquote** — APPROVED. `> quote` → quiet quote block: left vertical bar + indent
  (calm, not a heavy tinted box); hide the `>`. Handle nested `>>` (deeper indent) and
  multi-line/multi-paragraph quotes (styling carries across the whole block). De-emphasis
  of quote text is a spec detail — if dimmed, keep it contrast-safe on every theme.
- **Lists (bulleted + numbered)** — APPROVED. Highest everyday payoff (lists are
  everywhere). Bullets (•) and real sequence numbers (1,2,3). **Use standard, well-covered
  treatment like Google Docs** — SLIGHT indentation, proper hanging indent (wrapped lines
  align under the text, not the bullet), nested items indented further. Lean on the
  reading-profile spacing scale. Fiddlier than the rest of the easy wave (nesting,
  counting, tight-vs-loose spacing) but low risk — worst case is slightly-off spacing.
  Budget a bit more care here.
- **Task checkboxes** — APPROVED, and **interactive/clickable is the goal**. `- [ ]` / `- [x]`
  → real empty/checked boxes (builds on the list work). Write mode already tokenizes these,
  so Read is currently behind. **Interactivity design (user, 2026-07-04):** clicking a box
  in Read mode is modeled as a NORMAL text edit — it swaps `[ ]`↔`[x]` in the real document
  through the same undo-registering edit path as typing. Because of that, undo/autosave
  "just work" (Cmd-Z undoes it like any edit); Read mode is just a view over the same doc.
  **The one real piece of work is NOT undo — it's mapping a click on the rendered checkbox
  back to the exact source character range** (this would be the FIRST interactive element in
  Read mode; math/diagrams render as non-interactive pictures today). Contained, moderate,
  a notch above pure-styling effort. Sequencing: ship display-only in the easy wave (instant
  win, not blocked), then wire clicking as a fast follow — OR do interactive in one shot.
  Preserve scroll on the re-render after a toggle.
  **DECISION (user, 2026-07-04): go STRAIGHT to interactive — skip the display-only
  stepping stone.**
  **Save-state / autosave MUST apply to Read-mode checkbox edits.** Because the click is a
  normal `document.text` edit, it automatically flows through the same path as any edit:
  marks dirty, updates save state, triggers autosave. No special "Read mode edit" path.
  This is WHY Task 1 keeps `documentSaveStatus.noteUserEdit()` + autosave bookkeeping
  instant (never debounced) — the checkbox toggle relies on that. Same doc, different view
  ("a windowpane over the same source"). Do NOT lose autosave/dirty-tracking for Read-mode
  edits.
  **Open question (small):** the bottom status bar is HIDDEN in Read mode by design (calm/
  chrome-free), so autosave happens but the user won't SEE the "Autosaved" flash while in
  Read mode (state is correct on switching back to Write/Split). Decide at spec: add a tiny
  save-feedback affordance in Read mode on checkbox toggle, or keep silent autosave. TBD.
  **RESOLVED (user, 2026-07-04):** use the SAME EXACT existing conventions/rules — nothing
  new. So: silent autosave in Read mode, no new save-feedback affordance; status bar stays
  hidden in Read mode as today; the edit tracks/autosaves like any other edit.
- **Tables** — APPROVED. First real LAYOUT feature (harder than easy wave, high payoff).
  Key reframe (user): main use case is VIEWING tables, often AI-generated — read-legibility
  matters most; hand-authoring is rare (so a big insert-table tool is low priority).
  **Wide-table rule — SCREEN (Read mode):**
  1. Table lays out RESPONSIVELY to the reading-column width (change width in settings →
     table re-fits). Live text, always.
  2. Slightly too wide → WRAP cell text (rows get taller); nothing hidden, stays accessible.
  3. Genuinely too wide even wrapped → the table becomes its OWN horizontally-scrollable box,
     scroll CONTAINED to that one table block (prose stays locked to the user's set width).
     This confines the only compromise to the offending table, and only when necessary.
  **Wide-table rule — PDF export:** wrap to page width; for a genuinely-too-wide table,
  shrink-to-fit-the-page IS acceptable here (unlike on-screen) BECAUSE PDF readers have zoom
  and the app does not. Long (many-row) tables paginate across pages normally.
  **Rejected ideas (with reasons):** render-as-image → breaks the accessibility requirement
  (VoiceOver can't read cells), loses text selection, blurs when scaled. Prompt user
  wrap-vs-extend → intrusive; if control is ever wanted make it ONE global setting, not a
  per-table popup. In-app shrink-to-fit → no zoom in the app to recover legibility (user
  caught this). 
  **Other decisions:** quiet ruled style (light gridlines / subtle row separation, not a
  heavy grid); header row distinguished; per-column left/center/right alignment from the
  header dashes; malformed tables → best-effort, degrade gracefully. Sequence as its OWN
  wave AFTER the easy styling batch. Coordinates with PDF export (Task 7) and Task 4 cleanup.
  **DECISION (user, 2026-07-04): self-scrolling IN-WINDOW table is the chosen behavior** —
  a too-wide table becomes its own framed panel that scrolls sideways while prose stays put.
  Best UX and future-proofs a possible mobile version (same swipe-to-scroll pattern on a
  narrow screen). Authoring is ALWAYS just plain Markdown (pipes) — no drag/drop; the
  scroll behavior is a RENDER concern only.
  **Build note — "harder" characterized honestly:** this uses the embedded-view approach
  (a live scrollable panel inside the text view, e.g. a view-hosting text attachment). It is
  GENUINELY FIDDLY, NOT dangerous — no data/security/save risk (worst case = a cosmetic/
  interaction bug: table looks or scrolls wrong, fixable). Real edge cases to polish: scroll
  arbitration (horizontal table swipe vs. vertical page scroll), attachment sizing/layout,
  selection/copy across the table, theme-refresh. Well-trodden AppKit territory, just more
  careful UI work + testing. This is the app's first interactive/scrollable preview element
  (alongside interactive checkboxes).
  **Theming + text options (user wants yes; confirmed feasible & CHEAP):** because a table
  is LIVE TEXT (not a rasterized picture like diagrams/math), full theming is cheap/instant
  (no re-draw) — UNLIKE the fixed-card diagram decision. So: table background + text colors
  FULLY adapt to every reader theme; cell text INHERITS the reading profile (font, size,
  LINE HEIGHT, letter spacing) so it reads consistently with surrounding prose. Bonus: a
  real table view gives NATIVE VoiceOver row/column navigation — better for accessibility
  than faking columns in text. The fixed-card rule is diagrams/math ONLY, not tables.
  **Fallback idea (widen the reading column to fit tables) — REJECTED as primary:** blunt
  (widens ALL prose, capped by window size); keep reading-width as a general preference, not
  the wide-table mechanism. Scroll is the answer.

- **Images** — DEFERRED (do NOT render image files now). Decision + reasons (user, 2026-07-04):
  the one standard construct that's neither cheap nor safe — (1) least core to a calm
  *writing* app (pulls toward notes/docs tool); (2) the ONLY construct that touches the macOS
  sandbox/file-permission area behind past file-access incidents; (3) fuzzy sub-decisions
  (sizing, insert UX, out-of-scope/missing files). A principled exception to the "standard
  Markdown = do it" rule. Also: AI outputs diagrams as **Mermaid/ASCII**, not embedded image
  files, and Mermaid is ALREADY rendered natively — main use case covered better without
  images. Standard Markdown has NO image sizing anyway (`{width=60%}` is a non-standard
  extension), which cuts against the principle too.
  **DO add a quiet placeholder** for `![](...)`: file-free + network-free (never opens the
  file, never hits the network → sidesteps ALL sandbox/privacy risk). Reads as INTENTIONAL
  and preserves info, NOT a bug — e.g. alt text as a subtle caption + small image glyph
  ("🖼 [alt text]"), NOT "not supported currently." Wording/look = spec detail. (Better than
  today's half-rendered state where alt shows with a stray `!`.)
  **REJECTED outright (not parked): OCR / AI image→Mermaid recreation** — would put AI
  image-recognition inside the app, colliding with Lineform's stated "**No AI inside**"
  positioning pillar. Deliberately never.
  **Safe slice for the FUTURE only (if real demand appears):** render only images already
  INSIDE the granted workspace folder (no permission problem), fit-to-width, skip/placeholder
  remote + out-of-scope. Not now.

**Image hard parts / constraints (FUTURE safe-slice reference only — deferred):**
- File-access/permission: an image next to the doc may be OUTSIDE the granted folder —
  must solve "are we allowed to read this file?" (sandbox/security scope).
- Resolve relative paths against the doc location; downscale big images; missing-file
  fallback; reuse the mermaid raster cache discipline.
- **HARD PRIVACY LINE:** do NOT fetch remote `http(s)` images — local-first / no-network
  is positioning. Remote refs render as a plain link, not a downloaded picture.

**Status:** Spec first. Ship easy wave for a quick win. Tables follow. Images separate,
gated on the file-permission question. Fold Task 4 (double-split cleanup) in while here.

### Task 7 — PDF export (rich) + Print/⌘P (APPROVED intent, spec later)
**Correction:** PDF export already EXISTS but is plain-text (throws away formatting).
This task = upgrade it to export the RICH rendered output, plus add Print/⌘P.

**User's PDF export requirements (2026-07-04) — these are for the EXPORT/PRINT page,
NOT Read mode:**
- Always WHITE background regardless of theme; always BLACK text.
- INHERIT from the reading profile: font, font size, line height, block spacing,
  letter spacing.
- Do NOT inherit: column width, reading ruler, typewriter mode.
- Paper sizes: **US Letter (8.5×11") + A4** as the basics. A5 optional (smaller/booklet).
- Include images in the PDF. Candidate approach: "snapshot in app" — reuse the picture
  Read mode already rendered and stamp it onto the page (settle in spec).

**Dependency:** Rich PDF (esp. images) depends on Task 6 being done first (export reuses
Task 6's rendering). Order: Task 6 → Task 7.

**Status:** Approved intent; full spec later.

### Task 8 — Find & Replace (APPROVED)
**Plain terms:** Search exists (toolbar bar, match highlights, Return-to-next) but there's
no replace. Add find-and-replace: swap a word, or replace-all.

**Gain:** Standard everyday writing tool; its absence is felt the moment you reach for it.

**Scope confirmed by user (2026-07-04):** works in the SELECTED/open file only — NOT
across files. No cross-file / whole-folder replace (that drifts toward a notes database,
against positioning).

**Additive:** sits on top of the existing settled search UX — do NOT redesign search,
just add a replace field beside it. Write-mode only.

**Must get right (bounded, testable):**
- **Replace All = one Cmd-Z** (single undo step, not one per word).
- Replace matches the same way search matches (same case-sensitivity).

**Status:** Approved. Spec-light (mostly: where the replace field sits in the find bar).
Build with tests, especially single-undo Replace All.

---

## ⏸️ WAIT — revisit after Task 1 ships

### Task 2 — Only re-color the visible part of the page (not the whole document)
**✅ SHIPPED 2026-07-05** (branch `work-2026-07-05-2-scope-highlighting`, suite 503/0). See the
PROGRESS TRACKER entry above for the as-built summary. The refined approach below was followed,
with ONE code-verified change: the analyzer is line-local, so the "fenced-block state scan"
(step 2) proved unnecessary and was not built — line-boundary snapping alone guarantees
byte-identity. Felt-smoothness QA is with the user.

**Plain terms:** Write-mode coloring currently re-colors the entire document on each
typing pause; on big files that causes a small stutter. Fix would color only what's
on screen.

**Decision (2026-07-04):** WAIT. Do Task 1 first, live with it, and only build Task 2
if a real stutter remains in large files. The downside (subtle, hard-to-repro coloring
bugs) outweighs the upside (invisible smoothness) unless the stutter is confirmed.

**🔔 GATE NOW SATISFIED — measured 2026-07-04 (branch `work-2026-07-04-7-keystroke-debounce`).**
Task 1 shipped (code-complete on that branch; suite 386/0) and its own work was confirmed
reduced — the outline/stats/search derived pass measures ~84 ms on a 2.5 MB doc and now runs
once per typing pause instead of ~20× per keystroke burst. BUT felt typing stutter REMAINS
in that doc, and it was measured to THIS task's cause: `MarkdownRangeAnalyzer.ranges(in:)`
re-tokenizes the WHOLE document inside `highlight()` at **~121 ms/pass**, on top of a
full-range `setAttributes` + full TextKit relayout, firing 80 ms after each pause
(`MarkdownSyntaxHighlighter.swift:150-165`, `MarkdownTextViewRepresentable.swift:296-300`).
The other per-keystroke suspect — the whole-string bridge `text.wrappedValue = textView.string`
(`MarkdownTextViewRepresentable.swift:257`) — measured ~0 ms (COW), so it is NOT the cause.
Conclusion: Task 1 alone does not make a large doc feel smooth; **Task 2 is now the do-next
perf task.** Keep it in its OWN fresh session (WAIT-tier care) with the refined visible-region
+ fence-state approach below — do NOT fold it into the Task 1 branch.

**Refined approach if/when we build it** (safer than whole-document re-color, and
better than a plain margin):
1. Color what's visible **plus a margin** above and below (~a few hundred words) —
   smooths the seams as you scroll. (This was the user's margin idea; it helps the
   *downward* seam.)
2. **Load-bearing safety piece:** before coloring, do a cheap "are we inside a fenced
   code block?" scan from the top of the document (just tracking a yes/no past each
   fence marker — not the expensive coloring). This handles a fence opened far *above*
   the visible area, which a downward margin alone does NOT fix.
3. Re-color the newly visible region on scroll — off-screen text self-heals the moment
   it scrolls into view, so wrong coloring is never actually seen.
The margin is a nice-to-have; step 2 (correct fence state entering the window) is the
part that must be exactly right. Existing highlighter tests must pass unchanged
(small-doc coloring must stay byte-identical).

---

## ⏸️ DEFER — fold into other work

### Task 4 — Stop chopping the text into lines twice when building the reading view
**Plain terms:** Building the Read/Preview view splits the text into lines twice back
to back (same work, done twice). Fix: split once, hand the result to both consumers.
(The audit's scarier "O(n²) on blank-line-heavy docs" claim does NOT apply here — that
path is short-circuited on the preview render; only the harmless double-split is real.)

**Gain:** Small efficiency bump when the reading view rebuilds. Unlikely to be *felt*
(reading view rebuilds on pause, not while typing). Mostly code tidiness.

**Risk:** Very low. Guardrail: output must be byte-identical afterward — verify with the
existing renderer output tests.

**Decision (2026-07-04):** DEFER and fold into **Task 6** (which will already be working
heavily in this same renderer file). It's stable — it does NOT get worse over time, so
there's no cost to waiting, and doing it alongside Task 6 avoids a separate trip into
the file.

---

## 🛑 DO LAST — spec first, extreme care

### Task 5 — Stop the file-list scan from freezing the app on big folders
**Plain terms:** The Files sidebar scans your folders on the main lane (the same lane as
typing), so on a workspace with thousands of files, typing can hitch ~every half-second.
It's made worse by (a) rescanning the WHOLE tree every time any file changes — and
autosave-while-typing looks like "a file changed," so it triggers rescans constantly —
and (b) inspecting+sorting every file before trimming to the 80 shown.

**This IS a real problem worth fixing** — confirmed: users with big folders hit it.

**Pushback on the suggested fix (2026-07-04):** The audit jumps to "move the scan to a
background thread." That's the most direct fix but also the highest concurrency risk.
The spec must FIRST decide the *right* fix, not just implement the audit's. Candidates to
weigh:
1. Move scan off-main (audit's suggestion) — direct, but most concurrency hazard.
2. **Coalesce rescans** — autosave fires frequently; collapse a burst of change-pings
   into one rescan. Simple, low-risk, could kill most of the hitch.
3. **Scope the rescan** to just the folder that changed (use the FSEvent paths) instead
   of rescanning the whole tree. Addresses root cause.
4. **Cheapen the 80-cap** so a huge folder doesn't inspect thousands of files to show 80.
   Helps regardless of thread.
Options 2–4 may make it smooth with far less risk than threading. The audit's option 1
is A candidate, not THE decision.

**Why extreme care:** This area has TWO past incidents that shipped broken (a bricked
release; a broken-file-access release). It's entangled with iCloud rules and
file-access-permission rules, both of which have bitten before. CLAUDE.md is loud here.

**Process gate (required before touching this):**
- Everything else committed to git AND merged first.
- Work on a FRESH git worktree, so a bad outcome can be reset cleanly without touching
  the main line.

**Status:** DO LAST of all perf work. Spec first. Confirm the chosen fix shape before
any code. Skip the fanciest optimizations in v1.

---

## 🟢 RESOLVED BY DESIGN

### Task 3b — theme-switch freeze → RETIRED via fixed-background diagram/math images
**Original 3b:** draw diagrams in the background so a theme switch doesn't freeze the app
(complex: placeholders, cancellation mid-draw, off-main thread-safety of the render
libs). We are NOT doing that.

**Decision (2026-07-04) — solve it by design instead:** render block diagrams and block
math on a FIXED light ("white card") background, theme-INDEPENDENT. Because the theme
color is then no longer part of the image's cache key, a theme switch invalidates
nothing and redraws nothing — the freeze can't happen. No background-threading needed.

**Rules:**
- **Block** Mermaid diagrams + **block** `$$` math → fixed light card, theme-independent.
- **Inline** math (`$x$` mid-sentence) → KEEP theme-aware. A tiny white box mid-line looks
  bad; there are few of them and they're cheap, so they don't drive the freeze anyway.
- Card color need not be pure #FFFFFF — a calm paper-white is a spec detail.

**CONTRAST REQUIREMENT (dark mode is the deciding case):** if we ever make the card
partially transparent so the page tints it, black content on the tinted card MUST stay
readable — and dark/night mode (black page) is the worst case, because transparency
darkens the card most there. Peachy/sage are light pages so they're safe automatically;
only dark mode needs checking. This is TESTABLE — reuse the app's existing discipline of
verifying colors against EVERY theme background (cf. the status-bar
`...AAAgainstEveryThemeBackground` test): compute the card's effective color per theme and
assert black content passes the contrast bar. We will not ship a card that fails.

**Honest tradeoff → pick one of two clean options (avoid the transparent middle):**
- (A) **Solid light card, no transparency** — perfect contrast everywhere (always
  black-on-white); only cost is brightness on dark mode. Simplest, zero contrast risk.
- (B) **Two fixed variants** — light card for light themes, DARK card (light lines/text)
  for dark mode. Gives both dark-mode comfort AND full contrast, still no per-color
  redraw (key on isDark = 2 entries/diagram, not N). Use if dark-mode brightness bugs us.
- The "slightly transparent white" middle option needs the careful contrast check AND
  delivers the least brightness relief — likely skip it. If we DO try it, the exact
  opacity (e.g. ~96%) is a judgment call that REQUIRES visual checking in the running app
  on dark mode — not a value we can pick blind. User will eyeball it.

**Format note:** on-screen these are in-memory images (no file, no size concern). For PDF
embedding use **PNG** (flat-color line art + sharp text compresses small; JPEG would fuzz
text and can't do transparency). Do NOT use JPEG for diagrams/math.

**Where it lands:** fold this design rule into Task 6's rendering work. Retires Task 3b.

---

## ⬜ Still to review together
(all audit items reviewed)
