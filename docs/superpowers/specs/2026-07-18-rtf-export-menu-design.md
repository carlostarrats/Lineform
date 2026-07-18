# RTF export + "Export As" menu grouping

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** D

## Problem

Portability is a core Lineform principle ("documents outlive the app"). PDF export + Print
already ship, but writers frequently hand work to editors/collaborators on Word, and a
styled-text export (that Word opens) is the natural next portability step. Today "Export as
PDF…" sits as a standalone File-menu item; the user wants the export formats **grouped** in one
place.

**DOCX is explicitly dropped.** It has no native writer (would need a dependency or hand-rolled
Open XML), and **RTF fully covers the need**: Word, Pages, Google Docs, and TextEdit all open
`.rtf` cleanly. Real `.docx` would only buy the literal extension at a large cost; if ever
demanded it gets its own future spec.

## Decisions

- **Add RTF export**, reusing the existing export renderer. Keep PDF + Print.
- **Regroup the File menu:** Print… (⌘P) stays; "Export as PDF…" and the new "Rich Text
  (RTF)…" move under a **File ▸ Export As** submenu.
- **Export body matches PDF:** fixed 12pt document size (a saved artifact reads like a normal
  document, not the on-screen reading size), forced light `.system` theme, dark ink — identical
  to the PDF export profile.
- **RTF image limitation (accepted, documented):** plain `.rtf` can't portably embed images, so
  **math and mermaid blocks export as their caption / source text**, not as pictures. Everything
  textual — headings, paragraphs, lists, blockquotes, callouts, inline bold/italic/code/strike —
  carries cleanly. This covers the "hand it to an editor" use case; diagram-heavy documents
  should use PDF (noted in the RTF save context if practical).
- **Tables:** best-effort `NSTextTable` RTF serialization; may flatten in some editors.
  Acceptable — honest, not silently broken.

## Architecture

### 1. `DocumentExportRenderer` — add RTF path

`DocumentExportRenderer` (`Lineform/Preview/DocumentExportRenderer.swift`) already produces a
rendered attributed string via `MarkdownPreviewRenderer` for the PDF/print `NSPrintOperation`.
Add:

```swift
extension DocumentExportRenderer {
    /// Rendered document as RTF data. Reuses the export ReadingProfile (12pt, .system, dark ink)
    /// and the shared renderer, but with `imagesAsText: true` so math/mermaid become caption
    /// text (RTF can't portably embed images). Serialized with NSAttributedString RTF writer.
    func rtfData(for document: LineformDocument) throws -> Data
}
```

Implementation:
- Build the export attributed string exactly as the PDF path does, but thread a new
  **`imagesAsText: Bool`** flag through `MarkdownPreviewRenderer` (sibling of the existing
  `highlightsCode` / `fitTablesToWidth` export flags): when true, math/mermaid blocks append
  their caption/source text instead of a rasterized `NSTextAttachment`.
- `attributedString.data(from: NSRange(location:0, length:length),
  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])`.
- No `NSPrintOperation`, no offscreen window — pure serialization (also avoids the print-subsystem
  cold-start nondeterminism that quarantines the PDF-byte tests).

### 2. Menu — `AppCommands.swift`

Restructure the existing `CommandGroup(replacing: .printItem)` (`AppCommands.swift:313-322`):

```swift
CommandGroup(replacing: .printItem) {
    Button(printCommandTitle) { … printDocument … }
        .keyboardShortcut("p", modifiers: .command)

    Menu("Export As") {
        Button("PDF…")             { … exportPDF … }   // existing path
        Button("Rich Text (RTF)…") { … exportRTF … }   // new
    }
}
```

Add `LineformAppNotification.exportRTF` (mirroring `exportPDF`), posting the window-scoped
active-window payload. Titles live in `AppMenuConfiguration`.

### 3. Handling — `EditorContainerView`

Add an `exportRTF` receiver (sibling of the `exportPDF` handler): present an `NSSavePanel`
with `allowedContentTypes = [.rtf]`, default filename from the document, then write
`try DocumentExportRenderer().rtfData(for:)`. On write failure, show the app's native in-window
SwiftUI `.alert` (never `NSAlert`) — same as PDF export.

## Testing

- **Unit / default plan (RTF is pure serialization — no print subsystem, so NOT hosted):**
  - `rtfData(for:)` produces non-empty RTF that round-trips: re-read via `NSAttributedString`
    and assert headings, bold/italic, lists, blockquotes, callouts, and inline code survive as
    styled runs.
  - `imagesAsText: true` → no image attachments in the output; math/mermaid appear as their
    caption/source text.
  - The `imagesAsText` flag does not alter the PDF/on-screen path (`false` default keeps existing
    renders byte-identical — extend the existing renderer tests).
- **Manual:** export a rich document to RTF; open in TextEdit, Pages, and Word; confirm styling;
  confirm diagram-heavy docs degrade to caption text (and PDF still embeds the diagrams).

## Out of scope

- Real `.docx` (dropped; separate future spec only if the literal extension is demanded).
- Embedding images in RTF via `.rtfd` bundles (Apple-specific, less portable — revisit only if
  users specifically want diagram images in RTF).
- EPUB and other formats (entry — after this, if ever).
- Changing the PDF export or Print behavior.

## Risk

Low. RTF is native `NSAttributedString` serialization reusing the established export renderer;
the only shared-render change is the additive `imagesAsText` flag (default false → existing paths
unchanged). No new dependency, no entitlement, no print-subsystem involvement.
