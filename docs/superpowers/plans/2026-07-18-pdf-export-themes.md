# PDF Export Typographic Themes Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small curated set of typographic export presets (Standard / Manuscript / Compact / Article) to Lineform's PDF export + Print, chosen from a "Style" popup in the PDF save-panel accessory, persisted, and reused by Print — with "Standard" a **provable no-op** that reproduces today's export exactly.

**Architecture:** A pure, tested `ExportTypographyPreset` value type (in `Lineform/Preview`) maps each preset to the export-time typography (body face, size, line-height, heading scale, page margins). It produces the export `ReadingProfile` (light `.system` theme, dark ink pinned — exactly as today) and carries the two fields `ReadingProfile` does not have (`headingScale`, `pageMargins`), which are threaded into `MarkdownPreviewRenderer` (a defaulted `headingScale` parameter) and into `DocumentExportRenderer` (margin-aware overloads). The selected preset id persists in `UserDefaults` via a small helper mirroring `HiddenFoldersMenuState`. `EditorContainerView`'s save-panel accessory gains a Style popup; `exportPDF` passes the chosen preset, `printDocument` reads the persisted one. On-screen Read/Preview is untouched because every new parameter defaults to the Standard/no-op value.

**Tech Stack:** Swift, AppKit, SwiftUI, XCTest

## Global Constraints
- PDF export + Print ONLY — on-screen Read/Preview rendering is NOT changed. Every new renderer parameter defaults to its Standard value (`headingScale: CGFloat = 1.0`, `preset: .standard`), so the preview path is byte-identical.
- Typography/layout only (face, size, line-height, heading scale, margins); page stays LIGHT + dark ink. No color/dark PDFs. `exportReadingProfile(basedOn:)` still pins `themeID = .system` and `highContrastEnabled = false`, exactly like the current `DocumentExportRenderer.exportProfile(from:)`.
- ~4 curated presets; "Standard" reproduces today's export EXACTLY (proven no-op via a unit test asserting `ExportTypographyPreset.standard.exportReadingProfile(basedOn:) == DocumentExportRenderer.exportProfile(from:)`).
- System/bundled fonts only — NO new font bundling. `ExportFontFace` maps to existing `FontID` values (`.sfPro`, `.newYork`, `.atkinsonHyperlegible`, `.openDyslexic`).
- Style chosen in the PDF save-panel accessory (alongside the existing paper-size popup), persisted in `UserDefaults`; Print reuses the persisted style (no Print-panel UI in v1).
- Unknown/absent persisted id falls back to `.standard`.
- Follow the repo's module boundaries (preset + renderer changes in `Lineform/Preview`; persistence helper next to the other menu/state helpers; save-panel wiring in `Lineform/Editor/EditorContainerView.swift`). No unrelated refactors.
- Verification (per task) runs the pure default plan; the hosted PDF-byte plan (`DocumentExportPDFHostedTests`) is run once, manually, before considering the feature done (it exercises `NSPrintOperation`).

---

## Task 1 — `ExportFontFace` + `ExportTypographyPreset` (pure, tested)

Create the preset value type and its no-op guarantee. `standard` carries `bodyFace = nil` and `lineHeightMultiple = nil` ("inherit the user's reading profile") so that `standard.exportReadingProfile(basedOn:)` is identical to today's `DocumentExportRenderer.exportProfile(from:)` for **any** base profile.

**Files:**
- `Lineform/Preview/ExportTypographyPreset.swift` (new)
- `LineformTests/ExportTypographyPresetTests.swift` (new)
- `Lineform.xcodeproj/project.pbxproj` (register both new files — hand-rolled IDs, 4 sections, sequential `1F0000xx`; see repo memory note "pbxproj hand-rolled IDs")

