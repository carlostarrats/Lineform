# Localization Phase 2 — Prose and CJK Fonts

Date: 2026-08-05 (revised 2026-08-05 after Phase 1 shipped and was reviewed
against the code)

**Status: partially implemented, 2026-08-05 (branch `work-2026-08-05-3`).**

- **Item 1 (`MarkdownReference` prose) — SHIPPED.** `sections(in:)` and
  `Row.accessibilityLabel(in:)` are bundle-parameterized, the four
  `rendersSyntaxAsCode == false` label rows localize and the 25 syntax rows do
  not, the 90-character ceiling is enforced per language, and the
  `MarkdownReference.swift` sweep exemption is closed down to two literals.
- **Item 2 (CJK font cascade) — BUILT, MEASURED, REMOVED.** It shipped as
  `MarkdownFontCascade`, was reviewed three times, and every part of the premise
  below turned out to be false on macOS 26: CoreText's implicit substitution
  already resolves CJK correctly *including bold* (`.systemFont` +
  `.boldFontMask` → `.PingFangUITextSC-Bold`), so "`NSFontManager.convert` drops
  the cascade" was a problem that existed only because we attached a cascade. It
  also made typography worse — the system picks metric-compatible optical UI
  variants while a hardcoded list can only name the taller public families, so
  one mixed document went from line heights `18, 18, 18, 18, 18` to
  `18, 24, 24, 18, 24` and PDFs re-paginated; the serif reading font lost Songti
  SC. (Re-measured 2026-08-05: the five-line EN/zh/ja/EN/ja fixture in
  `CJKFontFallbackTests.mixedScriptDocument`, SF Pro 16pt, `NSLayoutManager`
  line-fragment heights, cascade `["Hiragino Sans", "PingFang SC"]` — the order
  that shipped. An earlier draft of this line said `18,24,18,24,24`, which
  matches neither the fixture's line order nor either cascade order; the figure
  above is the measured one and agrees with
  `docs/architecture/app-integration.md`. A PingFang-first cascade is not better,
  it is worse: `18, 22, 27, 18, 27`, three distinct heights.) The whole feature
  was reverted. `LineformTests/CJKFontFallbackTests.swift` now pins the platform
  behaviour instead, and the reasoning is in
  `docs/architecture/app-integration.md`. Do not rebuild it.
- **Item 4 (read-aloud voice) — SHIPPED.** `SpeechLanguageDetector` plus a
  widened `SpeechSynthesizing.speak(_:languageCode:)` seam.
- **Item 3 (BIZ UDGothic) — still deferred**, on the 8.9 MB alone, exactly as
  argued below. Item 2 stands without it.
- **Item 5 (CJK reading-preset tuning) — still deferred**, and still
  under-specified: there is no mechanism to vary a preset by script without
  minting new persisted profile identities. Decide the schema first.

Four corrections the implementation produced, recorded here so the text below is
not read as current in these places: glossary exemptions match on the whole
catalog key rather than the term; the Spanish word for Preview was
standardized on Apple's `Vista previa` across both phases; "the pairing is
unchosen" (below, CJK font cascade) is simply wrong — CoreText's substitution
is locale-informed and metric-compatible, which is why item 2 was removed
rather than re-ordered; and "non-accessibility faces cascade to Hiragino Sans
as normal" (below, BIZ UDGothic) describes a cascade that no longer exists —
nothing in the app declares one. The
`Lineform/Resources/*.md` question under "Unresolved Across Both Phases" was
**not** taken up and remains open.

Original status: Deferred. **Decided after Phase 1 ships and has been seen running in
German and Japanese.** Companion to
`2026-08-05-localization-phase-1-chrome-design.md`, which carries the shared
context: language set, refactor mechanism, translation-quality mechanisms, and
test-locale infrastructure — all assumed present here.

## Why Deferred

These surfaces cost the most and return the least. A user can write, save,
export, and navigate with none of them localized. They also concentrate the
idiom risk of having no native reviewers: long-form sentences are where
machine-plausible translation shows, in a way "Save As…" never does. Deciding
after Phase 1 means deciding with evidence — how the translations read in a
running app — instead of in advance of it.

## What Phase 1 Already Did

