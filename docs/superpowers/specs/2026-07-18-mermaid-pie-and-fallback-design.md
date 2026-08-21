# Mermaid: clean fallback for unsupported types + native pie charts

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation

## Problem

Lineform renders ```mermaid blocks natively via `BeautifulMermaid` (pinned 1.0.4). That
library renders: flowchart/graph, stateDiagram, sequenceDiagram, classDiagram, erDiagram,
and **xyChart** (`xychart-beta`, i.e. bar/line charts already work). It does **not** support
`pie`, `gantt`, `mindmap`, `timeline`, `journey`, `quadrantChart`, `sankey`, etc.

Two consequences today:

1. **Unsupported types mis-render, they don't fall back cleanly.** `BeautifulMermaid`'s
   parser (`Parser.parse`) matches a fixed set of type prefixes and **defaults everything
   else to flowchart**. So a ```mermaid `pie` block is parsed as a flowchart and drawn as
   garbage, rather than degrading to Lineform's clean captioned "Mermaid diagram (source)"
   fallback. This is the actual "looks broken" case.

2. **Pie charts don't render at all.** Proportion/pie is one of the most common chart types
   AIs emit into Markdown, and it currently produces the garbage-flowchart above.

This spec fixes (1) for the whole Mermaid family and closes (2) natively — with **no**
WebView, JavaScript, Vega-Lite, or new remote dependency. Everything stays inside the
existing native diagram pipeline and design language.

Out of scope (explicit): Vega-Lite / Chart.js / A2UI / arbitrary HTML or UI rendering (all
require a browser engine, contradicting the native/calm/offline principles); other Mermaid
types (gantt, mindmap, …) — after Part 1 they fall back **cleanly**, so they are not
"broken," just not drawn. They can be added later if a real gap is felt.

## Part 1 — Clean fallback for unsupported Mermaid types

### Approach

Add a pure classifier that decides, from the block source, whether `BeautifulMermaid` can
actually render it — mirroring the library parser's own prefix set exactly rather than
letting the library's flowchart-default fire.

New in `Lineform/Preview/MermaidRendering.swift`:

```swift
enum MermaidDiagramKind { case supported, pie, unsupported }

enum MermaidTypeClassifier {
    /// Classify a mermaid block by its declared type. Skips blank lines, `%%` comments,
    /// and a leading `---`/`---` YAML front-matter block, then inspects the first
    /// significant line (lowercased). Prefixes mirror BeautifulMermaid.Parser exactly.
    static func classify(_ source: String) -> MermaidDiagramKind
}
```