**Interfaces:**
```swift
// Lineform/Preview/ExportTypographyPreset.swift

/// The body font faces an export preset may pin. System/bundled only — no new fonts.
enum ExportFontFace: String, Equatable, CaseIterable {
    case system        // San Francisco
    case serif         // New York (system serif)
    case atkinson      // Atkinson Hyperlegible (bundled)
    case openDyslexic  // OpenDyslexic (bundled)

    var fontID: FontID {
        switch self {
        case .system: return .sfPro
        case .serif: return .newYork
        case .atkinson: return .atkinsonHyperlegible
        case .openDyslexic: return .openDyslexic
        }
    }
}

/// A curated typographic style for PDF export / Print. Typography + layout ONLY; the page always
/// stays light with dark ink (`exportReadingProfile` pins `.system` + no high contrast, exactly
/// like the fixed export profile it replaces). `Standard` leaves `bodyFace`/`lineHeightMultiple`
/// nil so it inherits the user's reading profile and is a provable no-op.
struct ExportTypographyPreset: Identifiable {
    let id: String
    let displayName: String
    /// nil = inherit the user's reading-profile font face (Standard).
    let bodyFace: ExportFontFace?
    let bodyPointSize: CGFloat
    /// nil = inherit the user's reading-profile line height (Standard).
    let lineHeightMultiple: CGFloat?
    /// Multiplier on the per-level heading size boost over body (1.0 = unchanged).
    let headingScale: CGFloat
    let pageMargins: NSEdgeInsets

    static let standard: ExportTypographyPreset
    static let manuscript: ExportTypographyPreset
    static let compact: ExportTypographyPreset
    static let article: ExportTypographyPreset
    static let all: [ExportTypographyPreset]   // [standard, manuscript, compact, article]

    /// Resolve a persisted id to a preset; unknown/absent → `.standard`.
    static func preset(withID id: String?) -> ExportTypographyPreset

    /// Build the export ReadingProfile: start from the user's profile, pin the light `.system`
    /// theme + no high contrast + the preset body size, and override face/line-height only when
    /// the preset declares them. `headingScale` and `pageMargins` are NOT ReadingProfile fields;
    /// they are threaded separately (renderer heading scale + DocumentExportRenderer margins).
    func exportReadingProfile(basedOn base: ReadingProfile) -> ReadingProfile
}
```

Preset values (asserted by tests):

| id | bodyFace | bodyPointSize | lineHeightMultiple | headingScale | pageMargins (t,l,b,r) |
|----|----------|---------------|--------------------|--------------|-----------------------|
| standard | nil | 12 | nil | 1.0 | 72,72,72,72 |
| manuscript | .serif | 12 | 2.0 | 1.0 | 90,90,90,90 |
| compact | .system | 10 | 1.2 | 0.85 | 54,54,54,54 |
| article | .serif | 12 | 1.5 | 1.25 | 72,72,72,72 |

`exportReadingProfile(basedOn:)` body:
```swift
func exportReadingProfile(basedOn base: ReadingProfile) -> ReadingProfile {
    var copy = base
    copy.themeID = .system
    copy.highContrastEnabled = false
    copy.fontSize = Double(bodyPointSize)
    if let bodyFace { copy.fontID = bodyFace.fontID }
    if let lineHeightMultiple { copy.lineHeightMultiple = Double(lineHeightMultiple) }
    return copy
}
```

`preset(withID:)`:
```swift
static func preset(withID id: String?) -> ExportTypographyPreset {
    guard let id, let match = all.first(where: { $0.id == id }) else { return standard }
    return match
}
```

