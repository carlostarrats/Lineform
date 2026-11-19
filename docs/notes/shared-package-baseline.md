# Shared package extraction: baseline

Recorded 2026-11-19 before any `LineformCore` work, so every later task of the shared-package plan
can compare against it. Task 1 gates: package 1 test passes; default plan 1983 (1982 app + 1
`LineformCoreTests`); combined 1984.

- Commit: `0c94147` ("Make privacy wording accurate for every network request"), the HEAD of the
  Check for Updates branch (controller ruling R1: this is the baseline, not `origin/main`).
- Xcode 27.2 (27B52), Swift 6.4.2, macOS 27.2.1 (26B131), Apple silicon MacBook Pro.

## Test counts

| Plan | Passed | Failed | Skipped |
|---|---|---|---|
| Default (`Lineform.xctestplan`) | 1982 | 0 | 0 |
| Hosted (`-testPlan LineformHosted`) | 25 | 1 | 0 |

Both run with `-parallel-testing-enabled NO`, Xcode not running.

Hosted failure: `EditorDrawerMotionHostedTests/testThemeSwitchStressAcrossEditorSurfacesStaysResponsiveAndResourceBoundedOnMacOS27`
(`XCTAssertLessThan failed: ("21.12") is not less than ("15.0")`, EditorDrawerMotionHostedTests.swift:665).
During that full run a few short Python script runs happened in another shell (light load, but
not a perfectly quiet machine). Re-run once in isolation (`-only-testing:` that one test, nothing else running) at the same
commit: failed again, `15.71` vs `15.0`. Nothing was changed. This is a wall-clock budget on a
load-sensitive hosted test (see `docs/notes/hosted-test-plan.md` on machine state); it fails at
the baseline, so a later failure of the same test is not by itself a regression from this plan.
Later tasks compare the hosted plan against 25 passed + this one known failure.

## Release build

`xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Release -destination 'platform=macOS' build`
after `clean`, default DerivedData (package checkouts and the module cache already warm):
**119 s**, BUILD SUCCEEDED.

## Performance timings (default plan, Debug test host)

`LargeDocumentPerformanceTests` (`measure` with `XCTClockMetric`, 5 values each, seconds):

| Test | Average | Values | RSD |
|---|---|---|---|
| testBenchmarkLargeDocumentStatistics | 0.001 | 0.000727, 0.000723, 0.000711, 0.000711, 0.000723 | 0.958% |
| testBenchmarkLargeOutlineParsing | 0.000 | 0.000387, 0.000392, 0.000383, 0.000381, 0.000379 | 1.122% |
| testBenchmarkLargePreviewRendering | 0.067 | 0.065773, 0.064638, 0.067586, 0.069048, 0.069019 | 2.617% |
| testBenchmarkLargeSyntaxHighlighting | 0.006 | 0.005701, 0.005932, 0.005618, 0.005894, 0.005719 | 2.076% |
| testBenchmarkRepeatedLargePreviewApplyForUnchangedContent | 0.000 | 0.000038, 0.000036, 0.000038, 0.000024, 0.000024 | 21.011% |

`MarkdownSpellCheckPerformanceTests`:

```
[perf] checkableRanges 4.382 ms/call vs whole-document 24.617 ms/call — 5.6× faster on 730 KB (floor 4.0×)
```

(Also measured in the same run: `MarkdownListContinuationTests/testBenchmarkReturnOnAListLineInALargeDocument`,
average 0.003 s, values 0.002810, 0.002837, 0.002827, 0.002813, 0.002973.)

To compare later: `grep -E "measured|\[perf\]"` over the default-plan `xcodebuild test` log.

## Package placeholder string (Task 1 → Task 3)

The package catalog holds one placeholder key, `LineformCore placeholder`, with explicit
stringUnits in en, es, fr, de, ja and zh-Hans. An empty catalog compiles to no `.lproj` at all,
so without the placeholder `PackageSmokeTests` cannot pass. Task 3 deletes the placeholder
together with `LineformCore.swift`, and replaces the smoke assertion with a check that a real
moved key resolves to its Japanese translation through `Bundle.module`.

The hosted failure above (`EditorDrawerMotionHostedTests` theme-switch stress: 21.1 s in the full
run and 15.7 s alone, against a 15.0 s limit) already exists at `0c94147`. It is not caused by
this plan.
