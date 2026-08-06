# Localization Phase 1 — App Chrome

Date: 2026-08-05
Status: Approved for planning. Supersedes the single combined localization spec
(same date), split after adversarial review showed cost and value distributed
unevenly across surfaces.

## Why Two Phases

The combined spec's review established that this work is a refactor of the
string-definition layer, not a catalog drop-in, and that three surfaces need
mechanisms of their own. Cost and value split cleanly:

- **Chrome** — menus, settings, alerts, sidebar, status bar — is what blocks a
  non-English speaker from using the app at all. It is also where nearly every
  string has an exact Apple-translated equivalent in the system `.loctable`
  files, so translation confidence is highest exactly where value is highest.
- **Prose and fonts** — the `MarkdownReference` explanations, the first-launch
  intro's bundled HTML, and the 8.9 MB BIZ UDGothic bundle — cost the most,
  return the least, and concentrate the idiom risk of having no native
  reviewers.

Phase 1 ships a complete, usable localized app. Phase 2
(`2026-08-05-localization-phase-2-prose-and-fonts-design.md`) is decided after
seeing Phase 1 run in German and Japanese. Phase 2 depends on Phase 1's catalog
and test-locale infrastructure; Phase 1 depends on nothing in Phase 2.

## Goal

Localize the app chrome into Spanish (`es`), French (`fr`), German (`de`),
Japanese (`ja`), and Simplified Chinese (`zh-Hans`), and fix the two formatting
behaviors that are wrong in any non-English locale (dates, CJK word count).
Nothing about document handling, storage, or Markdown semantics changes.

Korean was cut — smallest return of the candidates, addable later as a catalog
column. Excluded and not revisited here: RTL (a bidirectional Markdown source
editor is a separate project) and Traditional Chinese (not a script conversion
of `zh-Hans`; its own terminology and review cycle).

## The Work Is a Refactor, Not a Catalog Drop-In

A String Catalog extracts string **literals** at
`LocalizedStringKey`/`LocalizedStringResource` initializer positions. Lineform
routes nearly all user-facing text through `String` constants, which bind to the
non-localizing `StringProtocol` overloads — never extracted, not localized at
runtime even if a key existed.

Evidence:

- `Lineform/App/AppCommands.swift:33` onward — every menu title is a
  `static let` on `AppMenuConfiguration`.
- Consumed as variables: `AppCommands.swift:271`
  `Button(AppMenuConfiguration.aboutCommandTitle)`, `:517`, `:555`, and roughly
  twenty more.
- `Lineform/App/SettingsView.swift` contains **zero** `Text("…")` literal sites;
  it is built from `settingRow(title:note:)` taking `String` parameters.
- Whole-app literal-initializer count: **85**, against an estimated 350–450
  translatable strings.

Plus AppKit call sites a catalog never reaches: `NSMenuItem(title:)` ×10,
`NSAlert` `messageText`/`informativeText`/`addButton(withTitle:)` ×14, panel
`prompt`/`message`/`nameFieldStringValue` ×7, `setAccessibility*` ×11 (e.g.
`Lineform/Editor/LineformTextView.swift:971`).

**Therefore:** every `String` constant that reaches the UI is converted to
`LocalizedStringResource` or wrapped in `String(localized:)` at its definition
site. The result is a hand-maintained set of `String(localized:)` call sites;
plan it as a refactor of the string-definition layer, with the catalog as
storage rather than extraction.

`AppMenuConfiguration`'s constants have a second job — `MainMenuIconDecorator`
matches on them — so the refactor must preserve that coupling (below).

## Scope

In scope:

- Menus (`AppCommands`), toolbar, settings, alerts, confirmation dialogs.
- Files sidebar, tab bar, outline sidebar chrome (tab names, buttons, empty
  states), status bar, reading-experience popover.
- Accessibility labels, hints, and custom action names, including the AppKit
  `setAccessibility*` sites.
