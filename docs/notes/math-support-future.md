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

## Open questions before building

- Is math in-scope for a "calm writing" editor, or does it pull toward technical
  tooling the product deliberately avoids?
- Licensing review for SwiftMath (and update `FontLicenseReview.md` / credits if
  it bundles fonts).
- Interaction with Writing Tools protection over math regions (like fenced code).
