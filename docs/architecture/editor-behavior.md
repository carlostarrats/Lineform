# Editor behavior

Live reload, scoped syntax highlighting, save-state reporting, view modes, speech, and reading-position restore.

Extracted from `CLAUDE.md` so the always-loaded file stays scannable. Content is verbatim —
these are the same load-bearing notes, not a summary. Read this file before changing anything
in this area.

- Live reload: an open document refreshes from disk when its file changes externally (e.g. an agent rewrites the `.md`), on clean documents only, debounced, preserving scroll and mode, with a quiet "Updated" status. Implemented as a dedicated `NSFilePresenter` (`Lineform/Documents/DocumentReloadController`), not on the value-type `FileDocument`. Documents with unsaved edits defer to standard behavior — never clobbered. **Background-tab reconcile (load-bearing, do not remove):** there is ONE `DocumentReloadController` per window and it watches only the ACTIVE tab's file — background tabs are unwatched. So `activateSelectedTab` reconciles a **clean** incoming tab with disk (`reloadController.fileDidChange()`, guarded on `!isEdited`) right after re-registering the watcher: without it, switching to a clean background tab whose file was rewritten externally would show the stale in-memory snapshot and the next keystroke would autosave over the external rewrite (silent data loss). A **dirty** incoming tab is deliberately left untouched (its unsaved edits win, mirroring the `.ignoreDirty` policy). `register`'s new-URL branch does NOT reconcile on its own (it blesses the passed `syncedText` as the baseline), which is why the reconcile is triggered explicitly at the call site where clean-vs-dirty is known.

- Markdown syntax highlighting and range analysis. Write-mode highlighting is **visible-window-scoped** for large-doc typing performance (`Lineform/Editor/MarkdownSyntaxHighlighter.swift`, Task 2 / `docs/superpowers/specs/2026-07-05-scoped-syntax-highlighting-design.md`): `highlight(...tokenScope:)` applies base attributes (font/paragraph-style/kern/color) to the **whole document** — this is what keeps off-screen layout/line-height stable and MUST stay whole-doc — but colorizes tokens only within a scope, and `refreshTokens(scope:)` re-tokenizes just the visible window (+`highlightMargin`, line-snapped) on each typing pause and on a coalesced scroll-settle (`LineformTextView.refreshVisibleTokensAfterScroll`, skipped during IME marked text). This is only safe because `MarkdownRangeAnalyzer` is **strictly line-local** (no cross-line token state — every regex, incl. the newline-excluded link regex, matches within one line); a line-snapped window is therefore byte-identical to a whole-doc pass and needs no fenced-block state scan. **If you add a cross-line construct to the analyzer, scoped highlighting breaks — keep it line-local or rework the scoping.** No enclosing scroll view (tests) → whole-document fallback, so existing highlighter tests stay byte-identical. **Image links** `![alt](path)` are colored in Write mode too (`MarkdownRangeAnalyzer` `imageRegex` → `.imageText`/`.imageDestination` tokens → `NSColor.linkColor`): the alt **and** the path go link-blue (unlike ordinary links, whose path stays the muted marker gray) because image links commonly have an empty alt (`![](path)`) where the path is the only visible content. `linkRegex` carries a `(?<!!)` lookbehind so an image and a plain link never double-match the same span; both regexes stay newline-excluded (line-local).