Recorded here so this phase is not re-scoped from memory. Phase 1 shipped as
merge `3c39ccc`.

- **The first-launch intro overlay is done** — native button plus an injected
  string table for the web page (`db2cbd0`;
  `FirstLaunchIntroOverlay.swift:501, 522`, `localizationUserScript()`;
  `data-l10n-id` attributes in `Lineform/Resources/FirstLaunchIntro/index.html`).
  It is not a Phase 2 item and is listed under Out of Scope below so it stops
  being re-proposed.
- **The font picker's group headings are done** — `FontOption.swift:17, 24, 32`
  (`System` / `Writing` / `Reading & Accessibility`), plus `Monospaced` at `:28`
  with a comment recording why that one name localizes and the face names do
  not. Phase 1 owns the "font names are never translated" rule.
- **The deferral is recorded, not silently skipped** —
  `LocalizationSourceSweepTests.swift:38–39` exempts `MarkdownReference.swift`
  with the reason "explicitly deferred to Localization Phase 2 by the Phase 1
  spec." Item 1 below removes that allowlist entry.
- **`MarkdownReference.swift` was not touched** by Phase 1 — its last content
  commit is `73e3912` (2026-07-26, the underscore-emphasis copy fix), which
  predates the localization work.

## The Test-Locale Mechanism

Load-bearing for item 1, and the thing an implementer is most likely to get
wrong. **`String(localized:…locale:)` does not switch which `.lproj` answers** —
its `locale:` argument controls interpolated-value *formatting* only. Asserting
a German string requires the bundle-based path the repo already uses:
`Bundle.main.path(forResource: languageCode, ofType: "lproj")` →
`Bundle(path:)` → `localizedString(forKey:value:table:)`, as in
`MainMenuIconDecorator.swift:177`. The standing rule is
`docs/architecture/app-integration.md:95–100`: non-English behavior is asserted
by feeding a language code into pure functions, never by flipping the process
locale.

So `MarkdownReference.sections` cannot stay a bare `static let` of resolved
strings. It needs a per-bundle entry point (e.g.
`MarkdownReference.sections(in: Bundle)`, defaulting to `.main`) for the tests
to reach a non-English resolution at all. That is the actual shape of item 1's
refactor.

## Contents

### 1. `MarkdownReference` prose

The sidebar's "Markdown Basics" tab: 29 rows across 5 sections of syntax +
explanation from `Lineform/Outline/MarkdownReference.swift`, today a bare
`static let sections` (`:28`) — which the Test-Locale Mechanism above requires
replacing with `sections(in:)`, so this item is not as cheap as "it's just
static data" suggests.

- The **syntax column is never translated** — `# Title`, `**bold**` are
  Markdown, the same rule as callout labels: document-language text stays in the
  document's language. Only `explanation` and section `title`s localize.
- **Exception: four rows put an English *label* in the syntax column.**
  `rendersSyntaxAsCode: false` marks rows whose `syntax` is, per the file's own
  comment (`MarkdownReference.swift:10–11`), "a plain label, not literal
  syntax" — `"Tab"` (`:48`), `"Block Spacing"` (`:49`), `"Spelling"` (`:62`),
  `"Skipped"` (`:63`). Under the blanket rule these stay English in a Japanese
  sidebar, and the row's copy button
  (`OutlineMarkdownBasicsTabView.swift:114`) puts an English word on the
  pasteboard. **`rendersSyntaxAsCode == false` is already the exact predicate
  for "this is prose, translate it"** — so localize these four and leave every
  `true` row verbatim. (`"Return"` at `:66` renders as code and is a key name;
  it stays.) Doing so moves those rows' `Row.id`, which is `syntax` — see the
  identity note below.
- Keyboard-shortcut references in explanations (`⌘1 sets it`, `:30`) survive
  translation verbatim — glyphs, not words. English *prose* in the same
  assertions does not (see the test list below).
