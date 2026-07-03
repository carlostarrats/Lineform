# Math / LaTeX support — design spec

Status: **designed, ready for implementation plan.** Captured 2026-07-02.
Supersedes the exploratory note `docs/notes/math-support-future.md` (which remains
as the origin/context record).

## Summary

Render LaTeX math written in Markdown as typeset equations in **Read** and
**Preview** modes; **Write** mode shows the raw source. Two forms:

- **Inline** `$…$` — the equation sits inline with surrounding prose.
- **Block** `$$…$$` — a centered, standalone equation on its own line(s).

This mirrors the existing Mermaid feature: the user types plain-text math, and it
displays as a native image. It is **opt-in and silent** — a document with no `$`
math is completely unaffected. No user-facing font or setting is introduced.

Audience: technical / academic long-form writers. Consistent with "calm writing"
because it is additive and invisible unless used.

## Non-goals

- **No editing/authoring UI for math.** No equation palette, no WYSIWYG math
  editor, no autocomplete. Users type LaTeX as text, same as Mermaid.
- **No math in Write mode.** Write shows source, unchanged.
- **No semantic/accessible math tree (MathML/ARIA).** A raster image cannot carry
  it; VoiceOver reads the LaTeX source (see Accessibility). This is a stated
  limitation, not a deferred feature.
- **No new delimiters beyond `$` and `$$`.** `\(…\)` / `\[…\]` are explicitly out
  of scope (decided 2026-07-02).
- **No server, account, network, or analytics.** Rendering is fully local.

## Dependency: SwiftMath