Supported prefixes (must stay in lockstep with the pinned library's `Parser.parse`):
`flowchart`, `graph`, `statediagram`, `sequencediagram`, `classdiagram`, `erdiagram`,
`xychart`. `pie` → `.pie` (Lineform renders it, Part 2). Anything else → `.unsupported`.

### Outcome routing

Add a case to `MermaidRenderOutcome`:

```swift
case unsupported(String)   // recognized-but-unrenderable type (e.g. "gantt"); clean fallback
```

`MermaidImageProvider.outcome(...)` classifies **before** touching the library:

- `.unsupported` → return `.unsupported(type)` (not `.failed`: this is not a bug, so no
  DiagramLog entry and no "Report this" affordance — same clean treatment as `.skipped`).
- `.pie` → Part 2.
- `.supported` → existing `do/catch` BeautifulMermaid path, unchanged.

In `MarkdownPreviewRenderer.appendMermaidBlock`, the new `.unsupported` case routes to
`appendMermaidFallback(..., reportHash: nil)` — identical to the `.skipped` arm (captioned
source, no report link, no logging).

### Why not `.skipped`?

`.skipped` means "size guard tripped." Reusing it would conflate two reasons. A named
`.unsupported(type)` is self-documenting and future-proof (e.g. a later log/telemetry of
"which unsupported types do users paste" could hang off it) while behaving identically for
now.

## Part 2 — Native pie charts

### Rendering approach: monochrome, matching the two-color diagram theme

Lineform's Mermaid diagrams use a strict **two-color mono theme** (page + ink) — a calm,
restrained look. A rainbow pie would clash. So pie slices are drawn in the **same
two-color contract** the seam already passes to the provider:

- Slice fill: `foreground` (ink) at stepped alpha across slices, so adjacent slices read
  distinctly without introducing new hues.
- Slice edge: a thin `foreground` stroke (crisp borders on the transparent light canvas /
  the page-colored dark canvas — exactly how existing Mermaid diagrams behave).
- Title + legend text: `foreground`.

Data lives in the **legend** (below the circle), one row per slice: a swatch (that slice's
tint) + label + value + percent. A legend is calmer and more robust for the reading column
than radial labels, which collide when slices are many or small. Mermaid's `showData`
keyword is accepted and ignored (values are always shown in the legend).

### Files

New `Lineform/Preview/MermaidPieChart.swift`:

```swift
struct MermaidPieSlice { let label: String; let value: Double }   // value > 0

struct MermaidPieModel {
    let title: String?          // from `pie title <text>` (nil if absent)
    let slices: [MermaidPieSlice]
    var total: Double { slices.reduce(0) { $0 + $1.value } }
    func fraction(of s: MermaidPieSlice) -> Double  // s.value / total
}

enum MermaidPieChart {
    /// Parse `pie [showData] [title <text>]` + `"label" : value` lines.
    /// Returns nil when unrenderable: no slices, any non-numeric or <= 0 value,
    /// or total <= 0 → caller degrades to the clean fallback.
    static func parse(_ source: String) -> MermaidPieModel?
}

enum MermaidPieRenderer {
    /// Draw the pie + title + legend into an NSImage (already upright — we draw it
    /// ourselves, so no `uprightForMacOS` flip is needed). Returns nil only on a
    /// transient raster-context failure.
    static func image(model: MermaidPieModel, background: NSColor,
                      foreground: NSColor, scale: CGFloat) -> NSImage?
}
```

### Integration

Inside `MermaidImageProvider.outcome(...)`, after the size guard and cache lookups, when
`classify == .pie`:

```swift
guard let model = MermaidPieChart.parse(source) else { return .unsupported("pie") }
guard let image = MermaidPieRenderer.image(model: model, background: background,
                                           foreground: foreground, scale: scale) else {
    return .failed("Pie render produced no image")   // transient; not neg-cached
}
cache.setObject(image, forKey: key, cost: RasterImageCost.bytes(for: image))
return .image(image)
```

- Reuses the **existing** `NSCache`, cache key, size guard, and cost accounting.
- A malformed pie → `.unsupported("pie")` → clean captioned fallback (source still shown),
  no report affordance.
- The rendered pie flows through the **unchanged** `.image` arm of `appendMermaidBlock`
  (BlockRenderedAttachment, column-width constrained, `accessibilityDescription` set to the
  source). No renderer changes beyond the `.unsupported` arm from Part 1.

### Parsing rules

- First significant line: `pie`, optionally followed by `showData` and/or `title <text>`
  (either order tolerated; `title` consumes the rest of the line).
- Data line: `"<label>" : <number>` — quotes required (Mermaid syntax), number is int or
  decimal. Whitespace around `:` tolerated. `%%` comment and blank lines skipped.
- Reject → nil: zero valid slices, any value that is non-numeric / negative / zero, or a
  total of zero.

## Testing (all pure/deterministic → default test plan, no hosted tests)

Part 1 — `MermaidTypeClassifierTests`:
- `.supported` for flowchart/graph/stateDiagram/sequenceDiagram/classDiagram/erDiagram/
  xychart, incl. case variants, a leading `%%` comment, and a `---`/`---` front-matter block.
- `.pie` for `pie`, `pie showData`, `pie title Foo`.
- `.unsupported` for gantt, mindmap, timeline, journey, quadrantChart, sankey, gibberish.
- `MermaidImageProvider().outcome(<gantt>)` == `.unsupported` (no library call needed).
- Renderer: an `.unsupported` outcome yields the captioned fallback **without** "Report
  this" and **without** a DiagramLog record / report registration (stub provider + spy log).

Part 2 — `MermaidPieChartTests`:
- `parse` extracts labels/values/title/`showData`; handles decimals and extra whitespace;
  fractions sum to ~1.0.
- `parse` returns nil for: empty, negative value, zero value, zero total, non-numeric value,
  no data lines.
- `MermaidPieRenderer.image(...)` returns a non-nil NSImage with positive size for a valid
  model on both a `.clear` (light) and an opaque page (dark) background.
- `MermaidImageProvider().outcome(<pie>)` == `.image` (deterministic; renders natively).

## Risk / consistency notes

- The classifier's supported-prefix list is **coupled to the pinned BeautifulMermaid
  version**. A comment at both sites and a test naming the version guard against silent
  drift if the pin is bumped (re-check what the new version renders, same as the existing
  orientation-flip note).
- No change to the light/dark canvas contract, orientation handling for library diagrams,
  cache budget, size guard, or report/log plumbing.
- Net user-visible result: bar/line render (already), **pie renders (new)**, every other
  Mermaid type and any unknown AI output degrades to clean readable source — never garbage.