- The `Row.accessibilityLabel` composition (`:18`,
  `"\(explanation) Syntax: \(syntax)"`) localizes its connective text. It is a
  `String`, so it hits SwiftUI's verbatim overload at
  `OutlineMarkdownBasicsTabView.swift:104` and must be localized at the
  definition site — the standing `LocalizationSourceSweepTests` rule. The same
  view's own `.accessibilityLabel("Markdown basics")` (`:75`) is a string
  *literal*, so it takes `LocalizedStringKey` and already localizes — catalog
  entry, no code change. `:155` is a **ternary** of two interpolated literals
  (`isCopied ? "Copied" : "Copy \(rowID)"`); it should bind the same overload,
  but confirm which one Swift actually selects before assuming it localizes — if
  it resolves to the `StringProtocol` overload it ships English no matter how
  complete the catalog is.
- **`Row.id` is `syntax` (`:14`) and `Section.id` is `title` (`:25`)**, consumed
  by `ForEach(…, id: \.element.id)` at `OutlineMarkdownBasicsTabView.swift:38`.
  Localizing titles makes a section's SwiftUI identity language-dependent, and
  localizing the four label rows does the same for those rows. Non-persisted, so
  the risk is a redundant view rebuild on language change, not data loss — but
  it is the "display string used as identity" pattern the repo warns about. If
  the label rows localize, give `Row` a stable non-display `id` rather than
  leaving identity on translated text.

**Test rework — all seven tests in `MarkdownReferenceTests.swift`.** Two distinct
effects, and conflating them is how earlier drafts miscounted:

*Compile break — six tests plus one production call site.* Turning
`static let sections` into `sections(in:)` touches every reader of `sections`:
tests at `:6, :8, :14, :22, :31, :39, :50`, and in production
`OutlineMarkdownBasicsTabView.swift:31–33` (`private var sections`), not the
`ForEach` at `:38`. `testAccessibilityLabelReadsExplanationThenSyntax` (`:56`)
builds its own `Row` and never reads `sections`, so it does not recompile.
Keeping a `.main`-defaulted overload avoids most of the churn.

*Semantic rework — all seven.* The default plan pins the process to `en`
(`app-integration.md:95–100`), so none of these fail today; each asserts
English-only and must be re-keyed or extended per language. Note the failure
mode when they are run against another language is a **loud failure with a
misleading diagnostic** ("missing # Title"), not a silent pass — the filters
return `nil` and the collections go empty, which the assertions then report as
missing content rather than as a lookup failure.

| Test | Line | Why it needs rework |
|---|---|---|
| `testSectionsCoverEveryGroupAndAreNonEmpty` | `:5` | Asserts the exact English title array (`:7`) |
| `testBasicsIncludesCoreSyntax` | `:13` | Filters `$0.title == "Markdown Basics"` (`:14`) — returns `nil` under another language, syntaxes go `[]` |
| `testBasicsIncludesCalloutSyntax` | `:21` | Same filter (`:22`), same mode |
| `testReferenceNamesTheEditingShortcuts` | `:30` | Glyphs survive translation, but `"Return starts the next"` (`:32`) is English prose |
| `testExplanationsStayConcise` | `:38` | Doesn't break — must be **extended** to loop the shipped languages, since the 90-character ceiling (`:41–44`) has to hold in each |
| `testBlockSpacingIsNotRenderedAsCode` | `:49` | Keyed on `$0.syntax == "Block Spacing"` (`:53`), which the label-row exception above makes one of the four translated rows |
| `testAccessibilityLabelReadsExplanationThenSyntax` | `:56` | Doesn't recompile, but `:58` asserts `"Bold. Syntax: **bold**"` — and this item localizes that `" Syntax: "` connective, so the expectation becomes language-dependent |

The last row is the one earlier drafts called "safe." It is safe from the
refactor and not from the feature: exempting it on "constructs its own `Row`"
stopped being true the moment the connective localized.

The 90-character ceiling is the item's real risk: German expansion runs 30–35%
over English, and several explanations are already near the cap.

### 2. CJK font cascade

Declare an explicit fallback via `NSFontDescriptor`'s cascade list: Hiragino
Sans for Japanese, PingFang SC for Simplified Chinese. Both ship with macOS —
`NSFont(name:)` resolves each, re-confirmed 2026-08-05 on macOS 26. Today
CoreText substitutes per glyph — nothing is broken, but the pairing is unchosen
(superseded — see status header) and a mixed Chinese/Japanese document can
render Chinese in a Japanese face.

Measured on macOS 26, so the implementation does not re-litigate them — and the
second result overturns what the first draft asserted:

