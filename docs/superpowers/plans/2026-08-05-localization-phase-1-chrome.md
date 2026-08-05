# Localization Phase 1 — App Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize Lineform's app chrome into Spanish, French, German, Japanese, and Simplified Chinese, and fix the date-format and CJK word-count behaviors that are wrong in any non-English locale.

**Architecture:** A refactor of the string-definition layer — every `String` constant that reaches the UI becomes a `String(localized:)` call whose key is the English text — with three String Catalogs (`Localizable`, `InfoPlist`, `AppShortcuts`) as storage. `MainMenuIconDecorator` gains locale-aware title resolution. The WKWebView intro gets a Swift-injected string table. Translation quality is enforced by tests: catalog completeness, glossary consistency, and placeholder parity, with terminology sourced from Apple's own `.loctable` files.

**Tech Stack:** Swift/SwiftUI/AppKit, Xcode String Catalogs (`.xcstrings`), XCTest, Python 3 (extraction scripts only, run manually, not at build time).

**Spec:** `docs/superpowers/specs/2026-08-05-localization-phase-1-chrome-design.md` — read it before starting any task.

## Global Constraints

- Languages: `es`, `fr`, `de`, `ja`, `zh-Hans`. Apple's `.loctable` files key Chinese as `zh_CN` and escape values like `"Preferences\U2026"` — extraction scripts must handle both.
- Every localization key is the English display string itself, **exactly as found in the source, byte for byte**. The menus deliberately use ASCII three-period ellipses (`"Save As..."`, per the comment at `AppCommands.swift:44`), NOT the `…` character — copying a key with the wrong ellipsis changes English output and silently breaks decorator and glossary matching.
- **Catalog sync procedure** (referenced by several tasks): CLI builds emit `.stringsdata` into DerivedData but do not write new keys back into the source `.xcstrings` — that is Xcode-IDE behavior. After converting strings, populate the catalog with:

  ```sh
  xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -derivedDataPath build-loc
  find build-loc -name '*.stringsdata' > /tmp/stringsdata-list.txt
  xcrun xcstringstool sync Lineform/Localizable.xcstrings --stringsdata-file-list /tmp/stringsdata-list.txt
  ```

  Check `xcrun xcstringstool sync --help` once for the exact flag spelling on this Xcode (Task 5 pins it); if `sync` proves unable to consume the stringsdata, the fallback is to hand-author each task's keys directly into the catalog JSON from the task's "Produces" list — never skip the verification that keys are present. `SWIFT_EMIT_LOC_STRINGS = YES` is **already set** in both configurations (`project.pbxproj:1144, 1199`) — do not add it again, and do not treat its absence as the explanation for missing keys.
- **Never localize an enum `rawValue`** — add a `title` property instead (`OutlineFileSortOrder` and `EditorDisplayMode` are the models to follow).
- **Text that renders document content stays in the document's language** — callout labels, Markdown syntax, exported HTML. Only app chrome localizes.
- Font names, "Lineform", and `AppMenuConfiguration.aboutCopyright` / `aboutVersionDisplay` are never translated.
- Counted strings are catalog plural variations (`%lld …`), never number + noun concatenation. Japanese and Chinese have no `one` plural category.
- The project file is hand-rolled (`objectVersion 56`): new files are added by editing the four pbxproj sections (PBXBuildFile, PBXFileReference, PBXGroup children, PBXResourcesBuildPhase or PBXSourcesBuildPhase) with sequential IDs. Existing IDs run through `1F0000300000000000000002`; use `1F000031…`/`1F000032…` prefixes and `grep` the pbxproj for each new ID before use to guarantee uniqueness.
- During development run scoped tests only (`-only-testing:LineformTests/<Class>`); the FULL default-plan suite runs once, at the final task. CLI test runs re-sign the host ad-hoc and can trigger a TCC Documents prompt — warn the user before the first test run of a session; never run the suite unattended and assume it finished.
- Build/test command base: `xcodebuild <build|test> -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`.
- Commit after every green step; commit messages in repo style (imperative, reasoned body when non-obvious).

## File Structure

```
Lineform/Localizable.xcstrings                       (new) main string catalog
Lineform/InfoPlist.xcstrings                         (new) doc-type names + UTType description
Lineform/AppShortcuts.xcstrings                      (new) App Intents phrases
Lineform/App/SystemMenuItemTitles.swift              (new, generated) system menu titles per locale
packaging/extract-apple-glossary.py                  (new) loctable → glossary extraction
packaging/extract-system-menu-titles.py              (new) loctable → SystemMenuItemTitles.swift
docs/notes/apple-terminology-glossary.json           (new, generated) Apple platform terms ×5
docs/notes/lineform-glossary.json                    (new, authored) Lineform vocabulary ×5
LineformTests/LocalizationCatalogTests.swift         (new) completeness/glossary/placeholder gates
Lineform/Editor/EditorStatusPresentation.swift       (modify) date fix + localized strings
Lineform/Editor/DocumentStatistics.swift             (modify) CJK flag
Lineform/App/AppCommands.swift                       (modify) menu title refactor
Lineform/App/MainMenuIconDecorator.swift             (modify) locale-aware resolution
Lineform/App/SettingsView.swift                      (modify) settings strings
Lineform/App/FirstLaunchIntroOverlay.swift           (modify) native strings + JS injection
Lineform/Resources/FirstLaunchIntro/index.html       (modify) data-l10n-id attrs + title
Lineform/Outline/OutlineSidebarView.swift            (modify) tab title property + chrome
Lineform/ReadingExperience/FontOption.swift          (modify) group headings
Lineform/ReadingExperience/ReadingExperiencePopover.swift (modify) strings + formatter extract
Lineform/Editor/EditorContainerView.swift            (modify) alerts/panels/Untitled
Lineform/Editor/SaveAsExport.swift                   (modify) export panel strings
Lineform/Editor/DocumentTab.swift                    (modify) Untitled
Lineform/Editor/LineformTextView.swift               (modify) AX + context-menu strings
Lineform/Info.plist                                  (no key changes; localized via InfoPlist.xcstrings)
Lineform.xcodeproj/project.pbxproj                   (modify) new files, knownRegions
Lineform.xctestplan / LineformHosted.xctestplan      (modify) pinned test locale
```

---

### Task 1: Catalog infrastructure, knownRegions, pinned test locale

**Files:**
- Create: `Lineform/Localizable.xcstrings`, `Lineform/InfoPlist.xcstrings`, `Lineform/AppShortcuts.xcstrings`
- Modify: `Lineform.xcodeproj/project.pbxproj`, `Lineform.xctestplan`, `LineformHosted.xctestplan`

**Interfaces:**
- Produces: the three catalogs every later task writes keys into; the `en` test locale every later test relies on. Catalog JSON shape: `{"sourceLanguage":"en","strings":{},"version":"1.0"}`.

- [ ] **Step 1: Create the three empty catalogs**

Each file contains exactly:

```json
{
  "sourceLanguage" : "en",
  "strings" : {

  },
  "version" : "1.0"
}
```

- [ ] **Step 2: Register them in the pbxproj (4 sections) and extend knownRegions**

Add three PBXFileReference entries (IDs `1F0000310000000000000001`–`03`, `lastKnownFileType = text.json.xcstrings`), three PBXBuildFile entries (`1F0000310000000000000011`–`13`) referencing them, add the file refs to the `Lineform` group's children, and the build files to the app target's PBXResourcesBuildPhase. Grep the pbxproj for each ID first to confirm it is unused. Then change:

```
knownRegions = (
    en,
    Base,
);
```

to:

```
knownRegions = (
    en,
    Base,
    es,
    fr,
    de,
    ja,
    "zh-Hans",
);
```

- [ ] **Step 3: Pin the test locale in both test plans**

In `Lineform.xctestplan` and `LineformHosted.xctestplan`, `defaultOptions` is currently `{}`. Set:

```json
"defaultOptions" : {
  "language" : "en",
  "region" : "US"
}
```

- [ ] **Step 4: Build and verify nothing regressed**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Then verify the App Intents metadata still exists (CLAUDE.md invariant — this shipped broken once):

```sh
ls "$(xcodebuild -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/Lineform.app/Contents/Resources/Metadata.appintents"
```

Expected: the directory listing, not "No such file".

- [ ] **Step 5: Run the guard tests**

Run: `xcodebuild test … -only-testing:LineformTests/TestPlanGuardTests -only-testing:LineformTests/ReleaseResourceTests`
Expected: PASS (quarantine lists still in lockstep; print entitlement and appintents assertions green).

- [ ] **Step 6: Commit**

```bash
git add Lineform/Localizable.xcstrings Lineform/InfoPlist.xcstrings Lineform/AppShortcuts.xcstrings Lineform.xcodeproj/project.pbxproj Lineform.xctestplan LineformHosted.xctestplan
git commit -m "Add empty string catalogs, five knownRegions, and a pinned en test locale"
```

---

