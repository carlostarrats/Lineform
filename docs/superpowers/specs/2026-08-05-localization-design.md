# Localization Design

Date: 2026-08-05
Status: Approved for planning. Revised after adversarial review.

## Goal

Make Lineform usable by people who do not read English, by localizing the app's
interface into five additional languages. Nothing about document handling,
storage, or Markdown semantics changes.

## Languages

Spanish (`es`), French (`fr`), German (`de`), Japanese (`ja`), Simplified
Chinese (`zh-Hans`).

Korean was considered and cut: not for complexity — Hangul behaves like Latin for
layout — but because it is the smallest return of the candidates for a Mac
writing tool. It can be added later as a column in the same catalog; nothing here
forecloses it.

Deliberately excluded, and not to be revisited as part of this work:

- **RTL (Arabic, Hebrew).** A Markdown *source* editor with bidirectional text is
  a separate project: caret movement, selection, list markers, and table pipes
  all change. It is not a strings problem.
- **Traditional Chinese (`zh-Hant`).** Not a script conversion of `zh-Hans`.
  Different terminology, its own review cycle.

## The Work Is a Refactor, Not a Catalog Drop-In

This is the most important thing in this document, and the first version of it
got this wrong.

A String Catalog extracts string **literals** appearing at
`LocalizedStringKey`/`LocalizedStringResource` initializer positions. Lineform
does not write its UI that way. Nearly all user-facing text is routed through
`String` constants, which bind to the non-localizing `StringProtocol` overloads —
never extracted, and not localized at runtime even if a key existed.

Evidence:

- `Lineform/App/AppCommands.swift:33` onward — every menu title is a `static let`
  on `AppMenuConfiguration` (`aboutCommandTitle`, `saveAsCommandTitle`,
  `spellingMenuTitle`, `markdownFormattingCommandTitles: [String]`).
- Consumed as variables, not literals: `AppCommands.swift:271`
  `Button(AppMenuConfiguration.aboutCommandTitle)`, `:517`
  `Toggle(AppMenuConfiguration.showHiddenFoldersCommandTitle, …)`, `:555`
  `Menu(AppMenuConfiguration.spellingMenuTitle)`, and roughly twenty more.
- `Lineform/App/SettingsView.swift` contains **zero** `Text("…")` sites; it is
  built from `settingRow(title:note:)` taking `String` parameters.
- Whole-app count of literal-initializer sites: **85**, against an estimated
  350–450 translatable strings.

And a whole class the catalog never reaches regardless: AppKit call sites, where
a `String` literal is never extracted — `NSMenuItem(title:)` ×10, `NSAlert`
`messageText`/`informativeText`/`addButton(withTitle:)` ×14, save/open panel
`prompt`/`message`/`nameFieldStringValue` ×7, `setAccessibility*` ×11 (e.g.
`Lineform/Editor/LineformTextView.swift:971` `setAccessibilityLabel("Markdown
editor")`).

**Therefore:** every `String` constant that reaches the UI is converted to
`LocalizedStringResource`, or wrapped in `String(localized:)` at its definition
site. The result is a hand-maintained set of `String(localized:)` call sites —
the opposite of "no manual key registry to drift." Plan the work as a refactor of
the string-definition layer, sized accordingly, with the catalog as the storage
format rather than the extraction mechanism.

`AppMenuConfiguration`'s constants have a second job — they are matched by
`MainMenuIconDecorator` — so the refactor must preserve that coupling. See below.

## Scope

In scope:

- Menus (`AppCommands`), toolbar, settings, alerts, confirmation dialogs.
- Files sidebar, tab bar, outline sidebar, status bar, reading-experience popover.
- Accessibility labels, hints, and custom action names, including the AppKit
  `setAccessibility*` sites.
- `MarkdownReference` — the sidebar's "Markdown Basics" tab. In-app content.
- The first-launch intro overlay — **by a separate mechanism**, see below.
- `Info.plist`: both `CFBundleTypeName` entries (`:53`, `:69`) and
  `UTTypeDescription` (`:89`), via `InfoPlist.xcstrings`.
- App Intents phrases — **by a separate catalog**, see below.
- Date, time, and number formatting.
- Word and character count behavior for CJK.

Out of scope, with reasons:

- **`Lineform/Resources/*.md`.** These *are* shipped into `Contents/Resources`
  (`project.pbxproj:840–843`) — the earlier claim that they are "repo reference
  documents" was wrong. They are excluded because no app code loads them: there
  is no `Bundle.main.url(forResource:)` for any of them. They are dead bundled
  weight, which is worth noting separately, but nothing renders them to a user.
- **The app name.** "Lineform" is a proper noun and is not translated, for the
  same reason font names are not. Note `Lineform/Info.plist` has **no**
  `CFBundleDisplayName` at all — an earlier draft listed one that does not exist.
- **Callout labels.** See "Document-Derived Text" below.
- **Document content.** Spell checking routes through `NSSpellChecker`, which
  follows the system language already.
- **The CLI helper's terminal output** (`Lineform/CommandLineTool/`). Terminal
  tools conventionally stay English.
- **In-app announcement cards.** `AnnouncementFeed` carries `title`/`body`/
  `actionLabel` from a remote English-only JSON with no locale field
  (`AnnouncementFeed.swift:49–51`). Localizing them requires a feed schema
  change, a separate decision. Announcements stay English; state this rather
  than discovering it.
- **Sparkle's update UI and `docs/appcast.xml` release notes.** Sparkle supports
  per-language release notes; adopting that is its own change.
- **README, website, App Store metadata, GitHub.**
- **A runtime language picker.** macOS resolves by system language.

## Volume

1,618 raw string literals across the Swift sources, most not user-facing —
`CodeHighlighting` (210) is syntax keywords, `MainMenuIconDecorator` (306) is SF
Symbol names and match keys. A proxy count of unique capitalized literals
containing a space gives 201. Including single-word controls the translatable set
is estimated at **350–450 strings**. This is a static-counting estimate; the true
number falls out of the refactor above, not of a build.

## Mechanism

- `Localizable.xcstrings` — the app's own UI strings, populated from the
  `String(localized:)` sites created by the refactor.
- `InfoPlist.xcstrings` — `CFBundleTypeName` ×2, `UTTypeDescription`.
- `AppShortcuts.xcstrings` — **required and separate.** `AppShortcut` phrases
  (`Lineform/App/LineformAppIntents.swift:53–70`) are not extracted into
  `Localizable.xcstrings`. Every localized phrase must still contain
  `\(.applicationName)`; `appintentsmetadataprocessor` treats a phrase missing it
  as a **build error**, not a warning.
- `knownRegions` gains the five locales.

No third-party localization tooling, no new dependency.

## App Intents and the Metadata Invariant

CLAUDE.md: *"`AppIntents.framework` must stay LINKED … Verify
`Contents/Resources/Metadata.appintents` exists after any build-config change.
**This already shipped broken once.**"*

Adding `knownRegions` and a shortcuts catalog is a build-config change.
`LineformTests/ReleaseResourceTests.swift:242–250` is the existing gate.
Re-verifying `Metadata.appintents` after the catalogs land is a release gate for
this work, not an optional check.

## MainMenuIconDecorator

`MainMenuIconDecorator` attaches an SF Symbol to every main-menu row, resolving
two ways:

- **38 entries keyed by AppKit selector** (`symbolsByAction`, `:176`).
  Locale-proof.
- **108 entries keyed by normalized English title** (`symbolsByTitle`, `:225`).
  Counted programmatically; an earlier draft said 99, from a grep whose pattern
  dropped keys containing `&` and digits.

The 108 fail silently under localization: a German "Nach Updates suchen" does not
match `"check for updates"`, the lookup returns nil, and the row draws with no
icon. Roughly 108 main-menu rows lose their symbols in every non-English locale —
a visible regression of a shipped feature, caused by a change that never touches
this file, invisible to a developer running in English.

Four things the fix must handle:

1. **`normalizedTitle` is in the path.** Matching happens against
   `normalizedTitle(item.title)` (`:138`), which lowercases, strips trailing
   `…`/`.`, and strips the literal substring `"Lineform"` (`:144`). Any localized
   value must pass through `normalizedTitle` too, or nothing matches.
2. **Say which string is the key.** The existing keys are *post*-normalization
   (`"save as"`), while the catalog key will be the *pre*-normalization title
   (`"Save As…"`). The refactor must keep `AppMenuConfiguration`'s literals as
   the catalog keys, and the decorator resolves each through `String(localized:)`
   then `normalizedTitle`, cached per locale alongside the existing image cache.
