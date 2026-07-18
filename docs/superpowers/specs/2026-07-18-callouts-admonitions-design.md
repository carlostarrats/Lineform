# Callouts / admonitions (`> [!NOTE]`, `> [!WARNING]`, …)

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** B

## Problem

GitHub-style callouts (`> [!NOTE]`, `> [!TIP]`, …) are now a de-facto GFM extension (GitHub,
Obsidian, Clearly all render them). Lineform renders blockquotes but treats `> [!NOTE]` as
literal text — the marker just shows as `[!NOTE]` inside the quote. Callouts are pure text,
degrade gracefully in other editors, and fit the blockquote machinery already in the
block-grouping layer, so they are a natural, on-brand extension.

## Decisions

- **Types (v1):** the 5 GitHub-standard kinds — `NOTE`, `TIP`, `IMPORTANT`, `WARNING`,
  `CAUTION`. Case-insensitive match. An unknown type (`> [!FOO]`) → renders as an ordinary
  blockquote (graceful degradation, no error).
- **Syntax:** the first quote line is `> [!TYPE]`, optionally followed by a custom title on the
  same line (`> [!NOTE] Remember this` → title "Remember this", Obsidian-style). Every
  subsequent `>` line is the body.
- **Calm, monochrome styling.** A callout renders as the existing blockquote body (indent +
  gentle de-emphasis) with a **title row** prepended: a per-type SF Symbol + the type name (or
  custom title), medium weight, drawn in the **ink / secondary tone — NOT a per-type color**.
  No colored backgrounds, no accent bar. Restraint over the 15-color admonition look.
- **Read/Preview + export.** Write mode shows source (with existing markup highlighting).
  Callouts are pure text (title row + body), so they render in **PDF and RTF export** too — no
  color concern, consistent with the monochrome export page.
- **Info tab:** add a row to `MarkdownReference` teaching the syntax.
- **Out of scope:** foldable/collapsible callouts (needs Read-mode interaction state), a drawn
  left bar (stays consistent with the blockquote bar, currently a deferred visual refinement),
  and any type beyond the 5.

## Architecture

### 1. Callout detection — `MarkdownBlockGrouping.swift`

The grouping already emits `.blockquote(lines: [MarkdownQuoteLine], lastLineIndex:)`
(`MarkdownBlockGrouping.swift:30,338-346`) via `MarkdownBlockquote.quoteLine`. Add:

```swift
enum CalloutKind: String { case note, tip, important, warning, caution }

case callout(kind: CalloutKind, title: String?, body: [MarkdownQuoteLine], lastLineIndex: Int)
```

A pure classifier inspects the first quote line's text:

```swift
enum MarkdownCallout {
    /// If `firstQuoteText` is `[!TYPE]` (optionally `[!TYPE] Custom title`) with a known TYPE,
    /// returns (kind, optional title). Unknown/absent → nil (caller keeps it a blockquote).
    static func parse(firstQuoteText: String) -> (kind: CalloutKind, title: String?)?
}
```

When a blockquote's first `MarkdownQuoteLine` parses as a callout, the grouping emits
`.callout` with `body` = the remaining quote lines; otherwise it stays `.blockquote`. All other
routing is unchanged.

### 2. Rendering — `MarkdownPreviewRenderer`

Refactor first: extract the per-line indent/de-emphasis loop currently inside `appendBlockquote`
(`MarkdownPreviewRenderer.swift:338-370`) into a shared helper `appendQuoteLines(...)`.
`appendBlockquote` calls it directly (byte-identical output).

New `appendCallout(kind:title:body:...)`:

1. Emit a **title row**: the type's SF Symbol (as a small baseline-aligned image attachment,
   tinted to the ink tone) + a space + the title (custom, else the capitalized type name), in
   the body font at medium weight, indented like the quote body.
2. Emit the body via the shared `appendQuoteLines(...)` — same indent + de-emphasis as a
   blockquote.

Icon map (monochrome, SF Symbols): `note` → `info.circle`, `tip` → `lightbulb`, `important` →
`exclamationmark.circle`, `warning` → `exclamationmark.triangle`, `caution` →
`exclamationmark.octagon`. All tinted to `theme.textColor` (no color) so they read on every
theme and in export.

### 3. Export

`DocumentExportRenderer` reuses `MarkdownPreviewRenderer`, so callouts render in PDF/RTF
automatically. No special-casing — they are monochrome by construction (no `highlightsCode`-style
gate needed).

### 4. Info tab — `MarkdownReference`

Add one concise row: syntax `> [!NOTE]` over a plain-English explanation, listing the 5 types.
Keep it within the `MarkdownReferenceTests` length discipline.

## Testing

- **Unit (default plan):**
  - `MarkdownCallout.parse` — each of the 5 types, case-insensitivity, custom title, unknown
    type → nil, malformed (`[!]`, `[NOTE]`, missing `!`) → nil.
  - `MarkdownBlockGrouping` — a `[!TYPE]` blockquote becomes `.callout` (title + body split);
    an unknown-type or plain blockquote stays `.blockquote`; non-blockquote routing unchanged.
  - `appendBlockquote` output is byte-identical after the `appendQuoteLines` refactor (existing
    blockquote render tests must stay green).
  - `MarkdownReference` still passes its length/content tests with the new row.
- **Manual:** render each callout type in Read/Preview across light/dark themes; confirm
  monochrome; confirm PDF/RTF export shows the title row + body.

## Out of scope

- Collapsible callouts, nested callouts beyond what blockquote nesting already gives, colored
  variants, and a Format-menu insertion command (the syntax is taught in the Info tab; a menu
  affordance can come later if wanted).

## Risk

Low. Natural extension of the existing blockquote path; the only shared-code change is
factoring `appendQuoteLines` out of `appendBlockquote`, guarded by the existing blockquote
render tests. No new dependency, no rasterization beyond a small tinted SF Symbol per callout.