### Task 2: Terminology glossaries — Apple extraction plus Lineform vocabulary

**Files:**
- Create: `packaging/extract-apple-glossary.py`, `docs/notes/apple-terminology-glossary.json`, `docs/notes/lineform-glossary.json`

**Interfaces:**
- Produces: `docs/notes/apple-terminology-glossary.json` — `{ englishTerm: { "es"|"fr"|"de"|"ja"|"zh-Hans": translation } }`; `docs/notes/lineform-glossary.json` — same shape. Task 13's glossary-consistency test and every translation step consume these.

- [ ] **Step 1: Write the extraction script**

`packaging/extract-apple-glossary.py`:

```python
#!/usr/bin/env python3
"""Extract Apple's own localized terminology from the macOS .loctable files.

Loctables key Chinese as zh_CN (not zh-Hans) and store plural rules as dicts;
plain-string values only are extracted. Values may contain non-breaking spaces —
they are preserved verbatim (Apple's es uses NBSP before numerals on purpose).
"""
import json, plistlib, subprocess, sys
from pathlib import Path

APPKIT = Path("/System/Library/Frameworks/AppKit.framework/Versions/C/Resources")
TABLES = ["MenuCommands", "Menus", "Document", "SavePanel", "Printing",
          "FindPanel", "Spelling", "TextSystem", "Toolbar", "Services",
          "WritingTools", "NSSpellChecker", "NSTextViewContextMenu"]
LANGS = {"es": "es", "fr": "fr", "de": "de", "ja": "ja", "zh_CN": "zh-Hans"}

def load(table):
    raw = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(APPKIT / f"{table}.loctable")],
        capture_output=True, check=True).stdout
    return json.loads(raw)

glossary = {}
for table in TABLES:
    path = APPKIT / f"{table}.loctable"
    if not path.exists():
        print(f"warning: {table}.loctable missing on this OS", file=sys.stderr)
        continue
    data = load(table)
    english = data.get("en", {})
    for key, en_value in english.items():
        if not isinstance(en_value, str):
            continue  # plural-rule dicts handled by the catalog, not the glossary
        entry = {}
        for loc_key, our_key in LANGS.items():
            value = data.get(loc_key, {}).get(key)
            if isinstance(value, str):
                entry[our_key] = value
        if len(entry) == len(LANGS):
            glossary.setdefault(en_value, entry)

out = Path(__file__).resolve().parent.parent / "docs/notes/apple-terminology-glossary.json"
out.write_text(json.dumps(glossary, ensure_ascii=False, indent=1, sort_keys=True))
print(f"{len(glossary)} terms -> {out}")
```

- [ ] **Step 2: Run it and sanity-check the output**

Run: `python3 packaging/extract-apple-glossary.py`
Expected: a few hundred terms. Verify spot values:

```sh
python3 -c "
import json; g=json.load(open('docs/notes/apple-terminology-glossary.json'))
print(g['Replace All'])"
```