- Save-state status bar: the bottom editor status bar (hidden in Read mode) communicates save state so users never have to assume autosave happened. The metadata — word count, character count, and `Last save: …` time — is **always grey**; only *added* status words carry color. Two parts of it are locale-dependent (detail in `app-integration.md`'s Localization section): the word count is **suppressed** for predominantly-CJK text, leaving characters only, because the alphanumeric-run count degrades to a sentence count where there are no interword spaces; and the timestamp is rendered with `Date.FormatStyle` rather than a fixed pattern, so it follows the reader's clock and month conventions. An untitled/never-saved doc shows red **"Not saved yet"** in the main text (the counts stay grey); an established doc with pending edits shows amber **"Unsaved changes"** in the left indicator slot; a real write flashes green **"Saved"** (manual ⌘S / Save As) or **"Autosaved"** (autosave), fading after ~4s; an external disk reload keeps its pre-existing green **"Updated"** + `arrow.clockwise` flash. Logic lives in `Lineform/Editor/EditorStatusPresentation.swift` (`EditorStatusFormatter.indicator(...)`, `MetadataSegments`, `EditorStatusIndicator`/`Flash`, and `EditorStatusColors`). Dirty state = live `document.text` ≠ the last-written text tracked in `DocumentSaveStatus` (untitled docs are never "dirty" — they're "Not saved yet"). Only real writes (`fileWrapper` → `DocumentSaveStatus.recordWrite`) flash green; **load and external reload deliberately call `markSaved`, not `recordWrite`, so opening/reloading never flashes "Saved".** Manual vs. autosave is classified by a short-lived intent flag set by a ⌘S/⌘⇧S `NSEvent` local monitor (`ManualSaveIntentMonitor`) and the Save As menu button — pure observation that never touches the save machinery; a rare mouse-clicked menu **Save** may fall through as "Autosaved". The red/amber/green colors are appearance-specific (`dark:` selects the variant) and must clear WCAG AA against **every** `Theme.builtIn` background — enforced by `testStatusStateColorsMeetAAAgainstEveryThemeBackground`; if you retune a color, keep that test green.

- **⌘E** toggles Write↔Read (2026-07-18, matching Obsidian's edit/reading toggle): from Write it goes to Read, and from **either** Read or Split it goes to Write (`EditorDisplayMode.toggledWriteRead`, `Lineform/Editor/EditorDisplayMode.swift`) — a stateable two-way flip, not a 3-way cycle. It drives the **existing** mode-switch seam (the same `LineformDisplayModeMenuState`/`setDisplayMode` notification path the toolbar segmented control and the View-menu Mode picker already use), so all three stay in sync automatically. Split has no keyboard shortcut and stays toolbar/menu-only by design. See `docs/superpowers/specs/2026-07-18-view-mode-keyboard-shortcut-design.md`.

- Cross-mode reading-position restore (2026-07-18): switching Write ↔ Read ↔ Split keeps the reader's place instead of jumping to the top, so toggling to compare source vs. rendered is useful. Mechanism: the renderer tags **every** rendered run with a `.sourceSpan` (the SOURCE `NSRange` it maps back to — a single source line for prose/heading runs from `appendLines`, or the WHOLE source span of a multi-line block for non-`.lines` blocks in `render`; a full rendered→source map, finer than `.headingSourceRange`). Both surfaces already report their top-of-viewport position via `onVisibleTopRangeChanged`; the preview now reports the **exact** source offset (from `.sourceSpan`, sub-line precise — it adds the rendered offset within the run, **clamped to the span length** so a position inside a multi-line block can't overshoot past the block, which would mis-restore and bold the wrong outline heading) rather than the nearest heading. Non-`.lines` blocks get their FULL source span (first line start … last line end) via a running `sourceLineCursor` over the block partition (`blockLastLine`), never just the last line. `EditorContainerView.onChange(of: displayMode)` captures that tracked offset (`activeOutlineSourceRange`) and, deferred one runloop tick (the incoming view is created fresh and unsized this cycle), sets the shared `requestedScrollToTopRange`; the incoming Write editor scrolls via `scrollCharacterRangeToTopPersistently` and the Read/Preview view via `MarkdownPreviewTextView.scrollSourceRangeToTop` (maps the source offset back to a rendered position, sub-line precise). **Two load-bearing gotchas, both diagnosed from a scroll trace:** (1) a freshly created Write editor runs its layout-preservation machinery, which schedules a DEFERRED restore pinning the new view to the TOP — it fires a tick or two after the scroll lands and silently clobbers it; cancelling isn't enough (its second pass captured the top anchor locally), so `scrollCharacterRangeToTopPersistently` **re-asserts the target and cancels the competing restores across ~5 ticks**. (2) The explicit jump must bypass `LineformEditorClipView`'s transition lock (`setBoundsOriginBypassingVerticalLock`) or the fresh view's creation lock clamps it to 0. `resetTransientDocumentState` clears `activeOutlineSourceRange`/`requestedScrollToTopRange` **before** a tab switch sets the incoming tab's `displayMode`, so a stale position is never restored into a different document. Restore is exact for plain prose and a close approximation within paragraphs carrying stripped inline markup (source↔rendered sub-line drift; a full char map is the deferred follow-up). **Outline click in Read** no longer force-switches to Write (`jumpToHeading` dropped the `.read → .write` flip): the preview honors the scroll request in place via the same `.sourceSpan` seam.

- **Linked Split scrolling (2026-08-21):** Split starts with Write and Preview physically linked.
  Scrolling either pane moves the other directly from the AppKit bounds notification, in the SAME
  event turn — never through the debounced outline callback or a SwiftUI state round-trip. The
  synchronizer assigns only the source clip view's CURRENT Y directly to the paired clip view. It
  keeps no scroll history and performs no delta derivation, source mapping, proportional conversion,
  glyph query, text layout, animation, or deferred correction.
  Those calculations made rendered blocks appear to reorganize and trail the gesture. A wheel or
  momentum event remains owned only by the pane under the pointer; sending the event to both native
  scroll views creates competing momentum/elasticity states and visible bounce. A lower-right link
  button toggles the link. Unlinking leaves both positions alone; re-linking copies Write's current
  physical Y to Preview once (clamped only to Preview's scrollable bounds), then resumes direct Y
  assignment. `SplitScrollSynchronizer` holds weak
  references to both AppKit text views and uses an application guard while moving the destination,
  so its bounds notification cannot echo back. Split still uses a distinct one-shot request
  binding for EACH pane. While UNLINKED, an outline/mode-restore jump is sent independently to both
  panes; while LINKED, it is sent only to Write and Preview follows Write's physical Y. Sending two
  source-mapped jumps while the physical link is live makes each pane move the other back in turn,
  so the result depends on SwiftUI update order and the editor's deferred restore. Document swaps
  clear both request channels alongside the cross-mode anchor. A mode-switch restore verifies that
  its deferred target mode is still current before publishing, and every request clears the inactive
  mode's channel, so rapid mode changes cannot leave a stale jump waiting for a later view creation.
  SwiftUI can briefly overlap a departing representable with its replacement during a mode switch.
  Each bounds callback therefore carries the concrete source view and is accepted only when it is
  still the synchronizer's connected editor/preview. Both representables also disconnect by identity
  when their synchronizer changes or the view dismantles; a late teardown notification from an old
  pane can never scroll a surviving or newly connected pane.

- Read-aloud / text-to-speech (2026-07-18): **Edit ▸ Speech** submenu (Start Speaking / Pause·Resume / Stop, no default keyboard shortcut in v1) drives a native, offline `AVSpeechSynthesizer` — **no network, no new entitlement**, isolated behind `SpeechController` (`Lineform/ReadingExperience/SpeechController.swift`, an `ObservableObject` state machine — `.idle`/`.speaking`/`.paused` — wrapping a testable `SpeechSynthesizing` protocol) using the **system default voice and rate** (a Reading-Experience voice/rate picker is a deferred follow-up). Speech is never raw markdown: a pure `SpeechTextExtractor.spokenText` (`Lineform/ReadingExperience/SpeechTextExtractor.swift`) walks the same `MarkdownBlockGrouping.markdownBlocks(in:)` used by Read/Preview, strips inline markers (bold/italic/code/link syntax), reads headings/paragraphs/lists/blockquotes/callouts/table cells as plain text and images by their alt text, and **skips fenced code, math, and mermaid blocks** entirely (not readable prose). Since 2026-11-12 it also skips **inline** math (`$…$`, `\(…\)`, and their display forms) via the renderer's own `MathDelimiters.inlineSpans`, so escaped prose such as `see \(note\)` is read as "see (note)" exactly as drawn, and a **code span's contents are spoken verbatim** (never stripped, unescaped, or math-detected) — it had been unescaping them, so `` `\(x\)` `` was read as "(x)". Convert to Plain Text likewise leaves every math span and display block verbatim, delimiters included. See `rendering.md` ("Backslash math delimiters"). Start point: a selection speaks the selection; otherwise it speaks from the caret to the end in Write/Split, or the whole document in Read (no caret there). No spoken-word highlight-follow and no persisted playback position in v1. See `docs/superpowers/specs/2026-07-18-read-aloud-tts-design.md`.

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

## Selections that split a character (2026-07-27)

`MarkdownFormattingCommand.apply` aligns its incoming `selectedRange` to composed-character
boundaries (`composedCharacterAligned`) before any command runs, and every command's arithmetic
depends on that having happened.

The reason is a mismatch between two ways of measuring the same text. Every command computes
offsets in UTF-16, but the edit itself goes through `Range(_:in:)`, which returns `nil` for a range
that splits a surrogate pair or separates a base character from its combining mark. The private
`replace(range:in:with:)` helper treats that `nil` as "do nothing" — so the document came back
**unchanged while the command still returned the selection the edit would have produced**. That
selection points past the end of the shorter, unedited text, and `setSelectedRange` raises on an
out-of-bounds range rather than merely putting the caret somewhere odd. Selecting a run that
clipped half an emoji and pressing ⌘B was enough.

Aligning once at the entry point fixes all eight commands rather than each edit site, which is the
point: the `nil` branch is easy to reintroduce one helper at a time. It is also the behaviour a
person expects — a selection that covers half an emoji grows to cover the whole one. A **caret**
(zero length) is only nudged to the start of its sequence, never widened, or a formatting command
would silently turn a caret into a selection.

Found by fuzzing the commands with emoji, non-BMP scalars, and combining marks
(`RobustnessProbeTests`); the per-feature suites had only ever fed them ASCII. Note that the
neighbouring `MarkdownHeadingEditing` and `MarkdownTableEditing` do not need this — they convert
*computed line and block ranges*, which are aligned by construction, never the user's selection.

## Line endings on insert

Lineform never normalises a document's line endings — rewriting them would change lines the writer
never touched and produce a whole-file Git diff. But every insertion used to emit a bare `\n`, so a
Windows-authored file gained LF lines wherever it was edited and ended up MIXED.
`MarkdownLineEnding.inForce(at:in:)` (`Lineform/Editor/MarkdownLineEnding.swift`) now decides what
to insert, and the four insertion sites use it: plain Return, list continuation, Insert Table /
Tab's appended row, and Reformat Table (which rewrites the table's INTERIOR terminators, so joining
with `"\n"` converted a CRLF table to LF on every ⌃⌘R).

**It reads the LOCAL convention, not a whole-document tally.** This runs on every Return, and a
per-keystroke whole-document scan is the mistake `MarkdownSpellCheckRegions` and
`MarkdownListContinuation` were both built to avoid. Reading the terminator of the caret's own line
costs one line's length — and in a file with mixed endings it also gives the better answer.

**A `hasMarkedText()` guard sends Return straight to `super` while an IME composition is live**, and
it is not theoretical. `insertNewline` is normally unreachable mid-composition — the input context
consumes Return to COMMIT, which is the whole reason this and never `keyDown` is the hook — but that
is a property of the input sources tried, not a guarantee. Driven into a composing state with
`setMarkedText`, the localized edit paths rewrote the marked range out from under the input context:
list continuation produced `- oneか\n- ` and the CRLF path produced `alpha\r\nか\r\n`, writing a line
ending INTO the composition. List continuation has carried that exposure since it shipped; the guard
closes both.

This **is** covered automatically — the earlier claim that it could not be was wrong. The marked-text
API reaches the same state without an input source, so
`testReturnDuringCompositionDefersToAppKitAndLeavesTheCompositionIntact` and
`testListContinuationDoesNotFireDuringComposition` (both verified failing with the guard removed) run
in the default plan. They assert only that OUR paths left no artifact — what AppKit does to a live
composition is AppKit's business and is by definition what every other Mac text view does, so
asserting the resulting string exactly is wrong and was tried and rejected.

`MarkdownTableEditing.locate` also stepped to the next line with `NSMaxRange(line) + 1`, which in a
CRLF file lands on the `\n` still inside THIS line's `\r\n`: `lineRange` returned the same line, the
walk broke immediately, and no table was ever found below the caret — Tab between cells and Reformat
did not work at all in a Windows-authored document. It now steps through the paragraph range, which
includes the whole terminator.

## Line endings in the protection layer

`MarkdownWritingToolsProtection` has its own CRLF handling, separate from the renderer's
`markdownSourceLines(in:)`, because it works on the REAL document text at real offsets and cannot
strip anything. It trims lines with `lineTrimCharacters` (`CharacterSet.whitespaces` **plus `\r`**)
instead: lines are split on `\n`, so the only newline a line can carry is a CRLF's `\r`, and
`.whitespaces` does not contain it. Without that, a Windows-authored file's `$$` never read as a
block delimiter and `---` never opened front matter, so YAML and math were left unprotected —
Writing Tools could rewrite them, the spell checker flagged them, and ⌘1 inside front matter
prepended a heading marker to a YAML key.

**Two implementations must agree.** The whole-document passes trim with `lineTrimCharacters`; the
scoped `CFStringInlineBuffer` walk classifies the same lines through `isWhitespace(_:)`. They are
the same rule written twice for performance, so they move together or not at all —
`testScopedAndWholeDocumentPassesAgreeOnCRLF` is what holds them to it. `\n` is deliberately absent
from the set: a line cannot contain one, and adding it would only make that guarantee less obvious.
`frontMatterRange` accepts `\r\n` on both delimiters while still keying its search off the `\n`
that is present either way.

## Live spell check

Shipped 2026-07-26 (backlog item 2). Design:
`docs/superpowers/specs/2026-07-26-live-spell-check-design.md`. Measurements and the AppKit
probe that decided the shape: `docs/notes/2026-07-26-spell-check-probe-findings.md`.

`configureForMarkdownEditing` turns continuous checking on (from the persisted preference),
autocorrect **off**, and grammar checking **off** — the last two set explicitly, not omitted, so
the omission reads as a decision. The old state was the worst of the four combinations:
autocorrect silently rewrote words while nothing indicated what the checker objected to.

**Suppression.** `checkText(in:types:options:)` splits the incoming range through
`MarkdownSpellCheckRegions.checkableRanges` and calls `super` once per prose sub-range, so a
paragraph containing `inlineCode` still gets its real typos flagged. Suppressed: fenced code,
front matter, math, inline code spans, and link/image *destinations*. Link and image **text is
checked** — it is prose.

**Four things that were paid for in defects:**

(1) **`checkText(in:types:options:)` is the hook, and it is the one AppKit uses for as-you-type
checking** — verified by probe, not assumed. `textView(_:willCheckTextIn:options:types:)` fires
downstream of it, 1:1. Note the delegate method is `willCheckTextIn`, **not** `shouldCheckTextIn`:
the latter compiles, produces only a "nearly matches optional requirement" warning, and is never
called. Its options dictionary is keyed by `NSSpellChecker.OptionKey`.

(2) **Never call a whole-document pass from this path.** `ignoredRanges` is 18 ms at 730 KB and
`MarkdownRangeAnalyzer.ranges(in:)` has the same shape. The first implementation used the
whole-document passes with an `upTo` bound and measured **14.97 ms/call** — it failed the gate in
`MarkdownSpellCheckPerformanceTests`. The shipped version is a single walk that classifies prefix
lines by reading UTF-16 units through a `CFStringInlineBuffer` without allocating; the prefix
contributes only fence and `$$`-block *state*, so the real predicates run only on lines that can
emit a range. 2.26 ms in Debug, ~0.6 ms in an optimized build. **Debug measures ~3.6× slower than
Release** here — do not read a Debug number as what users feel.

**The gate is a RATIO, not a wall-clock ceiling (2026-07-27).** It measures `checkableRanges` and
the whole-document `ignoredRanges` back to back in the same run and requires the scoped path to be
at least **4×** faster; it measures **11.7×** (2.18 ms vs 25.45 ms on a developer Mac), and the
14.97 ms naive version it exists to reject would score barely above 1×. Measurement is best-of-N
batches on a monotonic clock, because scheduler preemption on a shared runner can only ever add
time — a mean absorbs one descheduled batch and reports it as a regression.

It began as an absolute 5 ms ceiling, which read ~2.2 ms locally and 5.5–8.4 ms on a GitHub
`macos-26` runner: **four CI failures in twelve runs, none of them a regression.** Raising the
number would have swapped a flaky gate for a blind one. The ratio takes the hardware out of the
question, so it is both stabler and stricter than any number tuned to one machine. **Do not put a
tight absolute ceiling back** — the remaining 30 ms backstop is only there to catch "everything got
slower at once", which a ratio cannot see.

(3) **AppKit provides no Spelling and Grammar menu, and this app replaces the Edit menu.** Nothing
supplies one for free — verified by dumping the live menu over Accessibility. Without the submenu
added to `AppCommands`, the feature has no off switch and `toggleContinuousSpellChecking` is
unreachable. Likewise `menu(for:)` replaces AppKit's context menu, which is where guesses, Learn,
and Ignore normally live; they have to be added by hand or a flagged word cannot be acted on.

(4) **Toggling has to be applied by hand, in both directions and across windows.** Enabling
checking does not make AppKit re-examine text that is already laid out, so underlines would not
appear until the next keystroke and the toggle would look broken; disabling leaves existing
underlines drawn. `applySpellCheckingEnabled` clears the `.spellingState` temporary attributes and
re-checks the visible range, and a notification broadcasts the change to every open text view —
the preference is app-wide, so two windows disagreeing reads as a bug.

(5) **Two guards in the context-menu path, both found in code review rather than QA.** The range
of the word being corrected is captured when the menu is BUILT (the click location is gone by the
time an item fires) and must be **revalidated against the stored word before editing**: live
reload is a debounced async dispatch and menu tracking runs in a common run-loop mode, so an
external rewrite can land underneath an open menu, leaving a range that points at different
characters or past the end of the text (`NSRangeException`). And right-click must **not** collapse
the selection onto the word when a non-empty selection already contains it — this menu also
carries Bold/Italic/Link, which act on the selection, so stealing it silently changes what they
format. Applying a correction then **resizes** that preserved selection by the length delta rather
than collapsing it, or the guard defeats itself the moment a suggestion is used. Only a selection
that *fully contains* the word is preserved; a partial overlap has its start shifted by the
replacement too, so it falls back to the caret rather than being subtly wrong. All three
decisions are pure functions on `LineformTextContextMenuPresentation` with regression tests.

**Suggestions show one candidate, not the whole list.** `NSSpellChecker.guesses` is a broad
phonetic net — for "teh" it returns the, ten, tbh, tex, feh, yeh, tea, ted — and listing them
buries the answer in noise. The list is ranked, so the first entry is the real candidate.
`NSSpellChecker.correction(forWordRange:…)` is preferred when present, but it returns nil whenever
the **system-wide** "Correct spelling automatically" setting is off, which is unrelated to this
app and cannot be depended on. The full list stays available at Edit ▸ Spelling and Grammar ▸ Show
Spelling and Grammar (⌘:).

The inline candidate list (`isAutomaticTextCompletionEnabled`) is **off**: it is a floating pill of
alternatives near the caret, defaults on, and becomes visible only once continuous checking is
enabled — so turning checking on silently introduces an unfamiliar hover-revealed control.

Spell checking routes through the system `NSSpellChecker` and nothing else — on-device, no
network. Corrections use the localized undoable path, so one ⌘Z reverses one correction.

## Table authoring

Three affordances, all built on the parser the renderer already uses: **Insert Table** (⌃⌘T)
writes a 3×2 skeleton, **Reformat Table** (⌃⌘R) aligns the pipes of the table under the caret,
and **Tab / Shift-Tab** move between cells inside a table. The decision surface is
`MarkdownTableEditing` — pure over `(text, selectedRange)`, no AppKit — so all of it is testable
in the default plan without a window. `LineformTextView` only applies outcomes.

**Detection delegates to `MarkdownTableParser`; it does not reimplement it.** `locate` walks the
maximal run of pipe-bearing lines around the caret, then picks the first line whose successor is a
delimiter row with a matching cell count — the same line `markdownBlocks` would settle on
(`MarkdownBlockGrouping.swift:427-444`). This is the `FileIdentity` lesson applied to a different
pair: if the editor's idea of "a table" and the renderer's ever diverge, Tab intercepts a
construct the reader never saw as a table, and Reformat rewrites it. The maximal-run detail
matters — a paragraph line that happens to contain a pipe can sit directly above a table, and the
renderer treats it as prose, so `locate` must too.

**Two different undo paths, deliberately.** Insert and Reformat are one-shot commands and go
through `applyWholeTextReplacement`, like Bold and Link: one ⌃⌘T, one ⌘Z. Tab is a per-keystroke
edit, so it must never touch that path. Most Tabs are `.select` and edit *nothing at all* — no
write, no undo step, no autosave churn — and the only Tab that writes, appending a row off the
last cell, uses the localized `replaceCharacters` path that list continuation established.

**Guard ordering is a performance requirement, not style.** Tab fires on a key the writer uses
constantly, so the first test is line-local `looksLikeRow`, which fails for essentially all prose
and costs one `lineRange`. Only after that, and after the block-local delimiter check, does the
whole-document `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter` scan run — the same
cheap-first ordering `MarkdownListContinuation` uses. A pipe table inside a fence is code and is
never navigated or rewritten.

**Reformat refuses rather than risks the file.** `MarkdownTableParser.cells(in:)` splits on every
pipe; escaped pipes are a known v1 limitation. That is harmless while *rendering* — the wrong
split shows a wrong cell and nothing is lost. Reformat **writes the result back to disk**, so the
same wrong split is permanent. It therefore declines outright on `\|` or on any backtick in the
region. The backtick half is deliberately over-broad: it passes up some tables it could safely
rewrite, and it never destroys one.

**Padding is APPENDED, never `String.padding(toLength:)`.** That method bridges to NSString and
measures in UTF-16 units, while `columnWidths` measures in Characters — so it silently TRUNCATED
every cell whose two measures disagree. `| 😀😀😀😀 |` came back as `| 😀😀 |`, and a decomposed
`café` as `cafe`, and Reformat writes that to the file. Appending `max(0, width - count)` spaces can
only ever add characters, so a cell is now impossible to shorten. Guarded by
`MarkdownTableEditingTests` and by the parsed-table round trip in `MarkdownRobustnessTests`.

**Delimiter colons are re-emitted from the original row, not from `table.alignments`.** The parser
maps both `---` and `:--` to `.left`, which is correct for rendering — they are identical there —
so rebuilding the delimiter from the parsed alignment silently erases every explicit-left
delimiter in the file. Caught by a test, not by QA; the rendered output would have looked fine.

**Reformat returns `nil` when the table is already aligned.** That is how idempotence is
expressed, and it is stronger than "produces the same string": a second ⌃⌘R registers no undo step
at all. A no-table, refused, or already-aligned Reformat is silent — no alert, no disabled menu
item. Disabling would mean `validateMenuItem:` plumbing through the responder chain for a command
whose only failure mode is "nothing happened".

**Tab geometry.** `contentRanges` mirrors `cells(in:)` but keeps the positions the parser throws
away. Tab selects a cell's *trimmed content* so typing replaces it; an empty cell yields a
zero-length caret where content would start in a reformatted row, not jammed against the pipe.
Navigation skips the delimiter row in both directions — nobody wants to Tab into `---`. Shift-Tab
at the head of the table is a consumed no-op (`.stay`), because inserting a literal tab there
would corrupt the construct. That case is named `stay` rather than `none` on purpose: `tabTarget`
returns `TabOutcome?`, and a bare `.none` would resolve to `Optional.none`, which means the
opposite — fall through and insert a tab.

A caret ahead of the first cell (⌘← puts it before the opening pipe) matches no cell at all. That
must select the *first* cell, not be folded into "already in cell 0", which skipped straight to the
second. Found in review, after the tests were green.

**Tab everywhere else is untouched.** The intercept only fires inside a real table, so a literal
tab still inserts in prose. That fall-through is the whole reason Tab could be claimed here when
list continuation deliberately left it alone. Like list continuation, the key path is not gated on
`textFormat` — only the menu rows are.

**The padded pipes will not visually line up in Lineform itself**, because the editor renders in a
proportional font. This is not a bug and should not be "fixed" by measuring display width: the
payoff is the *file* — aligned source reads correctly in any monospace editor and produces clean
Git diffs, which is the "real files" product thesis. Widths are grapheme counts, so CJK and emoji
cells under-pad; that is a known and accepted limitation of the same kind.

## Heading levels

⌘1–⌘6 set the heading level of the lines a selection touches, ⌘0 returns them to body text, and
pressing a line's current level clears it. `MarkdownHeadingEditing` owns the whole transform; it
is pure and AppKit-free, so it lives in the default test plan.

This shipped as a bug fix wearing a feature's clothes. The previous `.title` / `.section` commands
routed through `prefixSelection`, which prepended `"# "` to the **raw selection**: ⌘1 on
`## Section` produced `# ## Section` — not a heading in any dialect, invisible to
`MarkdownHeadingParser`, and therefore a line that silently vanished from the outline sidebar. A
caret mid-word split the word. Changing the level of a line that is *already* a heading is the
most common heading motion there is, so the shipped feature was broken on its main path.
`prefixSelection` is gone; both commands now route through this unit, which is why the fix reaches
⌘1 and ⌘2 and not only the new keys.

**Heading detection is local and does NOT reuse `MarkdownHeadingParser.heading(in:)`.** That
parser requires a non-empty title, so it reports `nil` for `"## "` — a heading whose text has not
been typed yet. Reusing it would classify that line as prose and prepend a second marker,
reintroducing the exact stacking bug this unit exists to remove. The local scanner accepts
1–6 hashes followed by a space **or end of line**. The two agree on every line that has content,
which is the only case the outline sidebar ever sees.

**`classify` and `MarkdownHeadingParser` must accept the same shape** — they are the write side and
the read side of "this line is a heading", and a disagreement means a command rewrites a line the
reader never saw as a heading, or leaves one the outline sidebar cannot see. Both now take up to
three columns of leading space and a space, a **tab**, or end of line after the hashes. The tab was a
live instance of the stacking bug: `##\tSection` is a real CommonMark heading, the parser rejected
it, and ⌘4 emitted `#### ##\tSection`. A heading the command writes always uses a space separator.
Guarded by `testHeadingDetectionAgreesWithTheOutlineParser`.

**The skip list is line-local first, protection second.** Blank lines, list items, blockquotes,
indented code blocks (four *columns* — a tab counts as four, or a tab-indented block reads as
prose), and fence delimiters are recognised from the line alone. List and blockquote detection
reuses `LinePrefix` from `MarkdownListContinuation`, promoted from `private` for exactly this —
one definition of "what markers start a line" rather than two that drift.

Fence *delimiters* need their own line-local check: `isInsideCodeOrFrontMatter` reports the
opening ``` as outside the block it opens, so without it the opening fence took a marker and broke
the block. A test caught this; it was not anticipated.

**Never call `isInsideCodeOrFrontMatter` per line.** It rescans from the start of the document on
every call, so a per-line loop makes Select All + a heading key quadratic in document length. The
block is classified with ONE scoped `protectedRanges(in:intersecting:)` pass instead.

**All-or-nothing decides the toggle direction.** A multi-line selection clears only when *every*
editable line already sits at the requested level; otherwise everything is raised to it. Without
that rule a mixed selection half-toggles and no second press ever returns it.

**A no-op returns `nil` and never reaches `applyWholeTextReplacement`** — the `reformatMarkdownTable`
precedent. A dead keypress must not leave an empty step on the undo stack.

**Selection follows the text, not the line.** The start shifts by the first touched line's marker
delta and the length by the deltas inside it, so `"Lineform"` selected whole stays selected whole.
A caret keeps its offset within the line's own content; a caret sitting *inside* markers being
rewritten is clamped to the new content start, which is the only honest place left for it.

## Outline fence tracking (2026-07-27)

`MarkdownOutlineParser` tracks fenced code with `MermaidFence.openingMarker` /
`isClosingFence` — the same CommonMark matching `markdownBlocks(in:)` uses — and splits with
`markdownSourceLines(in:)`. It is a second *caller* of that rule, never a second definition.

It used to toggle a flag on any line starting with ` ``` ` or `~~~`, and that disagreed with the
renderer on documents that are entirely ordinary: any note *about* Markdown, where a longer fence
wraps a shorter one, or a ``` block quoting a `~~~` line. The toggle closed on the inner delimiter,
so the rest of the block's `#` lines were listed as headings that do not exist — and, because the
state was then inverted for the remainder of the document, every real heading after it was
swallowed as "code" and disappeared from the sidebar. Clicking one of the phantom entries scrolled
into the middle of a code block.

Found by asserting the agreement directly rather than by reading either side:
`OutlineAndInsertionProbeTests` fuzzes fence-shaped documents and checks **both** directions — no
listed heading may sit inside a renderer-classified fence, and every heading the renderer treats as
prose must be listed. Both halves failed on the first run. `characterRange` still spans the line's
own text (excluding a CRLF `\r`), which is what the scroll restore expects.

## Editor-side fence tracking (2026-07-27)

The outline fix above closed one caller. A sweep for the same shape — *every* place that carries
fenced-code state across lines — found four more, all on the editor side, all invisible to the
suites because every fixture used one fence length:

- `MarkdownWritingToolsProtection.fencedCodeRanges` and its unit-level twin inside
  `protectedRanges(in:intersecting:)` compared `String(trimmed.prefix(3))`, so they matched the
  delimiter *character* but not the run *length*.
- `MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter` — the per-keystroke check — did the
  same, via `fenceMarker`.
- Both math passes toggled a plain `inCodeFence` flag on any fence line, so they did not even
  match the character.
- `MarkdownSyntaxHighlighter.markdownBlockSpacingLineIndexes` and
  `SpeechTextExtractor.appendLineRun` toggled the same way.

The consequence is worst in the ```` ```` ````-wraps-```` ``` ```` shape, which is what every note
about Markdown looks like. The renderer kept the block whole; these passes ended it at the first
inner ` ``` `. So Writing Tools could rewrite embedded code, the spell checker underlined it, and
`isInsideCodeOrFrontMatter` told the heading and list-continuation commands that a code line was
prose — the same class of disagreement as the outline bug, reached from four more directions.

All of them now go through `MermaidFence`. The two hot paths that cannot bridge a `String` per line
use `FenceMarker`/`FenceRun`, a UTF-16 twin of the same rule; the added work is a run count on lines
that already matched three delimiter characters, so `MarkdownSpellCheckPerformanceTests` is
unaffected.

Pinned by `MarkdownWritingToolsProtectionTests`: the scoped walk and the whole-document pass must
agree on a corpus of fence shapes (that is what ties `FenceRun` to `MermaidFence`), and
`isInsideCodeOrFrontMatter` must agree with `ignoredRanges` at every offset.
`MarkdownRobustnessTests` then pins the *product* answer — for one nested-fence note, the outline,
the block grouper, HTML export, and read-aloud must all place the end of the code block in the same
spot.

## Image insertion and line endings (2026-07-27)

`ImageInsertionText` terminates the line it adds with `MarkdownLineEnding.inForce(at:in:)`, like
every other insertion path. It wrote a bare `\n`, so dropping or pasting an image into a
Windows-authored file left a lone LF in it — the document's endings being normalised a line at a
time, which is the one thing insertion must never do. The line-endings class had been closed over
Return, list continuation, and the table commands; this path was simply never in the sweep. When
adding a new path that writes a line, add it to `testImageInsertionPreservesCRLFEndings`'s
neighbourhood rather than trusting the invariant to be remembered.

## Ordered-list markers and the renderer's cap (2026-07-27)

`LinePrefix.scanOrdered` scanned digits without a bound and then emitted `number + 1`. Two defects
came out of the same line:

- **A crash.** A line beginning `9223372036854775807. ` parses to `Int.max`, and the increment
  trapped. Return on that line killed the app — no alert, no autosave, whatever was unsaved in
  other tabs gone with it.
- **A disagreement with the renderer.** `MarkdownBlockGrouping`'s list regex is `[0-9]{1,9}` —
  CommonMark's cap. A 10-digit marker therefore drew as a *paragraph* while Return continued it as
  a list, so the editor was maintaining a construct the reader could not see.

The scan is now bounded at nine ASCII digits, which makes the increment total *and* makes the two
definitions agree. It also stopped using `CharacterSet.decimalDigits`, which contains Arabic-Indic
and Devanagari digits that no renderer treats as a list marker.

The same pass fixed the separator: the renderer accepts `[ \t]+` after a marker and `LinePrefix`
accepted only a space, so `-\titem` drew as a bullet but Return dropped out of the list.

`InteropProbeTests` asserts both directions against the renderer's cap. The suite missed all of
this because every ordered-list fixture in it used a one- or two-digit marker and a space.

## Table Reformat's caret in a CRLF document (2026-07-27)

`caretAfterReformat` rebuilds the table's line ranges from the replacement text so it can put the
caret back in the cell it came from. It split on `\n` and kept each line's trailing `\r`.
`MarkdownTableRegion.lineRanges` excludes terminators by contract, and `contentRanges` reads a
`\r` as ordinary cell content — so a CRLF table gained a phantom trailing cell per row and ⌃⌘R
left the caret a column away from where the writer was typing.

The rebuild now drops a trailing `\r` from each range's length while still stepping over it. The
existing CRLF table tests all asserted the resulting *text*, which was correct throughout; only the
selection was wrong, and nothing was checking it.

## Document model and autosave (audited 2026-07-27)

Four defects, all rooted in `textFormat` doing two jobs — "this file is a `.txt`" and "this text has
been converted to plain" — plus one stat that lied.

**Live reload fired at most once per file.** `LineformDocument.modificationDate(at:)` read
`url.resourceValues(forKeys:)`. `URL` caches resource values on the instance, and
`DocumentReloadController.startWatching` early-returns while the path is unchanged, so it stats the
SAME `URL` value for the life of the watch. After the first applied snapshot the date never changed
again and `reloadFromDisk`'s `modificationDate == lastSeen` pre-check skipped the read forever: an
agent rewriting the open `.md` produced no reload and no "Updated" flash, and the editor kept showing
— and autosaving — the stale text. Now stats through `FileManager.attributesOfItem`, which has no
per-instance cache. The suite missed it because every `DocumentReloadControllerTests` fake returns a
stored constant from `modificationDate(at:)`, so `FileSystemDiskReader` was never exercised;
`testUnchangedModificationDateSkipsFullRead` actually enshrined the blind spot. There is now a test
using the real reader against a temp file.

**A UTF-8 BOM was dropped on read and never re-emitted.** `String(data:encoding:.utf8)` strips a
leading U+FEFF on Darwin, so the mark never reached `document.text` and `markdownData()` could not
put it back — the first write of any kind rewrote the head of every Notepad-authored file. Decoding
now validates with the failable initializer (so invalid UTF-8 is still rejected, not repaired) and
decodes with `String(decoding:as:)`, which preserves the mark. `FileSystemDiskReader.readText` uses
the same pair, or a BOM'd file would compare unequal to its own in-memory text and reload on every
save. This is also what makes the existing BOM handling in the parsing layer reachable on real files.

**`data(for:)` and `recordsSourceSave(for:)` disagreed in exactly one cell.** For a `.md` document
left in `.plainText` by Convert to Plain Text, the write emitted the source verbatim while
`recordsSourceSave` returned false, so `recordWrite` never ran: no "Saved" flash, "Last save:" frozen
at open time, a permanently amber status bar, and — through the `savedAt` observer —
`lastSyncedText` never refreshed, which disables live reload and the `activateSelectedTab` disk
reconcile. Both now derive from one `writesSourceVerbatim(for:)`. The old test asserting
`recordsSourceSave(for: .markdownText) == false` for a plain-text document was asserting the bug and
has been corrected; a new test iterates all four `(textFormat, contentType)` pairs and asserts the
two agree.

**Convert to Markdown corrupted a plain-text file.** `restoreConvertedMarkdown` set
`textFormat = .markdown` even with no stored conversion. A `.txt` opened from disk has exactly one
Format row — "Convert to Markdown" — and clicking it left the document in the state whose next write
takes `plainTextData()`, running the Markdown stripper over the user's file: both ``` lines deleted,
link URLs gone, every leading marker stripped. It now only flips when a conversion actually restored.

## Speech transport (audited 2026-07-27)

All four findings here were produced by probing the real `AVSpeechSynthesizer` rather than reading
the code, and all four survived an independent refutation pass. Two of them are the same shape as the
rest of this audit: a test fake that models what the source BELIEVES instead of what the framework
DOES, so the suite certified the bug.

**A stopped utterance reports `didFinish`, not `didCancel`.** The `SpeechSynthesizing` contract and
the `didCancel` comment both asserted the opposite. Because `stop()` and `speak()` are issued
back-to-back with no runloop spin, the stopped utterance's `didFinish` arrived ~30 ms later — after
`startSpeaking` had already set `.speaking` for the NEW utterance — and clobbered the transport to
`.idle` while audio was playing. Pause and Stop then greyed out with no way to stop the sound, and
because `state == .idle` a further Start Speaking skipped the `if state != .idle { stop() }` branch
entirely, so the next passage QUEUED behind the still-playing one (measured 4.45 s to silence for a
word that takes 0.8 s alone). `SystemSpeechSynthesizer` now tracks `currentUtterance` and forwards
`didFinish` only for it — an identity check, not a guess about which delegate method means what.

**`pauseSpeaking(at: .word)` is asynchronous.** A `continueSpeaking()` issued before the pause landed
returned `true` and was then overtaken by it, leaving audio permanently silent while `state` said
`.speaking` and the menu row read "Pause". The transport now keeps `state` as the user's INTENT (set
optimistically, so the menu responds to the click) and reconciles against the real
`didPause`/`didContinue` callbacks: a pause that lands when the intent is `.speaking` is immediately
undone, and vice versa.

**Read-aloud could be handed a range from the wrong text view.**
`LineformAppNotification.activeWindowPayload` cast `firstResponder as? NSTextView`, which also
matches an `NSSearchField`'s field editor and the Split-mode preview pane. Pressing ⌘F selects the
field's whole contents, so Start Speaking read only the first `query.count` characters of the
document; and a selection in the rendered preview is in RENDERED coordinates, which
`speechSource` explicitly refuses to substring source text with — but its guard covers `.read` and
`.split` is a different mode. Narrowed to `LineformTextView`. Convert to Plain Text reads the same
payload and wanted the same narrowing.

**Speech outlived its document.** `stop()` was wired only to `NSWindow.willCloseNotification`, but a
tabbed, sidebar-navigating window replaces its document without the window closing. Starting
read-aloud and then clicking another file in the sidebar left the previous document being read to the
end, with the menu's Pause/Stop acting on a document no longer on screen. `stop()` now runs from
`resetTransientDocumentState()`, the single choke point every document swap goes through — the same
place, and for the same reason, that the stale cross-mode scroll anchor is dropped.

## LinePrefix, the plain-text converter, and the perf gate (verified 2026-07-27)

Gaps found by adversarially verifying the same day's own fixes. See `rendering.md` for the two
data-loss ones in `MarkdownPlainTextConverter`.

**Return wrote a byte-order mark into the middle of the document.** `LinePrefix.scanWhitespace`
learned to skip a leading BOM so a BOM'd file's first line would continue as a list — but the caller
still captured `indent` from index 0, so the mark travelled into the continuation. Pressing Return on
`<BOM>- milk` inserted `\n<BOM>- `, and `markdownSourceLines` strips a BOM only at index 0, so the
new line kept a literal U+FEFF: `MarkdownBlockGrouping`'s list regex no longer matched, and the
bullet the writer had just created drew as a paragraph while the editor still called it a list —
the exact editor/renderer split the fix set out to close, reproduced one line down. `Data(text.utf8)`
then autosaved the bytes. The mirror case was worse: on a document that is only `<BOM>- `, Return
returned `.terminate(clearing:)` over a range covering the BOM, silently stripping the file's mark.
The scan is now split into `scanByteOrderMark` and `scanWhitespace` so a caller can skip the mark
without capturing it.

**A bare list marker was a list to the editor and a paragraph to the renderer.** `scanBullet` and
`scanOrdered` only checked a separator `if cursor < ns.length` — so a line that is exactly `-`, `*`,
`1.` or `1)` matched with empty content, and `outcome` returned `.terminate(clearing: lineRange)`:
pressing Return at the end of that line ERASED the character the writer had just typed.
`MarkdownBlockGrouping` requires `[ \t]+`. The separator is now required, not merely accepted when
present.

**`isInsideCodeOrFrontMatter` disagreed with its siblings about what a line is.** It walked with
`NSString.getLineStart`, which breaks on a lone `\r`, U+2028 and U+0085 as well as `\n`, while
`ignoredRanges`, `protectedRanges(in:intersecting:)` and the renderer all split on `\n` only. In a
document containing any of those (a paste from InDesign or some web sources inserts U+2028) it
reported "inside fenced code" for text drawn as prose — and `MarkdownListContinuation` and
`MarkdownTableEditing` gate on it, so Return-continuation and Tab-between-cells silently stopped
working there.

**The perf gate measured half the real cost.** Its fixture pinned the caret to the document
MIDPOINT, described in the source as "the worst case for the prefix walk". It is not: the walk runs
from offset 0 to `NSMaxRange(scope)`, so cost is linear in how far in the caret sits and the worst
case is end of file — which is also where a writer drafting a long document actually types. Measured
at 0.0114 ms per KB of prefix, exactly 2.00x from midpoint to EOF. The gate could not see a
regression confined to the second half of a file, and the headroom above its 4x floor was half what
the commit message claimed. The fixture now measures the last line.

## History (2026-11-12)

Per-passage version History: right-click a selection ▸ **Add to History** keeps the passage's
current text as a version; History mode (the sidebar's History tab, or **View ▸ History**, ⌘Y)
shows passages with history and steps their versions. Spec:
`docs/superpowers/specs/2026-11-12-bring-your-own-ai-design.md` §5–§6. Pieces:
`PassageHistoryStore.swift` (store), `DocumentHistoryEngine` (passages, live ranges, versions),
`DocumentHistoryController` (one per editor window; the only thing that applies History's edits),
`LineformTextView+History.swift` (drawing, keys, applying edits), `HistorySidebar*` (sidebar).

- **Never in the document file.** The store is JSON under
  `~/Library/Application Support/Lineform/History/` (inside the sandbox container): `index.json`
  maps `FileIdentity.key` plus a bookmark to a `<uuid>.json` per document. Nothing is written until a
  version is actually kept. Cleanup: a deleted (or Trashed) file's entry goes, a passage no longer
  found is dropped, a passage untouched for 30 days (`FilePassageHistoryStore.staleInterval`) is
  dropped — `prune` runs once per app session, at the first document open, never at launch, on a
  background queue (opening never waits for it; the bookmark/folder checks run outside the store's
  lock). A file counts as deleted only on POSITIVE evidence: its bookmark resolves into the Trash,
  or its folder can be listed and the file is not in it (`FilePassageHistoryStore.confirmedMissing`).
  An unplugged drive, an unmounted network volume or a folder the sandbox cannot read proves
  nothing — that history stays until the 30-day rule. Bookmarks resolve `.withoutUI` and
  `.withoutMounting`. The store also persists on quit (`NSApplication.willTerminateNotification`)
  and window close, observed by the controller itself (not `applicationDidFinishLaunching`).
  **Settings ▸ Clear History** calls `DocumentHistoryController.clearAllHistory(in:)`: the store's
  `clearAll()`, then `didClearAllNotification` (object: the store), on which every controller on
  that store runs `reloadFromStore()`. `reloadFromStore` replaces the engine BEFORE leaving
  History mode, because leaving saves — the other order wrote the cleared history straight back
  (`SettingsClearHistoryTests.testClearHistoryCallsClearAll` catches it).
- **Normal writing draws nothing.** No counters, tints, or underlines outside History mode. The receded
  ink in History mode is a layout-manager TEMPORARY attribute; the text storage is never touched.
- **One source of user edits.** `LineformTextView.shouldChangeText(in:replacementString:)` is the
  only place user edits reach History: after AppKit allowed the edit, before it lands, in the
  coordinates of the text before it (attribute-only changes, `replacementString == nil`, are not
  edits). History's own edits run inside `performHistoryEdit {}` so they are not reported back as
  typing (which would leave History mode) nor as edits (the engine already moved its ranges).
  **Every reported edit is trimmed to its minimal changed span first**
  (`noteHistoryUserEditIfNeeded` → `HistoryUndoCollapse.unambiguousEdit` of the replaced text
  against the replacement; it reads only the replaced range). That is what makes the text view's
  whole-text path safe: formatting commands, heading keys, list toggles, Insert/Reformat Table and
  Find & Replace replace the whole text, and NSTextView UNDOES and REDOES those as one
  document-spanning `shouldChangeText`. Reported untrimmed (the 2026-11-12 final review), that
  straddled every passage: after any save (which re-locates) one ⌘Z on a ⌘B dropped all history.
  Trimmed, passages outside the change keep their live ranges. **The trim never guesses a
  placement.** When inserted or deleted text repeats next to itself the change can sit at several
  offsets: deleting the first of `Keep this. Keep this. Keep this. End.` trims prefix-first to
  {22,11} but suffix-first to {0,11}. Reporting the greedy prefix-first one left a passage on the
  second sentence at {11,10} — now the original THIRD sentence, identical text, so verification
  passed and ← / → rewrote the wrong sentence (the insertion mirror left a passage on a newly
  inserted copy). `unambiguousEdit` computes both placements; when they differ it reports their
  UNION (earliest start to latest end, replacement rebuilt so the result text is identical), so
  every passage overlapping the ambiguous region straddles the edit and is dropped — history may
  disappear, wrong text may not. Ordinary typing has one placement and is reported exactly as
  before. The exit collapse is built with `unambiguousEdit` too: its ⌘Z / redo run outside
  `performHistoryEdit` and are reported against live ranges. Normally the version undo and the
  redo bracket clear those first, but a session that DELETED a version registers neither, so an
  ambiguous prefix-first collapse's undo left a passage on an identical earlier sentence. Such an
  exit now registers `registerInvalidationBracket` (live ranges forgotten after the text undo and
  before the text redo) and the collapse straddles any ambiguous region.
  Writes that bypass the text view
  (they set the binding) still call `noteWholeTextReplacement()` / `engine.invalidateLiveRanges()`
  and passages are re-found literally: live reload, Convert to Plain Text / Restore Markdown, the
  Read-mode checkbox toggle, and image Reconnect. A new binding writer must do the same.
- **Tracking is by live ranges.** Passages carry live ranges moved by every reported edit. Text is
  searched only when a document opens, after a reload, or after an invalidation, and only
  LITERALLY (the current version's exact text). Any doubt drops the passage: the failure mode is
  "history quietly disappears", never "the wrong text is replaced". Overlapping non-nested passages
  are rejected at locate time. `PassageHistoryText.locate` REFUSES to choose between identical
  occurrences unless the best context score leads the runner-up by `max(4, 25% of best)` — a tie
  went to the first occurrence until the final review, so a step could rewrite a "quick" the writer
  never selected. `_` is a word character there (`foo` never matches inside `foo_bar`).
- **Undo.** History-mode steps are applied with undo registration disabled, and while History mode
  is up the representable's coordinator vends a stand-in EMPTY `UndoManager` (`undoManager(for:)`),
  because the tab's real stack holds edits in entry-text coordinates and ⌘Z would replay one against
  the stepped text. On exit (`applyHistoryExit`) the entry text is restored with registration off,
  then one collapsed, minimal edit (entry → exit, `HistoryUndoCollapse.unambiguousEdit`, widened to
  Character boundaries so CRLF and a BOM outside the change are never rewritten) is applied through
  the normal undoable path, and a version-restore undo action is registered in the same group. One
  ⌘Z after leaving restores both the entry text and each passage's current version. A REDO bracket
  is registered in that group just BEFORE the collapse (`applyHistoryExit(beforeCollapse:)`), so on
  redo it runs first: it makes the exit versions current and clears the live ranges before the
  collapse's text redo. Without it the text redo ran first against ranges a save had re-found for
  the entry text, and a collapse spanning several passages dropped them all (undo → save → redo).
  The version-restore action and the bracket are skipped after a version was deleted in the session
  (indices shifted).
- **History mode holds no selection and shows no caret.** Entering collapses the selection
  (`applyHistoryDisplay`) and the `setSelectedRanges` override (`historyClampedSelection`) refuses
  any non-empty one for the whole mode (⌘A included); the caret is hidden
  (`shouldDrawInsertionPoint` / `hidesInsertionPointForHistory`) and, when a passage is selected,
  parked at that passage's END, so the keystroke that leaves inserts there. Found by hand: ⌘B, ⌘S,
  ⌘Z leaves the WHOLE document selected; History-mode clicks never reach `super.mouseDown`, so the
  selection survived and the first keystroke (leave, then type) replaced the entire document.
  `refusesHistoryModeReplacement` is the backstop: a user edit in History mode that would replace
  a surviving non-empty SELECTION (`range == selectedRange()`) with text is refused (mode left,
  caret moved to its end). Only that: a first version refused every range-replacing edit and so
  silently threw away ⌘B/⌘I, ⌘0–⌘6, Insert/Reformat Table, Find & Replace and spelling
  corrections issued in History mode — those leave the mode and apply.
- **History-mode visuals (2026-11-12, owner-approved "C + A").** Entering: unchanged text
  receded (`recededInk`, ≥ 3.0:1), passages with history full ink on a gray wash (`tint`, hover
  `hoverTint` drawn opaque); no counters, so NOTHING reflows on entry. Focus (a passage clicked):
  no fills and no blue — the focused passage keeps the full ink, every other passage drops to
  `focusOtherInk` (0.38, ≥ 2.5:1; the hovered one to `recededInk`, so it reads as clickable), and
  unchanged text to `deepRecededInk` (0.22, ≥ 2.0:1). `HistoryPaletteTests` asserts the floors,
  their order, and AA for the focused text and counter on every theme. All inks are temporary
  layout-manager attributes.
- **The counter** ("current/total", `HistoryCounter.text`) appears ONLY on the focused passage,
  after its last non-whitespace glyph: 10pt medium tabular numerals (`HistoryCounterLayout`),
  3pt after the glyph, cap-aligned with the text, full ink. Its room is RESERVED so it can never
  overlap text: extra `.kern` on that one character (`HistoryCounterSpacing`), written straight to
  the text storage the way the highlighter writes attributes — never through `shouldChangeText`,
  with undo registration disabled — and tagged with a marker holding the kern it replaced, so it
  is removed exactly when focus moves or History mode ends. The highlighter's `setAttributes`
  wipes it, so every highlighter pass calls `reapplyHistoryCounterSpacingIfNeeded()` — WITHOUT
  layout preservation (it restores the layout already on screen; anchoring there captured the
  unkerned layout and scrolled a line per pass when the reserved room wraps the passage). The reflow
  runs inside `preserveVisibleLayoutAnchorDuring(anchoringCharacterAt:)` on the focused passage's
  first character, so its first line stays where it was on screen. Enter → focus → exit leaves the
  string, the file, the undo stack and every kern value unchanged, and posts no text change
  (`testEnterFocusExitNeverChangesTheDocument`). Nested passages: only the focused one shows a
  counter. Rejected 2026-11-12, do not retry: version dots under the first word (in every
  position tried: hugging the line, centred in the gap, trailing) and the blue selection fill.
- **Edits go through the localized path** — `shouldChangeText` → `textStorage.replaceCharacters` →
  `didChangeText` — never `applyWholeTextReplacement`.
- **Leaving.** Esc, another sidebar tab, Read or Split mode, typing (the first keystroke leaves and
  types), switching documents, and live reload (reload wins: History mode closes WITHOUT the
  collapse, and passages are re-found). View ▸ History toggles: it enters (showing the sidebar) or
  leaves. It is enabled only while the key window's document has history
  (`LineformHistoryMenuState`, pushed by `HistoryMenuHandlers` in `EditorContainerView`).
- **History follows the file.** Sidebar file and folder renames (`retarget` /
  `retargetDirectory`, so stored history of files that are not open follows a folder rename too),
  and a Finder/iCloud move of the open file (`onExternalMove`). Save As retargets in the
  `NSDocument` save COMPLETION handler — not the async URL check — and only when the saved tab is
  still the selected one; an untitled document's first save stores its in-memory history then
  (`documentGotFile`). A Finder rename of a file open only in a BACKGROUND tab is not followed in
  the session; the store re-finds it by bookmark at the next launch's prune.
- **Untitled documents** keep history in memory only, and only while they stay the active
  document: a tab or sidebar swap, or closing, discards it — there is no file to key it to.
- **Accessibility.** History mode's click and arrow-key paths are hit-tested, so the text view
  offers them as `accessibilityCustomActions` while (and only while) History mode is on: Select
  Next/Previous Passage, Previous/Next Version, Exit History (`HistoryModeAccessibilityAction`).
  A sidebar version row's Delete from History is in its context menu AND its `.accessibilityActions`,
  both built from `HistorySidebarPresentation.rowActions`.
- Shortcut: ⌘Y (Safari's Show History). Checked against every main-menu row with
  `LINEFORM_DUMP_MAIN_MENU=1`, whose dump now prints each row's shortcut; 48 rows carry one and no
  two collide.

## AI actions and review (2026-11-12)

Bring-your-own AI (spec `docs/superpowers/specs/2026-11-12-bring-your-own-ai-design.md` §4). The
connection and network side is in `app-integration.md` § Bring your own AI; this section is what an
action does to the document. The two sections after it cover the text-view and overlay detail.

- **State machine** (`AIActionController.State`): `idle → running(action, provider) →
  reviewing(session) | marking(ranges) | message(text) → idle`. `run` is a SILENT no-op unless
  connected, the selection is non-empty, nothing is running or under review, and History allows it
  (`DocumentHistoryController.allowsAIAction`: not in History mode, not inside a `.word` passage).
  It then builds the request, checks `AILimits` (≤ 400 segments, ≤ 24,000 UTF-16 units of prose,
  else "Select less text"), and only THEN calls `resolvedConnection()` — the one Keychain read —
  and the client. A generation token makes any reply after cancel/abandon a no-op. Write mode only;
  an action chosen in Split switches to Write as it starts; leaving Write ends the review.
- **What is sent.** Only `MarkdownStructureMap.proseSegments` of the selection — one JSON
  `{"action":…,"segments":[…]}` user message behind a fixed English system prompt
  (`AIActionPrompt`, deliberately not localized: it is a model instruction, never drawn). Mark
  sends the sentences the selection touches (`AISentenceSplitter`, prose only, list/quote markers
  excluded): sentences are found over the full lines of each touched block, so a boundary never
  cuts a construct, but only those whose prose range intersects the selection are kept — a partly
  selected sentence goes whole, a sentence the selection does not reach is never sent. Before the
  final review it sent every sentence of the touched lines, more than Privacy.md promised.
  Code, math, front matter, URLs, link destinations, image alt text, HTML, tables' pipes, every
  marker and every `* _ ~` are never sent.
- **What comes back is checked three times.** (1) `AIResponseParser.segments` takes the JSON
  between the first `{` and the last `}` and requires exactly `segments.count` strings, else the
  whole reply is "couldn't be used". (2) `MarkdownStructureGuard.admissibleRevisions` drops, per
  segment, any revision with a line terminator, a `Cc`, a `Cf` the original lacked, a different
  structure-punctuation sequence, or a different block signature. (3) The composed document must
  `verify` against the original's whole-document signature, or nothing is offered. Then EVERY
  decision is verified again on its own (below).
- **The structure rule, as built** (decisions paid for in review rounds — do not loosen):
  - Every `*`, `_` and `~` in the document is structure, paired or not. This closed a whole class of
    emphasis re-pairing bypasses; the cost is that the AI cannot fix a typo that touches one of them
    (`make_tset_file` stays as written). The signature also fingerprints which delimiter pairs with
    which, so prose beside a delimiter cannot re-pair emphasis.
  - Bare URLs, bare emails, `<autolinks>`, reference definitions and reference/shortcut links (judged
    against the WHOLE document's labels) are structure. HTML entities (`&amp;`, `&nbsp;`) are NOT —
    they remain prose and the AI may rewrite them.
  - The `Cf` (format character) rule fails CLOSED: a revision that adds a ZWJ, ZWNJ, ZWSP or bidi
    control the original segment did not contain is dropped. This also drops an AI's new emoji ZWJ
    sequence or Persian/Indic ZWNJ shaping — accepted as the price of never admitting invisible
    control characters.
  - Token comparison in the diff is canonical-equivalence (an NFC-only renormalisation is "no
    change", the writer's bytes kept); the stale-segment and stale-text checks are exact UTF-16.
- **Per-decision verify.** A subset of a verified reply can still change structure (`$5` → `5$`
  diffs into a deletion and an insertion; accepting only the insertion gives `$5$`, which is math).
  Each accept and each Accept Remaining runs `verify(current, current+edits)` first; a refused one is
  marked rejected (single) or left pending (batch) and shows "That change would alter the Markdown,
  so it wasn't applied." on the card.
- **Undo shape.** One decision = one `applyAIEdits` call = one undo group = one ⌘Z. Accept Remaining
  is ONE call, named "Accept Suggestions" ("Accept Suggestion" for one edit), its edits in
  descending order in pre-batch coordinates.
- **History.** Recorded once, when the review ends (last decision, End/Esc, or typing), and only if
  something was accepted: one passage per CHANGED paragraph (`acceptedPassages`). `abandon()`
  records nothing.
- **The selection after a review.** The reviewed passage stays selected in the editor under the
  overlay. Whenever `state` leaves `.reviewing` — Esc, the card's buttons, the last pill, a typed
  key, a tab swap's `endReview`, `abandon`, disconnect — its `didSet` calls
  `collapseSelectionForAI(at: caretEnd(of: selectionRange))` (the session keeps that range
  shifted by every accept). `caretEnd` stops BEFORE trailing `\n` / `\r\n`: a triple-click selects
  the line with its ending, and `NSMaxRange` put the typed key at the start of the next line. Mark
  collapses the same way when its marks appear — a selection draws over the wash and hid it. One choke point, so no exit can be missed. Without it the keystroke
  that ended a review (or the next Delete, Tab, Space or dictation) replaced the whole passage.
  The overlay's ⌫ only ends the review and is not re-sent: re-sent, it would delete the passage's
  last character.
- **A skipped edit ends the review.** `applyAIEdits` returns false when the text view skipped an
  edit (it would split a character or touch a line ending / BOM — never expected after the
  guards). The session's ranges then no longer describe the text, so the controller ends the
  review at once with "That change couldn't be applied, so the review ended.", records nothing in
  History and puts the caret at the passage's real end. Whatever did land stays (one ⌘Z).
- **Disconnect.** The controller observes `AIConnectionStore.connectedProvider`: a change away from
  the provider of a running request cancels it, and away from the provider a review came from
  abandons the review. Reconnecting the same provider (a new key) leaves both alone.
- **Mark** changes nothing: it shows `.marking(ranges)` as layout-manager temporary washes in
  `HistoryPalette.tint`; the reply's 1-based sentence numbers are bounded before any `Int`
  conversion, deduped, and capped at `max(1, ceil(n/3))`, lowest numbers kept.
- **Messages use one/many, not a stringsdict.** "1 change suggested" / "%lld changes suggested"
  (and the sentence-marked pair) are two catalog keys chosen by `count == 1`. That is correct for
  every shipped language (es, fr, de, ja, zh-Hans: ja/zh have one form, and 0 never reaches these
  strings — it becomes "No changes suggested." / "Nothing to mark."). A language with dual/few/many
  forms (Russian, Polish, Arabic) would need a real plural variation in the catalog.
- **Known gap: word passages right after a whole-text write.** `allowsAIAction` reads History's
  LIVE ranges only (it never searches text). `noteWholeTextReplacement()` invalidates them, so
  between a whole-text write and the next locate, an action inside a `.word` passage is not
  blocked. Live reload and open re-locate immediately, so the window is brief; the action itself is
  still structure-safe — only the spec §5 "nothing nests inside a word" rule is briefly unenforced.
- **Not hands-on verified yet** (owed in GUI QA): pills/keys/cards on screen, dead keys and IME
  hand-off (ja, zh-Hans, ⌥E), Focus/ruler assists (not mirrored in the overlay, so they vanish
  during a review), VoiceOver, German consent label fit.

## AI actions in the text view (2026-11-12)

`LineformTextView+AI.swift`; the controller is `AIActionController` (Lineform/AI).

- **Context menu.** After Paste and Add to History: separator, Rewrite ▸ (Trim, Cut in half,
  Rewrite), Proofread, Mark ▸ (Weakest sentences, Long sentences). ABSENT, not disabled, unless
  `aiAvailabilityHandler` says yes for a non-empty selection — a whole-document structure
  analysis, so it is asked only when the menu is built. Both submenus carry
  `MainMenuIconDecorator.excludedMenuIdentifier`.
- **One decision = one ⌘Z.** `applyAIEdits` opens ONE undo group and runs every edit through
  `shouldChangeText → textStorage.replaceCharacters → didChangeText`, so History hears each edit
  from its single user-edit source in pre-change coordinates. `breakUndoCoalescing` and
  `setActionName` happen INSIDE the open group: both register with the undo manager, and outside
  a group (an undo manager with `groupsByEvent` off) they raise. An edit that would split a
  composed character or touch a line ending / BOM is skipped, never widened.
- **Read-only review.** While `isAIReviewActive`, `shouldChangeText` refuses every edit except the
  review's own (`performAIEdit`) and History's (`performHistoryEdit`). A backstop: the review overlay
  holds focus. `insertTypedText` clears the flag itself before typing — the controller ends the
  review synchronously, before SwiftUI pushes the new state, so the ending keystroke is not refused.
- **Keys.** Esc (`cancelOperation:` in `doCommand(by:)`, after History's handling) cancels a
  running request, else dismisses marks; otherwise it is not taken.
- **Marks** are layout-manager TEMPORARY `.backgroundColor` in `HistoryPalette.tint` — the text
  storage is never touched — re-inked on a theme change, and dismissed by any real edit.
- **History.** An accepted review records one passage per CHANGED paragraph of the selection
  (`AIActionController.acceptedPassages`; accepted edits never add or remove a line ending, so
  original and accepted lines pair up). Before this, a multi-paragraph accept recorded one passage
  spanning the paragraphs.

## AI review overlay and cards (2026-11-12)

`Lineform/AI/AIReview*.swift`, wired in `EditorContainerView` (one `AIActionController` per editor,
the app's one `AIConnectionStore.shared`).

- **The suggestions are an overlay, never the buffer.** While `state == .reviewing` in Write, an
  `AIReviewSurfaceRepresentable` (an `NSScrollView` + `AIReviewTextView`, a TextKit 1 stack like the
  editor's) lies exactly over the editor. It shows `AIReviewComposition`: for each PENDING change, the
  document's own original (dimmed with a TEMPORARY `.foregroundColor` in `HistoryPalette.recededInk`,
  unless kept), the replacement in the normal ink, then a U+FFFC carrying an `AIReviewPillCell`.
  Decided changes contribute nothing. Everything before the first change is byte-identical to the
  document and `matchGeometry(of:)` copies the editor's inset, padding, container width, frame width
  and paragraph style, so its lines sit on the editor's.
- **Scroll hand-over is by CHARACTER, never pixel y.** Past the first change the overlay is taller
  than the document (it also shows removed text and pills), so a copied `bounds.origin.y` showed
  other text — a visible jump on every Esc / last decision, and on make when the selection began
  above the viewport. `topAnchor(of:)` takes the first character of the top line (and the offset
  into it); `AIReviewComposition.overlayIndex(forDocumentIndex:)` / `documentIndex(forOverlayIndex:)`
  map it (text a change adds maps to the change's end); `originY(in:showing:offset:)` puts that
  character's line at the top. On make it is applied now and again on the next turn (once SwiftUI has
  sized the scroll view); dismantle returns first responder to the editor.
- **Highlight, THEN attach.** `MarkdownSyntaxHighlighter.highlight` resets every attribute over the
  whole range, attachments included, so the pills are added after it.
- **A decision redraws only its span.** The first `present` (and a profile change) is a whole pass.
  A decision's composition differs from the last only around the decided change, so `present`
  replaces just the differing UTF-16 span (`differingSpan`), re-tokenizes just its lines
  (`refreshTokens`; the analyzer is line-local, so this equals a whole pass — asserted), re-sets
  every pill and the dimming, and does NOT `sizeToFit` (that lays out the whole document after the
  span; background layout grows the view instead). It also never sets `font` / `textColor`, which
  rewrite the whole storage. Measured at 700 KB: whole pass ~600 ms (~500 ms of it the full layout,
  ~80 ms highlighting), a decision ~11 ms. The one-time ~600 ms when a review opens on a very large
  document remains — the same full layout the editor pays when the document opens.
- **Keys: the overlay ROUTES, the editor still never intercepts `keyDown`.** In the overlay's
  `keyDown`, a key that is not a review key (arrows, Return/Enter, Esc, Page Up/Down, Home/End) and
  carries no ⌘/⌃ (and is not a function key) ends the review synchronously (`.end`), drops the editor's
  backstop (`prepareForAIHandOff`), makes the editor first responder and RE-SENDS the same event to
  `editor.keyDown`. The editor's own input context then handles it: plain text, dead keys (⌥E, ⌥U,
  ^ on ABC/French/German) and the first key of a Japanese/Chinese composition. Ending the review in
  `insertText` instead dropped that first keystroke — a dead key or an input method never reaches
  `insertText` on its first press. Review keys go to `interpretKeyEvents` (a NON-editable
  `NSTextView` drops key events before key binding — verified), and are decided in `doCommand(by:)`.
  `insertText → .typed` and `setMarkedText → .end` remain as fallbacks. The overlay also takes first
  responder in `viewDidMoveToWindow`: the representable's next-turn grab could run before SwiftUI put
  the view in a window, with no later update, so Return went to the read-only editor and did nothing
  until another key caused an update (hand-tested). The first change is current from the moment the
  session opens. Window-free tests cannot
  prove LineformTextView types from a re-sent event (its `keyDown` types nothing without a window);
  a plain text view stands in.
- **Undo can't reach underneath.** The overlay's `undoManager` is an empty private one: ⌘Z during a
  review is disabled rather than popping the document's stack (Task 7's open concern).
- **VoiceOver.** The overlay carries `accessibilityCustomActions` (Accept/Reject Change, Keep Removed
  Text when the current change removes text, Next/Previous Change, Accept/Reject All → Remaining,
  End Review); progress is announced by the controller, never written into an AX value.
- **Cards.** One floating card at the BOTTOM of `editorContent` (an overlay, never a laid-out bar):
  `AIStatusCard` for a running request (progress, "Esc to cancel", ✕ cancels), a message (steps aside
  after 8 s) or Mark's count ("Esc clears marks"); `AIReviewCard` ("3 of 7", Accept All / Reject All
  → Remaining after a decision) while a review has more than one change. A one-change review gets a
  quiet `AIStatusCard` ("1 change suggested", "Return to accept · Esc to dismiss", ✕ ends the
  review), so its modal keys are discoverable. While an AI card is up the
  announcement / default-app card is hidden. `usesDarkChrome` is threaded. All floating cards
  (announcement, default app, AI) share ONE `FloatingCardChrome` modifier. The card's arrival and
  departure animate on `aiCardKind` from a persistent `ZStack`.
- **Composition cache.** `AIReviewCompositionCache` rebuilds only when the session or the editor's
  text changes; the container body re-evaluates far more often. The overlay's spoken value drops the
  pills' U+FFFC (VoiceOver reaches them through the custom actions).
- **A refusal is seen, not only announced.** A decision `MarkdownStructureGuard` refuses sets
  `AIActionController.reviewNotice`, drawn on the review card (or alone on a status card for a
  one-change review) and cleared by the next command; if the refusal was the last decision the
  review ends and the refusal becomes `state = .message`.
- **Find & Replace ends the review** (`replaceCurrentMatch` / `replaceAllMatches` call
  `endAIForDocumentChange()` first, like typing). Before this the backstop refused the edit after the
  search state had already moved on. The representable also drops `isAIReviewActive`
  (`keepsReviewBackstop`) BEFORE applying a requested replacement in the same update.
- **Where AI ends.** Leaving Write, entering History mode, a tab or document swap
  (`resetTransientDocumentState`, BEFORE `historyController.close` so accepted changes are recorded in
  the outgoing History) and window close call `endReview()` then `abandon()`. Live reload, Read-mode
  checkbox/image rewrites and Convert Text Format call `abandon()` (nothing applied or recorded). An
  action chosen in Split switches to Write as its request starts (`AIActionModeHandlers`).
- **ATS.** Plain `http` to `127.0.0.1` and `localhost` (the "Other" provider) works with no ATS key:
  checked from the test host against the stub. `ReleaseResourceTests.testATSAllowsAtMostLocalNetworking`
  permits at most `NSAllowsLocalNetworking`, never arbitrary loads.

## Open bug: "Edited" stays in the title bar after a live reload (found 2026-11-06, not fixed)

**Seen on:** installed 1.7.5 (build 37, TestFlight), macOS 27.0.1.

**Steps:** open a file and leave its window open. Permanently delete the file (no Trash), create a
new file with the same name and different text, then open it from outside Lineform. AppKit re-shows
the existing document, and the window reconciles with disk when the app becomes active.

**Expected:** new text, the "Updated" flash, and no "Edited" in the title bar.

**Actual:** the new text and "Updated" flash appear, but the title bar still shows "Edited" under the
file name, and it was still there about eight seconds later. The file on disk stayed correct, and
closing the window showed no save prompt, so this looks cosmetic. Nothing was lost in the one run.

**Not verified:** whether any other external rewrite shows it. It was seen only in this one flow, and
ordinary live reload was not rechecked.

**Likely cause (untested):** `applyReload` writes `document.text` through the `FileDocument` binding
and then clears the change count synchronously. SwiftUI registers that binding write with the
`NSDocument` asynchronously, so it can mark the document edited after the clear. The comment in
`LineformSidebarFileOpener.replaceCurrentDocument` describes this same ordering, and that path adds a
deferred re-clear on the next main-queue turn. `applyReload` has no such re-clear.

**To fix:** reproduce on the steps above, confirm the cause, and add a test if the ordering can be
asserted. If the deferred re-clear is the fix, make sure it cannot wipe an edit typed in that same
turn: a real edit must keep its dirty state and autosave.