[SwiftMath](https://github.com/mgriebling/SwiftMath), pinned via SwiftPM.

- Pure native Swift LaTeX-math renderer — **no WebView, no JavaScript, no KaTeX.**
  Fits the native / no-WebView / local-first principles, exactly like
  `BeautifulMermaid`.
- **License (reviewed 2026-07-02): 100% open source.** Code is **MIT**. Bundled
  math fonts are all libre: Latin Modern Math + TeX Gyre Termes (GUST Font
  License), XITS Math (OFL), KpMath (SIL OFL). Actively maintained.
- **On adoption:** add SwiftMath's font license files under
  `Lineform/Resources/Fonts` and update `Lineform/Resources/FontLicenseReview.md`,
  exactly as for the existing bundled fonts. Credit SwiftMath in public
  docs/notices where dependencies are listed, as Sparkle/BeautifulMermaid are.
- Rejected alternatives: **iosMath** (older ObjC project SwiftMath is the Swift
  port of), **Typetex** (a whole competing editor app, not a library),
  **LaTeXSwiftUI** (renders via MathJax/SVG → pulls in a JS engine; violates
  no-WebView).

## Architecture

The Markdown preview renderer (`Lineform/Preview/MarkdownPreviewRenderer.swift`)
already: (a) accumulates fenced blocks and hands them to an isolated image
provider, and (b) tokenizes inline spans (bold/italic/code/link) per line. Math
plugs into **both** paths.

### The isolated seam — `MathImageProvider` (new `Lineform/Preview/MathRendering.swift`)

A direct parallel to `MermaidImageProvider` (`Lineform/Preview/MermaidRendering.swift`).
The single seam that touches SwiftMath. Every render is defensive (`do/catch`); any
failure degrades to the captioned-source fallback.

- Protocol `MathImageProviding` with a `DisabledMathImageProvider` (never renders)
  for the back-compat `render(_:profile:)` convenience and for tests, mirroring
  `DisabledMermaidImageProvider`.
- `outcome(latex:style:foreground:scale:) -> MathRenderOutcome` where
  `MathRenderOutcome` is `.image(NSImage)` / `.skipped` (size guard) /
  `.failed(String)`, mirroring `MermaidRenderOutcome`.
- `style` distinguishes **inline** (text style, baseline-fit) from **display**
  (block, centered, larger operators) — SwiftMath exposes both math modes.
- Caching: `NSCache` keyed by SHA-256 of `style + foregroundHex + scale + latex`
  (reuse the `MermaidCacheKey` pattern; math is theme-foreground-only, no
  background fill). A `failureCache` remembers deterministic parse failures so a
  broken formula isn't re-parsed on every preview pass.
- Size guard: `MathBlockPolicy.maxSourceLength` (mirror `MermaidBlockPolicy`,
  e.g. 20,000 chars) → `.skipped` → fallback.
- **Orientation:** SwiftMath renders through CoreText/`MTMathUILabel`, not the
  raw bottom-left `CGContext` path that forced `MermaidImageOrientation`. Verify
  orientation empirically during implementation; add a flip **only** if the raster
  actually comes back mirrored. Do not copy the Mermaid flip blindly.

### Block math `$$…$$` — a Mermaid-shaped clone

Handled at the line-accumulation level in `MarkdownPreviewRenderer`, next to the
existing `appendMermaidBlock` path:

- A line whose trimmed content is exactly `$$` (or `$$…$$` on a single line) opens
  a display-math block; accumulate body lines until the closing `$$`.
- Render via `MathImageProvider` with `.display` style → `NSTextAttachment` with
  the equation image, centered, `accessibilityDescription` = the raw LaTeX.
- On `.skipped` / `.failed`, append a captioned-source fallback identical in
  spirit to `appendMermaidFallback` ("Math (source)" caption + monospaced source).
- No network report path (unlike Mermaid's optional diagram report) — math
  failures are almost always the user's own LaTeX typos, not a library bug worth
  collecting.

### Inline math `$…$` — the one genuinely new piece

Inline math lives *inside* a line, alongside bold/italic/code, so it becomes a new
inline token kind in the `inlineMarkdown` / `inlineToken` machinery. Unlike
bold/italic (which only set text attributes), an inline-math token emits an
**inline `NSTextAttachment` (the equation image) baseline-aligned** so it sits
correctly on the text baseline within running prose.

- Set the attachment's `bounds` so the image's math axis aligns to the font
  baseline (SwiftMath exposes the label's baseline/descent; use it to compute the
  `bounds.origin.y` offset). This baseline alignment is the primary new
  engineering problem — everything else reuses proven attachment code.
- Render with `.inline` (text) math style at the profile's body point size.
- On failure/skip, the token falls back to the literal source styled as inline
  code (reuse the existing inline-code attributes), so a bad `$…$` reads as
  `x^2` in code style rather than vanishing.

### Delimiter rules (the `$` footgun)

Adopt GitHub/CommonMark math rules so ordinary prose dollar signs are never
mis-parsed:

1. An opening `$` must **not** be immediately followed by whitespace.
2. A closing `$` must **not** be immediately preceded by whitespace.
3. A `$` immediately preceded or followed by a digit does **not** open inline math
   (kills "it costs $5", "$10–$20").
4. `\$` is always a literal dollar and never a delimiter.
5. `$$` is only display math when it stands alone as a block delimiter; inside a
   line, unbalanced `$` that doesn't satisfy the rules stays literal text.
6. Anything that does not cleanly open-and-close as math is left as plain text —
   **never** partially consumed.

These rules live in a small, unit-testable parser (`MathDelimiters` /
`MathFence` in `MathRendering.swift`), independent of rendering, mirroring how
`MermaidFence` is a pure detection helper.

## Reading experience integration

- **Type size:** render at the reading profile's resolved body point size × screen
  scale, so equations track the user's chosen type size (large-type users must not
  get a tiny fixed equation next to big body text).
- **Theme + contrast:** render glyphs in the theme foreground color (dark mode,
  high-contrast themes). No background fill — the attachment sits on the page
  background like text.
- **Block spacing / margins:** display-math attachments respect the profile's
  paragraph spacing, matching how Mermaid blocks are appended.

## Accessibility

- **Known limitation:** VoiceOver reads the **raw LaTeX source** attached as the
  image's `accessibilityDescription`, not spoken math ("x caret 2", not "x
  squared"). A raster image cannot carry MathML/ARIA the way web MathJax/KaTeX
  can. State this plainly in any user-facing help copy; do not imply the math is
  semantically accessible. Same trade-off Mermaid already makes.
- **Dyslexia fonts:** equations render in a math typeface regardless of an
  OpenDyslexic/Atkinson body-font choice — inherent to math typesetting, not
  fixable. No action beyond awareness.

## Writing Tools protection

Treat inline and block math regions like fenced code in the existing Writing Tools
protection (so system autocorrect / rewrite does not mangle LaTeX inside `$…$` /
`$$…$$`). Extend the same range-classification the editor already applies to fenced
code and front matter to cover math delimiters. Scope this in the plan against the
current protection implementation in `Lineform/Editor`.

## Error handling

Every failure path is safe and non-destructive:

- Parse/render throw → `.failed` → captioned-source fallback (block) or
  inline-code fallback (inline). Document content is never altered.
- Oversized source → `.skipped` → same fallback.
- Deterministic failures are negatively cached so a broken formula is not
  re-parsed on every preview pass while the user types elsewhere.
- No orientation flip is applied unless the raster is verified to be mirrored.

## Testing

Deterministic, provider-mocked (no real SwiftMath dependency in most tests),
mirroring the Mermaid test approach:

- **Delimiter parser** (pure, no rendering): the six delimiter rules — inline
  open/close, whitespace rejection, digit-adjacency rejection ("$5"), `\$`
  literal, unbalanced `$` left literal, single-line vs. block `$$`. This is the
  highest-value test surface (the footgun lives here).
- **Renderer with a mock `MathImageProviding`:** a stub returning `.image` yields
  an attachment with the correct `accessibilityDescription` (raw LaTeX) and, for
  inline, a baseline-offset `bounds`; a stub returning `.failed`/`.skipped` yields
  the captioned-source / inline-code fallback.
- **Profile integration:** rendering at two different reading-profile point sizes
  requests two different scales/sizes from the provider (size tracks type size);
  theme foreground color is threaded through the cache key.
- **Live SwiftMath smoke test** (one, guarded): a known formula renders to a
  non-empty image and — importantly — is **right-side up**, so a future SwiftMath
  bump that reintroduces a y-origin bug is caught (the Mermaid orientation lesson).

Full gate per `CLAUDE.md`:

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

## Documentation to update on ship

- `Lineform/Resources/FontLicenseReview.md` + font license files (SwiftMath fonts).
- Public credits/notices where Sparkle / BeautifulMermaid are credited (add
  SwiftMath, MIT).
- `CLAUDE.md` "Main Features" — add a math-rendering bullet paralleling the Mermaid
  bullet.
- User-facing help doc in `Lineform/Resources/*.md` — brief "Math" section with the
  `$…$` / `$$…$$` syntax and the VoiceOver-reads-source caveat.
- `README.md` feature list if Mermaid is listed there.

## Open decisions deferred to the plan (not blockers)

- Exact `NSTextAttachment.bounds` baseline math for inline equations (needs
  empirical tuning against SwiftMath's reported descent/axis).
- Whether display `$$` blocks should be horizontally scrollable when an equation
  is wider than the reading column, or scaled down to fit. Default: scale to fit
  the column, matching Mermaid's width-constraint behavior.