Expected: `{'de': 'Alles ersetzen', 'es': 'Reemplazar todo', 'fr': 'Tout remplacer', 'ja': 'すべて置き換え', 'zh-Hans': '全部替换'}` (es may carry an NBSP variant — either is fine, it is Apple's own string).

- [ ] **Step 3: Author `docs/notes/lineform-glossary.json`**

The app's own vocabulary, fixed once. Content (exact):

```json
{
  "Write": {"es": "Escritura", "fr": "Écriture", "de": "Schreiben", "ja": "執筆", "zh-Hans": "写作"},
  "Read": {"es": "Lectura", "fr": "Lecture", "de": "Lesen", "ja": "閲覧", "zh-Hans": "阅读"},
  "Split": {"es": "Dividido", "fr": "Scindé", "de": "Geteilt", "ja": "分割", "zh-Hans": "拆分"},
  "Workspace": {"es": "Espacio de trabajo", "fr": "Espace de travail", "de": "Arbeitsbereich", "ja": "ワークスペース", "zh-Hans": "工作区"},
  "Outline": {"es": "Esquema", "fr": "Plan", "de": "Gliederung", "ja": "アウトライン", "zh-Hans": "大纲"},
  "Reading profile": {"es": "Perfil de lectura", "fr": "Profil de lecture", "de": "Leseprofil", "ja": "閲覧プロファイル", "zh-Hans": "阅读配置"},
  "Front matter": {"es": "front matter", "fr": "front matter", "de": "Frontmatter", "ja": "フロントマター", "zh-Hans": "front matter"},
  "Callout": {"es": "Recuadro", "fr": "Encadré", "de": "Hinweis", "ja": "コールアウト", "zh-Hans": "提示框"},
  "Tab": {"es": "Pestaña", "fr": "Onglet", "de": "Tab", "ja": "タブ", "zh-Hans": "标签页"},
  "Quick Open": {"es": "Apertura rápida", "fr": "Ouverture rapide", "de": "Schnellöffnen", "ja": "クイックオープン", "zh-Hans": "快速打开"}
}
```

Notes for the record: "Front matter" stays a technical term (lowercased or transliterated, never invented); Apple terms always beat this file when both apply.

- [ ] **Step 4: Commit**

```bash
git add packaging/extract-apple-glossary.py docs/notes/apple-terminology-glossary.json docs/notes/lineform-glossary.json
git commit -m "Extract Apple terminology glossary and author the Lineform term glossary"
```

---

### Task 3: Locale-correct date/time formatting (TDD)

**Files:**
- Modify: `Lineform/Editor/EditorStatusPresentation.swift:72-95`
- Test: `LineformTests/EditorDisplayModeTests.swift` (add to the existing class or a new `EditorStatusDateFormattingTests` in the same file's test target)

**Interfaces:**
- Consumes: nothing new.
- Produces: `EditorStatusFormatter.lastSavedDisplay(for date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> LastSavedDisplay` — the added `locale:` parameter is what tests and Task 5 rely on. `lastSavedText(for:now:calendar:locale:)` gains the same parameter.

- [ ] **Step 1: Write the failing tests**

```swift
final class EditorStatusDateFormattingTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let date = Date(timeIntervalSince1970: 1_785_942_240) // 2026-08-05 15:04:00 UTC (verified)

    func testGermanLocaleUses24HourClockAndGermanMonth() throws {
        let display = EditorStatusFormatter.lastSavedDisplay(
            for: date, now: date.addingTimeInterval(90_000),
            calendar: calendar, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(display.label, "Last save")
        let detail = try XCTUnwrap(display.detail)
        XCTAssertTrue(detail.contains("15:04"), "expected 24h clock, got \(detail)")
        XCTAssertFalse(detail.contains("PM"))
        XCTAssertFalse(detail.contains("Aug 5"), "English month order leaked: \(detail)")
    }

    func testJapaneseLocaleSameDayUses24HourClock() throws {
        let display = EditorStatusFormatter.lastSavedDisplay(
            for: date, now: date, calendar: calendar, locale: Locale(identifier: "ja_JP"))
        XCTAssertEqual(try XCTUnwrap(display.detail).contains("15:04"), true)
    }

    func testEnglishOutputUnchanged() {
        let display = EditorStatusFormatter.lastSavedDisplay(
            for: date, now: date.addingTimeInterval(90_000),
            calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(display.detail, "Aug 5, 2026 at 3:04 PM")
    }
}
```

(The epoch constant is verified: `1_785_942_240` = 2026-08-05T15:04:00Z. The `Date.FormatStyle(locale:calendar:timeZone:)` initializer and the composed `.year().month(.abbreviated).day().hour().minute()` chain are verified on this OS to produce `"Aug 5, 2026 at 3:04 PM"` in en_US — including the "at" joiner — `"5. Aug. 2026, 15:04"` in de_DE, and `"15:04"` for time-only in ja.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:LineformTests/EditorStatusDateFormattingTests`
Expected: FAIL — no `locale:` parameter exists ("extra argument 'locale' in call" compile error counts as the failing state; comment the new tests' bodies if needed to get a clean red run, or accept the compile failure as red).

- [ ] **Step 3: Implement**

Replace `formatted(_:format:timeZone:)` and its callers inside `EditorStatusPresentation.swift`:

```swift
static func lastSavedText(for date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
    lastSavedDisplay(for: date, now: now, calendar: calendar, locale: locale).accessibilityText
}

static func lastSavedDisplay(for date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> LastSavedDisplay {
    guard let date else {
        return LastSavedDisplay(label: "Not saved yet", detail: nil)
    }

    // Locale-aware system styles, never a hand-built pattern: a pattern string
    // localizes the words but not the order, joiner, or clock convention.
    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    style = calendar.isDate(date, inSameDayAs: now)
        ? style.hour().minute()
        : style.year().month(.abbreviated).day().hour().minute()
    return LastSavedDisplay(label: "Last save", detail: date.formatted(style))
}
```

Check `testEnglishOutputUnchanged` — `Date.FormatStyle` composed fields render en_US as "Aug 5, 2026 at 3:04 PM". If the joiner differs (e.g. "Aug 5, 2026, 3:04 PM"), switch to `style.dateStyle/.timeStyle` composition: `date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))`, and if the exact legacy string is still not reproduced, update the English assertion to the new system-produced string AND the pinned strings in `EditorDisplayModeTests` to match — system formatting wins over the legacy hand-built pattern; note it in the commit message.

- [ ] **Step 4: Run the new tests plus the legacy pins**

Run: `xcodebuild test … -only-testing:LineformTests/EditorStatusDateFormattingTests -only-testing:LineformTests/EditorDisplayModeTests`
Expected: PASS (or: legacy pins updated to the system-produced English strings, then PASS).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorStatusPresentation.swift LineformTests/EditorDisplayModeTests.swift
git commit -m "Format save timestamps with locale-aware styles instead of a pinned en_US_POSIX pattern"
```

---

### Task 4: CJK-aware word count (TDD)

**Files:**
- Modify: `Lineform/Editor/DocumentStatistics.swift`, `Lineform/Editor/EditorStatusPresentation.swift:30-32`, `Lineform/Editor/EditorContainerView.swift:1955-1957`
- Test: `LineformTests/DocumentStatisticsTests.swift` (create if absent; check for an existing file first and extend it if present)

**Interfaces:**
- Consumes: nothing new.
- Produces: `DocumentStatistics.isPredominantlyCJK: Bool`; `EditorStatusFormatter.statisticsText(for statistics: DocumentStatistics) -> String` replacing `statisticsText(wordCount:characterCount:)`. Task 5 localizes the strings this returns.

- [ ] **Step 1: Write the failing tests**

```swift
final class DocumentStatisticsCJKTests: XCTestCase {
    func testJapaneseDocumentIsPredominantlyCJK() {
        let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
        XCTAssertTrue(stats.isPredominantlyCJK)
    }

    func testEnglishDocumentIsNot() {
        XCTAssertFalse(DocumentStatistics(text: "The quick brown fox.").isPredominantlyCJK)
    }

    func testEnglishDocumentQuotingOneJapaneseSentenceKeepsWordCount() {
        let text = """
        The novel opens with a famous line. 吾輩は猫である。 It is narrated by a cat, \
        and the rest of this paragraph is English prose that outweighs the quotation \
        by a comfortable margin for the majority rule.
        """
        XCTAssertFalse(DocumentStatistics(text: text).isPredominantlyCJK)
    }

    func testHangulDoesNotTriggerSuppression() {
        XCTAssertFalse(DocumentStatistics(text: "나는 고양이로소이다 이름은 아직 없다").isPredominantlyCJK)
    }

    func testEmptyDocumentIsNot() {
        XCTAssertFalse(DocumentStatistics(text: "").isPredominantlyCJK)
    }

    func testCJKStatisticsTextReportsCharactersOnly() {
        let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
        let text = EditorStatusFormatter.statisticsText(for: stats)
        XCTAssertFalse(text.contains("words"))
        XCTAssertTrue(text.contains("\(stats.characterCount)"))
    }

    func testLatinStatisticsTextUnchanged() {
        let stats = DocumentStatistics(text: "one two three")
        XCTAssertEqual(EditorStatusFormatter.statisticsText(for: stats), "3 words — 13 characters")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:LineformTests/DocumentStatisticsCJKTests`
Expected: FAIL (no `isPredominantlyCJK`, no `statisticsText(for:)`).

- [ ] **Step 3: Implement**

`DocumentStatistics.swift` — one pass, per the spec's rule (suppress when Han/Kana exceed half of word-forming scalars):

```swift
struct DocumentStatistics: Equatable {
    var wordCount: Int
    var characterCount: Int
    /// True when more than half of the word-forming scalars are Han, Hiragana, or
    /// Katakana. CJK prose has no interword spaces, so the run-based word count
    /// degrades to a sentence count; the status bar suppresses it and reports
    /// characters only. Content-based on purpose — never keyed off the UI locale.
    /// Hangul is space-separated and counts correctly, so it deliberately does not
    /// participate.
    var isPredominantlyCJK: Bool

    init(text: String) {
        characterCount = text.count
        let counts = Self.scan(text)
        wordCount = counts.words
        isPredominantlyCJK = counts.hanKana * 2 > counts.wordForming
    }

    private static func scan(_ text: String) -> (words: Int, wordForming: Int, hanKana: Int) {
        var words = 0
        var wordForming = 0
        var hanKana = 0
        var isInsideWord = false
        let wordCharacters = CharacterSet.alphanumerics

        for scalar in text.unicodeScalars {
            if wordCharacters.contains(scalar) {
                wordForming += 1
                if isHanOrKana(scalar) { hanKana += 1 }
                if !isInsideWord {
                    words += 1
                    isInsideWord = true
                }
            } else {
                isInsideWord = false
            }
        }

        return (words, wordForming, hanKana)
    }

    private static func isHanOrKana(_ scalar: Unicode.Scalar) -> Bool {
        // isIdeographic covers Han including the extension blocks; Kana are not
        // ideographic and need their ranges (Hiragana 3040–309F, Katakana 30A0–30FF).
        scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }
}
```

`EditorStatusPresentation.swift` — replace `statisticsText(wordCount:characterCount:)`:

```swift
static func statisticsText(for statistics: DocumentStatistics) -> String {
    if statistics.isPredominantlyCJK {
        return "\(statistics.characterCount) characters"
    }
    return "\(statistics.wordCount) words — \(statistics.characterCount) characters"
}
```

`EditorContainerView.swift:1955-1960` — the computed `statisticsText` becomes:

```swift
private var statisticsText: String {
    EditorStatusFormatter.statisticsText(for: documentStatistics)
}
```

**Also the separately composed accessibility label** (spec requires both variants there too): `EditorContainerView.swift:1978` hard-codes `"Document contains \(wordCount) words and \(characterCount) characters"`. Move that composition into the formatter so the CJK rule cannot diverge:

```swift
static func statusAccessibilityText(for statistics: DocumentStatistics) -> String {
    if statistics.isPredominantlyCJK {
        return "Document contains \(statistics.characterCount) characters"
    }
    return "Document contains \(statistics.wordCount) words and \(statistics.characterCount) characters"
}
```

and point the `:1978` site at it. Add a test:

```swift
func testCJKAccessibilityLabelOmitsWordCount() {
    let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
    XCTAssertFalse(EditorStatusFormatter.statusAccessibilityText(for: stats).contains("words"))
}
```

Search for any other caller of the old signature (`grep -rn "statisticsText(wordCount" Lineform LineformTests`) and convert it the same way, including test call sites.

- [ ] **Step 4: Run the new tests plus the status-bar pins**

Run: `xcodebuild test … -only-testing:LineformTests/DocumentStatisticsCJKTests -only-testing:LineformTests/EditorDisplayModeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/DocumentStatistics.swift Lineform/Editor/EditorStatusPresentation.swift Lineform/Editor/EditorContainerView.swift LineformTests/DocumentStatisticsTests.swift
git commit -m "Suppress the word count for predominantly-CJK documents; report characters only"
```

---

### Task 5: Localize the status bar strings

**Files:**
- Modify: `Lineform/Editor/EditorStatusPresentation.swift`

**Interfaces:**
- Consumes: Task 3's `locale:` parameter, Task 4's `statisticsText(for:)`.
- Produces: catalog keys `"Updated"`, `"Unsaved changes"`, `"Saved"`, `"Autosaved"`, `"Not saved yet"`, `"Last save"`, `"Document updated from disk"`, `"%lld words — %lld characters"`, `"%lld characters"`, `"Document contains %lld words and %lld characters"`, `"Document contains %lld characters"`. Also: the pinned, working `xcstringstool sync` invocation every later conversion task reuses.

- [ ] **Step 1: Convert every English constant to `String(localized:)`**

```swift
static let updatedIndicatorText = String(localized: "Updated")
static let unsavedChangesText = String(localized: "Unsaved changes")
static let savedIndicatorText = String(localized: "Saved")
static let autosavedIndicatorText = String(localized: "Autosaved")
```

In `lastSavedDisplay`: `String(localized: "Not saved yet")` and `String(localized: "Last save")`. In `EditorStatusIndicator.accessibilityLabel`: the four literals each become `String(localized:)` (e.g. `String(localized: "Document updated from disk")`). In `statisticsText(for:)` and `statusAccessibilityText(for:)` (added in Task 4):

```swift
if statistics.isPredominantlyCJK {
    return String(localized: "\(statistics.characterCount) characters")
}
return String(localized: "\(statistics.wordCount) words — \(statistics.characterCount) characters")
```

(and the two `"Document contains …"` variants the same way).

- [ ] **Step 2: Sync the catalog and confirm the keys landed — this pins the procedure for every later task**

Run the Catalog sync procedure from Global Constraints. First check the tool's actual interface on this Xcode — `xcrun xcstringstool sync --help` — and adjust the flag spelling to what it prints (the subcommand exists; the exact stringsdata-input flag must be confirmed empirically here). Then:

`python3 -c "import json; s=json.load(open('Lineform/Localizable.xcstrings'))['strings']; print(sorted(s))"`

Expected: the eleven keys from this task's Produces list appear. If `sync` cannot be made to consume the stringsdata, hand-author the keys into the catalog JSON instead (empty `{ }` entries, same shape as Task 12's examples) — and note in the task journal that all later tasks must hand-author too. **Record the exact working command (or the hand-author decision) in the task journal — Tasks 6, 8, 9, 10, and 11 repeat it verbatim.** Do not touch `SWIFT_EMIT_LOC_STRINGS`; it is already YES in both configurations.

- [ ] **Step 3: Run the status-bar and formatting tests**

Run: `xcodebuild test … -only-testing:LineformTests/EditorDisplayModeTests -only-testing:LineformTests/DocumentStatisticsCJKTests -only-testing:LineformTests/EditorStatusDateFormattingTests`
Expected: PASS — under the pinned `en` test locale every string is byte-identical.

- [ ] **Step 4: Commit**

```bash
git add Lineform/Editor/EditorStatusPresentation.swift Lineform/Localizable.xcstrings Lineform.xcodeproj/project.pbxproj
git commit -m "Localize status bar strings through the catalog"
```

---

### Task 6: Localize AppMenuConfiguration and AppCommands

**Files:**
- Modify: `Lineform/App/AppCommands.swift` (the `AppMenuConfiguration` enum, `:33-121`, and any literal titles inside `AppCommands` views)

**Interfaces:**
- Consumes: catalog infrastructure.
- Produces: every `AppMenuConfiguration` title resolves localized at runtime while its **catalog key is the English title** — Task 7's decorator resolution depends on exactly that. Constant names and types are unchanged.

- [ ] **Step 1: Convert the ~40 static titles**

Pattern, applied to every user-facing title in `AppMenuConfiguration`:

```swift
static let aboutCommandTitle = String(localized: "About Lineform")
static let settingsCommandTitle = String(localized: "Settings…")
```

Arrays element-wise (`markdownFormattingCommandTitles`), and any `static func … -> String` title builder converts its returned literals (interpolated returns use `String(localized: "Convert to \(name)")`-style keys only if the interpolation is another localized noun; if the function switches over cases, localize each case's literal separately — never build a sentence by concatenation).

Do **not** convert: `aboutVersionDisplay`, `aboutCopyright` (Global Constraints), notification names, UserDefaults keys, URLs, or any string that never renders.

- [ ] **Step 2: Sweep AppCommands for literal titles the enum does not own**

Run: `grep -nE 'Button\("|Toggle\("|Menu\("|Text\("|Label\("' Lineform/App/AppCommands.swift`
Convert each user-facing hit to `String(localized:)` (SwiftUI literal initializers extract on their own, but this file mixes both shapes — converting keeps every key visible in one style). Keyboard shortcut definitions and SF Symbol names stay untouched.

- [ ] **Step 3: Sync the catalog; verify the keys landed; launch and eyeball the English menus**

Run the Catalog sync procedure exactly as Task 5 pinned it (its journal records the working command, or the hand-author decision). Confirm menu keys are in the catalog — e.g. `"Check for Updates..."` with the ASCII three-period ellipsis, exactly as the source literal reads (Global Constraints; the `…` character is wrong and will not match). Launch the FRESH build (full `BUILT_PRODUCTS_DIR` path per the debug-launch gotcha — never `open -a Lineform`) and confirm the menu bar reads exactly as before in English.

- [ ] **Step 4: Run the menu-related tests**

Run: `xcodebuild test … -only-testing:LineformTests/MainMenuIconDecoratorTests -only-testing:LineformTests/AppCommandNotificationTests -only-testing:LineformTests/AppCommandsSidebarFileTests`
Expected: PASS (en pinned; decorator still matches because English values are unchanged).

- [ ] **Step 5: Commit**

```bash
git add Lineform/App/AppCommands.swift Lineform/Localizable.xcstrings
git commit -m "Route AppMenuConfiguration titles through the string catalog"
```

---

### Task 7: Locale-proof MainMenuIconDecorator

**Files:**
- Create: `packaging/extract-system-menu-titles.py`, `Lineform/App/SystemMenuItemTitles.swift` (generated)
- Modify: `Lineform/App/MainMenuIconDecorator.swift`, `Lineform.xcodeproj/project.pbxproj` (add the new Swift file to PBXSourcesBuildPhase — 4 sections, IDs `1F0000320000000000000001`/`…11`)
- Test: `LineformTests/MainMenuIconDecoratorTests.swift`

**Interfaces:**
- Consumes: Task 6's guarantee that catalog keys are English titles.
- Produces: `MainMenuIconDecorator.runtimeLanguageCode(preferredLocalizations:) -> String`, `.localizedAliases(languageCode:) -> [String: String]`, `.systemProvidedNormalizedKeys: Set<String>`, `.localizedSymbolsByNormalizedTitle(languageCode:) -> [String: String]`; `SystemMenuItemTitles.titles: [String: [String: String]]` (`englishTitle → languageCode → localizedTitle`, language codes `es|fr|de|ja|zh-Hans`); `AppMenuConfiguration.allEnglishTitleKeys: [String]`.

Background (spec): 108 `symbolsByTitle` entries match by normalized English title and fail silently in other locales; 38 selector entries are locale-proof. `Passwords` and `Credit Card` have no Apple translation source — accepted icon loss outside English, asserted as the only exceptions.

- [ ] **Step 1: Write the failing locale test**

Add to `MainMenuIconDecoratorTests`:

The implementation keeps English keys in the runtime map as a safety net, so the
test must NOT probe through that fallback — it asserts each entry gained a
**localized** alias, which is the thing that can actually regress:

```swift
func testEveryTitleKeyedEntryGainsALocalizedAliasInAllShippedLocales() {
    // Passwords / Credit Card: AppKit ships no localized title for these AutoFill
    // rows, so their icons are accepted as English-only (spec, MainMenuIconDecorator).
    let acceptedLosses: Set<String> = ["passwords", "credit card"]

    for language in ["es", "fr", "de", "ja", "zh-Hans"] {
        let aliases = MainMenuIconDecorator.localizedAliases(languageCode: language)
        for englishNormalized in MainMenuIconDecorator.symbolsByTitle.keys
        where !acceptedLosses.contains(englishNormalized) {
            let localized = aliases[englishNormalized]
            XCTAssertNotNil(localized, "\(englishNormalized): no localized title in \(language)")
            // Once Task 13's translations land, a localized alias equal to the
            // English key means the entry silently fell back — flag it. Before
            // translations exist this holds trivially for system items only.
            if MainMenuIconDecorator.systemProvidedNormalizedKeys.contains(englishNormalized) {
                XCTAssertNotEqual(localized, englishNormalized,
                                  "\(englishNormalized): \(language) alias is just the English title")
            }
        }
    }
}

func testRuntimeLanguageDerivationMatchesCatalogFolderNames() {
    // Locale.language.languageCode collapses zh-Hans to "zh", which matches neither
    // the SystemMenuItemTitles keys nor the compiled zh-Hans.lproj folder. The
    // runtime code must use Bundle.main.preferredLocalizations — this pin keeps it so.
    XCTAssertEqual(MainMenuIconDecorator.runtimeLanguageCode(preferredLocalizations: ["zh-Hans", "en"]),
                   "zh-Hans")
    XCTAssertEqual(MainMenuIconDecorator.runtimeLanguageCode(preferredLocalizations: []), "en")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:LineformTests/MainMenuIconDecoratorTests`
Expected: FAIL — `localizedAliases`, `runtimeLanguageCode`, and `systemProvidedNormalizedKeys` do not exist yet.

- [ ] **Step 3: Write and run the system-title extraction script**

`packaging/extract-system-menu-titles.py` — reads every `*.loctable` under the AppKit Resources directory, takes the union of English values that appear (case-insensitively, after the same normalization the decorator applies: lowercase, strip trailing `…`/`.`) among `MainMenuIconDecorator.symbolsByTitle`'s keys, and emits `Lineform/App/SystemMenuItemTitles.swift`:

```python
#!/usr/bin/env python3
"""Generate SystemMenuItemTitles.swift from the AppKit .loctable files.

System-provided menu items ("Writing Tools", "Services", window management…)
arrive already localized from AppKit, so our catalog has no key for them; this
compiled dictionary is how MainMenuIconDecorator recognizes their localized
titles. Regenerate on a new macOS if system menu wording changes.
"""
import json, re, subprocess
from pathlib import Path

APPKIT = Path("/System/Library/Frameworks/AppKit.framework/Versions/C/Resources")
LANGS = {"es": "es", "fr": "fr", "de": "de", "ja": "ja", "zh_CN": "zh-Hans"}
DECORATOR = Path(__file__).resolve().parent.parent / "Lineform/App/MainMenuIconDecorator.swift"

def normalized(title):
    t = title.replace("Lineform", "").strip()
    while t.endswith("…") or t.endswith("."):
        t = t[:-1]
    return t.strip().lower()

src = DECORATOR.read_text()
body = src[src.index("symbolsByTitle: [String: String] = ["):]
body = body[:body.index("\n    ]")]
wanted = {normalized(k): None for k in re.findall(r'"([^"]+)"\s*:', body)}

found = {}
for table in sorted(APPKIT.glob("*.loctable")):
    data = json.loads(subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(table)],
        capture_output=True, check=True).stdout)
    english = data.get("en", {})
    for key, en_value in english.items():
        if not isinstance(en_value, str) or normalized(en_value) not in wanted:
            continue
        entry = {}
        for loc_key, our_key in LANGS.items():
            value = data.get(loc_key, {}).get(key)
            if isinstance(value, str):
                entry[our_key] = value
        if len(entry) == len(LANGS):
            found.setdefault(en_value, entry)

lines = ["// Generated by packaging/extract-system-menu-titles.py — do not edit by hand.",
         "// Localized titles of SYSTEM-provided menu items, which AppKit localizes itself",
         "// and our catalog therefore cannot resolve. Keyed by English title, then language.",
         "enum SystemMenuItemTitles {",
         "    static let titles: [String: [String: String]] = ["]
for en_value in sorted(found):
    entry = ", ".join(f'"{lang}": "{found[en_value][lang]}"' for lang in sorted(found[en_value]))
    lines.append(f'        "{en_value}": [{entry}],')
lines += ["    ]", "}", ""]
Path(DECORATOR.parent / "SystemMenuItemTitles.swift").write_text("\n".join(lines))
print(f"{len(found)} system titles")
```

Run it; expect several dozen titles (`Writing Tools`, `Services`, `Bring All to Front`, spelling/substitution/transformation items…). Register the new Swift file in the pbxproj (PBXSourcesBuildPhase, not Resources).

- [ ] **Step 4: Implement the localized resolution in the decorator**

```swift
/// The resolved app language, in the form that matches both the compiled
/// <lang>.lproj folder names and SystemMenuItemTitles' keys. NEVER derive this
/// from Locale.language.languageCode — it collapses "zh-Hans" to "zh", which
/// matches neither (verified), silently losing every title-keyed icon in Chinese.
static func runtimeLanguageCode(
    preferredLocalizations: [String] = Bundle.main.preferredLocalizations
) -> String {
    preferredLocalizations.first ?? "en"
}

/// englishNormalizedKey → the localized title's NORMALIZED form, for every entry
/// that has a translation source (our catalog, or the generated system table).
/// Split out from the map builder so the test can assert aliases exist without
/// the English fallback masking a miss.
static func localizedAliases(languageCode: String) -> [String: String] {
    var aliases: [String: String] = [:]
    let bundle = Bundle.main.path(forResource: languageCode, ofType: "lproj")
        .flatMap(Bundle.init(path:))

    for englishNormalized in symbolsByTitle.keys {
        for (englishTitle, translations) in SystemMenuItemTitles.titles
        where normalizedTitle(englishTitle) == englishNormalized {
            if let localized = translations[languageCode] {
                aliases[englishNormalized] = normalizedTitle(localized)
            }
        }
        if aliases[englishNormalized] == nil, let bundle {
            // Our own commands: the catalog key is the pre-normalization English
            // title, exactly as the AppCommands literal reads (ASCII "..." kept).
            for title in AppMenuConfiguration.allEnglishTitleKeys
            where normalizedTitle(title) == englishNormalized {
                aliases[englishNormalized] =
                    normalizedTitle(bundle.localizedString(forKey: title, value: title, table: nil))
            }
        }
    }
    return aliases
}

/// English normalized keys that resolve from the generated system table — the
/// test uses this to know which aliases must differ from English pre-translation.
static var systemProvidedNormalizedKeys: Set<String> {
    Set(SystemMenuItemTitles.titles.keys.map(normalizedTitle))
        .intersection(symbolsByTitle.keys)
}

/// Per-language lookup used by `symbolName(for:)`. English keys stay in the map
/// unconditionally: harmless in English, the safety net everywhere else. Built
/// once per process — the menu language cannot change mid-run.
static func localizedSymbolsByNormalizedTitle(languageCode: String) -> [String: String] {
    var map = symbolsByTitle
    for (englishNormalized, localizedNormalized) in localizedAliases(languageCode: languageCode) {
        map[localizedNormalized] = symbolsByTitle[englishNormalized]
    }
    return map
}

private static let runtimeTitleMap: [String: String] =
    localizedSymbolsByNormalizedTitle(languageCode: runtimeLanguageCode())
```

`symbolName(for:)`'s title branch becomes `return runtimeTitleMap[normalizedTitle(item.title)]`.

This needs `AppMenuConfiguration.allEnglishTitleKeys: [String]` — add it in
`AppCommands.swift` as a **plain hand-maintained array** listing the
pre-localization English key of every title constant, byte-for-byte as the
literals read. (A registrar that appends keys as constants initialize was
considered and rejected: static stored properties are lazy, so the array would
be empty or partial when the decorator reads it.) Completeness is asserted, not
remembered — extend `testConfiguredCommandTitlesAllHaveIcons`
(`MainMenuIconDecoratorTests.swift:32`) with: every `AppMenuConfiguration`
title it already walks must ALSO appear (normalized) among
`allEnglishTitleKeys.map(normalizedTitle)`, so a new menu command that skips
the array fails the suite.

- [ ] **Step 5: Run the decorator tests**

Run: `xcodebuild test … -only-testing:LineformTests/MainMenuIconDecoratorTests`
Expected: PASS. Pre-translation, our-command aliases resolve to English values (the catalog returns the key), which satisfies the existence assertion; system-provided entries must already differ from English — the generated table ships real translations. Task 13 Step 6 re-runs this suite once real catalog translations exist.

- [ ] **Step 6: Commit**

```bash
git add Lineform/App/MainMenuIconDecorator.swift Lineform/App/SystemMenuItemTitles.swift Lineform/App/AppCommands.swift packaging/extract-system-menu-titles.py Lineform.xcodeproj/project.pbxproj LineformTests/MainMenuIconDecoratorTests.swift
git commit -m "Resolve menu icons by localized title: catalog for our commands, generated AppKit table for system items"
```

---

### Task 8: Localize Settings

**Files:**
- Modify: `Lineform/App/SettingsView.swift`

**Interfaces:**
- Consumes: catalog infrastructure.
- Produces: catalog keys for every settings title, note, and button.

- [ ] **Step 1: Convert every user-facing string**

`SettingsView` has zero `Text("…")` literals; everything flows through `static let title = "Settings"`-style constants and `settingRow(title:note:)` `String` parameters. Convert each **definition site** to `String(localized:)` — the `settingRow` helper itself stays `String`-typed (its inputs arrive already localized). Sweep: `grep -nE '= "[A-Z]|: "[A-Z]' Lineform/App/SettingsView.swift` and convert every user-facing hit; skip UserDefaults keys and identifiers.

- [ ] **Step 2: Sync the catalog; verify keys landed; verify Settings window unchanged in English**

Run the Catalog sync procedure exactly as Task 5 pinned it, then check the catalog for a few expected keys (`"Settings"`, announcement toggle title). Launch the fresh build, open Settings, confirm identical English rendering.

- [ ] **Step 3: Run settings tests**

Run: `xcodebuild test … -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Lineform/App/SettingsView.swift Lineform/Localizable.xcstrings
git commit -m "Localize the Settings window strings"
```

---

### Task 9: Sidebar, tabs, outline chrome, reading popover

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift`, `Lineform/ReadingExperience/FontOption.swift`, `Lineform/ReadingExperience/ReadingExperiencePopover.swift`, `Lineform/Editor/DocumentTab.swift:17`
- Test: `LineformTests/OutlineSidebarTabTests.swift`, `LineformTests/OutlineSidebarViewTests.swift`, `LineformTests/ReadingExperienceTests` (locate the popover's test class by grep; create `ReadingPopoverFormatterTests` if none fits)

**Interfaces:**
- Consumes: catalog infrastructure.
- Produces: `OutlineSidebarTab.title: String` (localized; `rawValue` untouched); `ReadingExperienceInspector.decimalText(_:maximumFractionDigits:locale:) -> String` (existing private helper made internal, with a locale parameter).

- [ ] **Step 1: Write the failing tab-title test change**

In `OutlineSidebarTabTests`, replace the `rawValue`-based title assertion with:

```swift
func testTabTitlesRemainStableInEnglish() {
    XCTAssertEqual(OutlineSidebarTab.allCases.map(\.title), ["Outline", "Files", "Markdown Basics"])
}

func testRawValuesAreIdentityNotDisplayAndNeverChange() {
    // rawValue is persisted identity; localizing it would corrupt saved state.
    XCTAssertEqual(OutlineSidebarTab.allCases.map(\.rawValue), ["Outline", "Files", "Markdown Basics"])
}
```

Run `-only-testing:LineformTests/OutlineSidebarTabTests` — expect FAIL (no `title`).

- [ ] **Step 2: Add `title` and convert the render sites**

```swift
extension OutlineSidebarTab {
    /// Display name. `rawValue` stays English forever — it is identity, not copy.
    var title: String {
        switch self {
        case .outline: return String(localized: "Outline")
        case .files: return String(localized: "Files")
        case .markdownBasics: return String(localized: "Markdown Basics")
        }
    }
}
```

(Match the real case names — read the enum at `OutlineSidebarView.swift:4-7` first.) Convert `Text(tab.rawValue)` at `:911` to `Text(tab.title)`, and the `tabTitles` accessor at `:128` to map `\.title`. Update `OutlineSidebarViewTests.swift:27` to the `title`-based expectation.

- [ ] **Step 3: Sweep the sidebar chrome strings**

`grep -nE 'Text\("|Button\("|Label\("|accessibilityLabel\("|help\("|= "[A-Z]' Lineform/Outline/OutlineSidebarView.swift` — convert user-facing hits (empty states, buttons, context-menu items, AX labels/actions). **Skip `MarkdownReference` content entirely** (Phase 2). Convert `DocumentTab.swift:17`'s `"Untitled"` to `String(localized: "Untitled")`.

- [ ] **Step 4: Font group headings + popover strings + formatter extraction**

`FontOption.swift:15-37`: the three `FontOptionGroup(name:)` literals become `String(localized: "System")`, `String(localized: "Writing")`, `String(localized: "Reading & Accessibility")`. Font **names** stay literal. (`FontOptionGroup.id` is its name — session-stable, not persisted; verified acceptable in the spec.)

`ReadingExperiencePopover.swift`: sweep labels the same way. The file's view
type is `ReadingExperienceInspector` (line 3) — there is no type named
`ReadingExperiencePopover`. The number helper is
`private static func decimalText(_ value: Double, maximumFractionDigits: Int)`
at `:279-284`, which builds a `NumberFormatter` with no locale. Change it to
internal, add a locale parameter, and keep the existing configuration:

```swift
static func decimalText(_ value: Double, maximumFractionDigits: Int,
                        locale: Locale = .autoupdatingCurrent) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = maximumFractionDigits
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maximumFractionDigits)f", value)
}
```

New test (in the popover's existing test class if one exists — locate with
`grep -rln "ReadingExperienceInspector" LineformTests` — else a new
`ReadingExperienceInspectorFormatterTests`):

```swift
func testDecimalTextFollowsLocale() {
    XCTAssertEqual(ReadingExperienceInspector.decimalText(1.5, maximumFractionDigits: 1,
                                                          locale: Locale(identifier: "de_DE")), "1,5")
    XCTAssertEqual(ReadingExperienceInspector.decimalText(1.5, maximumFractionDigits: 1,
                                                          locale: Locale(identifier: "en_US")), "1.5")
}
```

- [ ] **Step 5: Sync the catalog, then run the touched suites**

Run the Catalog sync procedure exactly as Task 5 pinned it (this task's new keys must land in `Localizable.xcstrings` before the commit).
Run: `xcodebuild test … -only-testing:LineformTests/OutlineSidebarTabTests -only-testing:LineformTests/OutlineSidebarViewTests -only-testing:LineformTests/OutlineInfoContrastTests` plus the popover test class.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift Lineform/ReadingExperience/FontOption.swift Lineform/ReadingExperience/ReadingExperiencePopover.swift Lineform/Editor/DocumentTab.swift LineformTests Lineform/Localizable.xcstrings
git commit -m "Localize sidebar, tab, and reading-popover chrome; split OutlineSidebarTab title from rawValue"
```