Steps:
- [ ] Write `LineformTests/ExportTypographyPresetTests.swift` with a failing test class `ExportTypographyPresetTests` containing:
  - `testStandardExportProfileEqualsCurrentFixedExportProfile()` — for both `ReadingProfile.original` and a customized profile (set `themeID = .night`, `highContrastEnabled = true`, `fontID = .newYork`, `fontSize = 21`, `lineHeightMultiple = 1.7`, `letterSpacing = 1.5`, `paragraphSpacing = 13`), assert `ExportTypographyPreset.standard.exportReadingProfile(basedOn: p) == DocumentExportRenderer.exportProfile(from: p)`. (Uses `ReadingProfile`'s synthesized `Equatable`.)
  - `testEachPresetYieldsItsDeclaredFields()` — assert `manuscript.bodyFace == .serif`, `manuscript.bodyPointSize == 12`, `manuscript.lineHeightMultiple == 2.0`, `manuscript.headingScale == 1.0`, `manuscript.pageMargins.left == 90`; `compact.bodyFace == .system`, `compact.bodyPointSize == 10`, `compact.lineHeightMultiple == 1.2`, `compact.headingScale == 0.85`, `compact.pageMargins.top == 54`; `article.bodyFace == .serif`, `article.headingScale == 1.25`, `article.bodyPointSize == 12`.
  - `testExportReadingProfileAppliesFaceSizeAndLineHeightFromPreset()` — `manuscript.exportReadingProfile(basedOn: .original)` has `fontID == .newYork`, `fontSize == 12`, `lineHeightMultiple == 2.0`, `themeID == .system`, `highContrastEnabled == false`.
  - `testExportFontFaceMapsToExistingFontIDs()` — `ExportFontFace.system.fontID == .sfPro`, `.serif.fontID == .newYork`, `.atkinson.fontID == .atkinsonHyperlegible`, `.openDyslexic.fontID == .openDyslexic`.
  - `testAllListsFourPresetsStandardFirst()` — `ExportTypographyPreset.all.map(\.id) == ["standard", "manuscript", "compact", "article"]`.
  - `testPresetWithIDResolvesKnownAndFallsBackToStandard()` — `preset(withID: "compact").id == "compact"`; `preset(withID: "bogus").id == "standard"`; `preset(withID: nil).id == "standard"`.
- [ ] Run to fail (compile failure — types don't exist yet):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/ExportTypographyPresetTests`
- [ ] Create `Lineform/Preview/ExportTypographyPreset.swift` with `import AppKit`, `ExportFontFace`, and `ExportTypographyPreset` including all four `static let` presets (values from the table), `all`, `preset(withID:)`, and `exportReadingProfile(basedOn:)` exactly as above.
- [ ] Register both new files in `Lineform.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, group, and Sources/Tests build phases; test file into the LineformTests target).
- [ ] Run to pass: same `-only-testing:LineformTests/ExportTypographyPresetTests` command. Expect all 6 tests passing, 0 failures.
- [ ] Commit: `PDF export presets: ExportTypographyPreset value type + no-op guarantee`.

---

## Task 2 — Thread `headingScale` into `MarkdownPreviewRenderer` (defaulted no-op)

`headingScale` is not a `ReadingProfile` field, so it is a defaulted parameter on the render path. Default `1.0` leaves on-screen Read/Preview byte-identical.

**Files:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift`
- `LineformTests/MarkdownPreviewRendererHeadingScaleTests.swift` (new; register in pbxproj)

**Interfaces (exact edits):**
```swift
// render(...) — add trailing defaulted parameter:
func render(
    _ text: String,
    profile: ReadingProfile,
    columnWidth: CGFloat,
    mermaidProvider: MermaidImageProviding,
    mathProvider: MathImageProviding,
    diagramLog: DiagramFailureLogging,
    reportRegistry: DiagramReportRegistry,
    appVersion: String,
    fitTablesToWidth: Bool = false,
    headingScale: CGFloat = 1.0
) -> NSAttributedString

// appendLines(...) — add trailing parameter (no default; internal, called once):
private func appendLines(
    _ range: Range<Int>,
    to output: NSMutableAttributedString,
    lines: [String],
    lineRanges: [NSRange],
    profile: ReadingProfile,
    theme: Theme,
    mathProvider: MathImageProviding,
    bodyAttributes: [NSAttributedString.Key: Any],
    bodyBlockSpacingAttributes: [NSAttributedString.Key: Any],
    codeAttributes: [NSAttributedString.Key: Any],
    codeBlockSpacingAttributes: [NSAttributedString.Key: Any],
    blockSpacingLineIndexes: Set<Int>,
    headingScale: CGFloat
)

// headingAttributes(...) — add parameter and apply it to the boost:
private func headingAttributes(
    level: Int,
    profile: ReadingProfile,
    usesBlockSpacing: Bool,
    headingScale: CGFloat
) -> [NSAttributedString.Key: Any]
```

Inside `headingAttributes`, change the resolved size line from
`size: bodyFont.pointSize + sizeBoost`
to
`size: bodyFont.pointSize + sizeBoost * headingScale`.

At the `render` `case .lines` call site, pass `headingScale: headingScale` into `appendLines`. At the `appendLines` heading branch, pass `headingScale: headingScale` into `headingAttributes`. The back-compat `render(_:profile:)` convenience (which calls the full `render`) needs no change — it inherits the `1.0` default.

Steps:
- [ ] Write `LineformTests/MarkdownPreviewRendererHeadingScaleTests.swift`, class `MarkdownPreviewRendererHeadingScaleTests`:
  - Helper `firstHeadingFontSize(scale:)`: render `"# Title\n\nBody"` with `MarkdownPreviewRenderer().render("# Title\n\nBody", profile: .original, headingScale: scale)` via the back-compat convenience is not enough (no `headingScale` param) — instead call the full `render` with disabled providers: `MarkdownPreviewRenderer().render("# Title\n\nBody", profile: .original, columnWidth: 600, mermaidProvider: DisabledMermaidImageProvider(), mathProvider: DisabledMathImageProvider(), diagramLog: NullDiagramFailureLog(), reportRegistry: DiagramReportRegistry(), appVersion: "0", headingScale: scale)`. Read the `.font` attribute at offset 0 (the heading run) and return its `pointSize`.
  - `testDefaultHeadingScaleMatchesUnscaledBoost()` — `firstHeadingFontSize(scale: 1.0)` equals `ReadingProfile.original.fontSize + 11` (the level-1 boost), i.e. `28`.
  - `testHeadingScaleAmplifiesTheBoostOverBody()` — `firstHeadingFontSize(scale: 1.5) == 17 + 11 * 1.5` (`33.5`); `firstHeadingFontSize(scale: 0.0) == 17` (body size, boost removed).
  - `testHeadingScaleDoesNotChangeBodyRun()` — render with `scale: 1.5`; the body paragraph run's font `pointSize` is still `17`.
- [ ] Run to fail:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownPreviewRendererHeadingScaleTests`
- [ ] Apply the three signature edits + the two call-site edits + the `sizeBoost * headingScale` change.
- [ ] Register the new test file in pbxproj.
- [ ] Run to pass: same `-only-testing` command. Expect 3 tests passing.
- [ ] Regression: run the existing renderer/export suites to confirm the `1.0` default is a no-op:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentExportRendererTests` (all previously-green tests still green).
- [ ] Commit: `PDF export presets: heading-scale parameter on the preview renderer (default no-op)`.

---

## Task 3 — Thread `ExportTypographyPreset` into `DocumentExportRenderer`

Parameterize the export renderer by a preset (default `.standard`), deriving the export profile from `preset.exportReadingProfile(basedOn:)`, the page margins from `preset.pageMargins`, and the heading scale from `preset.headingScale`. Keep the existing `margin`/`contentSize(for:)`/`makePrintInfo(for:)` symbols working (Standard = 72pt all sides) so current callers and tests are untouched.

**Files:**
- `Lineform/Preview/DocumentExportRenderer.swift`
- `LineformTests/DocumentExportRendererTests.swift` (add cases to the existing class)

**Interfaces (exact edits):**
```swift
// Keep: static let margin: CGFloat = 72   (Standard's uniform margin; existing test anchor)
// Keep: static let bodyPointSize: Double = 12
// Keep: static func exportProfile(from:) -> ReadingProfile  (the no-op equality anchor; unchanged)

// New margin-aware content size; existing contentSize(for:) delegates with uniform `margin`.
static func contentSize(for paper: ExportPaperSize, margins: NSEdgeInsets) -> NSSize
static func contentSize(for paper: ExportPaperSize) -> NSSize   // unchanged behavior

// makeExportTextView / makePrintInfo / runOperation / runInteractivePrint / writePDF / pdfData
// each gain `preset: ExportTypographyPreset = .standard`:
@MainActor static func makeExportTextView(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard) -> NSTextView
@MainActor static func makePrintInfo(for paper: ExportPaperSize, margins: NSEdgeInsets) -> NSPrintInfo
@MainActor static func makePrintInfo(for paper: ExportPaperSize) -> NSPrintInfo   // delegates uniform `margin`
@MainActor @discardableResult static func writePDF(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard, to url: URL) -> Bool
@MainActor static func runInteractivePrint(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard)
@MainActor static func pdfData(text: String, profile: ReadingProfile, paper: ExportPaperSize, preset: ExportTypographyPreset = .standard) -> Data
```

Implementation notes:
```swift
static func contentSize(for paper: ExportPaperSize, margins: NSEdgeInsets) -> NSSize {
    let p = paper.sizeInPoints
    return NSSize(width: p.width - margins.left - margins.right,
                  height: p.height - margins.top - margins.bottom)
}
static func contentSize(for paper: ExportPaperSize) -> NSSize {
    contentSize(for: paper, margins: NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin))
}
```
- In `makeExportTextView`, replace `exportProfile(from: profile)` with `preset.exportReadingProfile(basedOn: profile)`, compute `let content = contentSize(for: paper, margins: preset.pageMargins)`, and pass `headingScale: preset.headingScale` into `MarkdownPreviewRenderer().render(...)`.
- `makePrintInfo(for:margins:)` sets `leftMargin = margins.left`, `rightMargin = margins.right`, `topMargin = margins.top`, `bottomMargin = margins.bottom`; the no-arg overload delegates with the uniform `margin`.
- `runOperation` gains `preset:` and forwards it to `makeExportTextView`; the private signature adds `preset: ExportTypographyPreset`. `runInteractivePrint`/`writePDF` build `makePrintInfo(for: paper, margins: preset.pageMargins)` and forward `preset:`. `pdfData` forwards `preset:` to `writePDF`.

Steps:
- [ ] Add failing cases to `DocumentExportRendererTests`:
  - `testContentSizeWithAsymmetricMarginsSubtractsEachEdge()` — `contentSize(for: .usLetter, margins: NSEdgeInsets(top: 54, left: 90, bottom: 54, right: 90))` equals `NSSize(width: 612 - 180, height: 792 - 108)`.
  - `testDefaultContentSizeUnchangedForStandardMargin()` — `contentSize(for: .a4)` still equals `NSSize(width: 595 - margin*2, height: 842 - margin*2)`.
  - `testMakeExportTextViewWithStandardPresetMatchesLegacyProfile()` — the view produced by `makeExportTextView(text:"Body", profile: custom, paper: .usLetter)` (default preset) has its first character's `.font` `pointSize == DocumentExportRenderer.bodyPointSize` and `.foregroundColor` near-black (reuse the dark-ink assertion), i.e. Standard is unchanged.
  - `testMakeExportTextViewWithManuscriptPresetAppliesSerifSizeAndMargins()` — `makeExportTextView(text:"# H\n\nBody", profile: .original, paper: .usLetter, preset: .manuscript)`: the body run font's `familyName` is the system serif (assert it is NOT `.original`'s SF Pro family — compare against `FontOption.option(for: .newYork)!.resolvedFont(size: 12).familyName`), and `view.frame.width == contentSize(for: .usLetter, margins: .manuscript's 90).width` (`612 - 180 == 432`).
- [ ] Run to fail:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentExportRendererTests`
- [ ] Apply the `DocumentExportRenderer` edits (margin-aware overloads + `preset:` threading + serif/heading-scale wiring in `makeExportTextView`).
- [ ] Run to pass: same `-only-testing:LineformTests/DocumentExportRendererTests`. Expect the 4 new + all existing cases green.
- [ ] Commit: `PDF export presets: parameterize DocumentExportRenderer by preset (Standard unchanged)`.

---

## Task 4 — Persist the selected style id (round-trip, fallback to Standard)

A small `UserDefaults`-backed helper mirroring `HiddenFoldersMenuState` (value-type static API — the popup only needs read/write, no observation). Unknown/absent id → `.standard`.

**Files:**
- `Lineform/Preview/ExportStylePreference.swift` (new; register in pbxproj)
- `LineformTests/ExportStylePreferenceTests.swift` (new; register in pbxproj)

**Interfaces:**
```swift
// Lineform/Preview/ExportStylePreference.swift
import Foundation

/// Persists the chosen PDF-export typography preset id. Mirrors the `HiddenFoldersMenuState`
/// pattern: plain `UserDefaults`, injectable for tests. Unknown/absent → `.standard`.
enum ExportStylePreference {
    static let defaultsKey = "Lineform.export.typographyStyleID"

    static func selectedPresetID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey) ?? ExportTypographyPreset.standard.id
    }

    static func setSelectedPresetID(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: defaultsKey)
    }

    static func selectedPreset(defaults: UserDefaults = .standard) -> ExportTypographyPreset {
        ExportTypographyPreset.preset(withID: defaults.string(forKey: defaultsKey))
    }
}
```

Steps:
- [ ] Write `LineformTests/ExportStylePreferenceTests.swift`, class `ExportStylePreferenceTests`, each test using an isolated `UserDefaults(suiteName:)` (unique per test, `removePersistentDomain(forName:)` in `tearDown`):
  - `testAbsentPreferenceResolvesToStandard()` — fresh suite: `selectedPresetID(defaults:) == "standard"` and `selectedPreset(defaults:).id == "standard"`.
  - `testKnownPresetIDRoundTrips()` — `setSelectedPresetID("compact", defaults:)`; then `selectedPresetID == "compact"` and `selectedPreset(defaults:).id == "compact"`.
  - `testUnknownPersistedIDFallsBackToStandard()` — write `"nonsense"` via `setSelectedPresetID`; `selectedPreset(defaults:).id == "standard"` (but `selectedPresetID` returns the raw stored string — assert the *preset* falls back, not the raw getter).
- [ ] Run to fail:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/ExportStylePreferenceTests`
- [ ] Create `Lineform/Preview/ExportStylePreference.swift`; register both files in pbxproj.
- [ ] Run to pass: same `-only-testing:LineformTests/ExportStylePreferenceTests`. Expect 3 tests passing.
- [ ] Commit: `PDF export presets: persist selected style id (unknown/absent → Standard)`.

