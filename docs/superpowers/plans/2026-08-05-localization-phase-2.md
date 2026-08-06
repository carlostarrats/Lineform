# Localization Phase 2 Implementation Plan

> ## STATUS, 2026-08-05: item 2 (the CJK font cascade) WAS REVERTED. Do not rebuild it.
>
> This plan is a **historical record of what was attempted**, kept unrewritten so the reasoning that
> led to a wrong feature stays legible. Items 1 (Markdown Basics prose) and 4 (read-aloud voice)
> shipped. **Item 2 shipped as `MarkdownFontCascade`, was then measured on macOS 26, and was removed**
> (commits `33206ad` + `a53c56d`). Every cascade task, design note, and test below — roughly 77
> mentions — describes a file that no longer exists, and none of it is an instruction.
>
> Why it was reverted, in one paragraph: CoreText's implicit substitution already resolves CJK
> correctly *including bold* (`.systemFont` + `.boldFontMask` → `.PingFangUITextSC-Bold`), so
> "`NSFontManager.convert` drops the cascade" was a problem that existed only because we attached a
> cascade. Worse, the system substitutes metric-compatible optically-sized UI variants while a
> hardcoded list can only name the taller public families: one mixed EN/zh/ja document at 16pt went
> from line heights `18, 18, 18, 18, 18` to `18, 24, 24, 18, 24`, PDFs re-paginated, and the serif
> reading font lost its serif Han face (Songti SC). `Claude.md` and
> `docs/architecture/app-integration.md` ("CJK fallback: why Lineform declares NO font cascade") now
> forbid rebuilding it; `LineformTests/CJKFontFallbackTests.swift` replaces `MarkdownFontCascadeTests`
> and pins the platform behaviour instead.
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize the Markdown Basics sidebar prose, give the font stack an explicit CJK fallback that survives bold/italic, and pick the read-aloud voice from the document's language instead of the UI's.

**Architecture:** Three independent slices of the Phase 2 spec. (1) `MarkdownReference` gains a `Bundle`-parameterized entry point so its strings can be resolved — and asserted — per language, then its titles, explanations, and four label rows localize. (2) A new `MarkdownFontCascade` helper attaches an `NSFontDescriptor` cascade list at all three `resolvedFont` consumers and re-attaches it after every trait conversion, because `NSFontManager.convert` drops it on the system fonts. (3) `SpeechSynthesizing` gains a language parameter, fed by `NLLanguageRecognizer` with a confidence floor.

**Tech Stack:** Swift 5, AppKit/SwiftUI, CoreText, NaturalLanguage, XCTest, String Catalogs (`.xcstrings`).

**Source spec:** `docs/superpowers/specs/2026-08-05-localization-phase-2-prose-and-fonts-design.md`

## Scope Decision

The spec has five items. This plan implements **items 1, 2, and 4**.

- **Item 3 (BIZ UDGothic, 8.9 MB) is deferred.** It is the spec's own "most likely to be cut," it needs a product call on bundle size, and its size figure is still unverified. Item 2 stands on its own without it. Adding it later is additive: two files into `Lineform/Resources/Fonts/`, two names into `BundledFontRegistrar.fontFileNames`, and one entry into `ReleaseResourceTests`'s license list — plus the five-surface credit sweep in the spec. **(Corrected after the revert: this step originally also said "one extra family in `MarkdownFontCascade.fallbackFamilies`". There is no such file and no cascade to extend — a bundled family reaches CJK text the same way every other family does, through CoreText substitution. Adding a `.cascadeList` is forbidden; see the status banner.)**
- **Item 5 (CJK preset tuning) is out.** The spec says it should not be built as written: there is no mechanism to vary a preset by script, and `ReadingProfile.name` is persisted `Codable` identity. It needs a schema decision first, not a tuning pass.

If you want item 3 in, say so before Task 5 — that is where the cascade families are defined.
**(Corrected after the revert: Task 5 no longer exists in the shipped code. Item 3 is now independent
of anything in this plan.)**

## Global Constraints

- Shipping languages are exactly `es`, `fr`, `de`, `ja`, `zh-Hans` (`LineformTests/LocalizationCatalogTests.swift:5`). Every new catalog key needs all five.
- UI strings route through `String(localized:)` **at the definition site**, with the English text as the catalog key. A `String` constant passed to `Button(_:)`/`.alert(_:)` picks SwiftUI's verbatim overload and ships English however complete the catalog is.
- Text that renders **document content** is never localized — Markdown syntax, callout labels. Only app chrome.
- Never localize an enum `rawValue` or any persisted `Codable` identity.
- The catalog is `Lineform/Localizable.xcstrings`, hand-editable JSON, 264 keys today. Gates: `testEveryKeyIsTranslatedInEveryLanguage`, `testFormatSpecifiersMatchAcrossLanguages`, `testGlossaryTermsTranslateConsistently` (`LineformTests/LocalizationCatalogTests.swift:67, 79, 107`).
- Non-English behavior is asserted by feeding a language code into pure functions, **never** by flipping the process locale (`docs/architecture/app-integration.md:95–100`).
- `String(localized:…locale:)` does **not** select an `.lproj`. Its `locale:` argument formats interpolated values only. Task 1 proves the mechanism that does work before anything depends on it.
- Default verification gate, run from the repo root:
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
    -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  Use `-only-testing:LineformTests/<Class>` during development. **Warn the user before any CLI test run** — the re-signed host can prompt for Documents access (TCC) and block.
- Commit after every task. Branch off `main`; do not push without asking.

---

## File Structure

**Created**
- `Lineform/ReadingExperience/MarkdownFontCascade.swift` — the one definition of the CJK fallback list, how it attaches to a font, and how it survives a trait conversion.
- `Lineform/ReadingExperience/SpeechLanguageDetector.swift` — document text → BCP-47 language code, or nil below the confidence floor.
- `LineformTests/MarkdownFontCascadeTests.swift`
- `LineformTests/SpeechLanguageDetectorTests.swift`

**Modified**
- `Lineform/Outline/MarkdownReference.swift` — `sections(in:)` seam; titles, explanations, four label rows, and the accessibility connective localize.
- `Lineform/ReadingExperience/FontOption.swift:59–70` — cascade attached in all four `availableFont` branches.
- `Lineform/Preview/MarkdownPreviewRenderer.swift:334, 556, 997, 1308, 1312` — trait conversions route through the helper.
- `Lineform/Editor/MarkdownSyntaxHighlighter.swift:35` and `Lineform/Editor/LineformTextView.swift:179` — the other two `resolvedFont` consumers.
- `Lineform/ReadingExperience/SpeechController.swift` — `SpeechSynthesizing.speak` gains a language; `SystemSpeechSynthesizer` sets the voice.
- `Lineform/Localizable.xcstrings` — new keys.
- `LineformTests/MarkdownReferenceTests.swift` — all seven tests.
- `LineformTests/LocalizationSourceSweepTests.swift:38–39` — allowlist entry removed.
- `LineformTests/SpeechControllerTests.swift` — `FakeSynthesizer` conformance.
- `docs/architecture/app-integration.md` — record the resolved decisions.

No pbxproj edit is needed for the two new `Lineform/` sources **only if** they are added through Xcode. This repo hand-rolls pbxproj IDs (objectVersion 56, no synced groups): adding a file means editing four sections with sequential `1F0000xx` IDs. Task 5 covers this explicitly.

---

## Task 1: Prove the per-language resolution mechanism and add the `sections(in:)` seam

Nothing else in item 1 is safe to build until we know which API actually reads a non-English `.lproj`. This task ends with the seam in place and **zero** string changes, so it is independently reviewable.

**Files:**
- Modify: `Lineform/Outline/MarkdownReference.swift:28`
- Test: `LineformTests/MarkdownReferenceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MarkdownReference.sections(in bundle: Bundle = .main) -> [MarkdownReference.Section]`, and `MarkdownReference.sections` retained as a computed `static var` delegating to it — so every existing reader (six tests, plus `OutlineMarkdownBasicsTabView.swift:31–33`) compiles unchanged.

- [ ] **Step 1: Write a spike test that pins down the resolution mechanism**

This asserts the negative the spec warns about *and* the positive it prescribes, using a key that is already translated in the shipped catalog. Add to `LineformTests/MarkdownReferenceTests.swift`:

