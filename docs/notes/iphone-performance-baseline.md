# iPhone performance baseline

Recorded 2026-11-23 for roadmap step 12 (polish and release). The budgets are measured by
`LineformiOSTests/PhonePerformanceBudgetTests` on the 1 MB corpus
(`StylingPerformanceTests.largeDocument()`: front matter, headings, prose, lists, quotes, fenced
code and block math, 1,048,699 UTF-16 units), always at the worst-case position: the caret, the
page and the AI review's changes at the END of the document unless a row says otherwise.

The absolute numbers below are this machine's and are never asserted. The gates are ratios taken
in the same run (see "Gates"), because other builds share the machine and CI is 2–4× slower.

- Machine: Apple M4 Pro, 24 GB, macOS 27.2.1 (26B131).
- Xcode 27.2 (27B52). CI builds with Xcode 26.6.
- Simulator: `step12b-sim` (iPhone, iOS 26.5, `2319B63D-78A7-4EEB-AFE6-52C1D64F5BD9`), 393 × 852 pt
  window.
- Debug configuration (the test host). The `LineformCore` package compiles at `-Onone` in Debug, so
  package-heavy rows (the token pass, the renderer) read slower than a shipping build.
- Load: a second worktree's build and tests ran on another simulator during some runs. Every
  timing gate that failed was re-run alone before it was treated as real.

## Task 1: the six budgets, before any fix

`testMeasureBudgets`, medians (ms):

| Budget | What is timed | Median |
|---|---|---|
| (a) Launch to a typable editor | `LineformTextView.make` + `setDocumentText("")` + hosted + `becomeFirstResponder` + `layoutIfNeeded` | 11.5 |
| (b) Open 1 MB | `MarkdownFileCodec.decode` + `setDocumentText` + `layoutIfNeeded`, caret at end | 13.7 |
| — reference | `ensureLayout(for: textContainer)`, the whole text | 609 |
| (c) One keystroke at the end | `replaceCharacters` + scoped token pass + visible-window `SpellCheckPass` | 4.4 |
| — reference | whole-document token pass (`applyTokens` over everything) | 101 |
| (d) Read first render | `LineformReadView.apply` (468 ms) + `layoutIfNeeded` | 1065 |
| (d) Read repeat apply, unchanged | `apply` + `layoutIfNeeded` | 0.46 |
| (e) Write → Read | `ModePositionKeeper.switchMode`, a new Read view rendered, the restore, layout | 1090 |
| (e) Read → Write | the switch back and the editor's restore, editor layout invalidated first | 573 |
| — reference | whole-document restyle (`MarkdownTokenStyler.apply`, `tokenScope: nil`) | 100 |
| (f) One AI review decision (accept) | session + composition rebuild + `present` + `revealCurrentChange` + layout; ten Proofread changes near the end | 682 |
| — reference | a whole-composition `present` on a fresh overlay | 99 |

After an open the editor had laid out glyphs up to 4,108 of 1,048,699
(`firstUnlaidGlyphIndex()`): an open lays out the first screen only.

## The three deferred issues

| Issue | Measured | Verdict |
|---|---|---|
| AI overlay restyles the whole composition per decision | 682 ms per accept: `setAttributedString` of the whole composition, the whole token pass (~100 ms), then `revealCurrentChange` laid the overlay out from the start to a change near the end (~580 ms) | **Breaks budget** (accept vs whole present ≈ 0.15×, budget 4×) |
| Reading assists force prefix layout after a full restyle | Reading Ruler on, caret at end: a profile change costs 614 ms, all of it `ensureExactLayout` laying out glyphs 0 … caret; `firstUnlaidGlyphIndex()` afterwards = all 1,048,699 | **Breaks budget** (structural) |
| Read overlays and the table grid force layout on long documents | Placing the pills from a fresh layout, page at the top: 330 ms (16 ms when already laid out). Every Copy pill's rect is measured, so the whole document is laid out in pieces. `firstUnlaidGlyphIndex()` stays near 3,400 because the layout is non-contiguous, so it cannot show this cost | **Breaks budget** |

Also found while measuring (e): the editor's Read → Write restore
(`scrollCharacterRangeToTop`) calls `ensureLayout(for: textContainer)`, laying out the whole
document, including everything after the target, whatever the target is.

## Task 2: gates, fixes and rulings

