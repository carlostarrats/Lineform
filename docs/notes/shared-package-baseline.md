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

## Task 2: split pure types out of AppKit files

Eleven new files, each importing only Foundation (`DocumentSaveStatus.swift` also imports Combine
for `ObservableObject`/`@Published`). Every declaration was cut verbatim; the only edit is
`MarkdownSyntaxHighlighter.analyzer` widened from `private` to internal (see below). Gates
unchanged: package 1, default plan 1983, combined 1984.

Taken along because a listed type's signature needs them (pure, same file order):
`MermaidDiagramKind` (the return type of `MermaidTypeClassifier.classify`) into
`MermaidSource.swift`; `MathStyle` (a stored property of `MathSpan`) into `MathDelimiters.swift`;
`OutlineFileRootState` (a stored property of `OutlineFileRoot`) into `OutlineFileTree.swift`;
the `#if DEBUG` `DocumentSaveStatus.testInstance()` extension (it calls the `private init`, so it
must share the file).

`CacheBudgets.swift` was not created: `DiagramCacheBudget`, `MathCacheBudget` and
`ImageCacheBudget` (in `Preview/DiagramCardStyle.swift`) are referenced only by the AppKit image
providers and `DiagramCardAndCacheTests`, never by pure code, so the plan's condition is not met.
Task 3's `CacheBudgets` entry therefore has no file to move.

### Stays until the platform-layer plan

- `Editor/MarkdownSyntaxTokens.swift`: `scopedTokenRange(visibleRange:margin:in:)` and
  `tokens(in:scope:)` sit in an `extension MarkdownSyntaxHighlighter`, because `tokens(in:scope:)`
  is an instance method (it reads the highlighter's `analyzer`) and both must stay reachable under
  their current names. The extension imports only Foundation, but `MarkdownSyntaxHighlighter` is
  the AppKit class, so this file cannot move into `LineformCore` until the highlighter is split in
  the platform-layer plan. The "pure token types" (`MarkdownTokenKind`, `MarkdownTokenRange`)
  were already in the pure `MarkdownRangeAnalyzer.swift`; nothing else to split.
- Left in their AppKit files because they take or return AppKit types: `MermaidHexColor`,
  `MermaidImageOrientation`, `MermaidRenderOutcome`, `MermaidPieRenderer`,
  `MathImageOrientation`, `MathRenderOutcome`, `RasterImageCost`, and the image providers.
- Pure but not in Task 2's list, so left where they are: `MermaidCacheKey`, `MathBlockPolicy`,
  `MathCacheKey` (CryptoKit + CGFloat), `OutlineFileTreeFlatRow`,
  `SecurityScopedResourceAccessing`/`URLSecurityScopedResourceAccessor`,
  `MarkdownSyntaxHighlighter.range(_:covers:)`.

## Task 3: Markdown core moved into LineformCore

Seventeen files moved verbatim into `Packages/LineformCore/Sources/LineformCore/Markdown/`
(`MarkdownBlockGrouping`, `MarkdownInlineSyntax`, `MarkdownHTMLRenderer`, `CodeHighlighting`,
`ImageResolver`, `ImageLinkRewrite`, `ImageExportPreflight`, `ImageFit`, `DiagramLog`,
`MermaidSource`, `MermaidPieChartModel`, `MathDelimiters`, `MarkdownHeadingParser`,
`MarkdownOutlineParser`, `MarkdownReference`, `MarkdownRangeAnalyzer`, `MarkdownLineEnding`).
The placeholder `LineformCore.swift` and its catalog key are gone. Nothing in the group needed an
app type, so nothing was split or left behind for that reason.

Not moved: `CacheBudgets` (no file; see Task 2) and `Editor/MarkdownSyntaxTokens.swift` (an
extension of the AppKit `MarkdownSyntaxHighlighter`; see "Stays until the platform-layer plan").

Edits beyond `public`: explicit `public init`s (`MarkdownTokenRange(kind:range:)`, and empty ones
for `MarkdownRangeAnalyzer`, `MarkdownOutlineParser`, `CodeSyntaxHighlighter`,
`NullDiagramFailureLog`); `Sendable` on `MarkdownTokenKind` (a public type loses the implicit
conformance an internal one had, and the app's `static let Set<MarkdownTokenKind>` needs it);
`DiagramLogStore` uses `URL(fileURLWithPath: NSHomeDirectory())` (same path on macOS, sandboxed or
not); `MarkdownReference`'s bundle defaults are `.module` (`sections(in:)`, internal) and
`.lineformCore` for the two public row methods, because a public default argument cannot name the
internal `Bundle.module`. `Bundle.lineformCore` (new, `LineformCoreBundle.swift`) is that public
alias.

Strings: 41 distinct keys (42 call sites; "Spelling" is used twice). 38 moved; "Markdown Basics",
"Block Spacing" and "Search" are also used by app code, so they were copied and stay in the app
catalog too. Xcode emits no `en.lproj` for the package bundle (the development language needs no
table without plurals); resolution still picks `en` for an English-first user, exactly like the
app bundle (checked with `Bundle.preferredLocalizations` against the built bundle).
