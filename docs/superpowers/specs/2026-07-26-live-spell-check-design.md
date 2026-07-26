# Live Spell Check — Design

**Date:** 2026-07-26
**Backlog item:** #2 in `docs/research/2026-07-25-feature-backlog.md`
**Status:** SHIPPED 2026-07-26. See "Corrections after implementation" at the end — three claims
in this document turned out to be false, and the open question below was answered.
**Area docs to read first:** `docs/architecture/editor-behavior.md`

---

## Problem

`LineformTextView.configureForMarkdownEditing` (`Lineform/Editor/LineformTextView.swift:632`)
sets `isAutomaticSpellingCorrectionEnabled = true` and never sets
`isContinuousSpellCheckingEnabled`, which defaults to `false` on `NSTextView`.

That is the least useful of the four combinations: the app silently rewrites the user's words
while showing no indication of what it thinks is wrong. Autocorrect is also actively hostile to
Markdown, where identifiers, filenames, and URLs are ordinary prose-adjacent content.

## Behavior being shipped

1. Misspellings get the standard red dotted underline as the user types. The system context menu
   (suggestions, Learn Spelling, Ignore Spelling) comes along for free.
2. **Autocorrect is turned off.** The app points at problems; it never edits the user's text
   behind their back. This is the only part of the change that removes existing behavior.
3. **No grammar checking.** `isGrammarCheckingEnabled` stays `false`, set explicitly rather than
   by omission. Grammar checking flags headings, list items, and captions as fragments — noisy,
   and it fights the calm-writing principle. The manual Edit ▸ Spelling and Grammar window
   remains available for anyone who wants a deliberate pass.
4. **Nothing is checked inside non-prose regions:** fenced code, YAML front matter, math,
   `inline code` spans, and link/image *destinations*. Link and image *text* IS checked — it is
   prose.
5. **On by default.** The only control is the standard Edit ▸ Spelling and Grammar ▸ Check
   Spelling While Typing menu item AppKit already draws. No Settings row. The user's choice
   persists across launches and applies to newly opened tabs and windows.
6. **Local only.** See invariant below.

## Local-only invariant

`NSSpellChecker` resolves against the on-device `AppleSpell` service and the user's local and
learned dictionaries. No network request, no Apple Intelligence, no server-side model. This
satisfies the app's existing network-free promise without new work.

**The invariant to preserve:** spell checking must never be routed through anything but the
system checker. Do not add a bundled dictionary, a third-party checking service, or any
network-backed suggestion source. This sits alongside the existing rule that remote image URLs
are never fetched (`docs/architecture/rendering.md`).

## Architecture

### `MarkdownSpellCheckRegions` (new, `Lineform/Editor/`)

Pure, AppKit-free, default-test-plan friendly:

```swift
enum MarkdownSpellCheckRegions {
    /// The sub-ranges of `enclosing` that should be spell-checked — i.e. `enclosing`
    /// minus every non-prose Markdown region intersecting it.
    static func checkableRanges(in text: String, enclosing range: NSRange) -> [NSRange]
}
```

It unions two sources, clips to `range`, and returns the complement:

- **Block regions** — fenced code, front matter, math.
- **Inline regions** — `codeSpan`, `linkDestination`, `imageDestination` tokens.

### `LineformTextView`

- `configureForMarkdownEditing`: `isAutomaticSpellingCorrectionEnabled = false`,
  `isGrammarCheckingEnabled = false`, and `isContinuousSpellCheckingEnabled` read from the
  settings store. Quote/dash/text-substitution stay `false` — unchanged and still correct.
- Override `checkText(in:types:options:)`: compute `checkableRanges` for the incoming range and
  call `super` once per surviving sub-range.
- Override `toggleContinuousSpellChecking(_:)`: call `super`, then write the resulting
  `isContinuousSpellCheckingEnabled` back to the settings store.

There is exactly one construction site (`MarkdownTextViewRepresentable.swift:43`), so reading
the persisted value in `configureForMarkdownEditing` is sufficient to cover every new tab and
window. No fan-out or notification broadcast is needed.

### `LineformSettingsStore`

