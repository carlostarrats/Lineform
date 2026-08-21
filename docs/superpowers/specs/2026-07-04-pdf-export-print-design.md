# Rich PDF Export + Print (⌘P) — Design Spec

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Task 7** from `docs/audits/2026-07-04-audit-decisions.md`. Written 2026-07-04, branch
`work-2026-07-04-10`. Depends on Task 6 (Read-mode rich rendering) which is DONE.

> **Shipped adjustments (found during in-app QA, 2026-07-04).** The design below is the
> pre-implementation plan; these are the deltas that shipped:
> - **Fixed 12pt body size, not the inherited reading size.** The audit said "inherit font
>   size," but on a page the on-screen reading size (17–18pt in an 820pt reading column, wider
>   than a Letter page) read as large-print. Per the user ("treat the PDF as a fixed thing —
>   keep it simple"), the export uses a **fixed 12pt** body (`bodyPointSize`); face + rhythm are
>   still inherited, headings scale up.
> - **`com.apple.security.print` entitlement** (both files) — a sandboxed app can't spool a
>   print job without it ("This application does not support printing"). Export writes a file via
>   the user-selected-file entitlement, so it worked without it; interactive Print did not.
> - **Interactive Print runs synchronously via `run()` in a hosted borderless window**, not the
>   async sheet variant (which tore the offscreen view down mid-print).
> - **White page painted by an `ExportTextView` subclass** — NSTextView's `backgroundColor`
>   isn't carried into the print context. (Content area white; 1" margins render white in normal
>   viewers.)
> - **Block-math orientation fix** (`MathImageOrientation.cgImageBacked`, shared with on-screen)
>   — SwiftMath's image flipped in the non-flipped print context.
> - **Tables + wide diagrams shrink-to-fit** the page (`render(...fitTablesToWidth:)` →
>   `fitColumnPercentages`; mermaid already caps at content width).
> - **Paper sizes expanded** to US Letter / Legal / Tabloid + A4 / A3 / A5.
> - **Export-failure alert is a native SwiftUI `.alert`**, not `NSAlert` (no app-icon modal).

## Problem

Today PDF export exists only as an implicit format in the standard Save As… panel
(`.pdf` is in `LineformDocument.writableContentTypes`), and it produces **plain text**:
`LineformDocument.pdfData()` runs `MarkdownPlainTextConverter.plainText(from:)`, throwing
away every bit of formatting — no headings, bold, tables, diagrams, math, lists. There is
**no Print / ⌘P support at all** (greenfield — no `NSPrintOperation` anywhere).

## Goal

Upgrade PDF export to render the **rich** document (the same output Read mode already
produces via `MarkdownPreviewRenderer`), and add first-class **Print… (⌘P)**. Both produce
the identical rendered page. Per the audit decisions:

- **Always white background, always black text** — regardless of the reader theme (this is
  the export/print page, NOT Read mode; Read mode keeps its themes).
- **Inherit from the reading profile:** font, font size, line height, block (paragraph)
  spacing, letter spacing.
