# Shared package platform layer: baseline

Recorded 2026-11-19 at Task 1 of the platform-layer plan, before any renderer code moves into
`LineformCore`. Every later task compares against these numbers.

- Commit: `89a1933` (merge of PR #11, `main`), plus this task's test-only change (no production
  code changed).
- Xcode 27.2 (27B52), macOS 27.2.1 (26B131), Apple silicon MacBook Pro, main screen backing scale 2.
- All runs with Xcode not running and `-parallel-testing-enabled NO`.

## Render golden

`LineformTests/RenderGoldenTests` pins the Mac renderer's output for one corpus
(`LineformTests/Fixtures/render-golden/corpus.md`) in 10 cases: the five `Theme.builtIn` themes,
high contrast, New York, OpenDyslexic, export flags (`fitTablesToWidth`, monochrome code,
`headingScale` 1.2), and `imagesAsText`. Real Mermaid, math and image providers; column width 680.

- `testRenderedAttributesMatchGolden` compares a per-run attribute fingerprint
  (`RenderFingerprint.describe`) with `golden.txt`.
- `testRenderedPixelsMatchGolden` compares a SHA-256 of each case drawn off-screen (TextKit 1,
  680 pt at scale 2, sRGB, fixed appearance, font smoothing off).
- `golden.txt` records the macOS version (line 1) and the main screen's backing scale (line 2).
  On another OS or scale both tests skip. The golden is never re-recorded in this plan.
- Recorded once with `TEST_RUNNER_RECORD_RENDER_GOLDEN=1`, then run twice without it: both runs
  passed with identical hashes. It also passed inside the full default plan.

## Gates

| Gate | Result |
|---|---|
| Package, macOS (`xcodebuild test -scheme LineformCore -destination 'platform=macOS'`) | 520 passed, 0 failed |
| Package, iOS Simulator (build only at Task 1) | BUILD SUCCEEDED |
| Default plan | 1994 passed (LineformTests 1474 + LineformCoreTests 520), 0 failed |
| Hosted plan (`-testPlan LineformHosted`) | 26 of 26 passed |

Unique tests (package macOS + app): **1994** (1992 before this task + the 2 golden tests).
`EditorDrawerMotionHostedTests` theme-switch stress passed in the full hosted run, so no isolated
re-run was needed.

Default plan, Debug with coverage: `testBenchmarkLargePreviewRendering` values 0.072681, 0.073132,
0.072328, 0.071786, 0.071884 s; `[perf] checkableRanges 7.476 ms/call vs whole-document 80.195
ms/call — 10.7×`.

## Optimised timing (Review Focus 5)

Method as in `shared-package-baseline.md`: Debug with `SWIFT_OPTIMIZATION_LEVEL=-O
SWIFT_COMPILATION_MODE=wholemodule`, `-enableCodeCoverage NO`, separate DerivedData,
`build-for-testing` once, then 3 `test-without-building` runs of
`LargeDocumentPerformanceTests/testBenchmarkLargePreviewRendering`. Only one tree exists at this
task, so the runs were not interleaved with another build. Load averages 3.5 to 6.7.

| Run | Values (s) |
|---|---|
| 1 | 0.061512, 0.060656, 0.060558, 0.060264, 0.059972 |
| 2 | 0.060899, 0.059951, 0.060674, 0.060727, 0.060540 |
| 3 | 0.061683, 0.061036, 0.061904, 0.060770, 0.061103 |

**Median of 15 samples: 60.7 ms.** Task 7's budget is within 10 %: at most 66.8 ms, measured the
same way (ideally interleaved with this commit's build).

## After the move (Task 7)

Recorded 2026-11-19 at Task 7. The tree is `ac76540` plus this task's CI and doc edits (no
production code changed). Same Mac, Xcode and OS as above, main screen backing scale 2. Xcode
not running, `-parallel-testing-enabled NO`.

### Gates