One `@Published var checksSpellingWhileTyping: Bool`, key
`Lineform.settings.checksSpellingWhileTyping`, default `true`, using the existing `didSet`
write-through pattern. No `@AppStorage` (matches the rest of the file). No Settings UI row.

## Performance constraint — load-bearing

**`MarkdownWritingToolsProtection.ignoredRanges` must NOT be called from the checking path as-is.**
Its own doc comment records **18 ms on a 730 KB file**: it computes every protected region in the
whole document, including a per-line inline-math regex pass. That cost is acceptable for a
once-per-session Writing Tools invocation and unacceptable on a path that re-runs as the user
types. Wiring it in naively reintroduces the large-document typing lag class of bug.

`MarkdownRangeAnalyzer.ranges(in:)` has the same shape — whole-document — which is why the
highlighter uses the scoped `MarkdownSyntaxHighlighter.tokens(in:scope:)` path instead.

`checkableRanges` must therefore be scoped:

- **Inline tokens:** reuse the existing scoped token path
  (`MarkdownSyntaxHighlighter.tokens(in:scope:)`, `MarkdownSyntaxHighlighter.swift:184`). Safe
  because `MarkdownRangeAnalyzer` is strictly line-local by construction — the invariant that
  already makes visible-window highlighting byte-identical to a whole-document pass. Do not
  break that to make this easier.
  **The scope MUST be snapped to line boundaries** before tokenizing, or the equivalence does
  not hold and a construct straddling the scope edge is mis-tokenized. `scopedTokenRange`
  (same file, line 154) already does this snapping; use it rather than passing AppKit's raw
  range through.
- **Block regions:** fence and front-matter state genuinely depend on the document prefix, so
  this needs a prefix walk in the style of `isInsideCodeOrFrontMatter` (walk lines tracking
  fence state, collect protected ranges only once inside the enclosing range) rather than the
  whole-document regex pass. Extending `MarkdownWritingToolsProtection` with a scoped variant is
  preferred over duplicating fence parsing in a second file.

### Attribute the cost before optimizing anything

There are **two independent** sources of possible typing lag here, and they have different
owners. Measure them separately, in this order, before writing optimization code:

| Config | Build | What it isolates |
|---|---|---|
| **A** | Today's build, continuous checking off | Baseline typing latency |
| **B** | Continuous checking on, **no suppression at all** | Cost of AppKit's own spell checker |
| **C** | Continuous checking on + `checkableRanges` suppression | Cost *we* add |

- **C vs. B** is our code. This is what the scoping rules above exist to keep near zero.
- **B vs. A** is Apple's checker, and no amount of care on our side reduces it. If B alone is
  already laggy on a large document, that is a **product** finding, not a bug to optimize —
  bring it back to the user. The likely answer would be a document-size threshold above which
  continuous checking stays off, not a cleverer implementation.

Skipping this attribution step is how a day gets spent optimizing our 0.3 ms while Apple's 40 ms
is the actual problem.

Reuse the existing profiling harness from the earlier large-document typing investigation
(sandboxed-app timing written to a CSV in the container tmp directory, TextEdit as the control).
Do not build a new one.

### Hard gate — the feature does not ship if this fails

**Acceptance criterion: C must show no measurable typing-latency regression against A** on a
730 KB document, typing in the middle of the file. Not "feels fine" — measured, with the numbers
reported honestly, including the case where they are bad.

**Budget for our own code:** `checkableRanges` costs **≤ 1 ms per call** at 730 KB. For scale,
that is one twentieth of the 18 ms whole-document pass this section exists to avoid, and well
inside a 120 Hz frame's 8.3 ms.

**Automated regression guard, default test plan:** an XCTest `measure` block running
`checkableRanges` against a large generated fixture with a hard threshold, so a later change
cannot silently regress this back. `MarkdownSpellCheckRegions` is pure and AppKit-free precisely
so this test needs no window and runs in the default plan.

### Implementation rules that keep it cheap

1. **Never** call `ignoredRanges(in:enclosingRange:)` or `MarkdownRangeAnalyzer.ranges(in:)`
   from the checking path. Both are whole-document. This is the single most likely way to
   reintroduce the bug.
2. Snap to line boundaries with `scopedTokenRange`, then tokenize with `tokens(in:scope:)`.
   Work is proportional to the checked range, not the document.
