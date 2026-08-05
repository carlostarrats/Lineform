# Localization Design

Date: 2026-08-05
Status: Approved for planning

## Goal

Make Lineform usable by people who do not read English, by localizing the app's
interface into five additional languages. Nothing about document handling,
storage, or Markdown semantics changes.

## Languages

Spanish (`es`), French (`fr`), German (`de`), Japanese (`ja`), Simplified
Chinese (`zh-Hans`).

Korean was considered and cut: not for complexity — Hangul behaves like Latin
for layout — but because it is the smallest return of the candidates for a Mac
writing tool, and every added language costs a native reviewer.

Deliberately excluded, and not to be revisited as part of this work:

- **RTL (Arabic, Hebrew).** A Markdown *source* editor with bidirectional text is
  a separate project: caret movement, selection, list markers, and table pipes
  all change. It is not a strings problem.
- **Traditional Chinese (`zh-Hant`).** Not a script conversion of `zh-Hans`.
  Different terminology, its own review cycle. Add it as its own decision or not
  at all.

## Scope

In scope — the app interface:

- Menus (`AppCommands`), toolbar, settings, alerts, confirmation dialogs.
- Files sidebar, tab bar, outline sidebar, status bar, reading-experience popover.
- Accessibility labels, hints, and custom action names.
- The first-launch intro overlay.
- `MarkdownReference` — the sidebar Info tab's Markdown syntax reference. This is
  in-app content shown to users, not a repo document.
- `Info.plist`: `CFBundleDisplayName`, both `CFBundleTypeName` entries.
- App Intents phrases in `LineformAppIntents.swift` (Shortcuts/Spotlight/Siri).

Out of scope:

- `Lineform/Resources/*.md`. No app code loads these; they are repo reference
  documents.
- Document content. Spell checking already routes through `NSSpellChecker`,
  which follows the system language on its own. No change needed.
- README, website, App Store metadata, GitHub.
- A runtime language picker. macOS resolves by system language; that is the
  native behavior and adding a picker would be non-standard.

## Volume

1,618 raw string literals across the Swift sources, but most are not user-facing
— `CodeHighlighting` (210) is syntax keywords and `MainMenuIconDecorator` (306)
is SF Symbol names and match keys. A proxy count of unique capitalized literals
containing a space gives 201. Including single-word controls ("Save", "Cancel",
"Copy") the real translatable set is estimated at **350–450 strings**. This is an
estimate from static counting, not an exact extraction; the String Catalog will
produce the true number on first build.

## Mechanism

A String Catalog, `Localizable.xcstrings`, in the app target. Xcode extracts
string literals from SwiftUI and the menu commands at build time, so there is no
manual key registry to drift. A second catalog, `InfoPlist.xcstrings`, covers the
`Info.plist` strings. `knownRegions` gains the five locales.

No third-party localization tooling and no new dependency.

Strings that are not user-facing must be excluded from extraction so the catalog
stays reviewable. In practice that means auditing the catalog after first build
and marking non-UI entries "Don't Translate" rather than pre-emptively annotating
call sites.

## Translation Quality

The stated requirement is that the translations be good. Machine-plausible
translations are the most likely source of bad reviews for an app of this kind —
a native speaker opening Settings and seeing a phrase no German would write
concludes the app is careless, and that impression is not recoverable by a font
choice or a feature.

Three mechanisms, in order of leverage:

**1. Platform terminology comes from Apple, not from invention.**

macOS ships Apple's own localized strings on disk as `.loctable` files, readable
with `plutil -convert json`. `AppKit.framework` alone carries 88 of them,
including `MenuCommands`, `Menus`, `Document`, `SavePanel`, `Printing`,
`FindPanel`, `Spelling`, `TextSystem`, and `Toolbar`. Every one contains all five
target languages.

Verified working:

| Key | en | de | fr | es | ja | zh-Hans |
|---|---|---|---|---|---|---|
| `Replace All` | Replace All | Alles ersetzen | Tout remplacer | Reemplazar todo | すべて置き換え | 全部替换 |

Any Lineform string that names a standard platform concept — Save As, Export,
Print, Find, Replace, Undo, Duplicate, Revert, Show/Hide Sidebar, Spelling and
Grammar — takes Apple's exact wording. This is what makes an app read as native
rather than merely translated, and it removes the largest category of judgment
calls from the translation work.

Build a glossary once by extracting the relevant tables into a reference file
under `docs/notes/`, then translate against it.

**2. Plural rules come from the catalog, not from string concatenation.**

The same extraction shows Japanese and Chinese have no singular plural category
and Spanish uses a non-breaking space before numerals. Any string with a count
("%d matches", "%d files") is authored as a String Catalog plural variation with
per-language categories, never assembled from a number and a noun.

**3. Native review before release.**

Each language is read end-to-end in the running app by a native speaker before
shipping. This is a release gate, not a nice-to-have; it is the only mechanism
here that catches wording that is correct but unidiomatic. Five languages is five
reviewers, and that cost is the reason Korean was cut.

## MainMenuIconDecorator

`MainMenuIconDecorator` attaches an SF Symbol to every main-menu row. It resolves
symbols two ways:

- **38 entries keyed by AppKit selector** (`saveDocument:`, `undo:`). Locale-proof.
- **99 entries keyed by lowercased English title** (`"check for updates"`,
  `"writing tools"`, `"privacy policy"`), via `normalizedTitle(_:)`.

The second set fails silently under localization. A German menu item titled
"Nach Updates suchen" does not match `"check for updates"`, so the lookup returns
nil and the row draws with no icon. The result is roughly 99 main-menu rows
losing their symbols in every non-English locale — a visible regression of a
shipped feature, produced by a change that never touches the decorator.

The title-keyed entries split into two populations needing different fixes:

- **Lineform's own commands** ("check for updates", "privacy policy", "install
  command line tool"). The English title is also the String Catalog key, so the
  decorator resolves each key through `String(localized:)` and matches against
  that. Built once per locale and cached, alongside the existing image cache.
- **System-provided items** ("services", "hide others", "writing tools",
  "proofread", "rewrite"). macOS supplies these already localized, so our catalog
  has no key for them. Their localized titles come from the same AppKit
  `.loctable` extraction used for the glossary, compiled into a lookup keyed by
  the English title.

This must be covered by a test that asserts every title-keyed entry resolves in
each of the five locales. Without it the failure is invisible in English, which
is the only locale a developer normally runs.

## Fonts

`FontOption.groupedOptions` offers six fonts in three groups. SF Pro, New York,
and Monospaced are system faces that already cascade to CJK correctly — no work.
The three in "Reading & Accessibility" are Latin-only: Atkinson Hyperlegible,
OpenDyslexic, and Comic Sans MS.

These are not broken today. CoreText substitutes per glyph, so a Japanese reader
sees Hiragino Sans mixed into Atkinson rather than missing glyphs. The problem is
that the pairing is unchosen: metrics do not match, and a document mixing Chinese
and Japanese can render Chinese in a Japanese face.

**Cascade.** Declare an explicit fallback in `FontOption.availableFont(size:)`
using `NSFontDescriptor`'s cascade list: Hiragino Sans for Japanese, PingFang SC
for Simplified Chinese. Both ship with macOS — confirmed present via
`system_profiler SPFontsDataType`. Zero bytes added, and the pairing becomes
deterministic.

**Bundle BIZ UDGothic for Japanese.** The cascade alone leaves the accessibility
group honest only for Latin text: a low-vision Japanese reader selecting Atkinson
gets a legibility-optimized face for the Roman characters and an ordinary system
face for the characters they are actually reading. Morisawa's BIZ UDGothic is
licensed under the SIL OFL, free, and purpose-built for legibility ("UD" =
Universal Design; used in Japanese schools and public signage). It is the direct
counterpart to Atkinson Hyperlegible and is the accessibility fallback for
Japanese.

