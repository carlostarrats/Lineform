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

## Task 4: editing logic moved into LineformCore

Eight files moved verbatim into `Packages/LineformCore/Sources/LineformCore/Editor/`:
`MarkdownListContinuation`, `MarkdownTableEditing`, `MarkdownHeadingEditing`,
`MarkdownFormattingCommand`, `MarkdownWritingToolsProtection`, `ImageInsertionText`,
`DocumentStatistics`, `EditorDisplayMode`.

Left in the app, and why:
- `MarkdownSpellCheckRegions`: `checkableRanges` takes a `MarkdownSyntaxHighlighter` (the AppKit
  class) and calls `MarkdownSyntaxHighlighter.scopedTokenRange` and `tokens(in:scope:)`, which live
  in the `extension MarkdownSyntaxHighlighter` in `MarkdownSyntaxTokens.swift` (see "Stays until the
  platform-layer plan"). It moves when the highlighter is split.
- `MarkdownStructureMap`: constructs `MarkdownSyntaxHighlighter()` and calls
  `MarkdownSpellCheckRegions.subtracting`, so it is blocked by the same thing.
- `ReadingAssistRangeResolver`: its signature takes `FocusMode`, declared in
  `ReadingExperience/ReadingProfile.swift`, which is Task 6's group. It can move with or after Task 6.

Edits beyond `public`: explicit `public init`s for `MarkdownEdit(text:selectedRange:)` and
`MarkdownPlainTextConversion(originalMarkdown:plainText:range:)` (same labels and order as the
memberwise inits; the app constructs both). `Sendable` added to `MarkdownFormattingCommand`,
`LineformTextFormat` and `MarkdownPlainTextConversion`: a public type loses the implicit
conformance an internal one had. Without it, `allCommands`/`allProbeCases` in two test files fail
Swift 6 checks, and `LineformDocument` (a `Sendable` struct) gets new warnings. The
`import LineformCore` lines Task 3 added to the moved files were removed, because a module cannot
import itself.

Strings: `EditorDisplayMode.title` has 3 keys ("Write", "Read", "Preview"). All three are copied
with `--keep-in-app`: `AppCommands.allEnglishTitleKeys` lists them for `MainMenuIconDecorator`,
which looks them up in the app bundle.

Tests: `ImageInsertionTextTests` (6), `MarkdownFormattingCommandTests` (18) and
`MarkdownTableEditingTests` (44) moved. `DocumentStatisticsTests` stays (it uses the app's
`EditorStatusFormatter`). `MarkdownListContinuationTests` and `MarkdownHeadingEditingTests` stay
(they host a `LineformTextView`). `MarkdownWritingToolsProtectionTests` stays (it calls
`MarkdownSpellCheckRegions`).
Gates: package 249, app 1734, default plan 1983, so unique tests are still 1983.

### Performance (Review Focus 4)

**Method.** You cannot test-build the Release configuration as it is:
- the Release test bundle does not compile, because tests use `#if DEBUG` helpers such as
  `DocumentSaveStatus.testInstance()` and `engagedSessionCountForTesting`;
- with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, ad-hoc signing and the Debug entitlements, the
  test runner hung before connecting.

The closest valid method is the Debug configuration with Release's Swift optimiser settings applied
to every target, the package included. Script: `.superpowers/perf/run.sh`, which is git-ignored:

```
xcodebuild build-for-testing … -configuration Debug -enableCodeCoverage NO \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
xcodebuild test-without-building … -parallel-testing-enabled NO \
  -only-testing:LineformTests/{LargeDocumentPerformanceTests,LargeDocumentLayoutReentrancyTests,
  MarkdownSpellCheckPerformanceTests,ScopedSyntaxHighlightingTests,
  MarkdownListContinuationTests/testBenchmarkReturnOnAListLineInALargeDocument}
```

- The scheme turns on code coverage (`-profile-generate`), and the shipped build does not have it,
  so it is off for the main measurement.
- Three commits were measured, each with its own DerivedData: `0c94147` (baseline, worktree),
  `ebf1334` (Task 3, worktree) and this task's tree.
- The three run interleaved, 3 runs each. A `measure` value is the median of 15 samples; the
  spell-check value is the median of 3 `[perf]` lines.
- Same Mac as above. Another session on the machine was building, so load averages were 3 to 17.
  The runs are interleaved, so that load falls on all three equally.

Optimised, no coverage (ms, median):

| Measurement | 0c94147 | ebf1334 | Task 4 |
|---|---|---|---|
| LargeDocumentStatistics | 0.734 | 0.683 | 0.701 |
| LargeOutlineParsing | 0.380 | 0.370 | 0.369 |
| LargePreviewRendering | 61.4 | 60.6 | 61.4 |
| LargeSyntaxHighlighting | 4.22 | 4.23 | 4.27 |
| RepeatedLargePreviewApply | 0.034 | 0.035 | 0.036 |
| ReturnOnAListLine (list continuation) | 2.81 | 2.80 | 2.79 |
| spell `checkableRanges` (hot path) | 1.072 | 1.057 | 1.045 |
| spell whole-document reference | 24.5 | 24.5 | 24.3 |
| spell ratio | 23.1× | 23.4× | 23.1× |
| LayoutReentrancy apply typography (s) | 0.178 | 0.175 | 0.174 |

The same build with coverage on gave the same picture: every row within 3% of baseline, and
`checkableRanges` 4.16, 4.16 and 4.21 ms. No hot path regressed by more than 10% in an optimised
build, so `@inlinable` was not added. The four named suites all passed in every run.

**Why the Debug numbers moved (24.6 → 69.9 ms).** It is real and reproducible, and it is a
Debug-only artifact:
- The app target sets no `SWIFT_OPTIMIZATION_LEVEL`, so Xcode's default applies, and the app's
  **Debug build compiles at `-O`**. The build logs show `-module-name Lineform … -O`.
- SwiftPM builds a package's Debug configuration at **`-Onone`** (`-module-name LineformCore …
  -Onone`).
- So every move into the package takes that code from `-O` to `-Onone` in Debug, and only in Debug.
  In Release both are `-O`, which the table above confirms.

Debug, coverage on (the default plan's settings), interleaved, 3 runs each (ms, median):

| Measurement | 0c94147 | ebf1334 | Task 4 |
|---|---|---|---|
| spell `checkableRanges` | 4.22 | 4.18 | 7.35 |
| spell whole-document | 24.1 | 70.3 | 80.4 |
| spell ratio | 5.7× | 16.5× | 11.0× |
| LargeOutlineParsing | 0.411 | 0.667 | 0.667 |
| LargeDocumentStatistics | 0.781 | 0.710 | 1.041 |
| ReturnOnAListLine | 2.80 | 2.79 | 3.17 |

- Task 3 moved `MarkdownRangeAnalyzer`, `MathDelimiters` and `MermaidFence`. They make up most of
  the whole-document pass, so the reference tripled.
- Task 4 moves `MarkdownWritingToolsProtection.protectedRanges`, which the hot path calls, so
  `checkableRanges` rises too. `DocumentStatistics` and list continuation move as well, so those
  rows rise too.
- Full default plan at Task 4: `[perf] checkableRanges 7.503 ms/call vs whole-document 80.187
  ms/call — 10.7×`.

The `MarkdownSpellCheckPerformanceTests` doc comment says this test runs in Debug and that Debug is
"~3.6× slower" than the shipped build. In this project that is not true: the app's Debug has been
`-O` all along. Only the moved code now runs at `-Onone` in Debug.

**Ratio-gate sensitivity (concern, thresholds unchanged).**
- The gate runs in the Debug default plan, where the reference now pays `-Onone`. At baseline the
  ratio was 5.7×, 1.4× above the 4× floor. It is now 10.7–11.0×, about 2.7× above it.
- So the scoped path could now get about 2.7× slower before the gate fails; at baseline the limit
  was about 1.4×.
- The regression the gate exists for, a whole-document pass in the checking path, would still score
  about 1×. Both sides would run the same `-Onone` package code, so that case is still caught.
- The loss is for partial slowdowns between about 1.4× and 2.7×.
- Options, all for the controller to decide: give the package `-O` in Debug through
  `unsafeFlags` or settings, measure the gate in an optimised build, or recalibrate.

Release build at Task 4 (`xcodebuild -configuration Release build`, after `clean`): BUILD SUCCEEDED.
iOS Simulator build of the `LineformCore` scheme: BUILD SUCCEEDED.

## Task 5: search and file tree model moved into LineformCore

Seven files moved verbatim into `Packages/LineformCore/Sources/LineformCore/Search/`:
`EditorSearchResolver`, `CrossFileSearchResolver`, `CrossFileSearchModel` (from `Editor/`) and
`OutlineFileTree`, `OutlineFileSortOrder`, `QuickOpenIndex`, `UbiquitousItemDownloader` (from
`Outline/`). The package built with the whole group on the first try: no file needed an app type,
nothing was split or left behind. `DirectoryEventMonitor` and `OutlineFileBrowserStore` stay in
the app, as the plan says.

Edits beyond `public`:
- An explicit `public init(id:title:systemImage:state:items:)` on `OutlineFileRoot`, with the same
  labels and order as the memberwise init. The app constructs it.
- An empty `public init() {}` on `CrossFileSearchFileReader`, which has no instance stored
  properties. `CrossFileSearchModel`'s public init uses it as a default argument.
- `Sendable` on `QuickOpenEntry` and `OutlineFileSortOrder`. A public type loses the implicit
  conformance an internal one had:
  - `QuickOpenEntry`: without it, `CrossFileSearchModel.search` fails a Swift 6 region-isolation
    check, because it sends `entries` into the nonisolated `scan`.
  - `OutlineFileSortOrder`: without it, `OutlineSidebarView` gets a new "capture of non-Sendable"
    warning.
- `CrossFileSearchResolver` and `EditorSearchToolbarPresentation` stay internal. No app code uses
  them; only the package and `@testable` tests do.

Persisted identifiers: `OutlineFileSortOrder`'s raw values are its case names (`name`,
`dateCreated`, `dateModified`), and they did not change. The defaults keys live in
`OutlineFileBrowserStore`, which stays in the app. `OutlineFileTreeItem`'s `CodingKeys` did not
change either.

Strings: 6 keys.
- Moved: "Date Created", "Date Modified", "Search for %@. No matches." and
  "Search for %@. %@. Result %lld of %lld.".
- Copied with `--keep-in-app`:
  - "Name": `TextField("Name")` in `EditorContainerView` uses it.
  - "%lld matches": `CrossFileSearchResultsView` uses it.
- The script warned that the "Result %lld of %lld." entry's `en` stringUnit is in state `new`.
  That was already true in the app catalog, and the entry moved unchanged.
- The built package bundle's `ja` and `de` tables hold all six keys, translated, including the
  plural `stringsdict` entry for "%lld matches".

Tests: `CrossFileSearchResolverTests`, `CrossFileSearchModelTests`, `QuickOpenIndexTests` and
`OutlineFileSortOrderTests` moved (38 tests). The only change in each is the import.
`OutlineSidebarViewTests`, `EditorDisplayModeTests` and `RobustnessProbeTests` stay, because they
use app types. They already had `@testable import LineformCore`.

Gates: package 287, app 1696, default plan 1983, so unique tests are still 1983.

## Task 6: reading model and speech moved into LineformCore

Ten files moved verbatim into `Packages/LineformCore/Sources/LineformCore/ReadingExperience/`:
`ThemeID`, `ReadingProfile` (with `FontID` and `FocusMode`), `ReadingPreset`,
`ReadingProfileStore`, `SpeechController` (with `SystemSpeechSynthesizer`),
`SpeechLanguageDetector`, `SpeechTextExtractor`, `SpeechVoiceResolver`, `BundledFontRegistrar`,
and `ReadingAssistRangeResolver` (from `Lineform/Editor/`, deferred from Task 4 because it takes
`FocusMode`). Nothing imports AppKit or SwiftUI and nothing uses an app type, so nothing was split
or left behind. `SpeechController` uses only `AVSpeechSynthesizer`, which iOS also has; there is
no `NSSpeechSynthesizer`. `Theme`, `FontOption`, `LineformColors` and `ReadingExperiencePopover`
are AppKit/SwiftUI and stay in the app.

Edits beyond `public`:
- `Sendable` on `ThemeID`, `FontID`, `FocusMode`, `ReadingProfile` and `ReadingPreset`. A public
  type loses the implicit conformance an internal one had, and the package's own `static let`
  presets, `ReadingProfile.original` and `automaticDarkModeExemptThemes` fail Swift 6 checks
  without it.
- `public` on `ThemeID.init(from:)`/`encode(to:)`, on every `SystemSpeechSynthesizer` member that
  witnesses `SpeechSynthesizing`, and on its four `AVSpeechSynthesizerDelegate` methods (the
  compiler requires it; the methods stay the delegate witnesses, so didFinish/didPause/didContinue
  still arrive). `SystemSpeechSynthesizer` and `SpeechSynthesizing` are public only because the
  public `SpeechController.init(synthesizer:)` uses them as its default argument and parameter type.
- Internal still: `SpeechLanguageDetector`, `SpeechVoiceResolver`, `SpeechVoiceCandidate`,
  `SpeechVoiceDecision`, `FocusMode.displayName`, the unused `ReadingProfile` fields
  (`name`, `focusMode`, `reduceMarkdownNoise`, `reduceMotionEnabled`,
  `adaptiveReadabilityEnabled`), and the store's defaults-key constants.

Persisted identifiers (Review Focus 2): unchanged. `ReadingProfileStore` keeps
`UserDefaults.standard`, the storage key `Lineform.activeReadingProfile`,
`Lineform.activeReadingPresetID` and `Lineform.readingPresetOverrides`. `ReadingProfile` has no
`CodingKeys` (synthesized from unchanged property names); the raw values of `ThemeID`, `FontID`
and `FocusMode` and `ThemeID`'s legacy `"lowLight"` decode did not change.

Fonts (Review Focus 3): `BundledFontRegistrar.registerFonts(bundle: Bundle = .main)` is unchanged.
A default argument is evaluated in the caller, and `Bundle.main` is the running process's bundle
in any module, so `LineformApp`'s call still reads `Lineform.app/Contents/Resources/Fonts`. The
font files did not move. `FontOptionTests` (stays; it uses the app's `FontOption`) registers with
the default and resolves Atkinson Hyperlegible and OpenDyslexic in the test host.

Strings: 7 keys. Moved: "Original", "Quiet", "Paper", "Calm", "Focus" (`ReadingPreset.title`).
Copied with `--keep-in-app`: "Code" (`AppCommands`, `LineformTextView`, `SelectionToolbar`) and
"Image" (`MarkdownPreviewRenderer`).

Tests moved (72): `ReadingAssistRangeResolverTests`, `ReadingProfileTests`,
`SpeechControllerTests`, `SpeechLanguageDetectorTests`, `SpeechTextExtractorTests`,
`SpeechVoiceResolverTests`, `ReadingAssistPreferenceTests`; only the import changed. Stay (use app
types): `ReadingPresetTests`, `ReadingProfileStoreTests`, `ThemeTests`, `FontOptionTests` and
others, which gained `@testable import LineformCore`.

Gates: package 359, app 1624, default plan 1983, so unique tests are still 1983.
