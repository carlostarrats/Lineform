# Plan — Rich PDF Export + Print (Task 7)

Spec: `docs/superpowers/specs/2026-07-04-pdf-export-print-design.md`. Branch
`work-2026-07-04-10`. Order below is the implementation sequence.

1. **White forcing via profile (no renderer/theme change).** `.system` theme is static
   #FFFFFF/#1F1F1F. Export profile = `activeProfile` with `themeID = .system` +
   `highContrastEnabled = false`. Funnels through the existing `Theme.theme(for: profile)`.

2. *(folded into step 3 — the export-profile derivation helper lives in DocumentExportRenderer.)*

3. **`DocumentExportRenderer`** (`Lineform/Preview/`, in the existing Preview group):
   - `exportProfile(from:)` → copy with `themeID = .system`, `highContrastEnabled = false`.
   - `ExportPaperSize` (usLetter 612×792, a4 595×842; `displayName`; `sizeInPoints`).
   - margin 72pt; `contentSize(for:)`.
   - `@MainActor makeExportTextView(text:profile:paper:) -> NSTextView` (rich string via
     renderer with the export profile, container = content width, white bg, non-editable).
   - `@MainActor makePrintOperation(text:profile:paper:jobSavingURL:) -> NSPrintOperation`
     (shared: builds view + NSPrintInfo; save-job when URL given, else interactive).
   - `@MainActor pdfData(text:profile:paper:) -> Data` (save-job to temp file, read back).

4. **Menu.** `AppCommands`: `CommandGroup(replacing: .printItem)` → Print… (⌘P) + Export as
   PDF…, both post new notifications with `activeWindowPayload()`. Add
   `LineformAppNotification.printDocument` / `.exportPDF` cases + names.

5. **Handlers.** `EditorContainerView`: `.onReceive` for both, window-matched. Print → run
   `makePrintOperation(...)` modal against `activeWindow`. Export → NSSavePanel (name from
   URL/`Untitled.pdf`, paper-size accessory popup) → save-job operation.

6. **Remove plain-text PDF.** `LineformDocument`: drop `.pdf` from `writableContentTypes`,
   delete `pdfData()` + `.pdf` case in `data(for:)`. Update `LineformDocumentTests`.

7. **Tests.** `DocumentExportRendererTests`: paper sizes, content width, `exportWhite`,
   theme-override forces black on a night profile, `pdfData` valid + multi-page, profile
   typography inheritance. Wire new files into pbxproj (Export group).

8. **Verify.** Default suite serial (Xcode quit; warn re TCC). Manual QA per spec. Code review
   + fix loop. Docs (CLAUDE.md main-features + README if warranted). Mark tracker done. Commit.
