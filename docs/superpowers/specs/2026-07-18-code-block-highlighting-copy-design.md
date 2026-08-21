# Code blocks: native syntax highlighting + copy button

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** C

## Problem

Fenced code blocks render as **flat monospace, one color, in every mode** (verified
2026-07-18). Lineform's existing "syntax highlighting" is *Markdown-markup* highlighting only
(heading/list/blockquote markers, the ` ``` ` fence delimiters). The fence's language tag
(` ```swift `) is parsed but unused: Write mode gives code one uniform inline-code color
(`MarkdownSyntaxHighlighter.swift:263`); Read/Preview uses uniform `codeAttributes`, no tokens
(`MarkdownPreviewRenderer.swift:431`). Byword is dinged by reviewers for exactly this. There is
also no way to copy a code block without manually selecting it.

## Decisions

- **Native, light tokenizer** — no new SPM dependency, no bundled grammar blobs. A shared
  scanner + compact per-language keyword/rule sets. On-brand (calm, native, light) and matches
  how Lineform already owns its rendering.
- **Languages (v1):** Swift, JavaScript/TypeScript, Python, JSON, Bash/shell, HTML, CSS.
  Unknown or absent language → monospace only (today's look) **but still gets the copy button**.
- **Calm palette, not rainbow:** ~4–5 muted token roles (keyword, string, comment, number,
  type/identifier) from a theme-derived palette. Restrained, monochrome-leaning.
- **Read/Preview only.** Write mode is **unchanged** — the scoped, line-local Write highlighter
  (`MarkdownSyntaxHighlighter`) is not touched, so typing performance and the line-local
  invariant are unaffected.
- **Export/PDF code stays MONOCHROME.** Highlighting is bypassed in `DocumentExportRenderer`;
  exported code is plain dark-ink monospace on the light export page. (User decision: no color
  in PDFs.)
- **Line numbers: out of scope** (parked; a numbered gutter reads "IDE," fights the calm feel,
  and needs fiddly copy-safe layout).
- **Display-only, zero bytes on disk.** Highlighting is pure text attributes (foreground color
  over ranges) — it rasterizes nothing, needs no cache, adds no images, and never writes to the
  `.md` or to exports. The document on disk is untouched.

## Architecture

### 1. Tokenizer — `Lineform/Preview/CodeHighlighting.swift`

Isolated behind a protocol, mirroring `MathImageProviding` / `MermaidImageProviding`:

```swift
enum CodeTokenKind { case keyword, string, comment, number, type, plain }

struct CodeToken { let range: NSRange; let kind: CodeTokenKind }

protocol CodeSyntaxHighlighting {
    /// Token ranges for `source` in `language`. Empty for unknown languages (→ monospace).
    /// Operates on the WHOLE fenced-block body (multi-line strings/comments are fine — this is
    /// a bounded block, NOT the line-local Write highlighter).
    func tokens(for source: String, language: String) -> [CodeToken]
}

struct CodeSyntaxHighlighter: CodeSyntaxHighlighting { /* shared scanner + per-language rules */ }
```

Language dispatch normalizes the fence tag (lowercased, aliases: `js`/`javascript`,
`ts`/`typescript`, `sh`/`bash`/`shell`, `py`/`python`, `yml`→ not in v1, etc.). Unknown → `[]`.

Per-language rules are small: a keyword `Set<String>`, string/comment delimiters, number
regex. The shared scanner walks the source once producing non-overlapping tokens; anything
unmatched is `.plain`. Keep each grammar a few dozen lines — no external tables.

### 2. Palette — `CodeSyntaxPalette` (in `DiagramCardStyle.swift` alongside `DiagramPalette`)

Maps `CodeTokenKind` → `NSColor`, derived from the theme (light/dark aware), muted. Reuses the
existing ink/secondary tones where possible so the set stays coherent with the reader themes.
`.plain` → the current code foreground (unchanged).

### 3. Block routing — `MarkdownBlockGrouping.swift`

Add a dedicated block case so code renders through its own path (parallel to mermaid/math,
which are already routed out of the plain-lines runs):

```swift
case fencedCode(language: String, body: String, closingIndex: Int?)
```

The grouping already special-cases ```mermaid and `$$` math out of `.lines`; extend the fence
scan to also split plain ` ``` ` code fences into `.fencedCode`. Prose, headings, inline
constructs, etc. keep flowing through the unchanged `appendLines` (byte-identical). Only fenced
code changes routing — which is the intent of this feature.

### 4. Rendering — `MarkdownPreviewRenderer.appendCodeBlock(...)`

New method (sibling of `appendMermaidBlock`):

1. Apply the existing monospace code paragraph style + block spacing (unchanged look/metrics).
2. If `highlightsCode` is true (Read/Preview) and the language is recognized, call the
   tokenizer and apply `CodeSyntaxPalette` foreground colors over the token ranges. If
   `highlightsCode` is false (export) or language unknown → skip coloring (monochrome).
3. Attach the block's **source `NSRange`** as an attribute (`.codeBlockSourceRange`, mirroring
   `.checkboxSourceRange`) so the copy button can copy the raw text.

`highlightsCode` is threaded from the caller: **true** for the on-screen `MarkdownPreviewView`,
**false** from `DocumentExportRenderer` (keeps PDFs monochrome).

### 5. Copy button — `MarkdownPreviewTextView`

A hover affordance, reusing the view's existing mouse tracking + rect hit-testing (the
checkbox-click precedent, `mouseDown` glyph hit-test → source mutation):

- On hover, find the code block's bounding rect (from the `.codeBlockSourceRange` attribute run)
  and draw a small **"Copy" pill in the top-right** — the **same translucent, theme-aware
  treatment as the Reconnect pill** (page tint bleeds through; `usesDarkChrome`-aware).
- On click, copy the block's raw source (from the stored range) to `NSPasteboard`; briefly swap
  the label to "Copied". No document mutation (unlike checkbox — copy is read-only).
- The pill is overlay-drawn, not part of the attributed string, so it never affects layout,
  selection, wrapping, or exported/printed output.

## Testing

- **Unit (default plan):**
  - `CodeSyntaxHighlighter.tokens(for:language:)` per language — keyword/string/comment/number
    classification, multi-line strings/comments within a block, unknown language → empty.
  - Language-tag normalization/aliases.
  - `MarkdownBlockGrouping` splits ` ``` ` code fences into `.fencedCode` while leaving mermaid,
    math, and prose routing byte-identical (extend existing grouping tests).
  - Export path: `appendCodeBlock` with `highlightsCode: false` applies **no** token colors.
  - `CodeSyntaxPalette` colors meet AA against every theme's code background (extend the
    existing per-theme contrast test discipline).
- **Manual:** hover copy pill in Read/Preview across light/dark themes; verify exported PDF code
  is monochrome and copy pill is absent from print output.

## Out of scope

- Line numbers (parked).
- Write-mode language highlighting (Write stays markup-only).
- Highlighting in PDF/Print (deliberately monochrome).
- Languages beyond the v1 set (add later if a real gap is felt — the architecture is additive:
  one keyword set + rules per language).
- Diff highlighting, code folding (IDE features, off-brand).

## Risk

Low–medium. The tokenizer is new code to own but small and dependency-free; highlighting is
pure attributes (no rasters, no cache, no file-size impact). The one structural change is the
`.fencedCode` block-routing split — contained, and covered by extending the existing
block-grouping tests to prove non-code routing is unchanged.