| Gate | Result |
|---|---|
| Package, macOS | 623 passed, 0 failed, 0 skipped |
| Package, iOS Simulator (`xcodebuild test -scheme LineformCore -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5'`) | 624 passed, 0 failed, 0 skipped |
| Package tests built for iOS (`xcodebuild build-for-testing -scheme LineformCore -destination 'generic/platform=iOS Simulator'`, the new CI step) | TEST BUILD SUCCEEDED |
| Default plan | 2014 passed (LineformTests 1391 + LineformCoreTests 623), 0 failed. Both `RenderGoldenTests` tests executed and passed (0 skipped) |
| Hosted plan (`-testPlan LineformHosted`) | 26 of 26 passed (load average 15.8 at start) |
| Release archive (`xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Release archive`) | ARCHIVE SUCCEEDED, `LineformQuickLook.appex` included. The archived app was not run or opened (iCloud data risk of local Release copies) |

Unique tests (package macOS + app): **2014**, the 1994 at Task 1 plus the tests Tasks 2 to 6 added.
The iOS package count is one higher than macOS: 3 tests are macOS-only (`#if os(macOS)`:
the Mermaid upright flip, the calibrated-white table, `NSScreen` metrics per call) and 4 are
iOS-only (no Comic Sans on iPhone, the horizontal rule width, a long table cell at narrow
width, table rows carrying their row index).
`EditorDrawerMotionHostedTests` theme-switch stress passed in the full hosted run, so no
isolated re-run was needed.

Default plan, Debug with coverage: `testBenchmarkLargePreviewRendering` values 0.075422,
0.075084, 0.074973, 0.076074, 0.075129 s (Task 1: about 0.072; the package now compiles the
renderer at `-Onone` in Debug, see Claude.md, Shared package); `[perf] checkableRanges 7.327
ms/call vs whole-document 81.158 ms/call — 11.1×`.

### Optimised timing (Review Focus 5)

Same method as at Task 1, interleaved with a second build of the Task 1 commit (`f234d39`,
exported with `git archive` to a scratch folder), each with its own DerivedData: build both
with `build-for-testing` once, then alternate 3 `test-without-building` runs of each. Load
averages 3.5 to 3.8 during the runs.

| Run | `f234d39` (Task 1) values (s) | `ac76540` + Task 7 values (s) |
|---|---|---|
| 1 | 0.060979, 0.059915, 0.060498, 0.060974, 0.060894 | 0.061747, 0.061742, 0.060574, 0.060836, 0.060916 |
| 2 | 0.061608, 0.061331, 0.061033, 0.060609, 0.061188 | 0.061943, 0.060859, 0.064057, 0.064559, 0.063810 |
| 3 | 0.061615, 0.061146, 0.060864, 0.061373, 0.061768 | 0.060324, 0.060806, 0.060808, 0.059903, 0.060788 |

**Median of 15 samples: 60.9 ms after the move**, against 60.7 ms recorded at Task 1 (+0.3 %) and
61.0 ms for the interleaved Task 1 build (−0.3 %). The limit was 66.8 ms. The renderer crossing
into the package did not make Read-mode rendering slower in an optimised build.

### Eye check (Step 4)

Not done in this task. The comparison by eye of the five themes in Read and Preview against
`main` is deferred to the owner's pre-release hand-test (ruling R13). The render golden's
attribute and pixel tests (both executed and passed) and the hosted plan stand in for it until
then.

### Known limitations carried to the iPhone steps

- iOS tables are tab-stop rows tagged with the internal `.markdownTableRow` key; make the key
  public when the iPhone Read view needs it.
- iOS `HorizontalRuleAttachment` overrides only the TextKit 1 attachment methods.
- `RenderDisplayMetrics.current` on iOS is a placeholder (scale 3, viewport 844); the iPhone Read
  view must pass real values.
- `MathImageProvider` uses `scale` only in its cache key, not for the raster's pixels (ruling R11).