---

### Task 10: Alerts, panels, AppKit menus, accessibility sweep

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift`, `Lineform/Editor/SaveAsExport.swift`, `Lineform/Editor/LineformTextView.swift`, plus any file the grep in Step 1 surfaces (e.g. `Lineform/App/LineformAppNotification.swift`, `Lineform/Editor/LineformTextView+ImageInsertion.swift`)

**Interfaces:**
- Consumes: catalog infrastructure; Apple glossary for standard wording.
- Produces: catalog keys for every alert, panel, AppKit menu item, and AX string.

- [ ] **Step 1: Enumerate the AppKit-side sites**

```sh
grep -rnE 'NSMenuItem\(title: "|messageText = "|informativeText = "|addButton\(withTitle: "|\.prompt = "|\.message = "|nameFieldStringValue = "|setAccessibility(Label|Help|Value)\("|accessibilityCustomActions|NSLocalizedString' Lineform --include="*.swift" | grep -v FirstLaunchIntro
```

This is the worklist — the spec counts ×10 NSMenuItem, ×14 NSAlert, ×7 panel, ×11 setAccessibility sites. Record the list in the task journal before converting.

(SwiftUI literal sites — `Text("…")`, `Button("…")`, `.accessibilityLabel("…")`, e.g. the alert copy at `EditorContainerView.swift:202-245` and AX labels around `:975-1000` — need **no code change**: literals in those positions are `LocalizedStringKey`s that resolve against the catalog at runtime, and the sync procedure extracts them. This task's conversions are the AppKit `String`-typed sites only, where no automatic lookup exists.)

- [ ] **Step 2: Convert each site**

Every user-facing literal becomes `String(localized:)` at its site (AppKit APIs take `String`, so the wrapped form is the whole mechanism — there is no SwiftUI extraction to lean on here). Specifics:

- Alert/button wording that matches a platform concept takes Apple's glossary wording as the English key unchanged (`"Save"`, `"Cancel"`, `"Don't Save"`, `"Replace"`) — the translation step maps them to Apple's exact terms.
- `EditorContainerView.swift:2073`, `:2121`, `SaveAsExport.swift:160`: `"Untitled"` → `String(localized: "Untitled")` (spec decision: suggested filenames localize, matching TextEdit).
- `LineformTextView.swift:971-973` AX strings; the hand-built context menu items in `menu(for:)` (spelling guesses header, Learn/Ignore) — their English keys are the exact AppKit spelling-menu titles so the glossary supplies Apple's wording.
- Do NOT touch: `CalloutKind.displayName` (document-derived), notification names, pasteboard types, UTType identifiers, log messages.

- [ ] **Step 3: Sync the catalog, then run the editor-behavior suites**

Run the Catalog sync procedure exactly as Task 5 pinned it (this task's keys must land in `Localizable.xcstrings` before the commit).
Run: `xcodebuild test … -only-testing:LineformTests/LineformDocumentTests -only-testing:LineformTests/EditorTabStoreTests -only-testing:LineformTests/DocumentReloadControllerTests -only-testing:LineformTests/AppCommandNotificationTests`
Expected: PASS.

- [ ] **Step 4: Manual English smoke test**

Launch the fresh build; trigger one alert (close an untitled tab with content), one save panel (⌘S on untitled — confirm the suggested name still reads "Untitled"), the editor context menu (right-click a misspelled word — guesses, Learn, Ignore all present). All identical to before.

- [ ] **Step 5: Commit**

```bash
git add -A Lineform Lineform/Localizable.xcstrings
git commit -m "Localize alerts, panels, AppKit menu items, and accessibility strings"
```

---

### Task 11: First-launch intro overlay

**Files:**
- Modify: `Lineform/App/FirstLaunchIntroOverlay.swift`, `Lineform/Resources/FirstLaunchIntro/index.html`

**Interfaces:**
- Consumes: catalog infrastructure.
- Produces: catalog keys `"Get Started"`, `"Dismisses the welcome screen and opens a new document"`, `"Simple markdown editing"`, `"Replay"`.

- [ ] **Step 1: Localize the native button**

`FirstLaunchIntroStartButtonView` (`:321`, `:352-353`): the label literal, `setAccessibilityLabel`, and `setAccessibilityHelp` each become `String(localized:)`. The button sizes itself from `FirstLaunchIntroOverlayMetrics.startButtonSize` — check whether the German label ("Los geht's" / similar length) overflows the fixed size; if the label is laid out by frame math rather than intrinsic size, widen using `label.intrinsicContentSize` at init.

- [ ] **Step 2: Tag the HTML strings and fix the title**

In `index.html`: `<title>Lineform Intro Prototype</title>` → `<title>Lineform</title>`. Add `data-l10n-id="tagline"` to the element containing `Simple markdown editing` and `data-l10n-id="replay"` to the Replay control. (The debug tuning labels — dispersion, refraction, etc. — are not user-facing; leave them.)

- [ ] **Step 3: Inject the string table**

In `FirstLaunchIntroWebView.makeNSView` (`:487`), before creating the web view, build a `WKUserScript`:

```swift
let l10n: [String: String] = [
    "tagline": String(localized: "Simple markdown editing"),
    "replay": String(localized: "Replay")
]
let json = String(data: try! JSONEncoder().encode(l10n), encoding: .utf8)!
let script = WKUserScript(
    source: """
    const l10n = \(json);
    document.querySelectorAll('[data-l10n-id]').forEach(el => {
        const value = l10n[el.getAttribute('data-l10n-id')];
        if (value) el.textContent = value;
    });
    """,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true)