3. **Do not force a synchronous re-highlight** from the checking path. `didChangeText` already
   schedules the debounced one — this is an existing load-bearing invariant in
   `docs/architecture/editor-behavior.md`, and the checking path must respect it too.
4. Keep the work synchronous on the main thread. It is bounded by rule 2, and dispatching it
   introduces ordering races against the text storage for no measured benefit. Revisit only if
   measurement demands it.
5. **Do not add a cache until the measurement says one is needed.** The obvious next step if the
   prefix walk proves too slow — checkpointing fence state every N lines and invalidating only
   from the edit offset forward — is real but non-trivial, and adds an invalidation bug surface.
   It is a documented fallback, not part of the first implementation.
6. Do not disturb the `lastSyncedText` guard in `updateNSView`. It is unrelated to this feature
   and is load-bearing for typing performance on its own.

Verify with a large document before calling the work done — a 700 KB+ file, typing in the middle,
watching for caret lag. The existing `lastSyncedText` guard in `updateNSView` is unrelated and
must not be disturbed.

## Open question to resolve FIRST

**Which AppKit hook does continuous, as-you-type checking actually route through?**

`checkText(in:types:options:)` is the documented entry point for the explicit "Check Document
Now" path. Whether continuous checking also routes through it — as opposed to an internal
scheduler that only consults the
`textView(_:shouldCheckTextIn:options:types:)` delegate method — is **unverified**. The whole
inline-suppression design depends on the answer.

**Probe before writing the real implementation:** in a Debug build, enable continuous checking,
override both hooks with logging, type a misspelling, and record which fires and with what
ranges.

- **If `checkText(in:types:options:)` fires:** build as designed above.
- **If only the delegate fires:** the delegate's granularity is the whole chunk it hands you, so
  suppressing on any intersection would disable checking for a paragraph containing a single
  code span. Fall back to the delegate for block regions (which are paragraph-aligned, so
  chunk granularity is close enough) and **bring the inline-region question back to the user**
  rather than silently dropping item 4 or adopting the temporary-attribute-stripping approach,
  which was considered and rejected below.

## Rejected alternatives

- **Coarse suppression via the delegate alone.** Two lines, documented hook, `Coordinator` is
  already the delegate. Rejected because it is all-or-nothing per chunk: one inline code span
  disables checking for the surrounding prose.
- **Let AppKit check, then strip `spellingState` temporary attributes over protected ranges.**
  Exact, but it fights AppKit on every re-check, races the debounced highlighter, and leaves the
  checker's internal state disagreeing with what is drawn.
- **A Settings toggle, or a toggle plus the menu item.** Rejected as duplicating a control macOS
  already draws, and doubling the state-sync surface for a single `Bool`.
- **Bundled or third-party dictionary.** Rejected — see the local-only invariant.

## Testing

**Default plan** (no window; this is where the real coverage lives):

- `MarkdownSpellCheckRegions`: prose-only text returns the whole range; a fenced block is
  excluded; front matter is excluded; inline `code` is excluded while surrounding prose is
  retained; a link's destination is excluded while its text is retained; an image's destination
  is excluded; adjacent and nested regions coalesce without producing zero-length or overlapping
  ranges; a range clipped to a partial region returns only the intersection.
- `LineformSettingsStore`: `checksSpellingWhileTyping` defaults to `true`, persists, and reads
  back through an injected `UserDefaults`.
- A scoped-vs-whole-document equivalence test, mirroring the existing highlighter equivalence
  test: `checkableRanges` over a sub-range must equal the whole-document computation clipped to
  that sub-range. This is what guards the line-local invariant.

**Manual, in a Debug build** (state the results honestly; do not claim them from tests):

- Type `teh` in prose → red underline appears.
- Type `teh` inside a fenced block, inside front matter, and inside `` `teh` `` → no underline.
- A link `[teh](/some/pth)` → `teh` underlined, `/some/pth` not.
- Toggle the Edit menu item off, quit, relaunch → still off. Open a new tab → still off.
- Type a word autocorrect used to "fix" → it is no longer silently changed.
- Large-document typing check per the performance section above.

