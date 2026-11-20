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
