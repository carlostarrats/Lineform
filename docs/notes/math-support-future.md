# Future idea: math / LaTeX support

Status: **candidate, not scheduled.** Not V1 scope. Captured 2026-07-02.

## The idea

Render inline `$…$` and block `$$…$$` LaTeX math in Read and Preview modes
(Write mode shows source), the same way ```mermaid fenced blocks render today.
Audience: technical / academic long-form writers. This is net-new product scope,
not a bug — decide whether calm long-form writing in Lineform actually wants
equations before building it.

## Recommended path: SwiftMath, isolated behind a provider

Use [SwiftMath](https://github.com/mgriebling/SwiftMath) directly.

- Pure native Swift formula renderer — **no WebView, no JavaScript, no KaTeX.**
  Fits Lineform's native / no-WebView / local-first principles, exactly like
  `BeautifulMermaid` does.
- **License reviewed 2026-07-02 — clean, 100% open source.** Code is **MIT**.
  All bundled math fonts are libre: Latin Modern Math + TeX Gyre Termes (GUST
  Font License), XITS Math (OFL), KpMath (SIL OFL) — same license family as the
  Atkinson Hyperlegible / OpenDyslexic fonts already shipped. Actively maintained
  (last release Dec 2024). To-do on adoption: add SwiftMath's font license files
  under `Lineform/Resources/Fonts` and update `FontLicenseReview.md`, exactly as
  for the existing bundled fonts. Rejected alternatives: **iosMath** (older ObjC
  project SwiftMath is the Swift port of), **Typetex** (a whole competing editor
  app, not a library — same trap as swift-markdown-engine), **LaTeXSwiftUI**
  (renders via MathJax/SVG → pulls in a JS engine, violates no-WebView).
- Wrap it behind an isolated seam mirroring `MermaidImageProvider`
  (`Lineform/Preview/MermaidRendering.swift`): render each math region to an
  `NSImage`, cache by source+theme+scale, size-guard, and **fall back to a
  captioned source block on any failure**. Reuse the Mermaid fallback UX.
- Carry an accessibility description with the raw LaTeX source (as the Mermaid
  attachment does) so VoiceOver reads the formula source.
- Watch the same macOS raster gotcha we hit with Mermaid: if the renderer draws
  into a raw bottom-left-origin `CGContext`, correct orientation at the seam
  (see `MermaidImageOrientation.uprightForMacOS`).

## Do NOT adopt swift-markdown-engine

[nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
is where this idea surfaced (its optional `MarkdownEngineLatex` module is what
shows math), but the math there is just a thin wrapper over SwiftMath — so depend
on SwiftMath directly.

The engine *itself* is a complete native AppKit Markdown editor (TextKit 2 +
SwiftUI bridge, live styling, reading column, Writing Tools, syntax highlighting).
That is a **parallel implementation of Lineform's own editor core** — adopting it
would replace `LineformTextView` / the editor container, not add to it. Two editor
engines can't coexist. Reject it as a whole; take only the SwiftMath idea.

## Accessibility (reviewed 2026-07-02)

No hard blocker — one honest limitation and two must-do integrations, all of which
mirror how the Mermaid provider already behaves:

- **VoiceOver reads the *source*, not spoken math (known limitation).** A rendered
  raster image can't carry MathML/ARIA the way web MathJax/KaTeX can, so the best
  we can attach is the raw LaTeX — VoiceOver reads "x caret 2," not "x squared."
  Same trade-off Mermaid already makes. State it plainly; do not imply the math is
  semantically accessible.
- **Must scale with the reading profile.** Render at the profile's point size so
  large-type users don't get a tiny fixed equation next to big body text.
- **Must respect theme + contrast.** Render in the theme foreground color (dark
  mode, high-contrast themes), not fixed black-on-white — exactly like the Mermaid
  provider themes from bg/fg.
- Minor/unavoidable: there is no dyslexia-friendly *math* font, so for
  OpenDyslexic/Atkinson users equations render in a math typeface that differs from
  their body text. Inherent to math typesetting.

## Open questions before building

- Is math in-scope for a "calm writing" editor, or does it pull toward technical
  tooling the product deliberately avoids? (Leaning yes — it is opt-in and silent:
  type no `$`, nothing changes.)
- Delimiter rules to avoid mangling prose dollar signs ("it costs $5") — the one
  real footgun. Follow GitHub/CommonMark math rules (see the spec).
- Interaction with Writing Tools protection over math regions (like fenced code).