3. **Not every system title is in AppKit's tables.** Present across the 88
   `.loctable`s: `Writing Tools`, `Proofread`, `Rewrite`, `Make Friendly`
   (`WritingTools.loctable`); `Move & Resize`, `Bring All to Front`
   (`MenuCommands.loctable`); `Services` (`Services.loctable`). **Absent:
   `Passwords`, `Credit Card`, `Hide Others`.** Those need another source or an
   accepted icon loss; the spec must not claim the extraction covers them.
4. **The language key is `zh_CN`, not `zh-Hans`.** `.loctable` keys are
   `['zh_CN','zh_HK','zh_TW']`; values are `\U`-escaped (`"Preferences\U2026"`).
   An extraction script written against `zh-Hans` returns nothing for Chinese.

A test must assert every `symbolsByTitle` entry resolves a symbol in each of the
five locales. `LineformTests/MainMenuIconDecoratorTests.swift:32–58`
(`testConfiguredCommandTitlesAllHaveIcons`) already walks this path and is
reworked alongside.

## Document-Derived Text Stays in the Document's Language

`CalloutKind.displayName` (`Lineform/Preview/MarkdownBlockGrouping.swift:243–254`)
returns "Note", "Tip", "Important", "Warning", "Caution". It feeds both the
on-screen preview and `MarkdownHTMLRenderer.calloutHTML` — so HTML, PDF, RTF
export, and print.

CLAUDE.md: *"HTML export is ONE-TO-ONE with the source … Special cases
accumulating here mean a non-one-to-one default crept back in."*

**Decision: callout labels are not localized.** A `> [!NOTE]` marker is English
Markdown syntax, like `TODO`, and its rendered label is a rendering of document
content rather than app chrome. Localizing it would make the same file export
differently on two machines, which is the invariant's whole point. It would also
force a matching hand-edit in the Quick Look appex
(`LineformQuickLook/QuickLookMarkdownRenderer.swift`), which mirrors the renderers
by hand and cannot import them — a paired definition guaranteed to diverge.

The general rule, which belongs in CLAUDE.md if this ships: **text that renders
document content stays in the document's language; text that is app chrome is
localized.**

## Formatting

**Dates and times are currently hard-pinned to English.**
`Lineform/Editor/EditorStatusPresentation.swift:83–95` sets
`formatter.locale = Locale(identifier: "en_US_POSIX")` with
`dateFormat = "MMM d, yyyy 'at' h:mm a"`. A German or Japanese user's
permanently-visible save-status bar reads `Aug 5, 2026 at 3:04 PM` — English
month, English "at", 12-hour clock in locales that use 24-hour.

Fix with `Date.FormatStyle` / `dateStyle` + `timeStyle`, **not** a localized
format pattern. Roughly twenty assertions across `LineformTests` pin these exact
strings and need a pinned test locale.

**Numbers.** `Lineform/ReadingExperience/ReadingExperiencePopover.swift:280`
builds a `NumberFormatter` with no explicit locale. It will switch to comma
decimal separators in `de`/`fr`/`es` — correct behavior, currently untested.

## Word Count and CJK

`Lineform/Editor/DocumentStatistics.swift:17–33` counts a word as a maximal run
of `CharacterSet.alphanumerics`. Han, Hiragana, and Katakana are all
alphanumeric, and CJK prose has no interword spaces, so runs break only at
punctuation. Measured against the shipped algorithm:

| Sample | Characters | Reported "words" |
|---|---|---|
| Japanese | 33 | 3 |
| Chinese | 23 | 2 |
| English | 44 | 9 |

It is counting sentences. The value is displayed unconditionally
(`EditorStatusPresentation.swift:31`). Shipping to `ja` and `zh-Hans` puts a
visibly wrong number in front of exactly the users who would notice.

**Decision: for CJK text, report characters and suppress the word count**, rather
than adopting a segmentation dependency. `CFStringTokenizer` could segment
properly, but that is a larger change than this work needs and the character
count is the metric CJK writers actually use.

## First-Launch Intro — a Separate Surface

