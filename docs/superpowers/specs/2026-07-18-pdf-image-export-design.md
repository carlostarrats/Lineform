# Real Image Files in Styled PDF Export — Design

**Date:** 2026-07-18
**Status:** Approved (pending spec review)

## Problem

Styled PDF export renders the document the way Read mode does — styled headings, tables,
mermaid diagrams, and math all appear as they do on screen. **Real image files (`![alt](path)`)
are the one exception:** they export as the `🖼` placeholder, a deliberate v1 deferral
(`DocumentExportRenderer` line 59). On screen those same images render as the actual picture
(`MarkdownPreviewRenderer.appendImageBlock`). The gap makes exported PDFs feel incomplete —
the diagram and the equation made it into the PDF, but the photo next to them didn't.

Two secondary problems this fixes:

1. **The Save As format popup gives no hint** what "PDF" vs "Styled PDF" mean. A user picking a
   format is guessing.
2. **A missing / out-of-scope image reads as "broken."** If an image can't be reached, silently
   dropping it to a placeholder leaves the user thinking export is broken, with no explanation of
   why or how to fix it.

## Scope

**In scope:**
- Real local image files render in **Styled PDF** export and **Print (⌘P)** (both use the
  `.styled` preset / `rendersMarkdown: true`).
- A short, format-specific **description line** under the Save As Format popup.
- A **consolidated grant-access prompt** for images the app can't currently reach, with
  plain-English text explaining why.

**Out of scope (unchanged):**
- **Normal PDF** (`.standard`, `rendersMarkdown: false`) stays pure raw markdown source — the
  image reference stays `![alt](path)` text, exactly as it treats `**bold**`, headings, and
  mermaid. (Confirmed with user: "Styled only.")
- **RTF** stays `imagesAsText: true` — plain RTF can't portably embed images; unchanged.
- **Remote `http(s)`/`data:` images** are never fetched — always placeholder. Preserves the
  network-free invariant. They never trigger the grant prompt.

## Why this is small

The rendering machinery already exists and already ships. `MarkdownPreviewRenderer.render(...)`
takes two arguments that the export path currently leaves at their disabled defaults:

- `documentDirectory: URL?` (default `nil`) — needed to resolve relative image paths.
- `imageProvider: ImageAttachmentProviding` (default `DisabledImageAttachmentProvider()`) — the
  seam that actually loads a file into a raster attachment.

On screen these are set to `currentFileURL`'s directory and a live `ImageAttachmentProvider()`;
the resulting `BlockRenderedAttachment` rasters print through `NSPrintOperation` exactly like the
mermaid/math attachments already do. So the core change is **threading the document directory and
a real image provider into the Styled export/print path.**

## Sandbox model — "what you see is what you export"

macOS sandboxes file reads: the app can only read files inside a granted security scope. Export
runs **in the app process**, so it inherits the same scopes the app already holds:

- The **workspace root** scope is held for the app's lifetime by `OutlineFileBrowserStore`.
- Any scope a prior on-screen **Reconnect** granted is still active for the session.

Therefore an image that renders in Read mode renders in the Styled PDF, with **no prompt** — the
normal case (images living beside the notes in the workspace) is fully frictionless.

## Out-of-scope / missing images — consolidated grant prompt

`ImageResolver.resolve` returns `.localFile(url)` only for paths the app can `stat`. Under the
sandbox, a file that exists but sits outside every granted scope returns `.unresolved` — the
**same** result as a genuinely missing file. The app cannot distinguish "missing" from "exists
but no permission." The design accepts this and phrases everything as **"can't be found in
folders Lineform can access,"** which is honest for both cases.

**Flow (Styled PDF export and Print):**

1. **Pre-flight scan.** Before generating the PDF, enumerate every image reference in the
   document (a pure helper reusing the existing image regex). Classify each with
   `ImageResolver.resolve(path:documentDirectory:)` against the current scopes. Partition into:
   - **remote** → always placeholder, never prompts;
   - **resolvable local** → will render;
   - **unresolvable local** (non-remote, `.unresolved`) → candidates for the prompt.
2. **If, and only if, there is at least one unresolvable local reference**, present **one**
   prompt (not one per image):

   > *"This document uses N image(s) stored outside the folders Lineform can access (for example,
   > your Desktop). Grant access to include them in the PDF, or continue without them."*
   >
   > **[ Grant Access… ]  [ Continue Without ]**

3. **Grant Access…** opens a single `NSOpenPanel` (`canChooseDirectories = true`,
   `allowsMultipleSelection = true`, an explanatory `message`). Selecting a folder grants a scope
   covering every image beneath it in one pick; selecting files grants those files. The panel's
   granted URLs are retained for the export (process-lifetime scope — sufficient to complete the
   render).