- **Do NOT inherit:** column width, reading ruler, typewriter mode, focus mode, theme.
- **Paper sizes:** US Letter (8.5×11") + A4 as the basics.
- **Images:** mermaid diagrams + block/inline math already render as images and WILL appear
  in the PDF. Real image files stay as the `🖼 alt` placeholder (Task 6 deferred real image
  rendering — PDF ships without them for now, consistent with the tracker note).

## Non-goals

- Real embedded image-file rendering (deferred with Task 6).
- Tagged/PDF-UA accessibility structure. NSTextView printing yields selectable text; full
  PDF/UA tagging is out of scope.
- Any change to Read-mode themes or on-screen rendering.
- Cross-document / batch export.

## Design

### 1. Reuse the Read-mode renderer, forced to white/black — via the profile, no renderer change

`MarkdownPreviewRenderer.render(...)` already turns document text + a `ReadingProfile` into a
single rich `NSAttributedString` (headings, inline styling, fenced code, mermaid/math image
attachments, HR cells, blockquotes, lists, checkbox glyphs, native `NSTextTable`). It derives
its `Theme` internally, in ~5 helpers, all through the single funnel
`Theme.theme(for: profile)`.

**Key realization:** `LineformColors.originalBackground` (#FFFFFF) and `primaryText`
(#1F1F1F) are **static** sRGB colors — not appearance-reactive. So the `.system` ("Original")
theme is a deterministic white page with near-black ink in any app appearance. Therefore we
force white/black **through the profile, not through the renderer**: the export profile is the
user's `activeProfile` with `themeID = .system` and `highContrastEnabled = false`. That
funnels white/#1F1F1F through *every* existing `Theme.theme(for: profile)` call with **zero
changes to `MarkdownPreviewRenderer`** — no missed color site, no threading, byte-identical
on-screen behavior. (An earlier `themeOverride:` parameter was designed and reverted once this
simpler funnel was found.)

"Black text" here means the app's own primary reading ink #1F1F1F on #FFFFFF — the natural
"Original theme" printed look, not pure #000000 (a deliberate, contrast-safe choice matching
the app's typography). `usesDarkChrome == false` for `.system`, so mermaid renders on a
transparent canvas with fixed dark ink and block math renders dark-ink transparent — both
composite cleanly on the white page. No provider changes needed.

Typography is inherited by keeping the user's `activeProfile` fields for
font/size/line-height/paragraph-spacing/letter-spacing (the renderer reads them straight from
the profile). The renderer never reads column width for prose wrapping (the text container's
job — §3), and ruler/typewriter/focus are view-only and never touched by the renderer — so
overriding only `themeID`/`highContrastEnabled` already satisfies "inherit typography, force
white, ignore column/ruler/typewriter."

The `columnWidth:` render argument (used only to cap diagram/math image widths) is set to the
**page content width** (§2) so wide diagrams fit the page.

### 2. Page metrics — `Lineform/Export/DocumentExportRenderer.swift` (new module)

Pure, testable value types:

- `enum ExportPaperSize { case usLetter, a4 }` with `sizeInPoints` (Letter 612×792, A4
  595×842) and a display name.
- Margins: reuse a 72pt (1") margin (matches the current `pdfData()` and print convention).
- `contentSize(for:)` → paper size inset by margins → the width prose wraps to and the width
  passed as `columnWidth`.

These are unit-tested (exact point sizes; content width = paper − 2×margin).

### 3. One shared rich builder, two native consumers

The **lowest-fidelity-risk** path is to lay the rich attributed string into an **offscreen
`NSTextView`** sized to the page content width and let AppKit's native printing handle
pagination, attachment drawing, table cell borders, and paper/margins — NSTextView is the
exact component that already renders these constructs correctly on screen, so fidelity is
inherited, not re-implemented.

`@MainActor func makeExportTextView(text:profile:paper:providers…) -> NSTextView`:
1. `exportProfile = profile.with(themeID: .system, highContrastEnabled: false)` (a small
   copy helper; see §4). `attr = MarkdownPreviewRenderer().render(text, profile:
   exportProfile, columnWidth: contentWidth, mermaidProvider: MermaidImageProvider(),
   mathProvider: MathImageProvider(), diagramLog: NullDiagramFailureLog(), reportRegistry:
   DiagramReportRegistry(), appVersion: <bundle short version>)`.
   (Fresh providers; export uses the null diagram log so it never writes to the failure log.)
2. Build an `NSTextView` with a text container of the content width, non-editable, white
   background, insert the attributed string.

Both consumers build one `NSPrintInfo` (paper size, 72pt margins, `.fit` horizontal
pagination) and use it:

- **Print… (⌘P):** `NSPrintOperation(view: textView, printInfo:)`, `showsPrintPanel = true`,
  run modally against the window. The standard print panel gives the user paper size, copies,
  page range, and the OS "PDF ▸ Save as PDF" for free.
- **Export as PDF…:** an `NSSavePanel` (default name from the document URL, else
  `Untitled.pdf`) with a small **accessory** popup for paper size (Letter / A4, default =
  system default paper). On confirm, run `NSPrintOperation(view: textView, printInfo:)` with
  `showsPrintPanel = false`, `showsProgressPanel = false`,
  `printInfo.jobDisposition = .saveJob`, `printInfo.dictionary[.jobSavingURL] = chosenURL`,
  then `operation.run()` → a paginated rich PDF at the chosen path.

A `@MainActor func pdfData(text:profile:paper:) -> Data` (build the view, run a save-job
operation to a temp file, read the bytes back) exists for unit tests to assert validity and
pagination without the print panel.

### 4. Forcing the white page (the export profile)

No custom theme. The export profile is the user's `activeProfile` with two fields overridden:
`themeID = .system` (deterministic #FFFFFF page / #1F1F1F ink — static colors) and
`highContrastEnabled = false` (otherwise `Theme.theme(for:)` returns dynamic
`.textColor`/`.textBackgroundColor` — white-on-black in a dark app appearance, which would
ruin the page). All typography fields are inherited unchanged. A tiny `ReadingProfile`
copy helper (or inline struct copy) produces it; unit-tested that the two fields flip and the
rest is untouched.

### 5. Menu wiring

`AppCommands` gains a `CommandGroup(replacing: .printItem)` with two buttons in the natural
File-menu Print slot:

- **Print…** — `⌘P` — posts `LineformAppNotification.printDocument` with
  `activeWindowPayload()`.
- **Export as PDF…** — posts `LineformAppNotification.exportPDF` with `activeWindowPayload()`.

Both are **always enabled** (like the existing Save As…, which is not gated). With no key
window the payload has no window number and no view matches → harmless no-op.

`EditorContainerView` handles both via `.onReceive` guarded by
`notificationMatchesActiveWindow` (the established pattern for Rename/Delete/Convert). Each
handler reads `document.text` + `readingProfileStore.activeProfile`, builds the export via
`DocumentExportRenderer`, and presents the print operation / save panel against `activeWindow`.
The command produces the **rich rendered document regardless of current display mode** (you
can Print/Export while in Write mode).

Two new `LineformAppNotification` cases + `Notification.Name` mappings.

### 6. Remove the superseded plain-text PDF path

- Remove `.pdf` from `LineformDocument.writableContentTypes` (Save As no longer offers the
  low-quality plain-text PDF — the dedicated Export command replaces it).
- Remove `LineformDocument.pdfData()` and the `.pdf` case in `data(for:)` (dead after the
  above).
- Update `LineformDocumentTests`: remove `testDocumentCanRenderPDFDataForSavePanel`,
  `testPDFExportPaginatesLongDocuments`, the `writableContentTypes.contains(.pdf)` assertion,
  and the two `recordsSourceSave(for: .pdf)` assertions. Their coverage moves to new
  `DocumentExportRendererTests` (rich, paginated, white-forced).

This avoids two competing PDF routes.

## Testing

**Pure/deterministic unit tests (default plan) — `DocumentExportRendererTests`:**
- Paper sizes: Letter = 612×792, A4 = 595×842; content width = paper width − 144.
- `Theme.exportWhite`: white bg, black text.
- Export profile: given a profile with `themeID = .night` + `highContrastEnabled = true`, the
  derived export profile has `themeID = .system`, `highContrastEnabled = false`, and identical
  typography fields; the rendered attributed string's sampled `.foregroundColor` is the
  static #1F1F1F ink (not the night theme's) — i.e. white-page forcing works.
- `pdfData(...)` for a normal doc → bytes start with `%PDF`, > 100 bytes, CGPDFDocument opens.
- `pdfData(...)` for a long doc → `CGPDFDocument.numberOfPages > 1` (preserves the old
  pagination assertion, now on the rich path).
- Export profile inheritance: font/size/line-height/paragraph-spacing/letter-spacing on the
  export attributed string match the profile; a non-default `columnWidth`/ruler/typewriter on
  the profile does not change the rendered prose width (wrapping is container-driven).

**Manual QA (report honestly what was/wasn't exercised):**
- ⌘P opens the print panel; paper size selectable; preview shows rich output (heading sizes,
  bold/italic, a table, a mermaid diagram, block math, a list, a blockquote, a checkbox).
- White page + black text even when the app is on a dark theme (night).
- Export as PDF… writes a file at the chosen path with Letter and with A4; open it — rich,
  white, paginated.
- Print/Export an **untitled** (never-saved) doc works.
- Image `![alt](url)` shows as the `🖼 alt` placeholder in the PDF (not a broken image).

## Risks & mitigations

- **NSPrintOperation-to-file in a unit test could be slow/flaky in CI.** Mitigation: the
  operation runs synchronously (`operation.run()`) to a temp file in-process; if it proves
  flaky, move only the two byte-producing tests to the hosted plan and keep the pure metric/
  theme/profile tests in the default plan. (Decide during implementation from actual runs.)
- **Fidelity of tables/attachments in the printed output** is inherited from NSTextView (the
  on-screen renderer), so it can't diverge from what Read mode shows — the reason for the
  offscreen-NSTextView approach over hand-rolled CGContext pagination.
## Known limitations (accepted)

- **Interactive Print + mid-print paper change:** the offscreen view is built for
  `defaultExportPaperSize` before the panel opens. Prose/tables re-paginate to the chosen paper
  (live text), but rasterized mermaid/math images keep their fitted width — changing paper size
  in the panel on a diagram-heavy doc may scale those images slightly. Export as PDF (paper
  chosen up front) is unaffected. Cosmetic; not worth rebuilding the view on every panel change.
- **Synchronous generation:** `operation.run()` runs on the main actor inside the save-panel
  completion. For a huge diagram-heavy doc this briefly blocks the UI — acceptable for a
  deliberate user action.
- **Print-subsystem test placement:** the PDF-byte tests invoke `NSPrintOperation`, whose OS
  cold start is nondeterministic; they live in the hosted (opt-in) plan so the default suite
  stays fast/deterministic. (Note: a separate, PRE-EXISTING intermittent ~210s full-run stall in
  `ReleaseResourceTests` was observed and confirmed at the base commit with this work stashed —
  it is not caused by this change.)

## Files

- New: `Lineform/Preview/DocumentExportRenderer.swift` (placed in the existing **Preview**
  group — it reuses the preview renderer; avoids a new pbxproj group),
  `LineformTests/DocumentExportRendererTests.swift`. Wired via the standard 4 pbxproj sections
  with sequential IDs `…325` / `…326`.
- Edit: `AppCommands.swift` (+2 buttons), `LineformAppNotification.swift` (+2 cases),
  `EditorContainerView.swift` (+2 handlers), `LineformDocument.swift` (remove plain-text PDF),
  `LineformDocumentTests.swift` (remove old PDF tests). **No change to
  `MarkdownPreviewRenderer.swift` or `Theme.swift`** — white forcing is via the export profile.