- `NSFont(descriptor:size:)` still returns `nil` for a bogus family — the
  `isAvailable` nil-signal (`FontOption.swift:55–57`) survives a cascade list.
- **`NSFontManager.convert(_:toHaveTrait:)` DROPS an attached `.cascadeList` on
  the system fonts.** An earlier draft of this spec claimed the opposite; that
  claim was tested only against named families and is false where it matters.
  Measured on macOS 26 via `CTFontCopyAttribute(kCTFontCascadeListAttribute)`:

  | Base font | base | `.boldFontMask` | `.italicFontMask` |
  |---|---|---|---|
  | `.systemFont` (`.sfPro`) | 1 | **nil** | **nil** |
  | `.monospacedSystemFont` (`.jetBrainsMono`) | 1 | **nil** | **nil** |
  | `withDesign(.serif)` (`.newYork`) | 1 | **nil** | **nil** |
  | Helvetica | 1 | 1 | 1 |
  | Comic Sans MS | 1 | 1 | 1 |

  The list survives only for real named families. Atkinson Hyperlegible and
  OpenDyslexic were tested directly and both preserve it — which matters,
  because they are item 3's cascade targets.

**This is the item's central implementation constraint, not a footnote.** The
three branches that lose the cascade are exactly the three that need
`addingAttributes` in the first place, and every bold or italic run goes through
`NSFontManager.shared.convert`. Attaching the cascade in `availableFont(size:)`
alone would ship a fallback that works for body text and silently reverts to
per-glyph substitution for every heading, table header, callout title, and bold
or italic span in the default font.

**Three `resolvedFont` call sites, not one** — and the third puts the Write-mode
editor in scope, which earlier drafts left out entirely:

| Call site | Feeds |
|---|---|
| `MarkdownPreviewRenderer.swift:995` | `headingAttributes` → the `convert` at `:997` |
| `MarkdownSyntaxHighlighter.swift:35` | `baseAttributes(for:)` (`MarkdownPreviewRenderer.swift:100`) → the converts at `:334` (table header), `:556` (callout title), `:1308`/`:1312` (inline bold/italic) |
| `LineformTextView.swift:179–180` | The Write-mode editor font |

The five `convert` sites in `MarkdownPreviewRenderer.swift` (`:334, :556, :997,
:1308, :1312`) are the complete list for that file **and** for all of
`Lineform/` — but four of them take their base from the highlighter, not from
`:995`. Patching `:995` alone, as an implementer reading an earlier draft would
have, misses four of the five.

So item 2 is two changes across four files: attach the cascade at all three
`resolvedFont` consumers, **and** route trait conversion through a helper that
re-attaches it afterwards.

**`availableFont(size:)` has four branches with different mechanics**
(`FontOption.swift:60–70`) and the cascade cannot be attached the same way to
each:

- `.sfPro` → `.systemFont(ofSize:)` and `.jetBrainsMono` →
  `.monospacedSystemFont(…)` **never return nil** (non-optional by type), so the
  `isAvailable` nil-signal fires only on `default:` (Atkinson, OpenDyslexic,
  Comic Sans) and, in principle, on `.newYork` — whose `systemSerifFont`
  fallback is itself optional (`withDesign(.serif)` returns an optional).
- Attaching a cascade to those two needs
  `font.fontDescriptor.addingAttributes([.cascadeList: …])`, not the
  `[.family: …]` descriptor form. Verified: both keep `.AppleSystemUIFont` /
  `.AppleSystemUIFontMonospaced`, and `isFixedPitch` survives on the mono one.
- `.newYork` (`:64`) already falls through to `systemSerifFont(size:)`
  (`:76–85`) because `NSFont(name: "New York")` returns nil on macOS 26
  (re-confirmed). The serif path builds its own descriptor via
  `withDesign(.serif)` and must carry the cascade too, or New York silently
  loses it — and, per the table above, loses it again on every bold or italic
  conversion.

### 3. BIZ UDGothic — Japanese accessibility fallback

**As a cascade target only, never a picker entry** — a picker entry would face
every English user with a sixth, unreadable option. It becomes the Japanese
cascade target for Atkinson Hyperlegible and OpenDyslexic specifically, so the
accessibility group is honest for Japanese rather than decorative. Comic Sans
and non-accessibility faces cascade to Hiragino Sans as normal (superseded —
see status header).

