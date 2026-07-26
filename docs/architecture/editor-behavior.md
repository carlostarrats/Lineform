# Editor behavior

Live reload, scoped syntax highlighting, save-state reporting, view modes, speech, and reading-position restore.

Extracted from `CLAUDE.md` so the always-loaded file stays scannable. Content is verbatim —
these are the same load-bearing notes, not a summary. Read this file before changing anything
in this area.

- Live reload: an open document refreshes from disk when its file changes externally (e.g. an agent rewrites the `.md`), on clean documents only, debounced, preserving scroll and mode, with a quiet "Updated" status. Implemented as a dedicated `NSFilePresenter` (`Lineform/Documents/DocumentReloadController`), not on the value-type `FileDocument`. Documents with unsaved edits defer to standard behavior — never clobbered. **Background-tab reconcile (load-bearing, do not remove):** there is ONE `DocumentReloadController` per window and it watches only the ACTIVE tab's file — background tabs are unwatched. So `activateSelectedTab` reconciles a **clean** incoming tab with disk (`reloadController.fileDidChange()`, guarded on `!isEdited`) right after re-registering the watcher: without it, switching to a clean background tab whose file was rewritten externally would show the stale in-memory snapshot and the next keystroke would autosave over the external rewrite (silent data loss). A **dirty** incoming tab is deliberately left untouched (its unsaved edits win, mirroring the `.ignoreDirty` policy). `register`'s new-URL branch does NOT reconcile on its own (it blesses the passed `syncedText` as the baseline), which is why the reconcile is triggered explicitly at the call site where clean-vs-dirty is known.

- Markdown syntax highlighting and range analysis. Write-mode highlighting is **visible-window-scoped** for large-doc typing performance (`Lineform/Editor/MarkdownSyntaxHighlighter.swift`, Task 2 / `docs/superpowers/specs/2026-07-05-scoped-syntax-highlighting-design.md`): `highlight(...tokenScope:)` applies base attributes (font/paragraph-style/kern/color) to the **whole document** — this is what keeps off-screen layout/line-height stable and MUST stay whole-doc — but colorizes tokens only within a scope, and `refreshTokens(scope:)` re-tokenizes just the visible window (+`highlightMargin`, line-snapped) on each typing pause and on a coalesced scroll-settle (`LineformTextView.refreshVisibleTokensAfterScroll`, skipped during IME marked text). This is only safe because `MarkdownRangeAnalyzer` is **strictly line-local** (no cross-line token state — every regex, incl. the newline-excluded link regex, matches within one line); a line-snapped window is therefore byte-identical to a whole-doc pass and needs no fenced-block state scan. **If you add a cross-line construct to the analyzer, scoped highlighting breaks — keep it line-local or rework the scoping.** No enclosing scroll view (tests) → whole-document fallback, so existing highlighter tests stay byte-identical. **Image links** `![alt](path)` are colored in Write mode too (`MarkdownRangeAnalyzer` `imageRegex` → `.imageText`/`.imageDestination` tokens → `NSColor.linkColor`): the alt **and** the path go link-blue (unlike ordinary links, whose path stays the muted marker gray) because image links commonly have an empty alt (`![](path)`) where the path is the only visible content. `linkRegex` carries a `(?<!!)` lookbehind so an image and a plain link never double-match the same span; both regexes stay newline-excluded (line-local).