configuration.userContentController.addUserScript(script)
```

- [ ] **Step 4: Sync the catalog, then verify in English and German**

Run the Catalog sync procedure exactly as Task 5 pinned it (`"Get Started"`, the AX help text, `"Simple markdown editing"`, and `"Replay"` must land in `Localizable.xcstrings` before the commit). Reset the first-launch flag (find it: `grep -rn "firstLaunch\|FirstLaunch" Lineform --include="*.swift" | grep -i "defaults\|UserDefaults"`, then `defaults delete com.lineform.app <key>`). Launch fresh build — intro identical in English. Then `defaults delete` again and launch with `open -a <full BUILT_PRODUCTS_DIR path>/Lineform.app --args -AppleLanguages "(de)"` — tagline/button render (still English pre-translation; the wiring is what's being verified: no blank tagline, no missing button label). Confirm Tab/Space still dismisses (AX invariant).

- [ ] **Step 5: Commit**

```bash
git add Lineform/App/FirstLaunchIntroOverlay.swift Lineform/Resources/FirstLaunchIntro/index.html Lineform/Localizable.xcstrings
git commit -m "Localize the first-launch intro: native button plus injected string table for the web page"
```

---

### Task 12: Info.plist and App Intents catalogs

**Files:**
- Modify: `Lineform/InfoPlist.xcstrings`, `Lineform/AppShortcuts.xcstrings`, `Lineform/App/LineformAppIntents.swift` (only if shortTitles need explicit keys)

**Interfaces:**
- Consumes: Task 1's catalogs.
- Produces: InfoPlist keys `"Markdown Document"`, `"Plain Text Document"`; AppShortcuts keys for the three phrases.

- [ ] **Step 1: Author the InfoPlist keys**

Document-type names localize with the English **value** as key. Edit `InfoPlist.xcstrings` to:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "Markdown Document" : { },
    "Plain Text Document" : { }
  },
  "version" : "1.0"
}
```