- **Family:** `BIZUDGothic` (fixed full-width pitch — conventional for
  long-form Japanese body text), not proportional `BIZUDPGothic`. Confirm
  visually; the swap is a filename change.
- **Weights:** Regular and Bold. CJK has no italic; italic cascades to regular.
- **License — verified 2026-08-05 by fetching `OFL.txt` from
  `github.com/googlefonts/morisawa-biz-ud-gothic`:** SIL OFL 1.1 (dated
  26 February 2007), `OFL.txt` at repo root. Copyright line to be reproduced
  verbatim including its upstream error (the URL names the *mincho* repo):
  `Copyright 2022 The BIZ UDGothic Project Authors (https://github.com/googlefonts/morisawa-biz-ud-mincho)`.
  **No Reserved Font Name** — confirmed in the fetched text: the OFL's RFN
  provisions are present in §3 boilerplate, but no name is designated after the
  copyright statement. Attribution must not invent one. "BIZ UDGothic" is a
  Morisawa Inc. trademark, credited not licensed.
- **Size — measured 2026-08-05, re-verify at implementation:** 4,667,380 B +
  4,638,128 B = **8.9 MB**, against ~1 MB of currently bundled fonts. The
  largest single cost in either phase.
- **Every launch pays it, but a gate is cheap.**
  `BundledFontRegistrar.registerFonts` (`BundledFontRegistrar.swift:16–23`,
  called from `LineformApp.init()` at `LineformApp.swift:10`) is unconditional,
  so 8.9 MB of CJK faces would be `CTFontManagerRegisterFontsForURL`'d for
  English-only users. It iterates the **hardcoded `fontFileNames` array**
  (`:5–14`), not the folder — the Xcode folder reference governs *bundling*
  only. So a conditional gate is a filter over that array, a few lines, not an
  architectural change. Cost is real; the complication is not. Note this
  weakens the case for cutting item 3 rather than strengthening it.
- The counter-argument is recorded: the reasoning that settles Chinese
  ("accessibility comes from size, line-height, contrast controls") would also
  settle Japanese. It was accepted because a free UD-class face *exists* for
  Japanese and not for Chinese — declining it is choosing a worse experience
  where a better one was available for bundle size alone. **This remains the
  item most likely to be cut, and the cascade (item 2) stands on its own without
  it — but the case for cutting rests on the 8.9 MB alone.** Launch-time
  registration is not a second reason: it is gateable in a few lines, per the
  bullet above.

**Registration and paperwork.** Files go into `Lineform/Resources/Fonts/`, which
is a **folder reference** — `project.pbxproj:341`
(`lastKnownFileType = folder; path = Fonts`), with its build file at `:164`,
group entry at `:626`, and Resources phase entry at `:867`. So **no pbxproj
edit**, unlike the repo's usual four-section hand-edit. Names are appended to
`BundledFontRegistrar.fontFileNames` (`:5–14`). Then, per repo policy, the
credit sweep — **all five surfaces, not the two the first draft named**:

1. `OFL-BIZUDGothic.txt` shipped alongside in `Lineform/Resources/Fonts/`.
2. `Lineform/Resources/FontLicenseReview.md` — kept in sync with the bundled set.
3. `README.md` credits.
4. **`CLAUDE.md`'s Credits And Third-Party Materials section**, which enumerates
   the bundled fonts verbatim.
5. **`POSITIONING_AND_MARKETING.md`**, whose load-bearing rule is currently
   "only Atkinson Hyperlegible + OpenDyslexic are bundled fonts."

And one existing gate the first draft missed:
`LineformTests/ReleaseResourceTests.swift:117–126` hardcodes the license-file
list (`OFL-AtkinsonHyperlegible`, `OFL-OpenDyslexic`) and must gain
`OFL-BIZUDGothic`, or the release resource test fails.