```swift
/// Guards the mechanism the whole per-language reference rests on. `String(localized:…locale:)`
/// formats interpolated VALUES for a locale; it does not choose which .lproj answers. Only a
/// bundle does. If this ever inverts, `sections(in:)` is silently English everywhere.
func testLanguageResolutionComesFromTheBundleNotTheLocale() throws {
    let german = try XCTUnwrap(
        Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)),
        "de.lproj missing from the test host — the app's own catalog should ship it"
    )

    // The positive: a German bundle resolves German.
    XCTAssertEqual(german.localizedString(forKey: "Don't Save", value: nil, table: nil), "Nicht sichern")

    // The negative: locale: does NOT.
    XCTAssertEqual(String(localized: "Don't Save", locale: Locale(identifier: "de_DE")), "Don't Save")

    // The form sections(in:) will use.
    XCTAssertEqual(String(localized: "Don't Save", bundle: german), "Nicht sichern")
}
```

- [ ] **Step 2: Run it and read the third assertion carefully**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownReferenceTests/testLanguageResolutionComesFromTheBundleNotTheLocale
```

Expected: all three PASS. All three were verified against the built app's `de.lproj` during plan review — `String(localized: "Don't Save", bundle: german)` returns `"Nicht sichern"`, and the `locale:` form returns `"Don't Save"`. So `sections(in:)` uses `String(localized: "…", bundle: bundle)` throughout, and Xcode's extractor harvests the literals automatically.

The test stays in the suite as a guard, not as a spike: it is the only thing that would catch this mechanism inverting under a future SDK, and every per-language assertion in Tasks 2–4 rests on it.

- [ ] **Step 3: Write the failing seam test**

```swift
func testSectionsInMainBundleMatchTheDefaultProperty() {
    XCTAssertEqual(MarkdownReference.sections(in: .main), MarkdownReference.sections)
}
```

- [ ] **Step 4: Run it to verify it fails**

Run the same command with `-only-testing:LineformTests/MarkdownReferenceTests/testSectionsInMainBundleMatchTheDefaultProperty`
Expected: FAIL to compile — "type 'MarkdownReference' has no member 'sections(in:)'".

- [ ] **Step 5: Convert `sections` into a bundle-parameterized function**

In `Lineform/Outline/MarkdownReference.swift`, replace `static let sections: [Section] = [` at `:28` with the pair below, leaving the array literal's contents **byte-for-byte unchanged** for now:

```swift
    /// Resolved against an explicit bundle so the tests can assert a non-English rendering.
    /// `String(localized:…locale:)` cannot do this — `locale:` formats interpolated values, it
    /// does not choose the .lproj. See `testLanguageResolutionComesFromTheBundleNotTheLocale`.
    static func sections(in bundle: Bundle = .main) -> [Section] {
        [
            // … existing Section(…) entries, unmodified …
        ]
    }

    /// Every existing reader keeps working, so this refactor is not a churn event.
    static var sections: [Section] { sections() }
```

The `bundle` parameter is unused at this point. That is correct — Task 2 is what starts reading it — and it needs no suppression: Swift warns about unused *locals*, not unused parameters. Do not rename it to `_ bundle:`; the label is part of the published interface.

- [ ] **Step 6: Run both tests to verify they pass**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownReferenceTests
```
Expected: all 9 tests PASS (the 7 existing + 2 new). The 7 existing ones must not have been edited.

- [ ] **Step 7: Commit**

```bash
git add Lineform/Outline/MarkdownReference.swift LineformTests/MarkdownReferenceTests.swift
git commit -m "Add a bundle-parameterized entry point to MarkdownReference

String(localized:locale:) formats interpolated values; it does not select an
.lproj. Per-language assertions need a Bundle, so sections() takes one. No
strings change yet — sections stays a computed property so every reader compiles."
```

---

## Task 2: Localize the five section titles and the four label rows

The smallest slice with visible behavior. Section titles are short chrome; the four `rendersSyntaxAsCode: false` rows are prose sitting in the syntax column.

**Files:**
- Modify: `Lineform/Outline/MarkdownReference.swift:29, 48, 49, 51, 55, 61, 62, 63, 65`
- Modify: `Lineform/Localizable.xcstrings`
- Test: `LineformTests/MarkdownReferenceTests.swift`

**Interfaces:**
- Consumes: `MarkdownReference.sections(in:)` from Task 1.
- Produces: a `Section.title` and four `Row.syntax` values that vary by bundle. `Row.id` is still `syntax`, so those four rows' identities become language-dependent — Task 4 addresses that.

- [ ] **Step 1: Write the failing test**

```swift
private func germanBundle() throws -> Bundle {
    try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
}

func testSectionTitlesLocalize() throws {
    let english = MarkdownReference.sections(in: .main).map(\.title)
    let german = MarkdownReference.sections(in: try germanBundle()).map(\.title)

    XCTAssertEqual(english, ["Markdown Basics", "Diagrams", "Math", "Spelling", "Search"])
    XCTAssertEqual(german.count, english.count)
    // "Diagrams"→"Diagramme" and "Math"→"Mathematik" are near-cognates; asserting the whole
    // array would just re-encode the translation. Assert that translation HAPPENED instead.
    XCTAssertNotEqual(german[0], english[0], "Markdown Basics should be translated in German")
    XCTAssertNotEqual(german[3], english[3], "Spelling should be translated in German")
}

func testLabelRowsLocalizeAndSyntaxRowsDoNot() throws {
    let german = try germanBundle()
    let englishRows = MarkdownReference.sections(in: .main).flatMap(\.rows)
    let germanRows = MarkdownReference.sections(in: german).flatMap(\.rows)

    XCTAssertEqual(germanRows.count, englishRows.count)

    for (en, de) in zip(englishRows, germanRows) {
        if en.rendersSyntaxAsCode {
            XCTAssertEqual(de.syntax, en.syntax, "Markdown syntax must never translate: \(en.syntax)")
        } else {
            XCTAssertNotEqual(de.syntax, en.syntax, "Label row should translate: \(en.syntax)")
        }
    }
}

func testExactlyFourRowsAreLabelsNotSyntax() {
    let labels = MarkdownReference.sections.flatMap(\.rows).filter { !$0.rendersSyntaxAsCode }
    XCTAssertEqual(labels.count, 4, "A new label row must be localized — see testLabelRowsLocalize…")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `-only-testing:LineformTests/MarkdownReferenceTests/testLabelRowsLocalizeAndSyntaxRowsDoNot`
Expected: FAIL — "Label row should translate: Tab" (German equals English, because nothing is localized yet).

- [ ] **Step 3: Localize the titles and the four label rows**

In `sections(in:)`, wrap the five `Section(title:)` values and the four `Row(syntax:)` values whose row carries `rendersSyntaxAsCode: false`. Leave every other `syntax` a bare literal. Delete the `_ = bundle` line from Task 1.

```swift
        Section(title: String(localized: "Markdown Basics", bundle: bundle), rows: [
            // … syntax rows unchanged: Row(syntax: "# Title", …) …
            Row(syntax: String(localized: "Tab", bundle: bundle),
                explanation: "Inside a table, moves to the next cell. Shift-Tab goes back.",
                rendersSyntaxAsCode: false),
            Row(syntax: String(localized: "Block Spacing", bundle: bundle),
                explanation: "Adds space around blocks in Read and Preview.",
                rendersSyntaxAsCode: false),
        ]),
        Section(title: String(localized: "Diagrams", bundle: bundle), rows: [ … ]),
        Section(title: String(localized: "Math", bundle: bundle), rows: [ … ]),
        Section(title: String(localized: "Spelling", bundle: bundle), rows: [
            Row(syntax: String(localized: "Spelling", bundle: bundle),
                explanation: "Misspellings underline as you type. Nothing is autocorrected.",
                rendersSyntaxAsCode: false),
            Row(syntax: String(localized: "Skipped", bundle: bundle),
                explanation: "Code, math, front matter, and link addresses are never flagged.",
                rendersSyntaxAsCode: false),
        ]),
        Section(title: String(localized: "Search", bundle: bundle), rows: [
            // "Return" is a KEY NAME rendered as code — it stays verbatim.
            Row(syntax: "Return", explanation: "While searching, jumps to the next match; wraps around."),
        ]),
```

- [ ] **Step 4: Add five keys to the catalog and reuse three**

Eight distinct strings, but **three are already in `Lineform/Localizable.xcstrings`** — verified during plan review. Reuse them; do not add a second entry, which would be a duplicate JSON key:

| Key | Status | Existing `de` |
|---|---|---|
| `Markdown Basics` | **exists** | `Markdown-Grundlagen` |
| `Search` | **exists** | `Suchen` |
| `Block Spacing` | **exists** | `Blockabstand` |
| `Diagrams` | new | — |
| `Math` | new | — |
| `Spelling` | new | — |
| `Tab` | new | — |
| `Skipped` | new | — |

(`Spelling` serves both the section title and the row, so it is one key.) Each new key needs `es`, `fr`, `de`, `ja`, `zh-Hans` with `"state": "translated"`. Build once and let Xcode add the new keys, then fill the translations — or add each entry by hand, matching the existing shape:

```json
"Block Spacing" : {
  "localizations" : {
    "de" : { "stringUnit" : { "state" : "translated", "value" : "Blockabstand" } },
    "es" : { "stringUnit" : { "state" : "translated", "value" : "Espaciado de bloques" } },
    "fr" : { "stringUnit" : { "state" : "translated", "value" : "Espacement des blocs" } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "ブロックの間隔" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "块间距" } }
  }
},
```

- [ ] **Step 4a: Exempt `Tab` from the glossary gate — it collides with the document tab**

`docs/notes/lineform-glossary.json` already defines `Tab` as the *document tab*: es `Pestaña`, fr `Onglet`, ja `タブ`, zh-Hans `标签页`, de `Tab`. `testGlossaryTermsTranslateConsistently` (`LocalizationCatalogTests.swift:107`) matches whole words against the key, so it would force the **keycap** `Tab` to those translations — wrong in four of five languages.

Add `"Tab"` to the `exemptions` set in `LineformTests/LocalizationCatalogTests.swift` (around `:143`) with a reason:

```swift
        // The glossary's "Tab" is the document tab (Pestaña / Onglet / タブ / 标签页). The
        // Markdown reference's "Tab" is the keycap, which stays "Tab" in every language.
        "Tab",
