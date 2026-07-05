# Read-mode Markdown rendering — design spec (Task 6 umbrella)

Status: **designed, ready for implementation plan.** Captured 2026-07-04.
Companion to `docs/audits/2026-07-04-audit-decisions.md` (Task 6). This spec is the
umbrella for the whole Read-mode rendering feature; it is implemented in **waves**,
each its own fresh session + QA (see "Waves" below).

The audit already recorded every **product** decision per construct (walked through
one-by-one on 2026-07-04). This spec keeps those verbatim and fills in only the
**how** — the architecture, the per-construct rendering mechanics, and the
cross-cutting rules.

## Summary

Read and Preview modes today render only headings, fenced code, Mermaid, math, and
inline bold/italic/code/link. Everything else — lists, blockquotes, tables, task
checkboxes, horizontal rules, strikethrough, images — shows as raw Markdown symbols.
This feature renders the rest of standard Markdown, so Read mode delivers on the
"readable long-form text" promise. Write mode is unchanged (it always shows source).

Guiding principle (user, 2026-07-04): **if standard Markdown supports it, we want
it.** The open question per construct is *how*, not *whether* — with one principled
exception (images, deferred to a placeholder; see below).

Read mode **keeps its themes** (sepia/dark/etc.). The white/black requirement is for
PDF export only (Task 7), not here.

## Non-goals

- **No image file rendering.** `![alt](url)` renders a quiet, file-free, network-free
  **placeholder** only (see Images). Real image rendering is deferred (audit: touches
  the sandbox/file-permission area behind past incidents; least core to a calm writing
  app). OCR / AI image→Mermaid recreation is **rejected outright** (collides with the
  "No AI inside" positioning pillar), not parked.
- **No change to Write mode.** Write always shows raw source, unchanged.
- **No new reading settings or fonts.** Rendering is additive and invisible unless the
  construct is used.
- **No network, account, analytics, or document upload.** Fully local, consistent with
  positioning.
- **No cross-file behavior.** Purely a render concern over the open document's text.

## Architecture: a block-grouping layer

### Why (decided 2026-07-04)

The current renderer (`Lineform/Preview/MarkdownPreviewRenderer.swift`, ~578 lines) is
a **per-line `while` loop**. It already accumulates a couple of multi-line blocks
(Mermaid fences, `$$` math) with ad-hoc `mermaidBody`/`mathBody` flags, and tokenizes
inline spans per line. The new constructs are **block-level**: lists need hanging
indents / nesting / numbering, blockquotes span multiple lines and nest (`>>`), tables
span a header + rows, horizontal rules must be distinguished from front matter and
setext headings by looking at surrounding lines. Bolting more accumulation flags onto
the line loop gets tangled fast.

Chosen approach (user, 2026-07-04): **introduce a small block-grouping layer.** Group
the document's lines **once** into typed blocks, then render each block. This also
**is** the Task 4 fix (the double-split): the text is split into lines a single time
and handed to grouping.

### Shape

Two new pure files in `Lineform/Preview`:

- **`MarkdownBlockGrouping.swift`** — `enum MarkdownBlock { … }` plus a pure
  `func blocks(in text: String) -> [MarkdownBlock]`. Splits once on `\n`, walks the
  lines, and emits typed blocks. No AppKit, fully unit-testable.
- **`MarkdownBlockRenderer.swift`** — renders one `MarkdownBlock` to an
  `NSAttributedString`, given the `ReadingProfile`, `Theme`, column width, and the
  image providers. Owns the per-block emitters.

`MarkdownPreviewRenderer.render(...)` keeps its **exact public signature** (tests and
`MarkdownPreviewTextView` call it unchanged) and becomes: `group → render each block →
concatenate`. The existing emitters — heading, `inlineWithMath`/`inlineMarkdown`,
`appendMermaidBlock`, `appendMathBlock`, their fallbacks, `headingAttributes`,
`codeAttributes`, `blockSpacingAttributes` — are **moved, not rewritten**, into the
block renderer and reused as-is. Block spacing (`markdownBlockSpacingLineIndexes`) and
the `BlockRenderedAttachment` / `BlockAttachmentRefit` resize machinery are preserved.