**Chinese has no free UD-class equivalent** — PingFang SC is the best available;
accessibility comes from the size/line-height/contrast controls. Known
limitation. **OpenDyslexic has no CJK counterpart and will not get one** — it
works by weighting letter bottoms so similar Latin letters do not flip; Han
characters do not fail that way. **Font names are never translated**; the
picker's group headings localized in Phase 1, which owns that rule.
**Substitution is not surfaced in the UI** — the picker reads
"Atkinson Hyperlegible" while an all-Japanese document renders in the fallback;
standard Mac behavior, and the alternatives (hiding fonts per locale, annotating
pairings) are worse.

### 4. Read-aloud voice

`SpeechController.swift:112` builds `AVSpeechUtterance(string:)` with no
`voice`, so the system default follows the **UI language** — a Japanese-UI user
reading an English document gets a Japanese voice. Nothing else in the app sets
a voice; the two references to one (`SpeechController.swift:86`,
`SpeechTextExtractor.swift:189–190`) are comments confirming the omission was
deliberate for v1. Select the voice from the document's detected language
(`NLLanguageRecognizer` on the spoken text), not the UI locale.

**This is a seam change, not a one-line change.** `SpeechSynthesizing.speak(_ text: String)`
(`SpeechController.swift:24`) carries no language, so the protocol, its shipping
conformer `SystemSpeechSynthesizer.speak` (`:111`),
`SpeechController.startSpeaking`, and `FakeSynthesizer` all move together — and
CLAUDE.md's rule applies: the fake must model the *shipping* behavior (a stopped
utterance reports `didFinish`; pause defers to a word boundary) or it certifies
the bug instead of catching it. Detection runs on the extracted spoken text, so
it composes with the existing `activeWindowPayload` rules rather than touching
them.

Language detection is a heuristic on user prose: short documents and mixed-script
documents will misdetect. Falling back to the current behavior (system default)
when confidence is low is preferable to confidently choosing wrong.

### 5. CJK reading-preset tuning

The reading profiles' line-height and column-width presets are literal constants
in `Lineform/ReadingExperience/ReadingPreset.swift` — `lineHeightMultiple`
1.45–1.6 and `columnWidth` 680–820 (Paper/Quiet/Calm/Code/Focus 1.5 / 820;
Accessible 1.55 / 720; Dyslexia 1.6 / 740; Low Light 1.45 / 680; High Contrast
1.5 / 700; plus `ReadingProfile.original` at `ReadingProfile.swift:73–82`,
1.5 / 820). Nothing in them is *derived* from script metrics, so "Latin-tuned"
is accurate only in the sense that they were chosen while looking at English.
CJK glyphs are full-width and taller at the same point size, so the presets read
tighter in Japanese and Chinese.

**Scope is six presets, not ten.** `ReadingPreset.builtIn` (`:198–205`) draws
only `original, quiet, paper, code, calm, focus`. Accessible, Dyslexia, Low
Light, and High Contrast are defined but never shown — annotated as such at
`LocalizationSourceSweepTests.swift:96–99`. A tuning pass that "fixes the
presets" without knowing this spends four-tenths of its effort on dead
constants.

**This item is under-specified and should not be built as written.** There is no
mechanism to vary a preset by script: `ReadingProfile` carries one
`lineHeightMultiple`, and a profile's `name` is persisted `Codable` identity
(allowlisted at `LocalizationSourceSweepTests.swift:91–100`, where `:100` covers
`ReadingProfile.original` — the default), so per-script preset
*variants* would introduce new persisted identities — a migration question, not
a tuning pass. Either scope it as "a script-aware multiplier applied on top of
the existing profile" (no new identities, one new derived value) or drop it.
Decide the schema before touching numbers.

Line *breaking* needs no work in either phase: TextKit already performs Japanese
line breaking correctly, including kinsoku shori. Checked during the original
design review; inherited from the platform.

## Unresolved Across Both Phases

**`Lineform/Resources/*.md`** (MarkdownGuide, Help, Privacy,
AccessibilityNutritionLabel, AppStoreMetadata, ReleaseReadiness,
FontLicenseReview). Phase 1 ruled them out as dead bundled weight because no app
code loads them. Re-verified: there are exactly four `forResource:` call sites
under `Lineform/` — `BundledFontRegistrar.swift:18` (fonts),
`MainMenuIconDecorator.swift:177` (lproj), `AppCommands.swift:205` (AppIcon.icns),
and `FirstLaunchIntroOverlay.swift:510` (the intro HTML). **None loads a `.md`**,
so the finding holds.