The intro is **not SwiftUI**. `Lineform/App/FirstLaunchIntroOverlay.swift:487–496`
loads `Bundle.main.url(forResource: "index", withExtension: "html", subdirectory:
"FirstLaunchIntro")` into a `WKWebView`. Copy lives in
`Lineform/Resources/FirstLaunchIntro/{index.html, intro.js, styles.css}` —
strings like "Simple markdown editing", "Get Started", "Replay", and a stale
`<title>Lineform Intro Prototype</title>`.

The String Catalog cannot reach any of it. This needs its own mechanism —
per-locale `.lproj` HTML, or a string table injected from Swift into the page —
plus its own layout check, because it is hand-laid-out CSS where German's 30–35%
expansion is not absorbed by autolayout.

It is also the window CLAUDE.md flags as blocking the app and required to be
keyboard- and VoiceOver-operable, so its localized strings include the AX names
that invariant depends on.

## Fonts

`FontOption.groupedOptions` offers six fonts in three groups. SF Pro, New York,
and Monospaced are system faces that already cascade to CJK correctly. The three
in "Reading & Accessibility" are Latin-only: Atkinson Hyperlegible, OpenDyslexic,
Comic Sans MS.

They are not broken today — CoreText substitutes per glyph, so a Japanese reader
sees Hiragino Sans mixed into Atkinson, not missing glyphs. The problem is that
the pairing is unchosen: metrics do not match, and a document mixing Chinese and
Japanese can render Chinese in a Japanese face.

**Cascade.** Declare an explicit fallback in `FontOption.availableFont(size:)`
via `NSFontDescriptor`'s cascade list: Hiragino Sans for Japanese, PingFang SC for
Simplified Chinese. Both ship with macOS, confirmed present via
`system_profiler SPFontsDataType`. Zero bytes, deterministic pairing.

Two behaviors verified by experiment rather than assumed, both of which hold:
`NSFont(descriptor:size:)` still returns `nil` for a bogus family, so adding a
cascade list does not break `FontOption.isAvailable`'s nil-signal; and
`NSFontManager.convert(_:toHaveTrait:)` preserves an attached `.cascadeList`, so
bold and italic do not lose the CJK fallback.

**BIZ UDGothic, for Japanese, as a cascade target only.** The cascade alone
leaves the accessibility group honest only for Latin: a low-vision Japanese
reader selecting Atkinson gets a legibility-optimized face for the Roman
characters and an ordinary one for the characters they are reading. BIZ UDGothic
is a Universal Design face built for legibility — the direct counterpart to
Atkinson Hyperlegible.

It is **not added to `FontOption.groupedOptions`.** It is the Japanese cascade
target for Atkinson Hyperlegible and OpenDyslexic only. This is deliberate: a new
picker entry would appear as a sixth, unreadable option to every English user —
the mirror of the case against hiding Latin-only fonts in CJK locales. Comic Sans
and all non-accessibility faces cascade to Hiragino Sans as normal.

- **Family:** `BIZUDGothic`, not `BIZUDPGothic`. Upstream ships both; the `P`
  variant is proportional, the unprefixed one is fixed full-width pitch, the
  conventional setting for long-form Japanese body text. Confirm visually; the
  swap is a filename change.
- **Weights:** Regular and Bold. CJK does not use italic; italic cascades to
  regular.
- **License — verified 2026-08-05** against
  `github.com/googlefonts/morisawa-biz-ud-gothic`: SIL Open Font License 1.1,
  `OFL.txt` at repo root. Copyright line, reproduced verbatim including its
  upstream error (the URL names the *mincho* repo):
  `Copyright 2022 The BIZ UDGothic Project Authors (https://github.com/googlefonts/morisawa-biz-ud-mincho)`.
  **No Reserved Font Name** — unlike OpenDyslexic; attribution must not invent
  one. "BIZ UDGothic" is a Morisawa Inc. trademark, credited not licensed.