- `Info.plist`: both `CFBundleTypeName` entries (`:53`, `:69`) and
  `UTTypeDescription` (`:89`), via `InfoPlist.xcstrings`. Note the app's
  Info.plist has **no** `CFBundleDisplayName`; do not add one — "Lineform" is a
  proper noun and is not translated.
- App Intents phrases, via their own `AppShortcuts.xcstrings`.
- **The first-launch intro overlay's strings and AX names.** The intro is the
  one window that blocks the app, and it is the first thing every new user
  sees — deferring it would make "complete localized app" false on first
  launch, on a phase that may never be scheduled. Its user-visible copy is
  small ("Simple markdown editing", "Get Started", "Replay", the stale
  `<title>Lineform Intro Prototype</title>`), and the mechanism is decided: a
  string table injected from Swift into the page
  (`FirstLaunchIntroOverlay.swift:487–496` loads
  `Resources/FirstLaunchIntro/index.html` into a `WKWebView`; the catalog
  cannot reach the HTML directly, so strings live in `Localizable.xcstrings`
  and are handed to the page at load). Injection over per-locale `.lproj` HTML:
  five diverging documents is the worse maintenance shape. The intro's German
  layout is checked in Phase 1 too — a handful of short strings in
  hand-laid-out CSS is a cheap check, and CLAUDE.md requires this window to
  stay keyboard- and VoiceOver-operable, so the localized AX names ship with
  the strings.
- The font picker's **group headings** ("System", "Writing",
  "Reading & Accessibility") — they render in the reading-experience popover,
  which is Phase 1 chrome. Font *names* are never translated (proper nouns);
  everything else font-related is Phase 2.
- Date, time, and number formatting.
- Word/character count behavior for CJK.

Deferred to Phase 2:

- `MarkdownReference` (the sidebar's "Markdown Basics" tab) — its ~30 rows of
  explanatory prose are the highest-idiom-risk strings in the app. The tab's
  *chrome* (its name in the tab strip) is Phase 1; its *content* is Phase 2.
  A localized tab name over English reference content is accepted for Phase 1:
  the content is optional reading, and the syntax column would stay English in
  every phase regardless (it is Markdown).
- CJK font cascade and BIZ UDGothic. **(Superseded — see the status header of
  `2026-08-05-localization-phase-2-prose-and-fonts-design.md`. The cascade was
  built, measured, and REMOVED in Phase 2; BIZ UDGothic stays deferred. Nothing
  here is live work.)**
- Read-aloud voice selection.
- CJK reading-preset tuning.

Out of scope entirely, with reasons:

- **`Lineform/Resources/*.md`.** Bundled into `Contents/Resources`
  (`project.pbxproj:840–843`) but no app code loads them — there is no
  `Bundle.main.url(forResource:)` for any of them. Dead bundled weight, worth
  noting separately; nothing renders them to a user.
- **Callout labels.** `CalloutKind.displayName`
  (`MarkdownBlockGrouping.swift:243–254`) feeds HTML/PDF/RTF export via
  `MarkdownHTMLRenderer.calloutHTML`. Localizing it breaks the one-to-one export
  invariant (same file exports differently on two machines) and forces a
  hand-edit in the Quick Look appex, which mirrors the renderers by hand. Rule:
  **text that renders document content stays in the document's language; text
  that is app chrome is localized.** This rule belongs in CLAUDE.md when this
  ships.
- **Document content.** Spell checking routes through `NSSpellChecker`, which
  follows the system language already.
- **The CLI helper's terminal output.** Terminal tools conventionally stay
  English.
- **In-app announcements.** `AnnouncementFeed` carries `title`/`body`/
  `actionLabel` from a remote English-only JSON with no locale field
  (`AnnouncementFeed.swift:49–51`). Localizing requires a feed schema change — a
  separate decision. Announcements stay English.
- **Appcast release notes.** Sparkle supports per-language release notes;
  adopting that is its own change. Note Sparkle's own dialogs need no work and
  will NOT stay English: the framework bundles its own localizations for all
  five target languages and resolves them itself, so the update sheet appears
  in German for free. Expected behavior, not a defect, when QA meets it.
- **README, website, App Store metadata, GitHub.** Localized App Store metadata
  is likely the highest-return reach move if a Store release is planned, but it
  is a marketing deliverable, not app code — tracked as its own decision.
- **A runtime language picker.** macOS resolves by system language; that is the
  native behavior.

## Volume

1,618 raw string literals in the Swift sources, most not user-facing
(`CodeHighlighting`'s 210 are syntax keywords; `MainMenuIconDecorator`'s 306 are
symbol names and match keys). Estimated **350–450 translatable strings**; the
true number falls out of the refactor, not a build.

## Mechanism

- `Localizable.xcstrings` — populated from the `String(localized:)` sites the
  refactor creates.
- `InfoPlist.xcstrings` — the three Info.plist entries above.
- `AppShortcuts.xcstrings` — **required and separate.** `AppShortcut` phrases
  (`LineformAppIntents.swift:53–70`) are not extracted into
  `Localizable.xcstrings`, and every localized phrase must still contain
  `\(.applicationName)` — `appintentsmetadataprocessor` rejects a phrase
  missing it (documented as an error; whether it fails the build or downgrades
  to a warning is **verified at the first localized build**, not assumed).
- `knownRegions` gains the five locales.

No third-party tooling, no new dependency.

**App Intents metadata gate.** Adding `knownRegions` and a shortcuts catalog is
a build-config change, and CLAUDE.md's `Metadata.appintents` invariant has
shipped broken once already. Re-verify `Contents/Resources/Metadata.appintents`
after the catalogs land; `ReleaseResourceTests.swift:242–250` is the existing
gate.

## MainMenuIconDecorator

Resolves SF Symbols two ways: **38 entries keyed by AppKit selector**
(`symbolsByAction`, `:176`) — locale-proof — and **108 entries keyed by
normalized English title** (`symbolsByTitle`, `:225`; counted
programmatically). The 108 fail silently in any non-English locale: "Nach
Updates suchen" never matches `"check for updates"`, the lookup returns nil, and
the row draws with no icon — a visible regression of a shipped feature,
invisible to a developer running in English.

The fix must handle four things:

1. **`normalizedTitle` is in the path** (`:138`): lowercases, strips trailing
   `…`/`.`, strips the literal `"Lineform"` (`:144`). Localized values must pass
   through it too, or nothing matches.
2. **Which string is the key.** Existing keys are *post*-normalization
   (`"save as"`); catalog keys are *pre*-normalization titles (`"Save As…"`).
   The refactor keeps `AppMenuConfiguration`'s literals as catalog keys; the
   decorator resolves each through `String(localized:)` then `normalizedTitle`,
   cached per locale alongside the existing image cache.
3. **Not every system title is in AppKit's tables.** Present: `Writing Tools`,
   `Proofread`, `Rewrite`, `Make Friendly` (`WritingTools.loctable`);
   `Move & Resize`, `Bring All to Front` (`MenuCommands.loctable`); `Services`
   (`Services.loctable`). **Absent and genuinely title-only: `Passwords` and
   `Credit Card`** (AutoFill rows, `symbolsByTitle` :292–293). Those two need
   another source or an accepted icon loss. (`Hide Others` is also absent from
   the tables but does not matter: `symbolName(for:)` checks `symbolsByAction`
   first and `"hideOtherApplications:"` is there at :180 — its `"hide others"`
   title entry at :234 is a dead fallback. Do not hunt for a translation
   nothing consumes.)
4. **The loctable language key is `zh_CN`, not `zh-Hans`**, and values are
   `\U`-escaped (`"Preferences\U2026"`). An extraction script written against
   `zh-Hans` returns nothing for Chinese.

Test: every `symbolsByTitle` entry resolves a symbol in all five locales.
`MainMenuIconDecoratorTests.swift:32–58` already walks this path and is
reworked alongside.

## Formatting Fixes

**Dates/times are hard-pinned to English.**
`EditorStatusPresentation.swift:83–95` sets `en_US_POSIX` with
`"MMM d, yyyy 'at' h:mm a"` — English month, English "at", 12-hour clock, in the
permanently visible save-status bar. Fix with `Date.FormatStyle` /
`dateStyle`+`timeStyle`, **not** a localized pattern string. Roughly twenty test
assertions pin these exact strings and need a pinned test locale.

**Numbers.** `ReadingExperiencePopover.swift:280` builds a `NumberFormatter`
with no explicit locale. Comma decimal separators in `de`/`fr`/`es` are correct
behavior — currently untested; add coverage.

**Word count is broken for CJK.** `DocumentStatistics.swift:17–33` counts
maximal runs of `CharacterSet.alphanumerics`; CJK prose has no interword spaces,
so runs break only at punctuation. Measured against the shipped algorithm:
33 Japanese characters → **3 "words"**; 23 Chinese characters → **2**. It counts
sentences. **Decision: suppress the word count and report characters only when
the document's text is predominantly CJK.** `CFStringTokenizer` segmentation is
out of scope — character count is the metric CJK writers use.

Because this was previously under-specified, the full rule:

- **Detection is content-based, never locale-based.** An English document under
  a Japanese UI keeps its valid word count; a Japanese document under an
  English UI gets the fix. The Goal's "wrong in any non-English locale" phrase
  describes the date bug, not this one.
- **The rule:** suppress when more than half of the document's word-forming
  scalars (those in `CharacterSet.alphanumerics`, the set the counter already
  walks) are Han, Hiragana, or Katakana. Computed in `DocumentStatistics` in
  the same single pass and exposed as a flag alongside the counts — the
  presentation layer receives it, never re-derives it. Mixed documents follow
  the majority; an English document quoting a Japanese sentence keeps its word
  count. The flag can flip as a document's balance crosses half, like any other
  statistic recomputed on edit.
- **Both composed variants are catalog keys**: the existing
  `"%lld words — %lld characters"` and a characters-only `"%lld characters"`,
  each a plural variation, in both `statisticsText` and the separately composed
  `statusAccessibilityLabel` (`EditorStatusPresentation.swift`).
- Hangul is space-separated and counts correctly, so this rule deliberately
  keys on Han/Kana only — nothing changes for Korean text if `ko` ships later.

## Translation Quality

No native reviewers are available; quality rests on mechanisms that can be
executed and tested.

**1. Platform terminology comes from Apple.** macOS ships Apple's localized
strings as `.loctable` files (`plutil -convert json`); AppKit alone carries 88,
including `MenuCommands`, `Menus`, `Document`, `SavePanel`, `Printing`,
`FindPanel`, `Spelling`, `TextSystem`, `Toolbar`. Verified:

| Key | en | de | fr | es | ja | zh_CN |
|---|---|---|---|---|---|---|
| `Replace All` | Replace All | Alles ersetzen | Tout remplacer | Reemplazar todo | すべて置き換え | 全部替换 |

Any string naming a platform concept — Save As, Export, Print, Find, Replace,
Undo, Duplicate, Revert, Show/Hide Sidebar, Spelling and Grammar — takes Apple's
exact wording. Extract the relevant tables once into a glossary under
`docs/notes/`; translate against it. Chrome strings are overwhelmingly of this
kind, which is why Phase 1's translation confidence is highest.

**2. Plurals come from the catalog.** Japanese and Chinese have no singular
category; Spanish uses a non-breaking space before numerals. Every counted
string is a String Catalog plural variation, never assembled from number + noun.

**3. A fixed term glossary, enforced by test.** Lineform's own vocabulary —
Write mode, Read mode, Split, Workspace, Tab, Outline, Callout, Front matter,
Reading profile — is translated once per language into a committed glossary and
used everywhere. A test asserts no source term maps to more than one translation
within a language.

**4. Format-specifier parity, enforced by test.** Same specifiers, same order,
same count as the source. A dropped `%@` is a crash.

**5. Back-translation for semantic drift.** Each translated string is
independently rendered back to English and compared against the source.

## Layout

German runs 30–35% longer than English; French and Spanish 15–25%. The toolbar,
settings panes, and tab bar are tight, so clipping is the likeliest visible
defect. Check every panel at its longest string; Xcode's pseudolocalization
finds most of it before translations land. Chinese runs about half English's
length — sparse-looking controls, cosmetic, accepted.

## IME

The invariant that keyboard intercepts hook `insertNewline`/`insertTab`/
`doCommandBy` and never `keyDown` is what makes list continuation and table Tab
safe during IME composition. No code change, but this work is the first time it
is exercised in earnest: **manual QA includes list continuation, table
Tab/Shift-Tab, and Find during active Japanese and Chinese composition.**

## Testing

- **Pin the test locale.** All suites run under explicit `en`. English UI copy
  is pinned across at least: `EditorDisplayModeTests` (twenty status-bar
  strings — the earlier draft's grep recipe found only this file and was
  presented as if it found them all), `MarkdownReferenceTests`,
  `OutlineSidebarViewTests:27`, `OutlineSidebarTabTests:8`, and
  `MainMenuIconDecoratorTests:32–58`. That list is a floor, not the
  enumeration. **The real recipe runs after the catalog exists:** for each
  English value in `Localizable.xcstrings`, grep `LineformTests` for it —
  mechanical, complete, and impossible before the keys are known. Sidebar
  ordering uses `localizedStandardCompare` (`OutlineFileSortOrder.swift:39`) so
  its tests need pinning too.
- **Decorator**: every `symbolsByTitle` entry resolves in all five locales.
- **Catalog completeness**: no user-facing key untranslated in any language.
- **Glossary consistency** and **placeholder parity**, as above.
- **`Metadata.appintents`** still emitted after the catalogs land.
- Both test plans' quarantine lists stay in lockstep (`TestPlanGuardTests`).

## Known Traps

- **"Untitled" is four strings with two different jobs.** `DocumentTab.swift:17`
  is the tab title — chrome, localized. `EditorContainerView.swift:2073`,
  `:2121`, and `SaveAsExport.swift:160` seed the save/export panels'
  `nameFieldStringValue` — they become **filenames on disk**. Decision: those
  localize too ("無題.md"), matching TextEdit and platform convention; a
  suggested filename is chrome the user edits, not document content. The point
  of this entry is that the sweep would otherwise make that filesystem-visible
  call silently.
- **`String`-raw-value enums where the raw value is display text.**
  `OutlineSidebarTab: String` (`OutlineSidebarView.swift:4–7`) renders
  `rawValue` directly (`:911`) and two tests assert the English titles
  (`OutlineSidebarViewTests.swift:27`, `OutlineSidebarTabTests.swift:8`).
  Add a `title` property; never localize a `rawValue`. `OutlineFileSortOrder`
  and `EditorDisplayMode` already separate the two — follow them.
- **Quick Look extension identity.** `INFOPLIST_KEY_CFBundleDisplayName =
  "Lineform Quick Look"` (`project.pbxproj:1287, 1312`) is a separate target
  with its own Info.plist, not covered by the app's `InfoPlist.xcstrings`.

## Release Positioning

Not marketed. Reviews come from unmet expectations; users discover their
language is present. Nobody leaves a bad review because a small free Mac app is
English-only — the downside is entirely execution risk, which the quality
mechanisms above exist to contain.