4. **Re-resolve and export.** After granting, references that now resolve render; any still
   unresolvable (genuine typos / missing files, or not covered by the grant) stay the placeholder.
   Export proceeds either way.
5. **Continue Without** → skip the panel, export with the unresolvable images as placeholders.
   The on-screen **Reconnect** button remains the other route to fix an individual image.

**Prompt surface:** the explanatory step is the `NSOpenPanel`'s own `message` text plus its
Cancel button (Cancel = "Continue Without"), so there is exactly **one** surface — no separate
`NSAlert` (which stamps the app icon, per project convention) and no extra SwiftUI alert. If a
richer two-button explanation is wanted, it becomes an in-window SwiftUI `.alert` leading into the
panel; the default is the single-panel form for minimum surface area.

**Zero-friction guarantee:** the scan and prompt only run for Styled PDF / Print, and the prompt
only appears when an unresolvable local image actually exists. In-scope documents (the common
case) see no new behavior beyond their images now appearing.

## Save As Format description line

Add a single `NSTextField` (wrapping, secondary label color) beneath the Format popup in
`SaveAsPanelController`'s accessory `NSStackView`. Its text updates in `syncPanel()` as the format
changes:

| Format | Description |
|---|---|
| Markdown (.md) | "The editable source file." |
| PDF | "Plain markdown source — shows `#`, `**` as typed." |
| Styled PDF | "Rendered like Read mode — with images, tables, math & diagrams." |
| Rich Text (.rtf) | "Styled text for Word, Pages & Google Docs." |

Copy is final-pass; keep each to one short line so the accessory keeps hugging its content and
`NSSavePanel` keeps centering it (do not pin it full-width — that left-aligns it, per the existing
comment in `SaveAsPanelController.makeAccessory`).

## Components & changes

- **`DocumentExportRenderer`** (`Lineform/Preview/DocumentExportRenderer.swift`)
  - `makeExportTextView`, `runOperation`, `runInteractivePrint`, `writePDF`, `pdfData` gain a
    `documentDirectory: URL?` parameter (default `nil`, so existing test/callers are unchanged and
    fall back to placeholder).
  - When `preset.rendersMarkdown` (Styled), pass `documentDirectory` and a real
    `ImageAttachmentProvider()` into `render(...)`. Normal (`rendersMarkdown == false`) and RTF are
    untouched.
  - Update the type doc comment (line 59) to reflect that Styled export now renders local images.
- **New pure helper** — image reference enumeration (e.g. `ImageExportPreflight` in
  `Lineform/Preview`). Given the document text + `documentDirectory`, returns the list of
  unresolvable local references (paths + source ranges). Reuses the existing image regex; pure and
  unit-testable, no filesystem writes.
- **`EditorContainerView`** (`Lineform/Editor/EditorContainerView.swift`)
  - `saveAsDocument()` `.pdf/.styledPDF` branch and `printCurrentDocument()`: for the Styled path,
    run the pre-flight scan; if unresolvable local images exist, present the grant prompt, retain
    granted scopes, then call `writePDF` / `runInteractivePrint` with
    `documentDirectory: currentFileURL?.deletingLastPathComponent()`.
  - Normal PDF and RTF branches unchanged.
- **`SaveAsPanelController`** (`Lineform/Editor/SaveAsExport.swift`)
  - Add the description `NSTextField`; update its `stringValue` in `syncPanel()`.

## Testing

- **Pure (default plan):**
  - `ImageExportPreflight` — enumerates references, correctly partitions remote / resolvable /
    unresolvable, honors relative-vs-absolute paths, ignores non-image extensions.
  - `SaveAsFormat` description text mapping (each format → its line).
  - `DocumentExportRenderer` Styled path builds an attributed string containing a rendered image
    attachment when handed a resolvable `documentDirectory` + a stub provider; and a placeholder
    when handed the disabled provider — proving the wiring without the print subsystem.
- **Hosted plan (`LineformHosted`, PDF-byte):** extend `DocumentExportPDFHostedTests` to assert a
  Styled PDF of a doc with a resolvable local image is larger than / differs from the same doc
  exported with the disabled provider (image bytes present). Keep in the hosted plan — it invokes
  `NSPrintOperation`.
- The grant-panel interaction (NSOpenPanel) is not unit-tested (UI dialog); the pre-flight
  decision that *drives* it is (the pure helper).

## Risks & non-goals

- **Detection ambiguity** (missing vs out-of-scope) is accepted and handled by neutral copy;
  granting access is offered as the fix and a genuine typo simply stays a placeholder.
- **Scope persistence across launches** is not added here — the granted scope lasts the session,
  which is all an export needs. Persisting via security-scoped bookmarks is a possible later
  follow-up, not required.
- **Normal PDF and RTF image behavior is intentionally unchanged.**
- No new entitlement (`user-selected.read-write` already covers the picked files; the workspace
  scope already covers in-workspace images).