- **Size — measured:** Regular 4,667,380 B + Bold 4,638,128 B = **8.9 MB**,
  against a current bundled font set of roughly 1 MB. This is the single largest
  cost in this design. It is accepted deliberately, and the counter-argument is
  recorded: the reasoning that settles Chinese ("accessibility comes from size,
  line-height, and contrast") would also settle Japanese, and Hiragino Sans is a
  strong face. It is kept because a free UD-class face *exists* for Japanese and
  not for Chinese, so declining it is a choice to ship a worse experience where a
  better one was available for bundle size alone.

**Registration.** `BundledFontRegistrar.swift:5–14` is a hard-coded
`fontFileNames` array registering from `subdirectory: "Fonts"` with
`CTFontManagerRegisterFontsForURL(url, .process, nil)`. Adding the font needs (a)
the files in `Lineform/Resources/Fonts/`, (b) the names appended to
`fontFileNames`, and (c) **no pbxproj edit** — `Fonts` is a folder reference
(`project.pbxproj:161, 844`), so on-disk files are picked up automatically. That
last point is non-obvious given the repo's usual "hand-edit four pbxproj
sections" convention.

`OFL-BIZUDGothic.txt` ships alongside the binaries; `FontLicenseReview.md` and
the README credits are updated in the same change, per repo policy.

**Chinese has no free UD-class equivalent.** PingFang SC is the best available and
is already strong. Accessibility for Chinese comes from the size, line-height,
and contrast controls. Known limitation, revisited if a suitable face appears.

**OpenDyslexic has no CJK counterpart and will not get one.** It weights letter
bottoms so visually similar Latin letters do not rotate. Han characters do not
fail that way.

**Font names are not translated** — proper nouns. Group headings are.

**Substitution is not surfaced in the UI.** A reader whose document is entirely
Japanese sees the fallback face while the picker reads "Atkinson Hyperlegible".
Standard Mac behavior; the alternatives are worse.

## Translation Quality

No native reviewers are available, so quality rests on mechanisms that can be
executed and tested rather than on a review step.

**1. Platform terminology comes from Apple, not from invention.** macOS ships
Apple's own localized strings as `.loctable` files, readable via
`plutil -convert json`. `AppKit.framework` carries 88, including `MenuCommands`,
`Menus`, `Document`, `SavePanel`, `Printing`, `FindPanel`, `Spelling`,
`TextSystem`, `Toolbar`. Verified:

| Key | en | de | fr | es | ja | zh_CN |
|---|---|---|---|---|---|---|
| `Replace All` | Replace All | Alles ersetzen | Tout remplacer | Reemplazar todo | すべて置き換え | 全部替换 |

Any string naming a standard platform concept — Save As, Export, Print, Find,
Replace, Undo, Duplicate, Revert, Show/Hide Sidebar, Spelling and Grammar — takes
Apple's exact wording. Extract the relevant tables into a glossary under
`docs/notes/` once, then translate against it. Note the `zh_CN` key and `\U`
escaping described above.

**2. Plural rules come from the catalog.** The same extraction shows Japanese and
Chinese have no singular category and Spanish uses a non-breaking space before
numerals. Every counted string — match counts, file counts, word/character counts
— is authored as a String Catalog plural variation, never assembled from a number
and a noun.

**3. A fixed term glossary, enforced by test.** Lineform's own vocabulary — Write
mode, Read mode, Split, Workspace, Tab, Outline, Callout, Front matter, Reading
profile — is translated once per language into a committed glossary and used
everywhere. The most common way a correct translation reads as sloppy is one
English term rendering three ways across three panels. A test asserts no source
term maps to more than one translation within a language.

**4. Format-specifier parity, enforced by test.** Every localized string carries
the same specifiers, in the same order and count, as its source. A dropped `%@`
is a crash, not a typo.

**5. Back-translation for semantic drift.** Each translated string is
independently rendered back to English and compared to the source, surfacing
plausible-sounding translations that have drifted from what the control does.

Mechanisms 1 and 3 carry most of the weight: the vocabulary users meet most often
is Apple's own professionally translated wording, verbatim. Residual exposure is
idiom and tone, concentrated in the longest strings — the intro overlay and the
`MarkdownReference` explanations. Both are kept short and plain in English, which
is what makes them translate cleanly.

## Layout

German runs 30–35% longer than English; French and Spanish 15–25%. The toolbar,
settings panes, and tab bar are already tight, so clipped or displaced controls
are the likeliest visible defect. Every panel is checked at its longest string.
Xcode's pseudolocalization finds most of it before translations land, so the
layout pass can start early. The first-launch intro needs its own pass, being
hand-laid-out CSS.

Chinese runs about half the length of English — nothing clips, controls may look
sparse. Cosmetic, accepted.

## CJK Typography and Input

TextKit already performs Japanese line breaking correctly, including kinsoku
shori. Inherited, no work.

The reading profiles' line-height and column-width presets are Latin-tuned. CJK
glyphs are full-width and taller at the same point size, so presets read tighter
in Japanese and Chinese. A tuning pass against the running app after strings
land — a known follow-up, not a silent omission.

**IME.** The existing invariant that keyboard intercepts hook
`insertNewline`/`insertTab`/`doCommandBy` and never `keyDown` is what makes list
continuation and table Tab structurally safe during IME composition. No code
change needed, but this work is the first time it will be exercised in earnest,
so **IME regression testing is added to the manual QA pass**: list continuation,
table Tab/Shift-Tab, and Find during active composition in Japanese and Chinese.

## Testing

- **Pin the test locale.** All existing suites run under an explicit `en` locale.
  Roughly twenty assertions across seven test files pin English UI copy
  (`grep -rn "Not saved yet\|Last save\|No matches\|words —" LineformTests`), and
  the sidebar sort order uses `localizedStandardCompare`
  (`OutlineFileSortOrder.swift:39`), so ordering legitimately changes per locale
  and its tests need a pinned locale too. "Existing suites must stay green" is
  not a plan; the affected tests are enumerated and converted.
- **`MainMenuIconDecorator`**: every `symbolsByTitle` entry resolves a symbol in
  all five locales.
- **Catalog completeness**: no user-facing key untranslated in any language.
- **Glossary consistency**: no glossary source term maps to more than one
  translation within a language.
- **Placeholder parity**: identical format specifiers, order, and count.
- **`MarkdownReference`**: `MarkdownReferenceTests` currently asserts a 90-character
  ceiling (`:38–47`), English section titles (`:5–11`), and an English phrase
  (`:30–35`). Because `MarkdownReference.sections` is static Swift data, a
  per-language ceiling requires re-resolving each key with an explicit `locale:`
  — the test cannot simply be re-run. All four tests are reworked.
- **Fonts**: the declared cascade resolves a real face for Japanese and Chinese
  sample text, and BIZ UDGothic registers via `BundledFontRegistrar`.
- **`Metadata.appintents`** still emitted after the catalogs land
  (`ReleaseResourceTests.swift:242–250`).
- Both test plans' quarantine lists stay in lockstep (`TestPlanGuardTests`).

## Known Traps

- **`String`-raw-value enums where the raw value is the display text.**
  `OutlineSidebarTab: String` (`OutlineSidebarView.swift:4–7`) has
  `case markdownBasics = "Markdown Basics"`, rendered directly at `:911`.
  Localizing the raw value silently changes an identity value. Contrast
  `OutlineFileSortOrder` and `EditorDisplayMode`, which correctly separate
  `rawValue` from `title`. Add a `title` property; never localize a `rawValue`.
- **Read-aloud voice.** `SpeechController.swift:111` builds
  `AVSpeechUtterance(string:)` with no `voice`, so the system default follows the
  **UI language**. A Japanese-UI user reading an English document would get a
  Japanese voice. Select the voice from the document's detected language, not the
  UI locale.
- **Quick Look extension identity.** `INFOPLIST_KEY_CFBundleDisplayName =
  "Lineform Quick Look"` (`project.pbxproj:1287, 1312`) is a separate target with
  its own Info.plist — not covered by the app's `InfoPlist.xcstrings`.

## Release Positioning

The localization is not marketed. Reviews come from unmet expectations, and
announcing "full Japanese support" invites scrutiny of vertical text and furigana
this work does not deliver. Users discover their language is present.

Nobody leaves a bad review because a small free Mac app is English-only — that is
an invisible state. The downside of shipping is entirely execution risk, which is
what the quality mechanisms above exist to contain.

## Out of Scope, Explicitly

- Vertical Japanese text (tategaki).
- Furigana / ruby annotation.
- Localized Markdown syntax, localized callout labels, or localized document
  templates.
- Per-document UI language override.
- CJK word segmentation (`CFStringTokenizer`) for word counts.
- Localizing the Quick Look extension's rendered output — it renders user
  content, already in the user's language.
- Localizing in-app announcements, Sparkle's UI, or appcast release notes.
