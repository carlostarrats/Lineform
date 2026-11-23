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