(`UTTypeDescription` shares the `"Markdown Document"` key.)

- [ ] **Step 2: Author the AppShortcuts keys**

The three phrases from `LineformAppIntents.swift:57-67`, with the application-name token in xcstrings placeholder form:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "New note in ${applicationName}" : { },
    "Create a note in ${applicationName}" : { },
    "Open a file in ${applicationName}" : { }
  },
  "version" : "1.0"
}
```

The `shortTitle`s (`"New Note"`, `"Open in Lineform"`) are `LocalizedStringResource` and extract into `Localizable.xcstrings` on build — verify they appear there after Step 3; if not, wrap them explicitly.

- [ ] **Step 3: Build and verify the metadata invariant**

Build; re-run the `Metadata.appintents` existence check from Task 1 Step 4. Expected: present. This is also where the spec's verify-at-first-build item resolves: note in the task journal whether the build logged any `appintentsmetadataprocessor` warnings/errors for the phrases.

- [ ] **Step 4: Run the release-resource tests**

Run: `xcodebuild test … -only-testing:LineformTests/ReleaseResourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/InfoPlist.xcstrings Lineform/AppShortcuts.xcstrings Lineform/Localizable.xcstrings Lineform/App/LineformAppIntents.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Author InfoPlist and AppShortcuts catalog keys"
```

---

### Task 13: Quality gates, then the translations themselves

**Files:**
- Create: `LineformTests/LocalizationCatalogTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (test file into LineformTests' PBXSourcesBuildPhase — IDs `1F0000320000000000000021`/`…31`), `Lineform/Localizable.xcstrings`, `Lineform/InfoPlist.xcstrings`, `Lineform/AppShortcuts.xcstrings`

**Interfaces:**
- Consumes: every key created by Tasks 3–12; both glossaries from Task 2.
- Produces: the three catalogs fully translated in `es`, `fr`, `de`, `ja`, `zh-Hans`; the gates that keep them that way.

- [ ] **Step 1: Write the three gate tests (they MUST fail now — no translations exist)**

```swift
import XCTest

/// Reads the .xcstrings source files from the repo (via #filePath), not the built
/// bundle — the gates protect the committed catalogs.
final class LocalizationCatalogTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // …/LineformTests/LocalizationCatalogTests.swift
            .deletingLastPathComponent()          // …/LineformTests
            .deletingLastPathComponent()          // repo root
    }

    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let url = repoRoot().appendingPathComponent("Lineform/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func translation(_ entry: [String: Any], _ language: String) -> String? {
        let localizations = entry["localizations"] as? [String: [String: Any]]
        let unit = localizations?[language]?["stringUnit"] as? [String: Any]
        // Plural entries nest under "variations"; any translated variation counts as present.
        if unit == nil, let variations = localizations?[language]?["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: [String: Any]],
           let anyForm = plural.values.first?["stringUnit"] as? [String: Any] {
            return anyForm["value"] as? String
        }
        return unit?["value"] as? String
    }

    private func isTranslatable(_ entry: [String: Any]) -> Bool {
        (entry["shouldTranslate"] as? Bool) ?? true
    }

    func testEveryKeyIsTranslatedInEveryLanguage() throws {
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            let strings = try catalog(name)
            for (key, entry) in strings where isTranslatable(entry) {
                for language in Self.languages {
                    XCTAssertNotNil(translation(entry, language),
                                    "\(name): '\(key)' missing \(language)")
                }
            }
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let pattern = try NSRegularExpression(pattern: #"%(\d+\$)?(lld|@|d|ld|lu|f|s)"#)
        func specifiers(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]) }
        }
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            for (key, entry) in try catalog(name) where isTranslatable(entry) {
                let source = specifiers(key)
                for language in Self.languages {
                    guard let value = translation(entry, language) else { continue }
                    XCTAssertEqual(specifiers(value), source,
                                   "\(name): '\(key)' \(language) placeholder drift")
                }
            }
        }
    }

    func testGlossaryTermsTranslateConsistently() throws {
        let glossaryURL = repoRoot().appendingPathComponent("docs/notes/lineform-glossary.json")
        let glossary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: glossaryURL)) as? [String: [String: String]])
        // Keys whose English is a whole glossary term used in a different sense may
        // be exempted here, with a comment saying why. Empty until proven needed.
        let exemptions: Set<String> = []

        // Whole-word matching, not substring: "Tab" must not match "Table" and
        // "Read" must not match "Reading & Accessibility".
        func containsWholeWord(_ text: String, _ term: String) -> Bool {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b",
                options: .caseInsensitive) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        let strings = try catalog("Localizable")
        for (term, translations) in glossary {
            for (key, entry) in strings
            where isTranslatable(entry) && containsWholeWord(key, term) && !exemptions.contains(key) {
                for language in Self.languages {
                    guard let value = translation(entry, language),
                          let expected = translations[language] else { continue }
                    XCTAssertTrue(
                        value.localizedCaseInsensitiveContains(expected),
                        "'\(key)' \(language): expected glossary term '\(expected)' in '\(value)'")
                }
            }
        }
    }
}
```

Register the file in the pbxproj (LineformTests sources phase).

- [ ] **Step 2: Run to verify the completeness gate fails**

Run: `xcodebuild test … -only-testing:LineformTests/LocalizationCatalogTests`
Expected: `testEveryKeyIsTranslatedInEveryLanguage` FAILS listing every key; the other two pass vacuously. **If it passes instead, the catalog is empty — the sync steps in Tasks 5–11 were skipped or broken. Stop and repair that first; a green gate over an empty catalog certifies nothing** (the whole translation step could no-op while every gate stays green).

- [ ] **Step 3: Mark non-UI keys `shouldTranslate: false`**

Read every key in `Localizable.xcstrings`. Any extracted key that is not user-facing copy (symbol names, identifiers, debug strings that leaked through a `String(localized:)` that should not have been one — fix those at the source instead) gets `"shouldTranslate" : false`. Font names and "Lineform" must not appear as keys at all (they were never wrapped).

- [ ] **Step 4: Author the translations**

For every remaining key, in all five languages, directly in the xcstrings JSON (`"state" : "translated"`). Rules, in priority order:

1. If the English key (or its obvious base, ellipsis/shortcut stripped) exists in `docs/notes/apple-terminology-glossary.json`, use Apple's translation **verbatim**.
2. Any embedded Lineform glossary term uses `docs/notes/lineform-glossary.json`'s rendering.
3. Counted strings get plural `variations` per language; Japanese and Chinese use only `other`; Spanish keeps Apple's NBSP-before-numeral convention where the glossary shows it.
4. Menus keep macOS conventions per language: `…` ellipsis retained; German capitalizes nouns; French uses non-breaking space before `?`/`!`; Japanese/Chinese drop the ellipsis only if Apple's own menus do (check the glossary entry).
5. `AppShortcuts` phrases must keep `${applicationName}` intact in every language, positioned naturally (e.g. de `"Neue Notiz in ${applicationName}"`).

Worked examples of the required shape (plural entry):

```json
"%lld words — %lld characters" : {
  "localizations" : {
    "de" : { "variations" : { "plural" : {
      "one" :   { "stringUnit" : { "state" : "translated", "value" : "%lld Wort — %lld Zeichen" } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld Wörter — %lld Zeichen" } }
    } } },
    "ja" : { "variations" : { "plural" : {
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld語 — %lld文字" } }
    } } }
  }
}
```

(The `one` form is genuinely wrong for a two-placeholder string unless both counts are one — follow Apple's own `%ld replaced` pattern: vary on the FIRST argument, accept the compromise, and do the same in every language that has `one`.)

- [ ] **Step 5: Run all three gates to green**

Run: `xcodebuild test … -only-testing:LineformTests/LocalizationCatalogTests`
Expected: PASS ×3. Iterate on Step 4 until they do.

- [ ] **Step 6: Re-run the decorator locale test — it now checks real translations**

Run: `xcodebuild test … -only-testing:LineformTests/MainMenuIconDecoratorTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add LineformTests/LocalizationCatalogTests.swift Lineform/Localizable.xcstrings Lineform/InfoPlist.xcstrings Lineform/AppShortcuts.xcstrings Lineform.xcodeproj/project.pbxproj
git commit -m "Author all five translations behind completeness, glossary, and placeholder gates"
```

---

### Task 14: Convert the remaining English-pinned tests

**Files:**
- Modify: any test file the recipe surfaces (known floor: `EditorDisplayModeTests`, `MarkdownReferenceTests`, `OutlineSidebarViewTests`, `OutlineSidebarTabTests`, `MainMenuIconDecoratorTests` — the last three already converted in Tasks 7/9)

**Interfaces:**
- Consumes: the completed `Localizable.xcstrings`.
- Produces: a suite that is green under the pinned `en` locale and does not silently depend on an unpinned one.

- [ ] **Step 1: Run the catalog-driven enumeration (the spec's recipe)**

```sh
python3 - <<'EOF'
import json, subprocess
strings = json.load(open('Lineform/Localizable.xcstrings'))['strings']
keys = [k for k, v in strings.items() if v.get('shouldTranslate', True) and len(k) > 3]
for key in keys:
    probe = key.split('%')[0].strip()
    if len(probe) < 4:
        continue
    out = subprocess.run(['grep', '-rlnF', probe, 'LineformTests'], capture_output=True, text=True).stdout  # -F: keys contain . ( ) that must not act as regex
    if out:
        print(f"{key!r}: {out.strip().splitlines()}")
EOF
```

Record the list. `MarkdownReferenceTests` hits are expected and STAY as-is (Phase 2 owns that content; it is still English source data).

- [ ] **Step 2: Convert each surfaced assertion**

For each test asserting a UI string: the pinned `en` test locale makes the English literal correct — the conversion needed is only where a test would break under a DIFFERENT locale being pinned later, i.e. replace literals with the constant they test where one exists (`EditorStatusFormatter.savedIndicatorText`, `AppMenuConfiguration.…`), keep literals where the test's very purpose is pinning English output (`testTabTitlesRemainStableInEnglish` — add a `// pinned-en` comment so the next sweep can skip them deliberately).

- [ ] **Step 3: Run every touched suite**

Run: `xcodebuild test … -only-testing:` each touched class.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add LineformTests
git commit -m "Point English-pinned tests at their source constants under the pinned en test locale"
```

---

### Task 15: Layout pass, per-language walkthrough, docs, full gate

**Files:**
- Modify: `Claude.md` (note: tracked lowercase — `git add CLAUDE.md` stages nothing), `docs/architecture/app-integration.md`
- No app-code changes expected; fix what the walkthrough finds, each fix as its own commit.

- [ ] **Step 1: Pseudolocalization-style stress check via German**

German is the stress case (30–35% expansion) and now has real strings. Launch the fresh build under each language:

```sh
BUILT=$(xcodebuild -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')
for lang in de fr es ja zh-Hans; do
  open -n "$BUILT/Lineform.app" --args -AppleLanguages "($lang)"
  # walk, then quit before the next
done
```

Walkthrough per language, screenshotting anything suspect: every main menu open (icons present — the decorator's real-world check), Settings (no clipped rows), status bar with a long German date, save panel (localized "Untitled" seed), an alert (close dirty untitled tab), sidebar tabs, reading popover (headings, no clipped sliders), toolbar, first-launch intro (`defaults delete` the flag first). Fix clipping with layout changes, not string shortening, unless the string is genuinely verbose.

- [ ] **Step 2: IME manual QA (the user drives; typing cannot be automated here)**

Ask the user to exercise, with Japanese (Hiragana) and Chinese (Pinyin) input sources: list continuation on Return mid-composition, table Tab/Shift-Tab mid-composition, Find with CJK input. Expected: composition is never broken by the intercepts (the `doCommandBy` invariant). Report what was and wasn't exercised — do not claim this passed without the user doing it.

- [ ] **Step 3: Documentation updates (CLAUDE.md rules)**

- `Claude.md`: one feature line under Main Features ("Localized interface: Spanish, French, German, Japanese, Simplified Chinese; chrome only — document-derived text stays in the document's language."), and one Load-Bearing Invariants line: "Text that renders document content (callout labels, Markdown syntax) is NEVER localized — HTML export is one-to-one; only app chrome localizes. UI strings route through `String(localized:)` with the English text as key; a bare literal in an AppKit call site silently ships English."
- `docs/architecture/app-integration.md`: a Localization section — the three catalogs, the decorator's localized-title resolution and its generated `SystemMenuItemTitles.swift`, the two accepted icon losses, the pinned `en` test locale, the intro's injected string table, the CJK word-count rule, and the glossary/gate test architecture.

- [ ] **Step 4: Full default-plan suite (the one full run)**

Warn the user about a possible TCC prompt, then:
Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: ~1100 tests, 0 failures. Report exact counts.

- [ ] **Step 5: Verify the release-surface invariants one last time**

`Metadata.appintents` exists in the built app; `ReleaseResourceTests` + `TestPlanGuardTests` green (covered by the full run); no `Lineform/Resources/Fonts` changes were made (none belong to this phase).

- [ ] **Step 6: Commit docs and report**

```bash
git add Claude.md docs/architecture/app-integration.md
git commit -m "Document Phase 1 localization: rules, decorator resolution, gates"
```

Report to the user: full-suite counts, per-language walkthrough results with anything unfixed, IME QA coverage (what the user did and didn't drive), and the two known accepted losses (Passwords/Credit Card icons outside English).

---

## Self-Review Notes

- Spec coverage checked section-by-section: refactor mechanism (T3–T11), catalogs/knownRegions/test locale (T1), App Intents + metadata gate (T1, T12), decorator with normalizedTitle/key-choice/absent-titles/zh_CN (T7), date fix (T3), number formatter (T9), CJK word count with full rule (T4), intro incl. AX and German check (T11), Untitled decision (T9 tab title, T10 filename seeds), glossaries and the five quality mechanisms (T2, T13; back-translation is folded into T13 Step 4's authoring rules rather than a separate pass — the gates are the enforceable part), pinned-test conversion with the catalog-driven recipe (T14), layout + IME + docs + full gate (T15).
- Out-of-scope guards present where an implementer would otherwise drift: MarkdownReference content (T9), CalloutKind (T10), Resources/*.md (untouched), announcements/Sparkle (untouched).
- Type consistency: `statisticsText(for:)`, `statusAccessibilityText(for:)`, `lastSavedDisplay(locale:)`, `OutlineSidebarTab.title`, `runtimeLanguageCode(preferredLocalizations:)`, `localizedAliases(languageCode:)`, `localizedSymbolsByNormalizedTitle(languageCode:)`, `SystemMenuItemTitles.titles`, `ReadingExperienceInspector.decimalText(_:maximumFractionDigits:locale:)` used consistently across tasks.
- Post-review corrections applied (second adversarial pass): catalog population via `xcstringstool sync` (CLI builds do not write back to xcstrings; `SWIFT_EMIT_LOC_STRINGS` already YES), runtime language from `Bundle.main.preferredLocalizations` (never `languageCode`, which collapses zh-Hans to zh), non-vacuous decorator test via `localizedAliases`, verified epoch `1_785_942_240`, ASCII `"..."` keys, `throws` on the date tests, `statusAccessibilityLabel` CJK coverage, `ReadingExperienceInspector.decimalText` naming, hand-maintained `allEnglishTitleKeys` (registrar rejected: lazy statics), whole-word glossary matching, `grep -F` in the enumeration recipe.