### Fixes, before → after

| Fix | Before | After |
|---|---|---|
| AI review overlay: a decision replaces only the differing span and restyles only the lines it and the re-tinted changes touch (`AIReviewOverlayTextView.presentIncrementally`) | accept 682 ms vs whole present 99 ms (0.15×) | accept 2.2 ms (best) / 3.0 ms (median) vs 99 ms (**45×**) |
| Read pills and table grid placed for a page above to a page below the visible one (`overlayWindow`), re-placed when a scroll or a height change leaves it | pills from a fresh layout, page at top: 325–358 ms vs full layout 577–609 ms (≈ 1.7×) | page at top: 7–10 ms vs 500 ms (**50–68×**); page at the end after a fresh layout: unchanged, 560–660 ms (Ruling 6) |
| Editor restore (`scrollCharacterRangeToTop`) lays out the prefix through the target and one page, not the whole text | Read → Write, page at the top: 535 ms vs whole restyle 98 ms (0.18×) | 2.8 ms vs 97 ms (**35×**) |

Each fix keeps what the writer sees, asserted by
`testIncrementalPresentDrawsWhatAWholePresentDraws` (the overlay's storage is `isEqual` to a whole
present's through accept, move, reject, select, a theme change and Accept All),
`testWindowedOverlaysMatchTheWholeSet` (top, middle and end: each placed pill has the whole set's
rect and number, and the grid at the end is the whole document's grid) and
`testScopedRestoreLandsWhereTheWholeLayoutRestoreDid` (targets at 0, 120, the middle and the end:
the offset matches the old formula to 0.5 pt). `AIReviewTests`, `ReadingAssistsTests`,
`ReadViewTests`, `ModeSwitchTests`, `LinkedScrollTests` and `StylingPerformanceTests` stay green.

### Gates (one run, all on `step12b-sim`, Debug)

| Gate | Scoped | Whole | Ratio | Asserted |
|---|---|---|---|---|
| `testKeystrokeIsScopedRatio` (edit via `textStorage.replaceCharacters`, see note) | 4.16 ms | 95.2 ms token pass | 22.9× | > 4× |
| `testOpenDoesNotLayOutWholeDocument` | 12.6 ms | 519 ms full layout | 41× | > 2×, plus unlaid < half |
| `testLaunchToTypableEditor` | 9.6 ms | 12.5 ms open / 96.5 ms token pass | 1.3× / 10× | > 0.4× / > 4× |
| `testReadRepeatApplyIsCheap` | 0.002 ms | 454 ms first render | > 10⁵× | > 10× |
| `testModeSwitchBackToWriteIsScoped` | 2.8 ms | 97.3 ms whole restyle | 35× | > 4× |
| `testAIDecisionIsScopedRatio` (rig's text fixed, see note) | 2.2 ms | 98.8 ms whole present | 45× | > 4× |
| `testReadingAssistsLayOutThePrefixOncePerRestyle` | 0.006 ms caret move | 615 ms restyle | > 10⁴× | > 10× |
| `testReadOverlaysDoNotForceWholeLayout` (page at top, Ruling 6) | 7.3 ms | 500 ms full layout | 68× | > 4×, plus < 20 pills, no far table |

Notes on what two gates leave out:

- **Keystroke.** The edit goes straight through `textStorage.replaceCharacters`, so it skips
  `insertText` → `shouldChangeText` (History's minimal-edit trim against its shadow text) and the
  edited line's layout. Both are bounded by the edit, not the document, but they are not in the
  timed number.
- **AI accept.** During a review the document never changes (decisions are applied when the review
  ends), so no editor edit belongs in a decision. But the rig hands the composition cache the SAME
  `String` every time, while production passes the editor's `textStorage.string`, a new bridged
  string per body evaluation: `AIReviewCompositionCache` then compares the 1 MB text to its key, and
  `AIReviewOverlay`'s coordinator compares the 1 MB compositions. Those comparisons (and a rebuild
  when the cache misses) are not in the timed number.

### Rulings

1. **Launch vs open (brief: ≥ 4×).** An open is lazy: it lays out the first screen only (13 ms),
   so launch to a typable editor (about 10 ms, most of it `becomeFirstResponder`) measured
   0.77–1.3× of it, never 4×. Ruling: the gate asserts launch is at most 2.5× an open (ratio
   > 0.4, about half the measured low) and, for the brief's intent ("an empty editor must not do
   document-scale work"), at least 4× cheaper than a document-scale pass, the whole-document token
   pass (measured 10×).
2. **Reading assists after a restyle (brief: structural, no prefix layout).** Unreachable without
   changing what the writer sees. TextKit 1's estimate for a line past an unlaid stretch is far
   off: for the last line of 1 MB, 335,817 pt estimated against 1,786,482 pt exact. The ruler and
   Typewriter Mode placed from the estimate would sit on the wrong line once the text above is laid
   out. So the prefix through the caret is laid out once per restyle or open with the ruler or
   Typewriter Mode on (about 600 ms on 1 MB, caret at the end; nothing during a Styling drag). The
   gate pins that it is paid ONCE: a caret move after the restyle is > 10× cheaper (measured over
   10⁴×). Not fixed.
3. **Read → Write gate position.** The restore must lay out the prefix through its target to place
   it exactly (the same TextKit 1 fact), so with the target near the end of a document whose
   editor layout was invalidated while in Read (a restyle in Read), the round trip still carries
   about 550 ms of editor prefix layout (measured 552 ms in the Read → Write leg in one run; in
   another the same work ran inside the Write → Read leg, 1,572 ms against 1,030 ms, because the
   editor's queued re-asserts ran there, so `testMeasureBudgets` also prints the round trip). What the fix removes is everything after the target; that
   part is largest with the target at the top, so the gate sits there (worst case for what it
   guards) and asserts the restore really put the page back at the top. The end case is reported
   by `testMeasureBudgets`, not gated. A possible follow-up: skip the restore when the editor
   already shows the target (the editor stays mounted in Read, so after a Read session without a
   scroll it never moved).
4. **Read overlays (brief: structural `firstUnlaidGlyphIndex`).** The Read view's layout is
   non-contiguous: placing every pill laid the whole document out in pieces (330 ms) while
   `firstUnlaidGlyphIndex()` stayed near 3,400. That check would pass before the fix, so it is not
   used. The gate is a ratio against a full layout plus structure: fewer than 20 pills placed on a
   page whose document has over 100 code blocks, and no grid for a table at the end.
6. **Read overlays gate at the top of the page.** The gate places the page at the top. With the
   page at the end and the layout fresh (a re-render that keeps a deep offset), positions past the
   laid-out prefix are TextKit 1 estimates, hundreds of thousands of points off (a pill measured at
   224,589 pt for a line drawn at 1,529,401 pt), so `overlayWindow` lays the whole text out first,
   exactly as placing every pill did before the fix: 561–663 ms (`testMeasureBudgets`, "page at the
   end"). The fix removes that cost only where the stretch starts inside the laid-out prefix (the
   top of a fresh render, ordinary scrolling). `testPillsFollowAReRenderNearTheEnd` asserts the end
   case places the right pills.
5. **Write → Read** (first render 460 ms + the position restore's full Read layout, about 1,030 ms
   in all) is reported, not gated, as the brief says.

### Final measurement (`testMeasureBudgets`, after the fixes)

| Budget | Median (ms) |
|---|---|
| (a) launch | 9.3 |
| (b) open 1 MB / full layout | 12.9 / 591 |
| (c) keystroke / whole token pass | 4.3 / 99.1 |
| (d) Read first render (apply) / repeat apply | 470 (466) / 0.62 |
| Read overlays from a fresh layout, page at top | 9.3 |
| (e) end, editor invalidated in Read: Write → Read / Read → Write | 1,572 / 6.0 (the ~550 ms prefix layout fell in the first leg this run; 1,026 / 552 in another) |
| (e) top, as an open leaves it: Write → Read / Read → Write | 1,041 / 3.8 |
| (f) AI accept / whole present | 3.4 / 99.0 |
| reading assists after a restyle (ruler on, caret at end) | 630 |

A last run of the gates (same machine, nothing else building): AI accept 43.9×, keystroke 22.7×,
launch 1.4× / 10.2×, Read → Write 27.8×, open 43.4×, ruler caret move 9×10⁴×, Read overlays 65.3×,
Read repeat apply 2.7×10⁵×. 12 of 12 passed.

Full `LineformiOS` suite on `step12b-sim` after the fixes: 432 tests, 0 failures.