---

## Task 5 — Save-panel Style popup + wire exportPDF/print (manual-verified)

Add a "Style" popup to the existing export save-panel accessory and pass the chosen preset into the renderer; persist the choice; make Print read the persisted preset. This is AppKit/SwiftUI glue in `EditorContainerView` (not unit-testable in the pure plan) — verified by building + a manual export/print pass and the hosted PDF plan.

**Files:**
- `Lineform/Editor/EditorContainerView.swift`

**Interfaces (exact edits):**
```swift
// New popup builder, mirroring makePaperSizePopup(); seeds from the persisted style.
private func makeStylePopup() -> NSPopUpButton {
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 25))
    for preset in ExportTypographyPreset.all {
        popup.addItem(withTitle: preset.displayName)
    }
    let currentID = ExportStylePreference.selectedPresetID()
    if let index = ExportTypographyPreset.all.firstIndex(where: { $0.id == currentID }) {
        popup.selectItem(at: index)
    }
    return popup
}

// makePaperSizeAccessory(popup:) → makeExportAccessory(paperPopup:stylePopup:)
// two labeled rows ("Paper Size:" / "Style:") stacked in the accessory container.
private func makeExportAccessory(paperPopup: NSPopUpButton, stylePopup: NSPopUpButton) -> NSView
```