Regular and Bold only — CJK does not use italic, so italic cascades to regular.
Roughly 8 MB against a current font set of about 1 MB. The license file ships in
`Lineform/Resources/Fonts` and `FontLicenseReview.md` and the README credits are
updated in the same change, per existing repo policy. **The OFL license file must
be verified as shipped with the actual font binaries before bundling.**

**Chinese has no free UD-class equivalent.** PingFang SC is the best available
and is already a strong face. For Chinese, accessibility comes from the size,
line-height, and contrast controls rather than the typeface. This is a known and
accepted limitation, revisited if a suitable face appears.

**OpenDyslexic has no CJK counterpart and will not get one.** It works by
weighting letter bottoms so visually similar Latin letters do not rotate or flip.
Han characters do not fail that way. It cascades to the same system faces as
everything else.

**Font names are not translated.** "Atkinson Hyperlegible", "SF Pro", "New York"
are proper nouns; Apple does not translate font names in any locale. The group
headings — "System", "Writing", "Reading & Accessibility" — are translated.

**Substitution is not surfaced in the UI.** A reader whose document is entirely
Japanese sees Hiragino Sans while the picker reads "Atkinson Hyperlegible". This
is standard Mac behavior — Pages and TextEdit do the same — and the alternatives
are worse: hiding Latin-only fonts in CJK locales would take OpenDyslexic from a
dyslexic reader who writes in English, and annotating every option with its CJK
pairing adds permanent UI noise for everyone.

## Layout

German runs 30–35% longer than English; French and Spanish 15–25%. The toolbar,
settings panes, and tab bar are already tight, so clipped or displaced controls
are the most likely visible defect.

Every panel is checked at its longest string before release. Xcode's
pseudolocalization (accented and doubled-length pseudo-languages) finds most of
it without waiting on translations, so the layout pass can start before the
translations land.

Chinese runs about half the length of English. Nothing clips; controls may look
sparse. Cosmetic, accepted.

## CJK Typography

TextKit already performs Japanese line breaking correctly, including kinsoku
shori, so line-breaking behavior is inherited and needs no work.

The reading profiles' line-height and column-width presets are tuned for Latin
text. CJK glyphs are full-width and taller at the same point size, so the presets
will read tighter in Japanese and Chinese. This is a tuning pass against the
running app after the strings land, not a design decision to make in advance. It
is explicitly a known follow-up, not a silent omission.

## Testing

- The `MainMenuIconDecorator` locale test described above — every title-keyed
  entry resolves a symbol in all five locales.
- A catalog completeness test: no user-facing key is left untranslated in any of
  the five languages.
- `MarkdownReferenceTests.testExplanationsStayConcise` currently asserts a length
  ceiling on English copy. Translations expand, so the ceiling is made
  per-language rather than deleted — the sidebar column is narrow and the
  constraint is real in every language.
- Existing suites must stay green. Both test plans' quarantine lists stay in
  lockstep per `TestPlanGuardTests`.
- Font cascade: assert the declared fallback resolves a real face for Japanese
  and Chinese sample text, and that BIZ UDGothic registers via
  `BundledFontRegistrar`.

## Release Positioning

The localization is not marketed. Reviews come from unmet expectations, and
announcing "full Japanese support" invites scrutiny of vertical text and furigana
that this work does not deliver. Users discover their language is present.

Nobody leaves a bad review because a small free Mac app is English-only — that is
an invisible state. The downside of shipping is therefore entirely execution
risk, which is why native review is a gate rather than a suggestion.

## Out of Scope, Explicitly

- Vertical Japanese text (tategaki).
- Furigana / ruby annotation.
- Localized Markdown syntax or localized document templates.
- Per-document language override.
- Localizing the Quick Look extension's rendered output (it renders user content,
  which is already in the user's language).