```

Add `LineformTests/LocalizationCatalogTests.swift` to this task's `git add` in Step 6.

`Tab` and `Return` are keyboard keys: use each language's Apple convention for a key legend — all five keep `Tab` — and do **not** invent a translation. Because `Tab` is therefore identical in every language, `testLabelRowsLocalizeAndSyntaxRowsDoNot` will fail on that row. **That is a real finding, not a test bug.** Narrow the assertion to the three rows that genuinely translate:

```swift
        } else if en.syntax == "Tab" {
            // A keycap legend. Apple ships "Tab" untranslated in de/ja; the key exists in the
            // catalog so other languages CAN differ, but equality here is correct, not a miss.
            continue
        } else {
```

- [ ] **Step 5: Run the reference and catalog tests**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownReferenceTests \
  -only-testing:LineformTests/LocalizationCatalogTests
```
Expected: all PASS. `testEveryKeyIsTranslatedInEveryLanguage` catches a missing language; `testGlossaryTermsTranslateConsistently` catches a term rendered differently from the rest of the app.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Outline/MarkdownReference.swift Lineform/Localizable.xcstrings \
        LineformTests/MarkdownReferenceTests.swift LineformTests/LocalizationCatalogTests.swift
git commit -m "Localize the reference's section titles and its four label rows

rendersSyntaxAsCode == false is the existing predicate for 'this is prose, not
Markdown', so it is what decides which syntax-column cells translate. The other
25 rows stay verbatim — document-language text stays in the document's language."
```

---

## Task 3: Localize the 29 explanations and enforce the ceiling per language

The bulk of item 1, and its real risk: German runs 30–35% longer than English against a 90-character cap sized for a narrow sidebar.

**Files:**
- Modify: `Lineform/Outline/MarkdownReference.swift:29–67`
- Modify: `Lineform/Localizable.xcstrings`
- Test: `LineformTests/MarkdownReferenceTests.swift:38–47`

**Interfaces:**
- Consumes: `sections(in:)`.
- Produces: fully localized `Row.explanation` for all 29 rows.

- [ ] **Step 1: Rewrite the ceiling test to run per language**

Replace `testExplanationsStayConcise` (`:38–47`) entirely:

```swift
/// Guards the narrow-column rewrite in EVERY language, not just English. The column does not
/// get wider in German. Pinning only `en` let a 120-character translation ship silently.
func testExplanationsStayConciseInEveryLanguage() throws {
    for language in ["en", "es", "fr", "de", "ja", "zh-Hans"] {
        let bundle = try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
            "\(language).lproj missing from the test host"
        )
        for section in MarkdownReference.sections(in: bundle) {
            for row in section.rows {
                XCTAssertLessThanOrEqual(
                    row.explanation.count, 90,
                    "too wordy for the sidebar in \(language): \(row.syntax) — \(row.explanation)"
                )
            }
        }
    }
}
```

`en.lproj` exists in the built app because the catalog ships a source language; if the `XCTUnwrap` for `"en"` fails, drop `"en"` from the array and cover English via `sections(in: .main)` in a separate loop — do not weaken the unwrap into a `continue`, which would make the whole test vacuous for any language whose bundle went missing.

- [ ] **Step 2: Run it to verify it fails**

Run: `-only-testing:LineformTests/MarkdownReferenceTests/testExplanationsStayConciseInEveryLanguage`
Expected: PASS at first — nothing is translated yet, so every language returns the English string. This is the one test in the plan that legitimately passes before its feature exists; it becomes load-bearing the moment Step 3 lands, and Step 4 is where it earns its keep.

- [ ] **Step 3: Wrap all 29 explanations**

Every `Row(explanation:)` in `sections(in:)` becomes `String(localized: "…", bundle: bundle)`. The English text stays the catalog key, verbatim — including the `⌘1`, `⌘0`, `⌘2 to ⌘6`, `⌃⌘T`, `⌃⌘R`, and `Shift-Tab` glyph references, which pass through translation unchanged.

Example, `:30`:
```swift
            Row(syntax: "# Title",
                explanation: String(localized: "Top-level heading. ⌘1 sets it, ⌘0 clears it.", bundle: bundle)),
```

- [ ] **Step 4: Add 29 keys × 5 languages to the catalog**

This is content work, and the acceptance criteria are mechanical:
1. Every key present in `es`, `fr`, `de`, `ja`, `zh-Hans` with `"state": "translated"` — gated by `testEveryKeyIsTranslatedInEveryLanguage`.
2. Every translation ≤ 90 characters — gated by Step 1's test. **Never raise the ceiling.**

   **Expect this to bite, and you are pre-authorized to fix it properly.** Roughly eight explanations are 74–78 characters in English; at German's typical +30% they project to 99–101. Shortening the German alone will not always be possible without mangling it. When it isn't, **shorten the English key too** — the sidebar column is narrow in English as well, and a 78-character explanation was already near the cap.

   Changing an English key means: update the `Row(explanation:)` literal, rename the catalog key (the old entry becomes dead — delete it), and check whether `testReferenceNamesTheEditingShortcuts` asserts on the phrase you changed. The only protected substrings are the shortcut glyphs and the phrase `"Return starts the next"`; if you need to reword that row, update the assertion in the same commit and say so in the message.
3. Shortcut glyphs (`⌘1`, `⌃⌘T`, `Shift-Tab`) reproduced exactly — they are UI, not prose.
4. Terms shared with the rest of the app (Read, Preview, Write, heading, list, table) translated the way the existing catalog already translates them — gated by `testGlossaryTermsTranslateConsistently`, which reads `docs/notes/lineform-glossary.json`. Two keys are constrained but satisfiable: `Callout` must be de `Hinweis`, and `front matter` must be de `Frontmatter`.

**One more glossary collision, same cause as Task 2 Step 4a.** The explanation `"Inside a table, moves to the next cell. Shift-Tab goes back."` contains `Shift-Tab`, and the hyphen is a word boundary — so the glossary's document-tab `Tab` matches inside it and demands `Pestaña`/`Onglet`/`タブ`/`标签页`. The `"Tab"` exemption added in Task 2 Step 4a covers this too; confirm it does rather than adding a second entry.

Do **not** translate: `# Title`, `**bold**`, `- [x] done`, `| a | b |`, `> [!NOTE]`, ` ```swift ` or any other `syntax` value with `rendersSyntaxAsCode: true`.