- In `exportCurrentDocumentAsPDF()`: build both popups, set `panel.accessoryView = makeExportAccessory(paperPopup: paperPopup, stylePopup: stylePopup)`. In the `write` closure, resolve the preset from `stylePopup.indexOfSelectedItem` (`ExportTypographyPreset.all[safe:] ?? .standard`), call `ExportStylePreference.setSelectedPresetID(preset.id)`, and pass `preset: preset` into `DocumentExportRenderer.writePDF(...)`.
- In `printCurrentDocument()`: pass `preset: ExportStylePreference.selectedPreset()` into `DocumentExportRenderer.runInteractivePrint(...)`.

Steps:
- [ ] Add `makeStylePopup()` and rename/extend the accessory builder to include the Style row; update `exportCurrentDocumentAsPDF()` to read the popup, persist, and pass `preset:`; update `printCurrentDocument()` to pass the persisted preset.
- [ ] Build (no test target needed for this glue), confirm it compiles:
  `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
- [ ] Manual verification (per CLAUDE.md quality bar — GUI, so do it or have the user do it): open a document with headings, a table, and a paragraph; File ▸ Export as PDF…; confirm the accessory shows **Paper Size** and **Style** popups. Export under **Standard** and confirm it is visually identical to a pre-change export (same body size/margins). Export under **Manuscript**, **Compact**, **Article**; confirm each varies face/size/leading/heading-scale/margins, the page stays **white with dark ink** in every case, and no color/dark page appears. Re-open the panel and confirm the last-picked Style is preselected (persistence). Then File ▸ Print… (⌘P) and confirm it uses the persisted Style with no extra Print-panel UI.
- [ ] Commit: `PDF export presets: Style popup in the save-panel accessory; Print reuses persisted style`.

---

## Final verification

- [ ] Full default plan (all pure tests, ~370+ cases, run once at the end; warn the user about the TCC Documents prompt — see CLAUDE.md):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  Read the output; report exact pass/fail counts.
- [ ] Hosted PDF plan (exercises `NSPrintOperation`; quit Xcode first, quiet machine — see CLAUDE.md hosted-plan section):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -testPlan LineformHosted
  ```
  Confirm `DocumentExportPDFHostedTests` still produces valid PDFs (Standard path unchanged).
- [ ] Do NOT weaken any existing test. `testExportProfileFixesBodySizeButKeepsFaceAndRhythm` and the white-page/dark-ink tests MUST stay green — they are the anchor for the Standard no-op.