- Save-state status bar: the bottom editor status bar (hidden in Read mode) communicates save state so users never have to assume autosave happened. The metadata — word count, character count, and `Last save: …` time — is **always grey**; only *added* status words carry color. An untitled/never-saved doc shows red **"Not saved yet"** in the main text (the counts stay grey); an established doc with pending edits shows amber **"Unsaved changes"** in the left indicator slot; a real write flashes green **"Saved"** (manual ⌘S / Save As) or **"Autosaved"** (autosave), fading after ~4s; an external disk reload keeps its pre-existing green **"Updated"** + `arrow.clockwise` flash. Logic lives in `Lineform/Editor/EditorStatusPresentation.swift` (`EditorStatusFormatter.indicator(...)`, `MetadataSegments`, `EditorStatusIndicator`/`Flash`, and `EditorStatusColors`). Dirty state = live `document.text` ≠ the last-written text tracked in `DocumentSaveStatus` (untitled docs are never "dirty" — they're "Not saved yet"). Only real writes (`fileWrapper` → `DocumentSaveStatus.recordWrite`) flash green; **load and external reload deliberately call `markSaved`, not `recordWrite`, so opening/reloading never flashes "Saved".** Manual vs. autosave is classified by a short-lived intent flag set by a ⌘S/⌘⇧S `NSEvent` local monitor (`ManualSaveIntentMonitor`) and the Save As menu button — pure observation that never touches the save machinery; a rare mouse-clicked menu **Save** may fall through as "Autosaved". The red/amber/green colors are appearance-specific (`dark:` selects the variant) and must clear WCAG AA against **every** `Theme.builtIn` background — enforced by `testStatusStateColorsMeetAAAgainstEveryThemeBackground`; if you retune a color, keep that test green.

- **⌘E** toggles Write↔Read (2026-07-18, matching Obsidian's edit/reading toggle): from Write it goes to Read, and from **either** Read or Split it goes to Write (`EditorDisplayMode.toggledWriteRead`, `Lineform/Editor/EditorDisplayMode.swift`) — a stateable two-way flip, not a 3-way cycle. It drives the **existing** mode-switch seam (the same `LineformDisplayModeMenuState`/`setDisplayMode` notification path the toolbar segmented control and the View-menu Mode picker already use), so all three stay in sync automatically. Split has no keyboard shortcut and stays toolbar/menu-only by design. See `docs/superpowers/specs/2026-07-18-view-mode-keyboard-shortcut-design.md`.

- Cross-mode reading-position restore (2026-07-18): switching Write ↔ Read ↔ Split keeps the reader's place instead of jumping to the top, so toggling to compare source vs. rendered is useful. Mechanism: the renderer tags **every** rendered run with a `.sourceSpan` (the SOURCE `NSRange` it maps back to — a single source line for prose/heading runs from `appendLines`, or the WHOLE source span of a multi-line block for non-`.lines` blocks in `render`; a full rendered→source map, finer than `.headingSourceRange`). Both surfaces already report their top-of-viewport position via `onVisibleTopRangeChanged`; the preview now reports the **exact** source offset (from `.sourceSpan`, sub-line precise — it adds the rendered offset within the run, **clamped to the span length** so a position inside a multi-line block can't overshoot past the block, which would mis-restore and bold the wrong outline heading) rather than the nearest heading. Non-`.lines` blocks get their FULL source span (first line start … last line end) via a running `sourceLineCursor` over the block partition (`blockLastLine`), never just the last line. `EditorContainerView.onChange(of: displayMode)` captures that tracked offset (`activeOutlineSourceRange`) and, deferred one runloop tick (the incoming view is created fresh and unsized this cycle), sets the shared `requestedScrollToTopRange`; the incoming Write editor scrolls via `scrollCharacterRangeToTopPersistently` and the Read/Preview view via `MarkdownPreviewTextView.scrollSourceRangeToTop` (maps the source offset back to a rendered position, sub-line precise). **Two load-bearing gotchas, both diagnosed from a scroll trace:** (1) a freshly created Write editor runs its layout-preservation machinery, which schedules a DEFERRED restore pinning the new view to the TOP — it fires a tick or two after the scroll lands and silently clobbers it; cancelling isn't enough (its second pass captured the top anchor locally), so `scrollCharacterRangeToTopPersistently` **re-asserts the target and cancels the competing restores across ~5 ticks**. (2) The explicit jump must bypass `LineformEditorClipView`'s transition lock (`setBoundsOriginBypassingVerticalLock`) or the fresh view's creation lock clamps it to 0. `resetTransientDocumentState` clears `activeOutlineSourceRange`/`requestedScrollToTopRange` **before** a tab switch sets the incoming tab's `displayMode`, so a stale position is never restored into a different document. Restore is exact for plain prose and a close approximation within paragraphs carrying stripped inline markup (source↔rendered sub-line drift; a full char map is the deferred follow-up). **Outline click in Read** no longer force-switches to Write (`jumpToHeading` dropped the `.read → .write` flip): the preview honors the scroll request in place via the same `.sourceSpan` seam.

- Read-aloud / text-to-speech (2026-07-18): **Edit ▸ Speech** submenu (Start Speaking / Pause·Resume / Stop, no default keyboard shortcut in v1) drives a native, offline `AVSpeechSynthesizer` — **no network, no new entitlement**, isolated behind `SpeechController` (`Lineform/ReadingExperience/SpeechController.swift`, an `ObservableObject` state machine — `.idle`/`.speaking`/`.paused` — wrapping a testable `SpeechSynthesizing` protocol) using the **system default voice and rate** (a Reading-Experience voice/rate picker is a deferred follow-up). Speech is never raw markdown: a pure `SpeechTextExtractor.spokenText` (`Lineform/ReadingExperience/SpeechTextExtractor.swift`) walks the same `MarkdownBlockGrouping.markdownBlocks(in:)` used by Read/Preview, strips inline markers (bold/italic/code/link syntax), reads headings/paragraphs/lists/blockquotes/callouts/table cells as plain text and images by their alt text, and **skips fenced code, math, and mermaid blocks** entirely (not readable prose). Start point: a selection speaks the selection; otherwise it speaks from the caret to the end in Write/Split, or the whole document in Read (no caret there). No spoken-word highlight-follow and no persisted playback position in v1. See `docs/superpowers/specs/2026-07-18-read-aloud-tts-design.md`.

- **Horizontal-inset animation teardown (2026-07-25).** `LineformTextView` animates column-width
  changes on a REPEATING `Timer(target: self)` (`horizontalInsetAnimationTimer`), which retains the
  text view — `deinit` cannot run while one is scheduled, so nothing in `deinit` can be the teardown
  point. Before this fix the timer was invalidated only when the animation converged, so a view torn
  down mid-animation (closing a tab or window, or switching Write → Read, which discards the editor)
  leaked the text view, its layout manager, and the document's text storage, while still running
  layout at 120 Hz on a detached view. **`viewDidMoveToWindow` now ends the animation at its target
  whenever the view leaves its window** — off-screen there is nothing to animate. A watchdog also
  force-ends any run that exceeds its own duration by `horizontalInsetAnimationGracePeriod`: the
  convergence check reads `textContainer?.containerSize` defaulted to `0` while the write it is
  checking is `textContainer?.containerSize = …`, so a missing text container makes the target
  unreachable and the timer would otherwise spin forever. Guarded by
  `LineformTextViewInsetAnimationTests` (verified failing with the teardown removed).
- **`MarkdownPreviewRenderer` is `@MainActor` (2026-07-25).** It builds `NSFont`/`NSColor`/`NSImage`
  and installs an `NSCell`-backed attachment cell (`HorizontalRuleAttachment`), which is main-actor
  isolated — constructing it from a nonisolated context was a Swift 6 warning today and a real data
  race if rendering ever moved off the main thread. Every call site was already on the main actor
  (view code and export), so the annotation changed no behavior; renderer test classes carry
  `@MainActor` to match. Do not "fix" a future isolation warning here by dropping back to
  `nonisolated` + `assumeIsolated` — that would silently permit off-main rendering.

- **List continuation on Return (2026-07-26).** Return after a bullet (`-`/`*`/`+`), ordered item
  (`1.`/`1)`), task checkbox, or blockquote continues the marker; Return on a marker the writer
  left empty clears it and ends the construct. The decision is a pure value type,
  `MarkdownListContinuation.outcome(for:selectedRange:)` (`Lineform/Editor/MarkdownListContinuation.swift`),
  returning `.continue(insertion:)`, `.terminate(clearing:)`, or `nil` for "behave normally" —
  no AppKit, so the whole decision surface is testable without a window. The marker character,
  ordered separator, and leading indentation are preserved verbatim; a continued checkbox is
  **always** `- [ ]` (inheriting `[x]` would silently mark new work done). Ordered items
  **increment only** and never renumber the items below — GFM renders `1. 2. 2.` as 1, 2, 3, so
  the cost is confined to the source text, whereas renumbering would be a multi-line edit that
  has to stay one undo step and hold the caret still. Tab/Shift-Tab indent was deliberately left
  out: it is the only part of the original scope that would REMOVE existing behavior (Tab inserts
  a literal tab) and Tab is a standard accessibility focus key. See
  `docs/superpowers/specs/2026-07-26-list-continuation-design.md`.

  **Four things that are load-bearing, each a real trap:**
  (1) It overrides **`insertNewline(_:)`, never `keyDown`.** `keyDown` fires BEFORE input-method
  handling, so it would swallow Return while a Japanese/Chinese IME commits a composition, and
  would fight the spelling-correction popup. `insertNewline` is only reached once the input
  context has decided the keypress really is a newline.
  (2) The edit goes through the **localized** `shouldChangeText → replaceCharacters → didChangeText`
  path (`applyListContinuationEdit`), **NOT** `applyWholeTextReplacement`, which every formatting
  command uses and which does `setAttributedString` over the ENTIRE document — a full-document
  rewrite on every Return. Copying the nearest formatting command is the obvious wrong move.
  One `replaceCharacters` is also what makes a single ⌘Z reverse the newline and its marker
  together, with no explicit undo grouping.
  (3) It deliberately does **not** re-highlight. `didChangeText` already reaches the delegate's
  `textDidChange`, which schedules the debounced visible-window pass; forcing a synchronous
  `refreshMarkdownHighlighting()` here re-attributes on every Return — the per-keystroke repaint
  measured as the large-doc caret trail on 2026-07-05. The explicit `scrollRangeToVisible` stays,
  because bypassing `super.insertNewline` also bypasses AppKit's own scroll-to-caret.
  (4) Fence/front-matter suppression uses
  **`MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location:in:)`**, added for this and
  kept in that file so the fence rules stay in one place. It is NOT `ignoredRanges`: that computes
  every protected region whole-document including a per-line inline-math regex, and measured
  **18.37 ms** on a 730 KB file versus **1.05 ms** for the narrow check — fine for a Writing Tools
  session, far too slow per Return. `MarkdownRangeAnalyzer` cannot answer this at all; it is
  strictly line-local by invariant and cannot see a fence opened on an earlier line. The
  whole-document walk is additionally gated behind a cheap line-local prefix match, so Returns on
  ordinary prose (0.001 ms) never pay for it.