- [ ] **Step 5: Run the reference, catalog, and sweep tests**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownReferenceTests \
  -only-testing:LineformTests/LocalizationCatalogTests
```
Expected: all PASS. Report the exact count. A failure naming a language and a row is a translation that needs shortening, not a test to relax.

- [ ] **Step 6: Re-key the English-asserting tests against `en.lproj`, not `.main`**

`testSectionsCoverEveryGroupAndAreNonEmpty` (`:5`), `testBasicsIncludesCoreSyntax` (`:13`), and `testBasicsIncludesCalloutSyntax` (`:21`) compare against English titles.

**`.main` is not the fix.** `MarkdownReference.sections` is *defined* as `sections(in: .main)`, so "pinning to `.main`" changes nothing: on a Mac or CI runner configured for German, `.main` resolves German and every one of these fails. Pin to the English bundle explicitly. Verified during plan review: the built app's `en.lproj` carries no `Localizable.strings`, so `String(localized:bundle:)` against it returns the key — which *is* the English text.

Add one helper and use it in all four tests:

```swift
private func englishBundle() throws -> Bundle {
    try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)),
                  "en.lproj missing from the test host")
}

func testSectionsCoverEveryGroupAndAreNonEmpty() throws {
    // Explicitly the ENGLISH rendering — not .main, which follows the host's language.
    // The group SET is the invariant; naming the titles is how we catch a dropped section.
    // Per-language shape is covered by testSectionTitlesLocalize.
    let sections = MarkdownReference.sections(in: try englishBundle())
    XCTAssertEqual(sections.map(\.title), ["Markdown Basics", "Diagrams", "Math", "Spelling", "Search"])
    for section in sections {
        XCTAssertFalse(section.rows.isEmpty, section.title)
    }
}
```

Apply the same treatment to the two `first { $0.title == "Markdown Basics" }` filters at `:14` and `:22`, and to `testExactlyFourRowsAreLabelsNotSyntax` from Task 2.

`testReferenceNamesTheEditingShortcuts` (`:30`) asserts `"Return starts the next"`, English prose. Split it: keep the glyph assertions against **every** language (they must survive translation), and pin the prose assertion to the English bundle.

```swift
func testReferenceNamesTheEditingShortcuts() throws {
    for language in ["en", "es", "fr", "de", "ja", "zh-Hans"] {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
        let explanations = MarkdownReference.sections(in: bundle).flatMap(\.rows).map(\.explanation).joined(separator: " ")
        for expected in ["⌘1", "⌘0", "⌘2 to ⌘6", "⌃⌘T", "⌃⌘R", "Shift-Tab"] {
            XCTAssertTrue(explanations.contains(expected), "\(language) lost the shortcut glyph \(expected)")
        }
    }

    let english = MarkdownReference.sections(in: try englishBundle()).flatMap(\.rows).map(\.explanation).joined(separator: " ")
    XCTAssertTrue(english.contains("Return starts the next"), "reference no longer describes list continuation")
}
```

`testBlockSpacingIsNotRenderedAsCode` (`:49`) filters on `$0.syntax == "Block Spacing"`, which Task 2 made translatable — pin it to the English bundle too:

```swift
func testBlockSpacingIsNotRenderedAsCode() throws {
    let row = MarkdownReference.sections(in: try englishBundle())
        .flatMap(\.rows)
        .first { $0.syntax == "Block Spacing" }
    XCTAssertEqual(row?.rendersSyntaxAsCode, false)
}
```

- [ ] **Step 7: Run the full reference suite and commit**

Run: `-only-testing:LineformTests/MarkdownReferenceTests`
Expected: all PASS.

```bash
git add Lineform/Outline/MarkdownReference.swift Lineform/Localizable.xcstrings LineformTests/MarkdownReferenceTests.swift
git commit -m "Localize the Markdown reference explanations, ceiling enforced per language

The 90-character sidebar ceiling now runs against all six languages, not just
English — the column does not get wider in German. Shortcut glyphs are asserted
to survive translation in every language; the English prose assertion is pinned
to the main bundle."
```

---

## Task 4: Localize the accessibility connective and close the sweep allowlist

**Files:**
- Modify: `Lineform/Outline/MarkdownReference.swift:18`
- Modify: `Lineform/Outline/OutlineMarkdownBasicsTabView.swift:104` (the call site) and `:155` (the ternary)
- Modify: `LineformTests/LocalizationSourceSweepTests.swift:38–39` (remove) and `:63` (two additions)
- Modify: `Lineform/Localizable.xcstrings`
- Test: `LineformTests/MarkdownReferenceTests.swift:56`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: `Row.accessibilityLabel(in bundle: Bundle = .main) -> String`, replacing the stored-property form.

- [ ] **Step 1: Write the failing test**

`accessibilityLabel` is a `String`, so it hits SwiftUI's `@_disfavoredOverload` verbatim overload at `OutlineMarkdownBasicsTabView.swift:104` — it must be localized at its definition site.

```swift
func testAccessibilityLabelReadsExplanationThenSyntax() {
    let row = MarkdownReference.Row(syntax: "**bold**", explanation: "Bold.")
    XCTAssertEqual(row.accessibilityLabel(), "Bold. Syntax: **bold**")
}

