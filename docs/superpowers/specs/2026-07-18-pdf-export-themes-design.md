# PDF export themes (curated typographic presets)

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** F

## Problem

Ink MD (JSON themes), MWeb (32 themes), and Byword (a long-requested custom stylesheet) let
users style their exported/preview output. Lineform's PDF/Print export is currently a single
fixed look: 12pt system body, forced light `.system` theme, dark ink. A small **curated** set
of export styles lets users tune the exported artifact (submitting a manuscript vs. a compact
handout) without any configuration surface.

## Scope constraint (load-bearing)

**PDF export + Print ONLY. This does NOT change how Markdown renders on screen** (Read / Preview
are untouched — user's explicit constraint). F is purely a typographic preset applied to the
paginated export renderer.

## Decisions

- **Curated presets, not a plugin/CSS/JSON system.** Ship a fixed set (like the reader themes);
  a user-editable system is a deliberate non-goal for now (scope-creep risk called out in the
  scan).
- **Typography/layout only. The page stays light with dark ink.** No colored or dark-page PDFs
  (ink-wasteful, less "document," and adds contrast burden for little gain). Each preset varies
  **body font face, body point size, line-height, heading scale, and margins** — nothing else.
- **~4 presets (v1):**
  - **Standard** — reproduces today's export exactly (12pt system body, current leading/margins).
    The **default**, so existing output is unchanged unless a user picks another.
  - **Manuscript** — serif body, generous line-height and margins (editor/submission feel).
  - **Compact** — smaller body, tighter leading, narrower margins (fewer pages).
  - **Article** — serif body with a slightly larger heading scale (clean long-form).
- **System / bundled fonts only** — San Francisco, the system serif (New York, via `.serif`
  design), and the already-bundled Atkinson Hyperlegible / OpenDyslexic. **No new font
  bundling** (keeps the fixed credits/licensing set).
- **Selection surface:** a **"Style" popup added to the existing PDF-export save-panel
  accessory** (which already carries the paper-size popup). The choice is **persisted**
  (`UserDefaults`), and **Print** uses the persisted style — no separate Print UI.

## Architecture

### 1. `ExportTypographyPreset` — `Lineform/Preview/ExportTypographyPreset.swift` (pure, tested)

```swift
struct ExportTypographyPreset: Identifiable {
    let id: String                    // stable key, e.g. "standard"
    let displayName: String
    let bodyFace: ExportFontFace?     // nil = INHERIT the user's face (Standard); else .system/.serif/…
    let bodyPointSize: CGFloat
    let lineHeightMultiple: CGFloat?  // nil = INHERIT the user's line-height (Standard)
    let headingScale: CGFloat         // multiplier applied to heading sizes over body
    let pageMargins: NSEdgeInsets

    static let all: [ExportTypographyPreset]   // Standard, Manuscript, Compact, Article
    static let standard: ExportTypographyPreset // == today's export (inherits face + line-height)

    /// Produce the export ReadingProfile for this preset, based on the user's current profile:
    /// pins the light `.system` theme + dark ink + export point size exactly as today, and
    /// overrides face/line-height ONLY when the preset specifies them (nil → inherit).
    func exportReadingProfile(basedOn userProfile: ReadingProfile) -> ReadingProfile
}
```

**Correction (found during planning):** today's export does NOT force a font face or line-height —
it pins only the theme, contrast, and (12pt) size, and otherwise **inherits the user's font face
and line-height/rhythm**. So for `standard` to be a *provable* no-op for any user, its `bodyFace`
and `lineHeightMultiple` are **nil (inherit)**, and the profile builder takes `basedOn:
userProfile`. `headingScale` and `pageMargins` are NOT `ReadingProfile` fields, so they are
threaded separately (a defaulted `headingScale` render parameter and export margins) rather than
through the profile. Standard uses `headingScale = 1.0` and today's export margins → byte-identical
output.

### 2. `DocumentExportRenderer` — take a preset

`DocumentExportRenderer` currently pins a fixed export `ReadingProfile` (12pt, `.system`). Thread
an `ExportTypographyPreset` (default `.standard`) into both the PDF/print render and the RTF path
(from the RTF spec), building the export profile from `preset.exportReadingProfile(basedOn:
currentUserProfile)` instead of the hard-coded values, and passing `preset.headingScale` /
`preset.pageMargins` separately (render parameter + export margins). Paper size, `fitTablesToWidth`,
and `imagesAsText` are unchanged and orthogonal.

### 3. Save-panel accessory + persistence

Extend the existing PDF-export `NSSavePanel` accessory (paper-size popup) with a **Style** popup
listing `ExportTypographyPreset.all`. The selected preset id is persisted via a
`LineformSettingsStore`-style key (or `UserDefaults` directly, mirroring existing prefs) and
seeds the popup on next export. `EditorContainerView`'s `exportPDF` handler passes the chosen
preset into the renderer; the Print (`⌘P`) handler reads the persisted preset (no Print-panel UI
change in v1).

## Testing

- **Unit (default plan):**
  - `ExportTypographyPreset.standard.exportReadingProfile()` equals the current fixed export
    profile (the "nothing changes by default" guarantee).
  - Each preset yields its declared face/size/leading/heading-scale/margins.
  - Preset id round-trips through the persistence key; an unknown/absent id falls back to
    `.standard`.
- **Manual:** export the same document under each preset; confirm page stays light + dark ink;
  confirm Standard is visually identical to the pre-change export; confirm the persisted style
  is reused by Print.

## Out of scope

- User-editable / importable themes (CSS or JSON) — the curated set first; a plugin system is a
  separate, later decision.
- Colored or dark-page PDFs, accent-colored headings (page stays light/dark-ink).
- Applying export styles to on-screen Read/Preview (explicitly excluded).
- Bundling new fonts.

## Risk

Low–medium. The risk is scope creep toward a theme-editor — bounded here by shipping a fixed
curated set and a single popup. Mechanically it is a parameterization of the existing export
profile; "Standard" is a proven no-op, so the default export is untouched.