**Three of the seven are already resolved and are not in question.**
`FontLicenseReview.md`, `AppStoreMetadata.md`, and `ReleaseReadiness.md` have
`PBXBuildFile` entries but are deliberately **excluded from the Resources
phase**, and `ReleaseResourceTests.swift:76–78` asserts they must not ship
("an internal release artifact and should not be bundled"). Only four `.md`
files are actually bundled — `project.pbxproj:863` MarkdownGuide, `:864` Help,
`:865` Privacy, `:866` AccessibilityNutritionLabel. (`:867` is `Fonts`, cited in
item 3.)

So the open question is over **four** files, not seven: they ship, and nothing
in the app opens them. The contradiction is between Phase 1's "dead bundled
weight" and CLAUDE.md's Documentation Expectations, which lists
`Lineform/Resources/*.md` as **user-facing bundled app/help docs**.
`ReleaseResourceTests.swift:110` does read `MarkdownGuide.md` from the bundle,
but that is a test asserting the file ships — not app code surfacing it, and not
evidence either way.

Phase 2 must state a disposition for those four — translate, delete, or leave
with a recorded reason — rather than inherit the silence. If they are genuinely
unreachable from the UI, "delete" is the honest answer and localization never
arises; if something is meant to surface them, that is a Phase 1 gap, not a
Phase 2 one. The existing exclusion test is the precedent for either answer.

**Disposition (settled 2026-08-05): LEAVE, with this reason recorded. Nothing is
deleted and nothing is translated.** The four bundled files — `MarkdownGuide.md`,
`Help.md`, `Privacy.md`, `AccessibilityNutritionLabel.md` — ship in the app
bundle and no app code opens any of them, so localizing them buys a user
nothing: there is no surface on which a translated copy would ever be read.
Deleting them is not free either — `ReleaseResourceTests.swift:110` asserts
`MarkdownGuide.md` ships, so "delete" is a test change plus a packaging change
in a localization pass that has no business touching either, and the files are a
few kilobytes of Markdown against an 8.9 MB font we already declined. They also
document real product commitments (privacy, accessibility) that are worth having
inside the shipped bundle even unreached. So: no translation, no deletion. If a
later phase gives them a UI surface — a Help viewer, an in-app privacy sheet —
that phase owns their localization, and this paragraph is the record that the
silence was a decision rather than an omission.

## Testing

- `MarkdownReferenceTests` reworked per the table in item 1 — all seven re-keyed
  or extended, six of them also recompiled against `sections(in:)`, bundle-based
  resolution (`Bundle(path:)` + `localizedString(forKey:…)`), **never
  `String(localized:…locale:)`**. The 90-character ceiling asserted for every
  shipped language.
- The four `rendersSyntaxAsCode == false` rows localize and every `true` row
  does not — assert the split directly, so a new label row cannot be added in
  English by accident.
- `LocalizationSourceSweepTests.swift:38–39` allowlist entry for
  `MarkdownReference.swift` removed.
- Cascade: the declared fallback resolves a real face for Japanese and Chinese
  sample text across all four `availableFont` branches, including the New York
  serif fallthrough, and at all three `resolvedFont` consumers (preview,
  highlighter, Write-mode text view). **Separately** assert that bold and italic
  still carry the cascade after trait conversion — this is the regression the
  measured table in item 2 predicts, and it fails against a naive
  implementation.
- BIZ UDGothic (if kept): registers via `BundledFontRegistrar`, and
  `ReleaseResourceTests` gains `OFL-BIZUDGothic`.
- Voice selection: language detection picks the document language over the UI
  locale for mixed samples, and falls back to the system default below a
  confidence floor. `FakeSynthesizer` continues to model shipping stop/pause
  behavior.

## Out of Scope, Explicitly (both phases)

- The first-launch intro overlay — **shipped in Phase 1** (see above).
- Vertical Japanese text (tategaki); furigana/ruby.
- Localized Markdown syntax, callout labels, or document templates.
- Per-document UI language override.
- CJK word segmentation (`CFStringTokenizer`) for word counts.
- Quick Look rendered output; announcements; appcast release notes (Sparkle's
  own dialogs localize themselves — no work, and not English).