func testAccessibilityLabelKeepsExplanationFirstAndSyntaxVerbatimInEveryLanguage() throws {
    let row = MarkdownReference.Row(syntax: "**bold**", explanation: "Fett.")

    for language in ["en", "es", "fr", "de", "ja", "zh-Hans"] {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
        let label = row.accessibilityLabel(in: bundle)

        XCTAssertTrue(label.hasPrefix("Fett."), "\(language): explanation must come first — \(label)")
        XCTAssertTrue(label.hasSuffix("**bold**"), "\(language): syntax must be last and verbatim — \(label)")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `-only-testing:LineformTests/MarkdownReferenceTests/testAccessibilityLabelConnectiveLocalizes`
Expected: FAIL to compile — "cannot call value of non-function type 'String'".

- [ ] **Step 3: Convert the property to a bundle-taking method**

`MarkdownReference.swift:18`:

```swift
        /// VoiceOver reads a coherent phrase — explanation first, then the raw syntax — instead
        /// of spelling out Markdown punctuation on its own. The CONNECTIVE localizes; the syntax
        /// never does. This is a method, not a property, because it must be resolvable against an
        /// explicit bundle for the per-language tests.
        func accessibilityLabel(in bundle: Bundle = .main) -> String {
            String(localized: "\(explanation) Syntax: \(syntax)", bundle: bundle)
        }
```

The catalog key becomes `%@ Syntax: %@` with two positional arguments. Translations must keep both `%1$@` and `%2$@` and may reorder them — `testFormatSpecifiersMatchAcrossLanguages` (`LocalizationCatalogTests.swift:79`) enforces that every argument is consumed exactly once.

- [ ] **Step 4: Update the one call site**

`OutlineMarkdownBasicsTabView.swift:104` becomes `.accessibilityLabel(row.accessibilityLabel())`.

- [ ] **Step 5: Resolve the `:155` ternary**

`.accessibilityLabel(isCopied ? "Copied" : "Copy \(rowID)")` is a ternary of two interpolated literals. It *should* bind `LocalizedStringKey`, but that was never confirmed, and if it binds `StringProtocol` it ships English regardless of the catalog. Determine it, don't assume — split the ternary so each branch is unambiguously a `LocalizedStringKey` position:

```swift
        .accessibilityLabel(isCopied ? Text("Copied") : Text("Copy \(rowID)"))
```

`Text` takes `LocalizedStringKey` for a literal, and `accessibilityLabel(_: Text)` is a distinct non-disfavored overload, so this removes the ambiguity rather than betting on it. Add `Copied` and `Copy %@` to the catalog if they are not already present.

- [ ] **Step 6: Swap the file-level sweep exemption for two literal-level ones**

Delete `LocalizationSourceSweepTests.swift:38–39` — the whole-file `MarkdownReference.swift` exemption and its "explicitly deferred to Localization Phase 2" reason. The file localizes at its definition sites now, so the sweep should police it like any other.

**But two literals will then fail the sweep, and both are correct as English.** Verified during plan review by running the sweep's own `isDisplayCopy` (`:474`) against the post-Task-3 file: `"flowchart LR"` (`MarkdownReference.swift:53`) and `"Return"` (`:66`). Both are `Row(syntax:)` arguments, and `Row` is not in `localizedStringKeyCallees` (`:130`), so they hit the hard-failure branch. Neither may be translated — one is Mermaid diagram syntax, the other a keycap rendered as code.

Add both to `exemptLiterals` (`:63`):

```swift
        "MarkdownReference.swift|flowchart LR":
            "Mermaid diagram syntax shown as an example — document content, never localized.",
        "MarkdownReference.swift|Return":
            "A keycap legend rendered as code, like the ⌘ glyphs in the explanations.",
```

The other 23 syntax literals pass cleanly — they are punctuation or Markdown tokens the sweep does not consider display copy.

- [ ] **Step 7: Run the reference, sweep, and catalog tests**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownReferenceTests \
  -only-testing:LineformTests/LocalizationSourceSweepTests \
  -only-testing:LineformTests/LocalizationCatalogTests
```
Expected: all PASS. If the sweep now flags a bare literal in `MarkdownReference.swift`, it is right — that is a `syntax` value you localized that should have stayed verbatim, or an explanation you missed.

- [ ] **Step 8: Commit**

```bash
git add Lineform/Outline/MarkdownReference.swift Lineform/Outline/OutlineMarkdownBasicsTabView.swift \
        LineformTests/LocalizationSourceSweepTests.swift LineformTests/MarkdownReferenceTests.swift \
        Lineform/Localizable.xcstrings
git commit -m "Localize the reference's VoiceOver connective and close its sweep exemption

accessibilityLabel is a String, so it took SwiftUI's verbatim overload and shipped
English however complete the catalog was. It localizes at the definition site now,
and MarkdownReference.swift comes off the LocalizationSourceSweepTests allowlist."
```

---

## Task 5: `MarkdownFontCascade` — declare the CJK fallback and make it survive trait conversion

The spec's central finding: `NSFontManager.convert(_:toHaveTrait:)` **drops** an attached `.cascadeList` on `.systemFont`, `.monospacedSystemFont`, and `withDesign(.serif)` — the three branches that need it — while preserving it for named families. A cascade attached only in `availableFont(size:)` would work for body text and silently fail for every heading, table header, callout title, and bold/italic span.

**Files:**
- Create: `Lineform/ReadingExperience/MarkdownFontCascade.swift`
- Create: `LineformTests/MarkdownFontCascadeTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MarkdownFontCascade.fallbackFamilies: [String]`
  - `MarkdownFontCascade.applying(to font: NSFont) -> NSFont`
  - `MarkdownFontCascade.convert(_ font: NSFont, toHaveTrait trait: NSFontTraitMask) -> NSFont`

- [ ] **Step 1: Write the failing tests**

Create `LineformTests/MarkdownFontCascadeTests.swift`:

```swift
import AppKit
import CoreText
import XCTest
@testable import Lineform

final class MarkdownFontCascadeTests: XCTestCase {

    private func cascadeCount(_ font: NSFont) -> Int? {
        (CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute) as? [Any])?.count
    }

    func testFallbackFamiliesAllResolveOnThisSystem() {
        for family in MarkdownFontCascade.fallbackFamilies {
            XCTAssertNotNil(NSFont(name: family, size: 17), "\(family) does not ship with this macOS")
        }
    }

    func testApplyingAttachesTheCascadeWithoutChangingTheFamily() {
        let base = NSFont.systemFont(ofSize: 17)
        let cascaded = MarkdownFontCascade.applying(to: base)

        XCTAssertEqual(cascaded.familyName, base.familyName)
        XCTAssertEqual(cascaded.pointSize, base.pointSize)
        XCTAssertEqual(cascadeCount(cascaded), MarkdownFontCascade.fallbackFamilies.count)
    }

    func testMonospacedKeepsFixedPitch() {
        let mono = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        XCTAssertTrue(MarkdownFontCascade.applying(to: mono).isFixedPitch)
    }

    /// The regression the whole helper exists for. NSFontManager.convert drops the cascade on
    /// every system font — measured, not assumed — so a naive convert loses the fallback for
    /// headings, table headers, callout titles, and every bold/italic span.
    func testConvertPreservesTheCascadeOnSystemFonts() {
        let bases: [(String, NSFont)] = [
            ("systemFont", .systemFont(ofSize: 17)),
            ("monospacedSystemFont", .monospacedSystemFont(ofSize: 17, weight: .regular))
        ]

        for (label, base) in bases {
            let cascaded = MarkdownFontCascade.applying(to: base)
            for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] {
                let converted = MarkdownFontCascade.convert(cascaded, toHaveTrait: trait)
                XCTAssertEqual(
                    cascadeCount(converted), MarkdownFontCascade.fallbackFamilies.count,
                    "\(label) lost its cascade under \(trait)"
                )
            }
        }
    }

    func testBareNSFontManagerStillDropsIt() {
        // Pins the platform behaviour the helper works around. If this ever starts passing,
        // the helper can be simplified — but do not assume it; measure.
        let cascaded = MarkdownFontCascade.applying(to: .systemFont(ofSize: 17))
        let naive = NSFontManager.shared.convert(cascaded, toHaveTrait: .boldFontMask)
        XCTAssertNil(cascadeCount(naive), "AppKit now preserves the cascade — revisit MarkdownFontCascade")
    }

    func testConvertActuallyAppliesTheTrait() {
        let bold = MarkdownFontCascade.convert(MarkdownFontCascade.applying(to: .systemFont(ofSize: 17)),
                                               toHaveTrait: .boldFontMask)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `-only-testing:LineformTests/MarkdownFontCascadeTests`
Expected: FAIL to compile — "cannot find 'MarkdownFontCascade' in scope".

- [ ] **Step 3: Implement the helper**

Create `Lineform/ReadingExperience/MarkdownFontCascade.swift`:

```swift
import AppKit

/// The ONE definition of what a Lineform font falls back to for CJK text.
///
/// Without an explicit cascade list CoreText substitutes per glyph, so the pairing is unchosen
/// and a mixed Chinese/Japanese document can render Chinese in a Japanese face. Declaring it
/// costs nothing and makes the choice ours.
///
/// The subtlety is `convert(_:toHaveTrait:)`. Measured on macOS 26: `NSFontManager` PRESERVES an
/// attached `.cascadeList` for real named families (Helvetica, Atkinson Hyperlegible) and DROPS
/// it for `.systemFont`, `.monospacedSystemFont`, and `withDesign(.serif)` — which are exactly
/// the fonts most users read. Every trait conversion in the app therefore goes through
/// `convert(_:toHaveTrait:)` below, never `NSFontManager` directly.
enum MarkdownFontCascade {

    /// Both ship with macOS. Order matters: CoreText walks the list, so Japanese resolves before
    /// Simplified Chinese for Han characters the two share.
    static let fallbackFamilies = ["Hiragino Sans", "PingFang SC"]

    private static let descriptors: [NSFontDescriptor] = fallbackFamilies.map {
        NSFontDescriptor(fontAttributes: [.family: $0])
    }

    /// Returns `font` with the fallback list attached. Returns the input unchanged if the
    /// descriptor cannot be realized — a font without the cascade is degraded, not broken, and
    /// this must never be the reason text fails to draw.
    static func applying(to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: descriptors])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// `NSFontManager.convert` plus re-attachment. Use this everywhere instead of
    /// `NSFontManager.shared.convert(_:toHaveTrait:)`.
    static func convert(_ font: NSFont, toHaveTrait trait: NSFontTraitMask) -> NSFont {
        applying(to: NSFontManager.shared.convert(font, toHaveTrait: trait))
    }
}
```

Re-attaching unconditionally (rather than only when the input had a cascade) is deliberate: every caller in this app wants the fallback, and a conditional read of the input's attribute is a second place for the two to disagree.

- [ ] **Step 4: Register both new files in the pbxproj**

This repo hand-rolls IDs (objectVersion 56, no synced groups). For **each** new file, add an entry to four sections using the next sequential `1F0000xx` ID — check the highest in use first with `grep -o '1F0000[0-9A-F]\{18\}' Lineform.xcodeproj/project.pbxproj | sort -u | tail -5`:

1. `PBXBuildFile` (near `:157–164`)
2. `PBXFileReference` (near `:341, :375–381`)
3. The group's `children` array — `Lineform/ReadingExperience` for the source, `LineformTests` for the test
4. `PBXSourcesBuildPhase` for the owning target — the app target for `MarkdownFontCascade.swift`, the test target for `MarkdownFontCascadeTests.swift`

Adding them through the Xcode UI does the same thing and is less error-prone; either is fine.

- [ ] **Step 5: Run the tests**

Run: `-only-testing:LineformTests/MarkdownFontCascadeTests`
Expected: all 6 PASS. If `testBareNSFontManagerStillDropsIt` fails, the platform changed — do not delete the helper, re-measure and update its doc comment.

- [ ] **Step 6: Commit**

```bash
git add Lineform/ReadingExperience/MarkdownFontCascade.swift LineformTests/MarkdownFontCascadeTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add MarkdownFontCascade: an explicit CJK fallback that survives bold and italic

NSFontManager.convert drops an attached cascade list on the three system-font
paths and keeps it for named families. Measured on macOS 26 and pinned by a test,
so a naive convert cannot quietly reintroduce per-glyph substitution."
```

---

## Task 6: Attach the cascade at all three `resolvedFont` consumers and route every conversion through it

**Files:**
- Modify: `Lineform/ReadingExperience/FontOption.swift:59–70`
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift:334, 556, 997, 1308, 1312`
- Modify: `Lineform/Editor/MarkdownSyntaxHighlighter.swift:35`
- Modify: `Lineform/Editor/LineformTextView.swift:179`
- Test: `LineformTests/MarkdownFontCascadeTests.swift`

**Interfaces:**
- Consumes: `MarkdownFontCascade.applying(to:)` and `.convert(_:toHaveTrait:)`.
- Produces: no new API. `FontOption.availableFont(size:)` keeps returning `NSFont?` with the same nil-signal.

- [ ] **Step 1: Write the failing tests**

Append to `MarkdownFontCascadeTests.swift`:

```swift
func testEveryFontOptionCarriesTheCascade() {
    for option in FontOption.groupedOptions.flatMap(\.options) where option.isAvailable {
        let font = option.resolvedFont(size: 17)
        XCTAssertEqual(
            (CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute) as? [Any])?.count,
            MarkdownFontCascade.fallbackFamilies.count,
            "\(option.name) resolved without the CJK fallback"
        )
    }
}

/// The nil-signal `isAvailable` depends on must survive the cascade: a bogus family still has
/// to resolve to nil, or every unavailable font silently becomes "available".
func testUnavailableFamilyStillResolvesToNil() {
    let bogus = FontOption(id: .comicSans, name: "Nope", familyName: "NoSuchFamilyXYZ", source: .system)
    XCTAssertNil(bogus.availableFont(size: 17))
    XCTAssertFalse(bogus.isAvailable)
}

func testNewYorkFallsThroughToTheSerifDesignWithCascadeIntact() throws {
    let newYork = try XCTUnwrap(FontOption.option(for: .newYork))
    let font = newYork.resolvedFont(size: 17)
    XCTAssertNotNil(CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `-only-testing:LineformTests/MarkdownFontCascadeTests/testEveryFontOptionCarriesTheCascade`
Expected: FAIL — "SF Pro resolved without the CJK fallback" (nil vs 2).

- [ ] **Step 3: Attach the cascade in all four `availableFont` branches**

`FontOption.swift:59–70`. Attach **after** resolution so the nil-signal is untouched:

```swift
    func availableFont(size: CGFloat) -> NSFont? {
        // The cascade is attached AFTER resolution, never via the family descriptor: a bogus
        // family must still resolve to nil, which is what `isAvailable` reads.
        switch id {
        case .sfPro:
            return MarkdownFontCascade.applying(to: .systemFont(ofSize: size))
        case .newYork:
            return (NSFont(name: familyName, size: size) ?? systemSerifFont(size: size))
                .map(MarkdownFontCascade.applying(to:))
        case .jetBrainsMono:
            return MarkdownFontCascade.applying(to: .monospacedSystemFont(ofSize: size, weight: .regular))
        default:
            return NSFont(name: familyName, size: size).map(MarkdownFontCascade.applying(to:))
        }
    }
```

`.newYork` needs the wrap on the whole expression, not just the `NSFont(name:)` half — `NSFont(name: "New York")` returns nil on macOS 26, so in practice it is always the `systemSerifFont` branch that ships.

- [ ] **Step 3a: Cascade the `resolvedFont` fallback too**

`resolvedFont` (`:72–74`) falls back to a bare `.systemFont(ofSize:)` when `availableFont` returns nil, and so do all three consumers with their own `?? .systemFont(...)`. That path gets no cascade, and `testEveryFontOptionCarriesTheCascade` cannot see it because it filters `where option.isAvailable`. Close it at the single choke point:

```swift
    func resolvedFont(size: CGFloat) -> NSFont {
        // The fallback is cascaded too: an unavailable font is the case MOST likely to be
        // rendering someone else's script.
        availableFont(size: size) ?? MarkdownFontCascade.applying(to: .systemFont(ofSize: size))
    }
```

Add the covering test to `MarkdownFontCascadeTests.swift`:

```swift
func testTheUnavailableFontFallbackIsAlsoCascaded() {
    let bogus = FontOption(id: .comicSans, name: "Nope", familyName: "NoSuchFamilyXYZ", source: .system)
    let font = bogus.resolvedFont(size: 17)
    XCTAssertEqual(
        (CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute) as? [Any])?.count,
        MarkdownFontCascade.fallbackFamilies.count
    )
}
```

The three consumers' own `?? .systemFont(...)` fallbacks are unreachable — `resolvedFont` is non-optional — so they need no change.

- [ ] **Step 4: Run to verify the font tests pass**

Run: `-only-testing:LineformTests/MarkdownFontCascadeTests`
Expected: all 9 PASS.

- [ ] **Step 5: Route the five trait conversions through the helper**

In `Lineform/Preview/MarkdownPreviewRenderer.swift`, replace `NSFontManager.shared.convert(` with `MarkdownFontCascade.convert(` at `:334` (table header), `:556` (callout title), `:997` (heading), `:1308` and `:1312` (inline bold/italic). The argument lists are unchanged — the helper's signature matches.

Verify none were missed:
```sh
grep -rn "NSFontManager.shared.convert" --include="*.swift" Lineform/
```
Expected output: nothing. If a hit remains outside `MarkdownFontCascade.swift`, it is a sixth site the spec did not know about — route it too and note it in the commit.

- [ ] **Step 6: Confirm the other two `resolvedFont` consumers inherit it**

`MarkdownSyntaxHighlighter.swift:35` and `LineformTextView.swift:179` both call `FontOption.resolvedFont(size:)`, which now returns a cascaded font — so they need **no edit**. Confirm rather than assume:

```sh
grep -rn "resolvedFont" --include="*.swift" Lineform/
```
Expected: five lines — the definition at `FontOption.swift:72`, plus `MarkdownPreviewRenderer.swift:995`, `MarkdownSyntaxHighlighter.swift:35`, and `LineformTextView.swift:179` and `:180`.

- [ ] **Step 6a: Decide the code fonts explicitly — do not let the grep decide**

Nine sites build a font directly instead of going through `FontOption`, so neither grep sees them: `MarkdownPreviewRenderer.swift:329, 555, 959, 984, 1013, 1181, 1315`; `MarkdownSyntaxHighlighter.swift:271`; `LineformTextView.swift:1255`. These are the monospaced faces for inline code and fenced code blocks. As written, CJK inside a code span or a fenced block gets no declared fallback and falls back to per-glyph substitution.

**Default: bring them in.** CJK in code blocks is common — comments, string literals, and prose-in-code — and the inconsistency between a CJK heading and a CJK code comment is exactly the unchosen-pairing problem item 2 exists to fix. Wrap each construction in `MarkdownFontCascade.applying(to:)` and extend `testEveryFontOptionCarriesTheCascade`'s sibling coverage with one assertion per site's helper.

If a site turns out to need an exact metric that the cascade perturbs, leave that one out and record which and why in the commit message. What is not acceptable is leaving all nine unexamined.

- [ ] **Step 7: Run the rendering and editor suites**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownFontCascadeTests \
  -only-testing:LineformTests/MarkdownPreviewRendererTests \
  -only-testing:LineformTests/MarkdownPreviewRendererHeadingScaleTests \
  -only-testing:LineformTests/ScopedSyntaxHighlightingTests
```
Expected: all PASS. A font-metrics assertion that shifts is a real signal — the cascade should not change the primary face's metrics; if one moves, the descriptor is overriding more than the fallback list.

- [ ] **Step 8: Verify in the running app, not just the tests**

Build and launch the fresh build by full path — never `open -a Lineform`, which picks an installed copy:

```sh
xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Debug -destination 'platform=macOS' build
```

Then open a document containing a Japanese heading, a Chinese paragraph, a table with a CJK header cell, and a `**bold**` CJK span, using the built app's full path. Switch through SF Pro, Monospaced, and New York in the font picker. Confirm no tofu boxes and that bold CJK renders in the same face as body CJK. This is the part the tests cannot cover.

- [ ] **Step 9: Commit**

```bash
git add Lineform/ReadingExperience/FontOption.swift Lineform/Preview/MarkdownPreviewRenderer.swift LineformTests/MarkdownFontCascadeTests.swift
git commit -m "Attach the CJK cascade to every resolved font and every trait conversion

Attaching it in availableFont alone would have covered body text and missed all
five convert sites — headings, table headers, callout titles, inline bold and
italic — because AppKit drops the cascade when converting a system font."
```

---

## Task 7: Pick the read-aloud voice from the document's language

`SpeechController.swift` builds `AVSpeechUtterance(string:)` with no `voice`, so the system default follows the **UI** language: a Japanese-UI user reading an English document gets a Japanese voice reading English. This is a protocol-seam change, and `FakeSynthesizer` must model shipping behavior or it certifies the bug.

**Files:**
- Create: `Lineform/ReadingExperience/SpeechLanguageDetector.swift`
- Create: `LineformTests/SpeechLanguageDetectorTests.swift`
- Modify: `Lineform/ReadingExperience/SpeechController.swift` (protocol `speak`, `SystemSpeechSynthesizer.speak`, `startSpeaking`)
- Modify: `LineformTests/SpeechControllerTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SpeechLanguageDetector.language(for text: String) -> String?` — BCP-47 code, or nil below the floor.
  - `SpeechSynthesizing.speak(_ text: String, languageCode: String?)` — replaces `speak(_:)`.

- [ ] **Step 1: Write the failing detector tests**

Create `LineformTests/SpeechLanguageDetectorTests.swift`:

```swift
import XCTest
@testable import Lineform

final class SpeechLanguageDetectorTests: XCTestCase {

    func testDetectsUnambiguousProse() {
        XCTAssertEqual(SpeechLanguageDetector.language(for:
            "The quick brown fox jumps over the lazy dog. It was a bright cold day in April."), "en")
        XCTAssertEqual(SpeechLanguageDetector.language(for:
            "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。"), "ja")
    }

    /// The whole point of the feature: the document's language wins over the UI's. This test does
    /// not touch the UI locale at all — that is the invariant, the detector never reads it.
    func testDetectionIsIndependentOfTheProcessLocale() {
        let english = "This document is written entirely in English and should be read as such."
        XCTAssertEqual(SpeechLanguageDetector.language(for: english), "en")
    }

    /// A heuristic on user prose. Two words is not evidence, and a confidently wrong voice is
    /// worse than the system default — nil means "leave it alone".
    func testReturnsNilForInputTooShortToJudge() {
        XCTAssertNil(SpeechLanguageDetector.language(for: "ok"))
        XCTAssertNil(SpeechLanguageDetector.language(for: ""))
        XCTAssertNil(SpeechLanguageDetector.language(for: "   \n  "))
    }

    func testReturnsNilWhenNoLanguageClearsTheConfidenceFloor() {
        XCTAssertNil(SpeechLanguageDetector.language(for: "asdf qwer zxcv hjkl 12345 67890 ..."))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `-only-testing:LineformTests/SpeechLanguageDetectorTests`
Expected: FAIL to compile — "cannot find 'SpeechLanguageDetector' in scope".

- [ ] **Step 3: Implement the detector**

Create `Lineform/ReadingExperience/SpeechLanguageDetector.swift`:

```swift
import Foundation
import NaturalLanguage

/// Picks the voice language from the DOCUMENT, not the UI.
///
/// `AVSpeechUtterance` with no `voice` falls back to the system default, which follows the UI
/// language — so a Japanese-UI user reading an English document heard English read by a Japanese
/// voice. Detection is a heuristic on user prose, so it is deliberately conservative: below the
/// confidence floor it returns nil and the caller keeps the old behaviour.
enum SpeechLanguageDetector {

    /// Below this, the guess is not worth acting on. A wrong voice is more jarring than the
    /// system default, which is at least the user's own language.
    private static let confidenceFloor = 0.65

    /// Shorter than this and there is nothing to judge — "ok" is not evidence of English.
    private static let minimumCharacters = 12

    /// - Returns: a BCP-47 language code (`"en"`, `"ja"`, `"zh-Hans"`), or nil to leave the
    ///   synthesizer's default alone.
    static func language(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= confidenceFloor else { return nil }

        return language.rawValue
    }
}
```

`NLLanguage.rawValue` already yields BCP-47 (`zh-Hans` for Simplified Chinese), which is what `AVSpeechSynthesisVoice(language:)` wants.

- [ ] **Step 4: Register both files in the pbxproj**

Same four-section procedure as Task 5, Step 4. `SpeechLanguageDetector.swift` goes in the app target's Sources phase; `SpeechLanguageDetectorTests.swift` in the test target's.

- [ ] **Step 5: Run the detector tests**

Run: `-only-testing:LineformTests/SpeechLanguageDetectorTests`
Expected: all 5 PASS. If `NaturalLanguage` fails to link, add `NaturalLanguage.framework` to the app target's Frameworks phase — the same explicit-link rule that `AppIntents.framework` is under.

- [ ] **Step 6: Write the failing seam test**

In `LineformTests/SpeechControllerTests.swift`, extend `FakeSynthesizer` to record the language and add:

```swift
func testSpeakingPassesTheDocumentsDetectedLanguage() {
    let fake = FakeSynthesizer()
    let controller = SpeechController(synthesizer: fake)

    controller.startSpeaking("吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。")

    XCTAssertEqual(fake.spokenLanguageCode, "ja")
}

func testShortTextLeavesTheVoiceUnset() {
    let fake = FakeSynthesizer()
    let controller = SpeechController(synthesizer: fake)

    controller.startSpeaking("ok")

    // Assert the call HAPPENED before asserting what it carried: spokenLanguageCode starts nil,
    // so without this the test passes even if speak() is never reached.
    XCTAssertEqual(fake.spokenTexts, ["ok"])
    XCTAssertNil(fake.spokenLanguageCode, "below the floor the system default must be left alone")
}
```

- [ ] **Step 7: Run to verify failure**

Run: `-only-testing:LineformTests/SpeechControllerTests/testSpeakingPassesTheDocumentsDetectedLanguage`
Expected: FAIL to compile — `FakeSynthesizer` has no `spokenLanguageCode`.

- [ ] **Step 8: Widen the protocol seam**

In `SpeechController.swift`, change the protocol requirement:

```swift
    /// `languageCode` is the DOCUMENT's language (BCP-47), or nil to keep the synthesizer's
    /// default. It is not the UI language — that is the bug this parameter exists to fix.
    func speak(_ text: String, languageCode: String?)
```

`SystemSpeechSynthesizer.speak`:

```swift
    func speak(_ text: String, languageCode: String?) {
        let utterance = AVSpeechUtterance(string: text)
        // Only override when detection was confident AND the system actually has that voice.
        // AVSpeechSynthesisVoice(language:) returns nil for an uninstalled language, and
        // assigning nil is the same as never setting it.
        if let languageCode {
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        }
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }
```

And in `SpeechController.startSpeaking`, at the point it currently calls `synthesizer.speak(text)`:

```swift
        synthesizer.speak(text, languageCode: SpeechLanguageDetector.language(for: text))
```

- [ ] **Step 9: Update `FakeSynthesizer` — model shipping behavior, not the new parameter alone**

Add the recording property and update the signature. Do **not** change the fake's existing stop/pause semantics: `stop()` must still deliver `onFinish` (the shipping `AVSpeechSynthesizer` reports a stopped utterance as `didFinish`, ~30 ms later) and `pause()` must still be deferred, not instantaneous. Those two inversions each hid a real transport bug before.

```swift
    private(set) var spokenTexts: [String] = []
    private(set) var spokenLanguageCode: String?

    func speak(_ text: String, languageCode: String?) {
        spokenTexts.append(text)
        spokenLanguageCode = languageCode
        // … existing body unchanged …
    }
```

- [ ] **Step 10: Run the speech suites**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/SpeechControllerTests \
  -only-testing:LineformTests/SpeechLanguageDetectorTests
```
Expected: all PASS, including every pre-existing transport test. A newly failing pause/stop test means the fake's semantics were altered — restore them.

- [ ] **Step 11: Commit**

```bash
git add Lineform/ReadingExperience/SpeechLanguageDetector.swift Lineform/ReadingExperience/SpeechController.swift \
        LineformTests/SpeechLanguageDetectorTests.swift LineformTests/SpeechControllerTests.swift \
        Lineform.xcodeproj/project.pbxproj
git commit -m "Read aloud in the document's language, not the interface's

AVSpeechUtterance with no voice follows the UI language, so a Japanese-UI user
reading an English document got a Japanese voice. Detection is conservative:
below the confidence floor, or under 12 characters, the default is left alone."
```

---

## Task 7a: Independent translation review

The gates prove every key is present, fits the column, and uses consistent terminology. None of them prove a German sentence reads like a person wrote it. The author of a translation is the worst judge of it, so this is a cold read by someone who did not write them.

**Files:**
- Modify: `Lineform/Localizable.xcstrings` (fixes only)

- [ ] **Step 1: Dispatch a reviewer per language**

One agent per language (`es`, `fr`, `de`, `ja`, `zh-Hans`). Give each **only** the English key and its translation for the ~34 keys added in Tasks 2–4 — not the reasoning behind them, not the other languages. Ask for, per string:

- Is it accurate to the English?
- Does it read as natural product UI in that language, or as machine translation?
- Is the register right — Apple's macOS conventions for that language, not a literal rendering?
- For `ja`/`zh-Hans`: is the terminology what a native Markdown editor would use?

Require a verdict per string (`fine` / `awkward` / `wrong`) and a proposed replacement for anything not `fine`.

- [ ] **Step 2: Apply the fixes and re-run the gates**

Any replacement must still clear the 90-character ceiling and the glossary gate.

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownReferenceTests \
  -only-testing:LineformTests/LocalizationCatalogTests
```

- [ ] **Step 3: Commit**

```bash
git add Lineform/Localizable.xcstrings
git commit -m "Apply independent review fixes to the Phase 2 translations"
```

---

## Task 8: Documentation and full-suite gate

**Files:**
- Modify: `docs/architecture/app-integration.md`
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-08-05-localization-phase-2-prose-and-fonts-design.md`

- [ ] **Step 1: Record the decisions in the architecture doc**

Add to `docs/architecture/app-integration.md`, in the localization section:

- `MarkdownReference.sections(in:)` exists so prose can be asserted per language; `String(localized:…locale:)` cannot select an `.lproj` and must never be used for that.
- `rendersSyntaxAsCode == false` is the predicate deciding which syntax-column cells localize. A new label row must be localized; a new syntax row must not.
- The 90-character sidebar ceiling is enforced in all six languages.
- `MarkdownFontCascade` is the one definition of the CJK fallback, and `NSFontManager.shared.convert` must never be called directly — it drops the cascade on system fonts.
- Read-aloud voice comes from `SpeechLanguageDetector`, never the UI locale.

- [ ] **Step 2: Add the two rules that can never be broken to CLAUDE.md**

Under Load-Bearing Invariants, one line each — in the **Localization** group:

> - `String(localized:…locale:)` selects a value FORMAT, never an `.lproj`. Per-language assertions resolve through `Bundle(path: "<lang>.lproj")`; `MarkdownReference.sections(in:)` exists for exactly this. And the reference's 90-character sidebar ceiling holds in EVERY language — the column does not get wider in German.

and in the **Rendering** group:

> - ~~`NSFontManager.shared.convert(_:toHaveTrait:)` DROPS an attached `.cascadeList` on `.systemFont`, `.monospacedSystemFont`, and `withDesign(.serif)` while preserving it for named families. Every trait conversion goes through `MarkdownFontCascade.convert`, or CJK text silently reverts to per-glyph substitution for headings, table headers, callout titles, and every bold/italic span — the exact surfaces a body-text-only check passes.~~

**RETRACTED — this is the exact claim the revert measured false, and it is NOT in `Claude.md`.**
The drop is real but harmless, because the bare converted font is already correct: measured on
macOS 26, `.systemFont` + `.boldFontMask` resolves CJK to `.PingFangUITextSC-Bold`, with `traitBold`
set, and `.monospacedSystemFont` + `.boldFontMask` to `.PingFangUITextSC-Semibold`. "Reverts to
per-glyph substitution" was never a degradation — substitution is the correct, metric-compatible
result. What `Claude.md` and `docs/architecture/app-integration.md` carry instead is the opposite
rule: Lineform declares no cascade list anywhere, and `CJKFontFallbackTests` asserts it.

Remember `CLAUDE.md` is tracked as `Claude.md` — `git add CLAUDE.md` stages nothing and silently drops the edit. Use `git add Claude.md` and confirm with `git status`.

- [ ] **Step 3: Mark the spec's implemented items**

At the top of the spec, note that items 1, 2, and 4 shipped in this plan, and that items 3 (BIZ UDGothic) and 5 (preset tuning) remain deferred with the reasons already recorded in the doc.

- [ ] **Step 4: Run the full default gate**

**Warn the user before running this** — the re-signed test host can prompt for Documents access and block the run. Never run it unattended and assume it finished.

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Expected: ~1100 tests, all passing. Report the exact pass/fail counts from the output — do not summarize as "tests pass."

- [ ] **Step 5: Commit**

```bash
git add Claude.md docs/architecture/app-integration.md docs/superpowers/specs/2026-08-05-localization-phase-2-prose-and-fonts-design.md
git commit -m "Document Phase 2's localization and font-cascade invariants"
```

---

## Notes for the Implementer

**The hosted test plan is not needed here.** None of this touches editor motion, drawer/inspector presentation, reload scroll behavior, or PDF export. If Task 6 changes font metrics unexpectedly, that changes — run `-testPlan LineformHosted` with Xcode quit.

**Two things the tests cannot prove**, both of which need the running app (Task 6 Step 8 covers the second):

1. Whether the translations read like a native speaker wrote them. The gates prove every key is present, fits the column, and uses consistent terminology — not that a German sentence is idiomatic. This is the spec's stated reason for deferring prose to Phase 2, and it does not go away by shipping.
2. Whether the CJK fallback looks right. "No tofu" is testable; "Chinese text is not rendering in a Japanese face" is a visual judgment.

**Three gates outside `MarkdownReferenceTests` will fight you in Tasks 2–4**, and each is handled in its own step — do not work around any of them by weakening a test:

- `testGlossaryTermsTranslateConsistently` forces `Tab` to the *document tab*'s translations (Task 2 Step 4a).
- `LocalizationSourceSweepTests` hard-fails on two `Row(syntax:)` literals that must stay English (Task 4 Step 6).
- The 90-character ceiling is not comfortably reachable in German for ~8 rows (Task 3 Step 4, which pre-authorizes shortening the English).

**Run tests on an English-configured Mac**, or the English-asserting tests in Task 3 Step 6 will fail for the right reason at the wrong time. They are pinned to `en.lproj` rather than `.main` precisely so this is survivable, but the app's own UI will be in your system language while you work.
