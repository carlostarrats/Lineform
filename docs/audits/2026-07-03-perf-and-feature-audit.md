# Lineform Performance & Feature Audit — Handoff Tasks

**Date:** 2026-07-03. **Verified against:** branch `work-2026-07-03-4`, commit `e698bdc`.
All file:line references were confirmed by code reading on this date; re-verify locations if the tree has moved on before acting.

## How to use this document

Each task below is **self-contained** — paste ONE task block (plus the "Global rules" section) into a fresh Claude Code session, on its own branch. Do not hand a session more than one task; the diffs touch different subsystems and should land as separate reviewable branches.

Tasks are ordered by effort-to-payoff. Tasks 1–5 are performance diagnoses ready to action. Tasks 6–8 are **feature gaps that need a design spec first** — instruct the session to brainstorm/spec before writing code (this repo's established workflow: design spec → plan → implement, see `docs/superpowers/specs/` for precedent).

## Global rules (include with every task)

- Read `CLAUDE.md` at the repo root first and follow it. Non-negotiables that these tasks brush against:
  - Full test suite must run **serially** (`-parallel-testing-enabled NO`) with **Xcode quit**; a CLI run triggers a TCC Documents prompt near the end — warn the user, never run unattended.
  - Do not weaken the hosted editor motion tests (`EditorDisplayModeTests`) to make them pass.
  - Preserve the **iCloud laziness invariant**: `OutlineFileBrowserStore`'s expensive scan must never run at window/view construction or for windows not showing the Files tab.
  - Never revert the sidebar's held security scope to transient start/stop access (the 1.1.1 file-access bug).
  - Keep UI native, restrained; no analytics, no uploads.
- Verify each cited finding yourself before changing code (the citations were accurate on 2026-07-03).
- For perf tasks: create a large test document first (e.g. `python3 -c "print(('# H\n\nlorem ipsum dolor sit amet. ' * 40 + '\n\n') * 2000)" > /tmp/big.md` ≈ 4–5 MB) and reproduce the symptom before fixing; confirm the fix against the same file after.
- "Done" = symptom reproduced → fixed → acceptance criteria met → full serial test suite green with exact pass/fail counts reported.

---

## Task 1 — Debounce the per-keystroke outline/stats/search refresh (smallest fix, biggest exposure)

**Problem:** `EditorContainerView`'s `onChange(of: document.text)` runs synchronously on **every keystroke** with no debounce: full-document outline reparse, full-document word count, and search-match refresh.

**Evidence:**
- `Lineform/Editor/EditorContainerView.swift:256-260` — the un-debounced `onChange` calling all three.
- `Lineform/Outline/MarkdownOutlineParser.swift:19` — `enumerateSubstrings(byLines)` over the full document, plus per-line `MarkdownHeadingParser.heading` (`Lineform/Outline/MarkdownHeadingParser.swift:8`, char-by-char substring).
- `Lineform/Editor/DocumentStatistics.swift:17` — `countWords` iterates every unicode scalar, per keystroke.
- Contrast: syntax highlighting IS debounced correctly at 80ms via `cancelPreviousPerformRequests` (`Lineform/Editor/MarkdownTextViewRepresentable.swift:296-300`) — mirror that pattern or use a coalescing `DispatchWorkItem`/Combine debounce.

**Fix shape:** Coalesce the outline + stats (and search refresh) work behind a ~100–200ms trailing debounce. Keep the parse itself unchanged. Do not debounce the binding write itself (typing latency must not change).

**Constraints:** Outline sidebar and word count may lag typing by the debounce interval, but must settle correctly after the last keystroke (including on the final keystroke before a mode switch or save). Search highlight behavior is FINAL per repo history — don't change its UX, only coalesce the recompute.

**Acceptance criteria:**
1. In a 4–5 MB document, typing a burst of 20 characters triggers ≤ 2 outline reparses (was 20). Verify by temporary instrumentation or a unit test on the debouncing wrapper.
2. Outline and word count are correct within ~250ms after typing stops.
3. No per-keystroke beachball/hitch typing in the 4–5 MB file (manual check in the running app).
4. Full serial suite green.

---

## Task 2 — Scope syntax highlighting to the edited region (whole-document re-attribute per pass)

**Problem:** Every (debounced) highlight pass resets attributes across the **entire document** and re-tokenizes the **entire document** on the main thread, forcing a full relayout — felt as a hitch after each typing pause in large files.

**Evidence:**
- `Lineform/Editor/MarkdownSyntaxHighlighter.swift:150-165` — `highlight` always uses `fullRange = 0..storage.length`; `:159` `setAttributes(baseAttributes, range: fullRange)`, `:161` re-tokenizes `textView.string` in full, wrapped in `beginEditing`/`endEditing` (full layout invalidation).
- `Lineform/Editor/MarkdownRangeAnalyzer.swift:27-39` — `ranges(in:)` does `enumerateSubstrings(byLines)` over the whole doc with a `substring(with:)` allocation per line (`:48`), plus two more full-document regex passes (code spans `:36`, links `:37`/`:76`), then sorts all tokens (`:39`). All main-thread.
- Also: two full NSString→String bridges per change cycle (`MarkdownTextViewRepresentable.swift:257` and inside `highlight` at `MarkdownSyntaxHighlighter.swift:161`).

**Fix shape:** Restrict re-attribution and re-tokenization to the edited paragraph range (or edited-line span extended to enclosing block constructs — fenced code blocks and front matter span lines, so extend the dirty region to enclosing fence boundaries). An alternative acceptable shape: analyze only the visible range + margin. Keep the existing 80ms debounce.

**Constraints:** Multi-line constructs (fenced code, front matter) must stay correctly highlighted when a fence line itself is edited (opening or closing a fence re-scopes everything after it — handle by rescanning from the edited fence to the next fence/EOF). The Writing Tools protection ranges (`MarkdownWritingToolsProtection`) consume analyzer output — confirm they still see correct ranges. Behavior on small documents must be byte-identical (existing highlighter tests must pass unmodified).

**Acceptance criteria:**
1. Typing in a 4–5 MB document: the post-pause highlight hitch is gone or under ~16ms (measure with signposts or a simple `CFAbsoluteTimeGetCurrent` around `highlight` before/after).
2. Editing inside, opening, and closing a fenced code block re-highlights correctly (add/extend unit tests).
3. All existing `MarkdownSyntaxHighlighter`/`MarkdownRangeAnalyzer` tests pass unmodified.
4. Full serial suite green.

---

## Task 3 — Move Mermaid/Math rasterization off the main thread; fix cache-limit thrash

**Problem (two related):**
1. A mermaid/math **cache miss renders synchronously on the main thread** inside the preview render pass. A theme toggle changes every cache key (fg/bg hex is in the key), so a diagram-heavy document freezes the UI while every block re-rasters in one pass.
2. Cache `countLimit`s are 50 (mermaid) / 100 (math). A document with more blocks than that **evicts before reuse** — it can never be fully cached, so every rebuild re-renders the evicted blocks even when nothing changed.

**Evidence:**
- `Lineform/Preview/MermaidRendering.swift:110-139` — `NSCache` countLimit 50 (`:117`), key = SHA256(scale+bg+fg+source) (`:44-50`), synchronous `MermaidRenderer.renderImage` on miss (`:133-139`) plus a CoreGraphics y-flip redraw per cold render (`:61-85`, the `uprightForMacOS` correction — do NOT remove it, see CLAUDE.md).
- `Lineform/Preview/MathRendering.swift:181-231` — countLimit 100 (`:193`), synchronous `MathImage.asImage()` on miss (`:210-231`).
- `Lineform/Preview/MarkdownPreviewViewRepresentable.swift:79-90` — the whole render pass (including these misses) runs inside `apply()` on the main thread.
- Theme-key invalidation: `Lineform/Preview/MarkdownPreviewRenderer.swift:224-230, 294-302`.

**Fix shape:** (a) Raise or replace the count limits — size-bound via `totalCostLimit` (cost = raster byte size) instead of count-bound, or raise counts well past realistic doc sizes. This alone is a two-line change with real payoff; do it first. (b) Async fill: on cache miss, emit a placeholder attachment (sized to the estimated/last-known size to avoid reflow jumps), render the raster on a background queue, then patch the attachment image and invalidate display on completion. Keep the failure/negative caches — they're load-bearing.

**Constraints:** The `uprightForMacOS` flip must survive (upstream y-origin bug, documented in CLAUDE.md). The 20,000-char size guards must survive. The failure path must still fall back to captioned source blocks and (mermaid only) DiagramLog + Report-this. Determinism of the existing renderer unit tests must hold — inject a synchronous provider in tests if the async path would flake them.

**Acceptance criteria:**
1. A doc with 60+ mermaid or 120+ math blocks: after one full render, a subsequent no-change rebuild performs **zero** raster renders (instrument the provider to count).
2. Theme toggle on a diagram-heavy doc no longer freezes the UI (main thread unblocked; placeholders acceptable during fill).
3. All existing Mermaid/Math rendering tests pass (adapted only for provider injection, not weakened).
4. Full serial suite green.

---

## Task 4 — Preview render pass efficiency (redundant scans, O(n²) block spacing)

**Problem:** Each (0.12s-debounced) preview rebuild does redundant and superlinear full-document work on the main thread: the text is split into lines **twice**, and the block-spacing pass has a worst-case O(n²) look-ahead scan.

**Evidence:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift:48-51` — `render()` calls `markdownBlockSpacingLineIndexes(in: text)` (which splits + scans all lines: `Lineform/Editor/MarkdownSyntaxHighlighter.swift:106-137`) and then splits the same text again with `components(separatedBy: "\n")`.
- `Lineform/Editor/MarkdownSyntaxHighlighter.swift:121, 139-145` — `hasNonEmptyLine(after:)` can scan to end-of-document per line → O(n²) worst case (pathological on documents with long runs of blank lines).
- Per-line inline tokenizer re-runs 4 `firstMatch` regexes per consumed token (`MarkdownPreviewRenderer.swift:493-533`) — acceptable, but allocation-heavy (`:552-557` new NSAttributedString + `NSFontManager.convert` per token).

**Fix shape:** Split once and pass the line array to both consumers; compute "has a later non-empty line" with a single reverse pre-pass (O(n)). Optional stretch: reuse font conversions via a small cache keyed by (font, trait).

**Constraints:** Output attributed string must be **identical** for the same input (this is pure refactor — add a characterization test comparing old vs new output on a corpus of sample docs before deleting the old path, or assert against existing renderer test fixtures). Keep the renderer synchronous and injectable as-is (Task 3 owns async).

**Acceptance criteria:**
1. Renderer output byte-identical on existing test fixtures.
2. A 4–5 MB doc's render pass measurably faster (log before/after timings in the task report); the pathological blank-line doc (e.g. 100k blank lines) no longer superlinear.
3. Full serial suite green.

---

## Task 5 — Files sidebar: scan off the main thread, cap before stat/sort

**Problem:** The recursive directory scan runs **synchronously on the main thread**, a FSEvents tick triggers a **full-tree rescan** (event paths are discarded), and the 80-per-folder display cap is applied only **after** stat-ing and sorting every entry. A several-thousand-file workspace hitches the UI every 0.5s while typing (own-process autosave events are deliberately not filtered).

**Evidence:**
- `Lineform/Outline/OutlineSidebarView.swift:1199` (`Self.items(...)` scan), called synchronously from `refreshWorkspaceRoot` `:1145` / `refreshICloudRoot` `:1073`; FSEvents delivered on `.main` (`Lineform/Outline/DirectoryEventMonitor.swift:63`) and wired straight to full refreshes (`OutlineSidebarView.swift:825-832`); event paths ignored (`DirectoryEventMonitor.swift:46-48`).
- Cap after full enumerate+stat+sort: `:1263-1264` (`.sorted{...}.prefix(80)` after per-child `resourceValues` reads at `:1211`, `:1227`).
- Publish guard is a full deep `Equatable` tree diff on main (`:1074`, `:1094`, `:1160`) — correct, but runs after the scan already cost the main thread.
- Per-window `init` also scans the workspace synchronously on main (`:803`); iCloud is correctly deferred (`:799-802`).
- iCloud ubiquity calls (`url(forUbiquityContainerIdentifier:)` `:1167`, `ensureDownloaded` loop `:1175-1188`) run on main per refresh tick.

**Fix shape:** Move the scan (and the tree-equality diff) to a background queue/`Task.detached`; hop to main only to publish. Apply the same treatment to the `init` workspace scan and the iCloud refresh path. Optional second step: use the FSEvents callback paths to scope rescans to affected subtrees (the store already scopes refreshes by root via `refreshSidebarFiles`).

**Constraints — this task has the most tripwires; re-read CLAUDE.md's iCloud and sidebar sections:**
- The **iCloud laziness invariant** must hold: no iCloud container resolution/scan at construction or for hidden Files tabs.
- The workspace **security scope is HELD by the store for its lifetime** — do not introduce transient start/stop access around the scan (1.1.1 regression).
- `@Published` didSet observers fire for `init` assignments — the store deliberately uses `Published(initialValue:)` backing-storage init; don't disturb that.
- Sort-change-triggers-rescan is deliberate (cap is applied in display order; order decides membership) — keep it.
- Own-process FSEvents are deliberately NOT filtered (keeps Date Modified sort live) — keep that; the fix is making the rescan cheap/off-main, not filtering events.
- Publish-only-on-change guard must survive (prevents SwiftUI re-diff churn).

**Acceptance criteria:**
1. With a synthetic 5,000-file workspace (script its creation), typing in an open document (autosave firing) produces no main-thread hitches; Instruments or a main-thread watchdog shows the scan off-main.
2. Sidebar still live-updates on external file create/rename/delete within ~1s; sort changes still re-scan; hidden-folders toggle still works.
3. New-window creation no longer blocks on a workspace scan (measure window-open time on the 5,000-file workspace before/after).
4. Existing sidebar/store tests pass; full serial suite green.

---

## Task 6 — DESIGN SPEC FIRST: Read/Preview mode Markdown coverage (tables, images, lists, blockquotes, task lists, hr, strikethrough)

**Gap:** The Read/Preview renderer handles only headings, fenced code, mermaid, math, and inline bold/italic/code/link (`Lineform/Preview/MarkdownPreviewRenderer.swift` — no code paths exist for tables, `![](...)` images, list styling, blockquotes, task-list checkboxes, horizontal rules, or strikethrough; they render as literal source). Write mode's analyzer already tokenizes checkboxes (`Lineform/Editor/MarkdownRangeAnalyzer.swift:63-64`), so Read mode lags Write mode's own vocabulary.

**Instruction to the session:** Do NOT start coding. Brainstorm + write a design spec (`docs/superpowers/specs/` precedent) covering, at minimum:
- Which constructs ship in which order (suggested: lists/blockquotes/hr/task-lists first — pure text styling; then tables; then images).
- Visual design of each in the calm reader themes (tables in a quiet ruled style; blockquote treatment; list indentation with the reading profile's spacing scale).
- **Images are the hard one:** relative-path resolution against the document's location, sandbox/security-scope implications for images outside a granted root, downscaling/size caps, missing-file fallback, and whether remote `http(s)` images are allowed at all (local-first privacy default says **no network fetch** — recommend rendering remote refs as links).
- Interaction with the existing line-based renderer architecture and Task 4's refactor (coordinate if both are in flight).
- Performance budget (tables/images must not regress Task 3/4 wins; image rasters need the same cache discipline as mermaid).

**Acceptance for the spec:** user sign-off before implementation. Acceptance for the implementation: each construct has renderer unit tests + fixture docs; no network requests introduced; full serial suite green.

---

## Task 7 — DESIGN SPEC FIRST: Export / Print

**Gap:** No PDF/HTML export and no ⌘P anywhere in `Lineform/App` (checked `AppCommands.swift` and siblings on 2026-07-03). "Get my formatted document out" is a standard expectation for a Markdown reader.

**Instruction to the session:** Brainstorm + spec first. Decisions the spec must settle:
- Scope: Print (⌘P) of the Read-mode rendering, PDF export, HTML export — which subset for v-next (recommend Print + PDF via the existing Read renderer; HTML is a different fidelity contract).
- Whether export uses the current reading profile/theme or a dedicated print-friendly profile (recommend: dedicated light/serif print profile; on-screen themes are for screens).
- Pagination of the attributed string (NSPrintOperation over an NSTextView is the native path), margins/paper handling, mermaid/math raster resolution at print scale (current rasters are screen-scale — may need a re-render at higher scale; note the mermaid cache key already includes scale).
- Menu placement (File menu, native conventions) and behavior for untitled documents.

**Constraints:** No new dependencies; native print pipeline only; nothing uploaded anywhere. Coordinate with Task 6 (exporting a doc whose tables/images don't render yet exports literal source — the spec should state that ordering dependency explicitly).

---

## Task 8 — DESIGN SPEC FIRST: Find & Replace (in-document)

**Gap:** `Lineform/Editor/EditorSearchResolver.swift` finds matches; there is no replace. No cross-file search (recommend explicitly deferring cross-file search — it drifts toward "notes database" and against positioning).

**Instruction to the session:** Brainstorm + spec first, with one hard constraint from repo memory: the current search UX (toolbar search bar, yellow/blue highlights, Return-to-next) is **FINAL and settled** (commit `6b84d3a`) — replace must be additive to it, not a redesign. The spec must settle: how the replace field appears (native find-bar conventions), Replace / Replace All semantics, undo grouping (Replace All must be one undo step), behavior inside protected regions (fenced code/front matter — probably replace normally; Writing Tools protection is about system AI features, not user edits — confirm), and interaction with Read/Split modes (replace is Write-mode only).

**Acceptance for implementation:** unit tests for the replace resolver (case sensitivity matching the existing search semantics), single-undo Replace All, suite green.

---

## Small correctness nit (bundle with Task 3 or fix standalone)

On window resize, preview image attachments don't refit the new column width until the next real re-render: the resize path deliberately skips re-rendering (`Lineform/Preview/MarkdownPreviewViewRepresentable.swift:63-66, 75-77` — `apply()` early-returns when text+profile unchanged), and attachment bounds are only computed during a render (`MarkdownPreviewRenderer.swift:238-240`). The mermaid cache key also omits column width. Visible when narrowing a window containing a wide diagram: the image overflows/clips instead of refitting. Fix shape: on live-resize end, recompute attachment `bounds` in place (no re-render/re-raster needed — the raster scales; only the bounds fit is stale).

---

## What NOT to do (from this audit)

- Don't add wiki-links/backlinks, tags, cloud accounts, analytics, or AI features — against positioning.
- Don't filter own-process FSEvents, don't weaken the 80-cap-in-display-order design, don't touch the mermaid y-flip, don't weaken hosted motion tests, don't revert the held security scope. All deliberate; all documented in CLAUDE.md.
- The following were audited and are **already well-optimized** — leave them alone: highlighting debounce, preview debounce + no-op guard, precompiled regexes, mermaid/math negative caches and key composition, off-main live-reload with stat pre-check, sidebar snapshot caching, hidden-folder in-memory filtering, `DocumentSaveStatus` copy cap.
