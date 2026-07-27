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