Proposed block cases (added incrementally by wave; the enum starts with today's
constructs so the refactor is behavior-preserving):

```
enum MarkdownBlock {
    case paragraph([String])          // body lines (inline tokenized, incl. math)
    case heading(level: Int, line: String)
    case fencedCode([String])         // ``` / ~~~ non-mermaid
    case mermaid(source: String)
    case mathBlock(latex: String)
    // added by waves:
    case horizontalRule               // Wave 1
    case blockquote(depth: Int, [MarkdownBlock])   // Wave 1 (nested)
    case list(ordered: Bool, items: [ListItem])    // Wave 1
    case table(TableModel)            // Wave 3
    case imagePlaceholder(alt: String) // Wave 1
    // task checkboxes are list items with a checkbox state (Wave 2)
}
```

### Correctness gate for the refactor

Before **any** new construct is added, the block layer must reproduce the current
renderer's output **byte-for-byte** for every construct that exists today (headings,
fenced code, Mermaid, math block + inline, inline bold/italic/code/link, block
spacing, unclosed-fence flush, single-line `$$…$$`). The existing renderer output
tests are the guard; extend them with any missing current-behavior cases first, land
the refactor green, *then* build constructs on top. This isolates "did the refactor
change anything?" from "does the new construct look right?".

## Per-construct rendering

All render in **Read + Preview**; **Write shows source** (unchanged). Each obeys the
three cross-cutting requirements (Info modal, accessibility, menu affordance) in the
same session it ships.

### Strikethrough — `~~text~~`  (Wave 1)

- A **new inline token** (`.strikethrough`) in the existing per-line tokenizer
  (`nextInlineToken` / `InlineToken.Kind`), alongside bold/italic/code/link. Applies
  `.strikethroughStyle = .single`; the `~~` marks are hidden (only the inner text is
  emitted), exactly like `**bold**` today.
- Competes **by position**: it loses to an earlier code span or emphasis run and is
  never detected inside another inline token (so `` `~~x~~` `` stays literal code) —
  the same rule inline math already follows.
- **Menu:** `MarkdownFormattingCommand.strikethrough` = wrap-selection toggle
  (`~~`…`~~`), shortcut **⌘⇧X** (locked). Mirrors bold/italic.
- **Accessibility:** announced as deleted text (`.strikethroughStyle` is bridged by
  the text system).
- **Info modal:** add `~~text~~` row.

### Horizontal rule — `---` / `***` / `___` on its own line  (Wave 1)

- A standalone line of three-or-more `-`, `*`, or `_` (optionally spaced) → a **quiet,
  thin, low-contrast divider** with breathing room above/below (calm, not a heavy bar).
  The dashes are hidden.
- Rendering: a full-width hairline. Preferred implementation = an empty paragraph
  whose paragraph style carries the divider, or a thin `NSTextAttachment` sized to the
  column width; pick whichever refits cleanly on resize (reuse `BlockRenderedAttachment`
  if an attachment is used, so it participates in `BlockAttachmentRefit`). Color =
  low-contrast, contrast-safe on every theme.
- **Gotchas the grouping pass handles (it sees surrounding lines):**
  - `---` as the **first** content of the doc delimiting **front matter** → not a rule.
  - `---` (or `===`) on the line **directly under** a non-blank text line → a **setext
    heading underline**, not a rule. (Only `---`/`===` immediately under text; a blank
    line between them makes it a real rule.)
- **Menu:** insert command (no shortcut) — HR is an insert, not a toggle.
- **Accessibility:** exposed as a separator.
- **Info modal:** add `---` (horizontal rule) row.

### Blockquote — `> quote`  (Wave 1)

- A run of `>`-prefixed lines → a **quiet quote block**: a left vertical bar + indent
  (calm, not a heavy tinted box). The `>` markers are hidden.
- **Nesting:** `>>` deepens the indent (the `blockquote(depth:)` case recurses — a
  blockquote contains blocks, so a quoted list/paragraph styles correctly).
- **Multi-line / multi-paragraph:** the styling carries across the whole contiguous
  quote block.
- Rendering: paragraph style with `firstLineHeadIndent`/`headIndent` for the indent;
  the vertical bar drawn as a leading attachment or a left border. If quote text is
  de-emphasized (dimmed), the dim color must stay **contrast-safe on every theme**
  (reuse the app's every-theme contrast discipline).
- **Menu:** `blockquote` line-prefix command (toggles `> ` on selected lines). Shortcut
  confirmed at implementation (no strong standard; leave unbound unless one is chosen).
- **Accessibility:** announced as a quote.
- **Info modal:** add `> quote` row.

### Lists — bulleted (`-`/`*`/`+`) and numbered (`1.`)  (Wave 1)

- **Highest everyday payoff.** Render **Google-Docs-style**: slight indentation, real
  bullets (•) and real sequence numbers (1, 2, 3…), a proper **hanging indent**
  (wrapped lines align under the item text, not under the bullet), nested items
  indented further. Lean on the reading-profile spacing scale; respect tight-vs-loose
  (blank line between items) spacing.
- Rendering: per item, an `NSParagraphStyle` with a tab stop + `headIndent` set to the
  marker column width so wraps hang; nesting multiplies the indent. Numbered lists
  count within their level and resume correctly.
- Fiddlier than the rest of the easy wave (nesting, counting, tight/loose) but **low
  risk** — worst case is slightly-off spacing. Budget extra care.
- **Menu:** `unorderedList` already exists (`- `); add `orderedList` (`1. `) line-prefix
  command. Shortcuts (Google Docs uses ⌘⇧8 bulleted / ⌘⇧7 numbered) confirmed at
  implementation.
- **Accessibility:** item structure exposed (each item a list item).
- **Info modal:** the `- bullet` row exists; add a numbered-list row.

### Task checkboxes — `- [ ]` / `- [x]`  (Wave 2, interactive)

Built on the list work. Renders real empty/checked boxes, and **clicking a box in Read
mode toggles it** — the audit's decision is to go **straight to interactive** (skip a
display-only stepping stone).

**Model (audit, 2026-07-04):** a click is a **normal text edit** — it swaps `[ ]`↔`[x]`
in the real document through the same edit path as typing. Because it's a normal edit,
dirty-tracking, autosave, and undo "just work." Read mode is "a windowpane over the
same source."

**The one real piece of work is the click→source-range mapping** (this is the first
interactive element in Read mode; math/diagrams are non-interactive pictures):

1. When rendering a checkbox, attach a **custom attribute** to the rendered checkbox
   character(s) carrying that checkbox's **source `NSRange`** (the exact span of
   `[ ]`/`[x]` in `document.text`).
2. `MarkdownPreviewTextView` (already an `NSTextViewDelegate` handling link clicks)
   gains a click handler: hit-test → character index → read the checkbox attribute →
   compute the toggled text (`[ ]`↔`[x]` at that source range) → send it up.
3. **Edit plumbing:** add an `onEdit: (String) -> Void` (or a `Binding`) to
   `MarkdownPreviewViewRepresentable` / `DebouncedMarkdownPreviewView`.
   `EditorContainerView` wires it to set `document.text` (it holds `@Binding var
   document`). The new text flows back down and re-renders (debounced) — **preserve
   scroll** across that re-render (audit requirement).

**Undo (the key risk to verify).** `LineformDocument` is a value-type `FileDocument`;
mutating it through the DocumentGroup binding registers **automatic** undo. **Intended
mechanism:** set `document.text` from the container; a single ⌘Z reverts the toggle.
**QA gate (must pass):** after a Read-mode checkbox toggle, one ⌘Z restores the prior
state cleanly (one step, not partial). **Fallback if it does not produce one clean
step:** route the toggle through the shared write-edit path so it registers exactly
like a typed edit. Decide by testing, not assumption.

**Save-state (audit RESOLVED 2026-07-04):** use the **same exact existing conventions**
— nothing new. Silent autosave in Read mode; the status bar stays hidden in Read mode
as today (so no visible "Autosaved" flash while in Read mode — state is correct on
switching back to Write/Split). No new save-feedback affordance. This is why Task 1
keeps `documentSaveStatus.noteUserEdit()` + autosave bookkeeping instant (never
debounced) — the toggle relies on it.

- **Accessibility:** each box announces checked/unchecked and is actionable.
- **Info modal:** add `- [ ] task` / `- [x] done` rows.

### Tables — `| a | b |`  (Wave 3)

**First real layout feature.** Main use case = **viewing** tables (often AI-generated),
so read-legibility matters most; hand-authoring is rare.

**Chosen behavior (audit, 2026-07-04): a self-scrolling in-window table.**

1. The table lays out **responsively to the reading-column width** (change reading
   width → table re-fits). **Live text, always** (never a rasterized image — that would
   break VoiceOver, lose selection, and blur when scaled; explicitly rejected).
2. Slightly too wide → **wrap** cell text (rows get taller); nothing hidden.
3. Genuinely too wide even wrapped → the table becomes its **own horizontally
   scrollable framed panel**, scroll **contained** to that one table block (prose stays
   locked to the user's set width). The only compromise is confined to the offending
   table, and only when necessary. (This also future-proofs a possible mobile version —
   same swipe-to-scroll pattern.)

**Implementation:** an **embedded view-hosting text attachment** — a live scrollable
panel (its own `NSScrollView`/table view) inside the read text view, sized to the
column width. This is the app's first interactive/scrollable preview element (alongside
checkboxes). Honestly characterized: **genuinely fiddly, not dangerous** — no data /
security / save risk; worst case is a cosmetic/interaction bug. Real edge cases to
polish: **scroll arbitration** (horizontal table swipe vs. vertical page scroll),
attachment sizing/layout, selection/copy across the table, theme refresh.

**Theming + text options (audit — feasible & cheap because it's live text):** table
background + text colors **fully adapt** to every reader theme; cell text **inherits the
reading profile** (font, size, line height, letter spacing) so it reads consistently
with surrounding prose. Instant (no re-draw) — unlike the fixed-image diagram/math rule,
which applies to diagrams/math **only**, not tables.

**Style:** quiet ruled look (light gridlines / subtle row separation, not a heavy grid);
header row distinguished; **per-column left/center/right alignment from the header
dashes** (`:---`, `:---:`, `---:`); malformed tables → best-effort, degrade gracefully.

**Rejected (with reasons, do not revisit):** render-as-image (breaks accessibility /
selection / scaling); per-table wrap-vs-extend prompt (intrusive; if ever wanted, one
global setting, not a per-table popup); in-app shrink-to-fit (no zoom in the app to
recover legibility); widening the reading column to fit tables as the primary mechanism
(blunt — widens all prose). Scroll is the answer.

- **Menu:** insert-table template command (no shortcut). Authoring is always plain
  Markdown pipes — no drag/drop; scroll is a render concern only.
- **Accessibility:** a real table view gives **native VoiceOver row/column navigation**
  — better than faking columns in text.
- **Info modal:** add a small table-syntax row (pipes + header dashes + alignment).

### Images — `![alt](url)`  (Wave 1, placeholder only)

**Do not render image files.** Render a **quiet placeholder**, file-free **and**
network-free (never opens the file, never touches the network → sidesteps all
sandbox/privacy risk). It must read as **intentional**, not a bug: e.g. a small image
glyph + the alt text as a subtle caption (`🖼 alt text`), **not** "not supported."
Exact wording/look is a spec-of-the-wave detail. This is strictly better than today's
half-rendered state (alt text with a stray `!`).

- **Accessibility:** the placeholder exposes the alt text.
- **Info modal:** optional — a row explaining images show as a labelled placeholder
  (decide at the wave; keep honest).

**Future safe-slice (deferred, reference only — not now):** render only images already
**inside** the granted workspace folder (no permission problem), fit-to-width, resolve
relative paths against the doc, downscale big images, missing-file fallback, reuse the
Mermaid raster-cache discipline. **Hard privacy line:** never fetch remote `http(s)`
images — remote refs stay a plain link/placeholder, never a downloaded picture.

## Cross-cutting requirements (apply to every construct)

1. **Info modal.** Each construct is something the user **types** to get an outcome, so
   whenever we add rendering for one, the in-app **Info / Markdown Basics modal**
   (`MarkdownBasicsModal` in `Lineform/Editor/EditorChromeAndControls.swift`) gets its
   syntax taught in the **same session**. It's a static list of `Section`/`Row` —
   adding a row is trivial. Do not ship rendering without documenting the syntax.
2. **Accessibility (VoiceOver).** Each rendered construct is accessible (per-construct
   notes above). Hold to the standard already in the app (math VoiceOver descriptions;
   search match-count announcements).
3. **Menu authoring affordances.** Provide menu-bar commands **where they'd be
   expected**, consistent with existing bold (⌘B) / italic (⌘I) / link (⌘K)
   (`MarkdownFormattingCommand`). **Not** a command for every construct just because we
   can. Interaction shape varies: strikethrough = wrap-toggle; blockquote / list =
   line-prefix; HR / table = insert; checkbox = no authoring command (the toggle is the
   interaction). **Locked now:** Strikethrough **⌘⇧X**. All other shortcuts are
   confirmed per-wave at implementation (audit: "judge per construct at spec"); default
   to no shortcut unless a widely-standard one exists.

## Waves (each = its own fresh session + QA)

1. **Wave 1 — block layer + easy styling.** Land the block-grouping refactor
   behavior-preservingly (byte-identical output gate), which **also completes Task 4**
   (single split). Then add: **strikethrough, horizontal rule, blockquote, lists,**
   and the **image placeholder**. Each with its Info-modal row, accessibility, and menu
   affordance where applicable.
2. **Wave 2 — interactive checkboxes.** Click→source-range mapping, edit plumbing, the
   single-⌘Z undo gate, scroll preservation, Info-modal rows.
3. **Wave 3 — tables (self-scrolling panel).** The embedded scrollable view, alignment,
   theming, scroll arbitration, Info-modal row. **Verify** that Task 4's double-split
   cleanup (already folded into Wave 1's block layer) holds — no separate trip.

## Testing

- **Refactor gate:** existing renderer output tests pass **byte-identical** after the
  block-layer refactor, before any new construct. Extend them to cover any
  current-behavior case not already asserted.
- **Grouping:** pure unit tests for `blocks(in:)` — front-matter vs. HR vs. setext
  underline; nested blockquotes; tight/loose lists; ordered/unordered and nesting;
  well-formed and malformed tables; fenced code / mermaid / math unaffected.
- **Rendering:** per-construct attributed-string assertions (strikethrough style,
  indent/hanging-indent metrics, HR presence, blockquote depth, checkbox glyph +
  source-range attribute).
- **Checkboxes:** click charIndex → correct source range → correct toggled text;
  **single-⌘Z** reverts a Read-mode toggle; scroll preserved across the re-render.
- **Tables:** grouping + alignment parsing; theming/profile inheritance; scroll
  containment (hosted where interactivity is exercised).
- Keep hosted-test discipline: only reach for the hosted plan where interactivity/scroll
  genuinely needs a real window; keep everything else in the pure default plan.

## Open items resolved in this spec

- Renderer architecture: **block-grouping layer** (decided with user, 2026-07-04).
- Task 4 double-split: **folded into Wave 1's block layer**; Wave 3 verifies.
- Menu shortcuts: **Strikethrough ⌘⇧X locked**; the rest confirmed per-wave.
- Images: **placeholder only**, deferred; future safe-slice documented, not built.
