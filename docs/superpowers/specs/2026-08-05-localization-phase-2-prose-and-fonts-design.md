# Localization Phase 2 — Prose and CJK Fonts

Date: 2026-08-05
Status: Deferred. **Decided after Phase 1 ships and has been seen running in
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

## Contents

### 1. `MarkdownReference` prose

The sidebar's "Markdown Basics" tab: ~30 rows of syntax + explanation from
`Lineform/Outline/MarkdownReference.swift`, pure static data.

- The **syntax column is never translated** — `# Title`, `**bold**` are
  Markdown, the same rule as callout labels: document-language text stays in the
  document's language. Only `explanation` (and section `title`s) localize.
- Keyboard-shortcut references in explanations (`⌘1 sets it`) survive
  translation verbatim — glyphs, not words.
- `MarkdownReferenceTests` asserts a 90-character ceiling (`:38–47`), English
  section titles (`:5–11`), and an English phrase (`:30–35`). Because
  `sections` is static Swift data, a per-language ceiling requires re-resolving
  each key with an explicit `locale:` — the tests cannot simply re-run. All four
  are reworked. The ceiling stays per-language: the sidebar column is narrow in
  every language.
- The `Row.accessibilityLabel` composition ("… Syntax: …") localizes its
  connective text.

### 2. CJK font cascade

Declare an explicit fallback in `FontOption.availableFont(size:)` via
`NSFontDescriptor`'s cascade list: Hiragino Sans for Japanese, PingFang SC for
Simplified Chinese (both ship with macOS, confirmed present). Today CoreText
substitutes per glyph — nothing is broken, but the pairing is unchosen and a
mixed Chinese/Japanese document can render Chinese in a Japanese face.

Verified by experiment, so the implementation does not re-litigate them:
`NSFont(descriptor:size:)` still returns `nil` for a bogus family (the
`isAvailable` nil-signal survives a cascade list), and
`NSFontManager.convert(_:toHaveTrait:)` preserves an attached `.cascadeList`
(bold/italic keep the fallback).

### 3. BIZ UDGothic — Japanese accessibility fallback

**As a cascade target only, never a picker entry** — a picker entry would face
every English user with a sixth, unreadable option. It becomes the Japanese
cascade target for Atkinson Hyperlegible and OpenDyslexic specifically, so the
accessibility group is honest for Japanese rather than decorative. Comic Sans
and non-accessibility faces cascade to Hiragino Sans as normal.

- **Family:** `BIZUDGothic` (fixed full-width pitch — conventional for
  long-form Japanese body text), not proportional `BIZUDPGothic`. Confirm
  visually; the swap is a filename change.
- **Weights:** Regular and Bold. CJK has no italic; italic cascades to regular.
- **License — verified 2026-08-05** against
  `github.com/googlefonts/morisawa-biz-ud-gothic`: SIL OFL 1.1, `OFL.txt` at
  repo root. Copyright line reproduced verbatim including its upstream error
  (the URL names the *mincho* repo):
  `Copyright 2022 The BIZ UDGothic Project Authors (https://github.com/googlefonts/morisawa-biz-ud-mincho)`.
  **No Reserved Font Name** — attribution must not invent one. "BIZ UDGothic"
  is a Morisawa Inc. trademark, credited not licensed.
- **Size — measured:** 4,667,380 B + 4,638,128 B = **8.9 MB**, against ~1 MB of
  currently bundled fonts. The largest single cost in either phase, and the
  counter-argument is recorded: the reasoning that settles Chinese
  ("accessibility comes from size, line-height, contrast controls") would also
  settle Japanese. It is accepted because a free UD-class face *exists* for
  Japanese and not for Chinese — declining it is choosing a worse experience
  where a better one was available for bundle size alone. **This is the item
  most likely to be cut when this phase is decided; the cascade (item 2) stands
  on its own without it.**
- **Registration:** files into `Lineform/Resources/Fonts/` (a folder reference —
  `project.pbxproj:161, 844` — so **no pbxproj edit**, unlike the repo's usual
  four-section hand-edit), names appended to `BundledFontRegistrar.fontFileNames`
  (`:5–14`). `OFL-BIZUDGothic.txt` ships alongside; `FontLicenseReview.md` and
  README credits update in the same change, per repo policy.

**Chinese has no free UD-class equivalent** — PingFang SC is the best available;
accessibility comes from the size/line-height/contrast controls. Known
limitation. **OpenDyslexic has no CJK counterpart and will not get one** — it
works by weighting letter bottoms so similar Latin letters do not flip; Han
characters do not fail that way. **Font names are never translated**; the
picker's group headings localize in Phase 1, which owns that rule.
**Substitution is not surfaced in the UI** — the picker reads
"Atkinson Hyperlegible" while an all-Japanese document renders in the fallback;
standard Mac behavior, and the alternatives (hiding fonts per locale, annotating
pairings) are worse.

### 4. Read-aloud voice

`SpeechController.swift:112` builds `AVSpeechUtterance(string:)` with no
`voice`, so the system default follows the **UI language** — a Japanese-UI user
reading an English document gets a Japanese voice. Select the voice from the
document's detected language (`NSLinguisticTagger`/`NLLanguageRecognizer` on the
spoken text), not the UI locale.

### 5. CJK reading-preset tuning

The reading profiles' line-height and column-width presets are Latin-tuned; CJK
glyphs are full-width and taller at the same point size, so presets read tighter
in Japanese and Chinese. A tuning pass against the running app — depends on
Phase 1's strings being in place to evaluate properly.

Line *breaking* needs no work in either phase: TextKit already performs Japanese
line breaking correctly, including kinsoku shori. Checked during the original
design review; inherited from the platform.

## Testing

- `MarkdownReferenceTests` reworked as above, per-language, explicit `locale:`.
- Cascade: the declared fallback resolves a real face for Japanese and Chinese
  sample text; BIZ UDGothic (if kept) registers via `BundledFontRegistrar`.
- Voice selection: language detection picks the document language over the UI
  locale for mixed samples.

## Out of Scope, Explicitly (both phases)

- Vertical Japanese text (tategaki); furigana/ruby.
- Localized Markdown syntax, callout labels, or document templates.
- Per-document UI language override.
- CJK word segmentation (`CFStringTokenizer`) for word counts.
- Quick Look rendered output; announcements; appcast release notes (Sparkle's
  own dialogs localize themselves — no work, and not English).