Per `CLAUDE.md`, open QA files with
`open -a "$BUILT_PRODUCTS_DIR/Lineform.app" file.md`, never a bare `open`.

## Risk

Low mechanically — a few flags and one pure helper. The two things that make it feel native
rather than annoying are the non-prose suppression and the absence of typing lag.

The typing-lag risk is the one the user called out explicitly, and it is handled by a measured
gate rather than by care: attribute A/B/C, budget our own code at ≤ 1 ms, guard it with an
automated perf test, and treat "Apple's own checker is the slow part" as a product question
rather than something to optimize around. **If the gate fails, the feature does not ship in this
form** — report the numbers and bring back the options.

The genuine unknown is the AppKit routing question, which the probe resolves before any real
code is written.

## Docs to update in the same change

- `CLAUDE.md`: one line in Main Features; one line under Load-Bearing Invariants for the
  local-only spell-checking rule.
- `docs/architecture/editor-behavior.md`: the implementation narrative, the performance
  constraint, and the probe's outcome.
- `docs/research/2026-07-25-feature-backlog.md`: mark item 2 shipped, update the status count.
- `Lineform/Resources/*.md`: user-facing help and release notes.

---

## Corrections after implementation (2026-07-26)

This document was written before any build was run. Four things in it were wrong. They are left
in place above rather than edited away, because the pattern — *asserting platform behavior from a
static read* — is the thing worth remembering.

**1. "AppKit already provides Edit ▸ Spelling and Grammar for free (it's already in your menu)."
False.** SwiftUI builds no such submenu and this app replaces the Edit menu. Dumping the live menu
over Accessibility showed: Undo, Redo, Cut, Copy, Paste, Delete, Select All, Find, Find & Replace…,
Speech, Writing Tools, AutoFill, Start Dictation…, Emoji & Symbols. The inference came from
`MainMenuIconDecorator` mapping an icon for `checkSpelling:` — an icon mapping for an item that was
never built. **Consequence: the feature shipped with no off switch until QA caught it**, and
`toggleContinuousSpellChecking` was unreachable dead code.

**2. "The system context menu (suggestions, Learn Spelling, Ignore Spelling) comes along for
free." False.** `LineformTextView.menu(for:)` builds a custom menu that fully replaces AppKit's,
which is exactly where those items live. A misspelled word had no actionable UI at all.

**3. "The manual Edit ▸ Spelling and Grammar window remains available." False**, for the same
reason as (1). Now true: Show Spelling and Grammar (⌘:) and Check Document Now (⌘;) were added.

**4. The delegate method is `textView(_:willCheckTextIn:options:types:)`, not `shouldCheckTextIn`**,
and its options dictionary is keyed by `NSSpellChecker.OptionKey`, not
`NSAttributedString.TextCheckingOptionKey`. A `shouldCheckTextIn` method compiles and is silently
never called — Swift emits only a "nearly matches optional requirement" warning.

**The open question was answered: `checkText(in:types:options:)` DOES fire for as-you-type
checking**, with `willCheckTextIn` firing downstream of it 1:1. Range-splitting works, so inline
suppression shipped as designed. AppKit also scopes each check to ~700 characters near the caret
and coalesces ~300 keystrokes into ~14 checks, which made the feature far cheaper than feared.

**The performance gate did its job.** The first implementation — the scoped path calling the two
whole-document passes with an `upTo` bound — measured 14.97 ms/call and failed. It was rewritten as
a single allocation-free prefix walk. Full numbers:
`docs/notes/2026-07-26-spell-check-probe-findings.md`.

**One design decision changed after user review:** suggestions show a single ranked candidate
rather than the checker's full list. `NSSpellChecker.guesses` returns the, ten, tbh, tex, feh, yeh,
tea, ted for "teh" — a phonetic net, not an answer. `correction(forWordRange:)` looked like the fix
but returns nil whenever the system-wide autocorrect setting is off, so the top guess is the
fallback.

**Also not anticipated:** enabling continuous checking surfaces a floating inline candidate pill
near the caret (`isAutomaticTextCompletionEnabled`, on by default, invisible until checking is
enabled), and toggling checking does not re-examine already-laid-out text in either direction.
Both are handled; see `docs/architecture/editor-behavior.md`.
