# RTF Export + Export-As Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Rich Text (RTF) export path that reuses the existing document export renderer, and regroup the File menu so "Export as PDF…" and the new "Rich Text (RTF)…" live under a **File ▸ Export As** submenu (Print… ⌘P stays put). RTF exports styled text (headings, bold/italic/code/strike, lists, blockquotes, callouts, tables) that Word/Pages/Google Docs/TextEdit all open; math and mermaid degrade to caption/source text because plain `.rtf` can't portably embed images. DOCX is dropped.

**Architecture:** One additive `imagesAsText: Bool = false` flag threaded through `MarkdownPreviewRenderer.render(...)` (sibling of `fitTablesToWidth`) that makes the math/mermaid emitters append caption+source text instead of a rasterized `NSTextAttachment`. `DocumentExportRenderer.rtfData(for:)` builds the export attributed string with that flag on (reusing the same export `ReadingProfile`: 12pt, `.system`, dark ink) and serializes via `NSAttributedString.data(from:documentAttributes:)` with `.rtf` — no `NSPrintOperation`, no offscreen window, so RTF tests are pure and live in the DEFAULT plan. Menu: restructure the existing `CommandGroup(replacing: .printItem)`; add `LineformAppNotification.exportRTF`. Handler: `EditorContainerView` gets an `exportRTF` receiver presenting an `NSSavePanel([.rtf])` and reusing the native SwiftUI `.alert` failure path.

**Tech Stack:** Swift, AppKit (NSAttributedString RTF), SwiftUI, XCTest

## Global Constraints
- RTF only — DOCX dropped. No new dependency, no entitlement, no print-subsystem involvement.
- Reuse the existing export renderer + export `ReadingProfile` (`DocumentExportRenderer.exportProfile(from:)` → 12pt body, `.system` theme, dark ink, high-contrast cleared).
- `imagesAsText:true` for RTF (math/mermaid → their caption + source text); **default `false` keeps the PDF/on-screen render byte-identical** — this is the load-bearing invariant of Task 1.
- The `imagesAsText` flag is additive and threads through the private emitters (`appendMermaidBlock`, `appendMathBlock`, `appendInlineMath`, and their `appendLines`/`appendBlockquote`/`appendList` callers). It must NOT change any output when `false`.
- RTF is pure `NSAttributedString` serialization — **its tests go in the DEFAULT plan** (`DocumentExportRendererTests`), never the hosted plan. Do not touch `DocumentExportPDFHostedTests` or either `.xctestplan`.
- Export write failure → the app's native in-window SwiftUI `.alert` (never `NSAlert`). Reuse the existing PDF-export alert plumbing pattern.
- Tables serialize best-effort via `NSTextTable`'s RTF writer (may flatten in some editors — accepted, honest).
- Follow existing patterns: window-scoped notification + `activeWindowPayload()`, `notificationMatchesActiveWindow(_:)` guard, `AppMenuConfiguration` string constants.
- Do NOT commit (per task instruction). Run the per-task verification command; run the full default plan on the final task.
- Menu/handler tasks (3, 4) are UI-wiring and are **manual-verified** (SwiftUI `Commands`/`NSSavePanel` are not unit-testable here); the two logic tasks (1, 2) carry the automated coverage.

Verification command template (single test):
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<ClassName>/<testName>
```
NOTE (from CLAUDE.md): a CLI `xcodebuild test` re-signs the host ad-hoc and can trigger a one-time TCC "access Documents" prompt — warn the user and have them click Allow; do not run unattended.

---

## Task 1 — Thread `imagesAsText` through `MarkdownPreviewRenderer`

Add an additive `imagesAsText: Bool = false` parameter to `render(...)` and thread it to the mermaid/math emitters. When `true`, math (block + inline) and mermaid blocks append their caption + source text (the existing fallback rendering) instead of a rasterized attachment. When `false` (default), output is byte-identical to today.

**Files:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift` (impl)
- `LineformTests/MarkdownPreviewRendererTests.swift` (tests)

**Interfaces (exact signatures):**
```swift
// New parameter on the primary render entry point (sibling of fitTablesToWidth):
func render(
    _ text: String,
    profile: ReadingProfile,
    columnWidth: CGFloat,
    mermaidProvider: MermaidImageProviding,
    mathProvider: MathImageProviding,
    diagramLog: DiagramFailureLogging,
    reportRegistry: DiagramReportRegistry,
    appVersion: String,
    fitTablesToWidth: Bool = false,
    imagesAsText: Bool = false
) -> NSAttributedString
```
The flag is threaded into these private emitters, each gaining an `imagesAsText: Bool` parameter (default `false` where practical, but always passed explicitly from `render`):
```swift
private func appendMermaidBlock(..., appVersion: String, imagesAsText: Bool)
private func appendMathBlock(..., mathProvider: MathImageProviding, imagesAsText: Bool)
private func appendInlineMath(_ span: MathSpan, ..., mathProvider: MathImageProviding, imagesAsText: Bool)
// plus appendLines / appendBlockquote / appendList gain `imagesAsText: Bool` to forward to inline math.
```

**Behavior when `imagesAsText == true`:**
- `appendMermaidBlock`: skip `mermaidProvider.outcome(...)` entirely and call `appendMermaidFallback(source:to:profile:codeAttributes:reportHash: nil)` (caption "Mermaid diagram (source)" + source, no "Report this" link — there is no failure and no network in an export).
- `appendMathBlock`: skip the provider and call `appendMathFallback(latex:to:profile:codeAttributes:)` (caption "Math (source)" + latex).
- `appendInlineMath`: skip the provider and take the existing `else` branch — append `span.latex` in the monospaced code attributes (no attachment).

**TDD steps:**

- [ ] Write a failing test `testImagesAsTextDefaultFalseStillProducesMathAttachment` in `MarkdownPreviewRendererTests.swift`. Render block math with a real provider and assert an attachment IS present (locks the default-unchanged path):
```swift
func testImagesAsTextDefaultFalseStillProducesMathAttachment() {
    let rendered = MarkdownPreviewRenderer().render(
        "$$x^2$$",
        profile: .original,
        columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: MathImageProvider(),
        diagramLog: NullDiagramFailureLog(),
        reportRegistry: DiagramReportRegistry(),
        appVersion: "0"
        // imagesAsText omitted → defaults to false
    )
    var attachmentCount = 0
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
        if value != nil { attachmentCount += 1 }
    }
    XCTAssertGreaterThan(attachmentCount, 0, "Default (imagesAsText:false) must still rasterize math to an attachment")
}
```
- [ ] Run to fail (the method won't compile yet if you also add the flag; if it compiles because the param defaults, this test should PASS immediately since it asserts existing behavior — that's fine, it's the guard test. The real red comes from the next test).
- [ ] Write a failing test `testImagesAsTextSubstitutesMathSourceTextWithNoAttachment`:
```swift
func testImagesAsTextSubstitutesMathSourceTextWithNoAttachment() {
    let rendered = MarkdownPreviewRenderer().render(
        "$$x^2$$",
        profile: .original,
        columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: MathImageProvider(),
        diagramLog: NullDiagramFailureLog(),
        reportRegistry: DiagramReportRegistry(),
        appVersion: "0",
        imagesAsText: true
    )
    var attachmentCount = 0
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
        if value != nil { attachmentCount += 1 }
    }
    XCTAssertEqual(attachmentCount, 0, "imagesAsText:true must not emit image attachments")
    XCTAssertTrue(rendered.string.contains("Math (source)"), "caption present")
    XCTAssertTrue(rendered.string.contains("x^2"), "latex source present as text")
}
```
- [ ] Run to fail (expect a compile error: `render` has no `imagesAsText:` argument).
- [ ] Write a failing test `testImagesAsTextSubstitutesMermaidSourceText`:
```swift
func testImagesAsTextSubstitutesMermaidSourceText() {
    let rendered = MarkdownPreviewRenderer().render(
        "```mermaid\nflowchart TD\nA-->B\n```",
        profile: .original,
        columnWidth: 600,
        mermaidProvider: MermaidImageProvider(),
        mathProvider: DisabledMathImageProvider(),
        diagramLog: NullDiagramFailureLog(),
        reportRegistry: DiagramReportRegistry(),
        appVersion: "0",
        imagesAsText: true
    )
    var attachmentCount = 0
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
        if value != nil { attachmentCount += 1 }
    }
    XCTAssertEqual(attachmentCount, 0, "imagesAsText:true must not emit mermaid image attachments")
    XCTAssertTrue(rendered.string.contains("Mermaid diagram (source)"))
    XCTAssertTrue(rendered.string.contains("flowchart TD"))
    XCTAssertFalse(rendered.string.contains("Report this"), "no report affordance in export text mode")
}
```
- [ ] Write a failing test `testImagesAsTextSubstitutesInlineMathAsSourceText`:
```swift
func testImagesAsTextSubstitutesInlineMathAsSourceText() {
    let rendered = MarkdownPreviewRenderer().render(
        "before $a+b$ after",
        profile: .original,
        columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: MathImageProvider(),
        diagramLog: NullDiagramFailureLog(),
        reportRegistry: DiagramReportRegistry(),
        appVersion: "0",
        imagesAsText: true
    )
    var attachmentCount = 0
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
        if value != nil { attachmentCount += 1 }
    }
    XCTAssertEqual(attachmentCount, 0)
    XCTAssertTrue(rendered.string.contains("a+b"), "inline latex rendered as text")
}
```
- [ ] Run to fail.
- [ ] Implement: add `imagesAsText: Bool = false` to `render(...)`'s signature (after `fitTablesToWidth`). Thread it into the `switch block` cases:
  - `.singleLineMath` / `.fencedMath` → pass `imagesAsText: imagesAsText` to `appendMathBlock`.
  - `.mermaid` → pass `imagesAsText: imagesAsText` to `appendMermaidBlock`.
  - `.lines` / `.blockquote` / `.list` → pass `imagesAsText: imagesAsText` to `appendLines` / `appendBlockquote` / `appendList` so it reaches inline math.
- [ ] Implement the emitter guards:
  - In `appendMermaidBlock`, at the top: `if imagesAsText { appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes, reportHash: nil); return }` before touching `mermaidProvider`.
  - In `appendMathBlock`, at the top: `if imagesAsText { appendMathFallback(latex: latex, to: output, profile: profile, codeAttributes: codeAttributes); return }`.
  - In `appendInlineMath`, at the top: `if imagesAsText { var codeAttrs = baseAttributes; codeAttrs[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular); output.append(NSAttributedString(string: span.latex, attributes: codeAttrs)); return }` (mirrors the existing `else` branch).
  - Add the `imagesAsText: Bool` parameter to `appendLines`, `appendBlockquote`, `appendList` signatures and forward it to their inline-math call sites (the calls that reach `appendInlineMath`). The convenience `render(_:profile:)` overload passes nothing (default false).
- [ ] Run each new test to pass:
  - `-only-testing:LineformTests/MarkdownPreviewRendererTests/testImagesAsTextDefaultFalseStillProducesMathAttachment`
  - `-only-testing:LineformTests/MarkdownPreviewRendererTests/testImagesAsTextSubstitutesMathSourceTextWithNoAttachment`
  - `-only-testing:LineformTests/MarkdownPreviewRendererTests/testImagesAsTextSubstitutesMermaidSourceText`
  - `-only-testing:LineformTests/MarkdownPreviewRendererTests/testImagesAsTextSubstitutesInlineMathAsSourceText`
- [ ] Run the whole `MarkdownPreviewRendererTests` class to prove nothing else regressed (the byte-identical invariant):
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownPreviewRendererTests
```
- [ ] Do not commit (per instructions). Note completion.

---

## Task 2 — `DocumentExportRenderer.rtfData(for:)` + round-trip tests

Add a pure RTF serializer that builds the export attributed string exactly as the PDF path does (same `exportProfile`, same content width from the default paper) but with `imagesAsText: true`, then serializes to `.rtf` `Data`. No `NSPrintOperation`, no window.

**Files:**
- `Lineform/Preview/DocumentExportRenderer.swift` (impl — new extension method + a shared attributed-string builder)
- `LineformTests/DocumentExportRendererTests.swift` (tests — DEFAULT plan)

**Interfaces (exact signatures):**
```swift
extension DocumentExportRenderer {
    /// The rendered export attributed string for RTF (text-only: math/mermaid become caption/source
    /// text). Reuses the export ReadingProfile and content width; no attachments.
    @MainActor
    static func makeRTFAttributedString(text: String, profile: ReadingProfile, paper: ExportPaperSize) -> NSAttributedString

    /// Rendered document as RTF data. Pure NSAttributedString serialization — no print subsystem.
    @MainActor
    static func rtfData(for document: LineformDocument, profile: ReadingProfile, paper: ExportPaperSize) throws -> Data
}
```
Notes on signature choice: the spec sketches `rtfData(for document:) throws -> Data`; the concrete app has no ambient profile inside `DocumentExportRenderer` (the PDF path takes `profile`/`paper` as arguments from `EditorContainerView`). Keep the same explicit-argument shape as `writePDF(text:profile:paper:to:)` for consistency — pass `profile` and `paper` in. `paper` only determines the wrap `contentSize(for:).width` (RTF has no fixed page, but the renderer needs a column width; use the default paper's content width, matching PDF).

**Serialization body:**
```swift
static func makeRTFAttributedString(text: String, profile: ReadingProfile, paper: ExportPaperSize) -> NSAttributedString {
    let content = contentSize(for: paper)
    return MarkdownPreviewRenderer().render(
        text,
        profile: exportProfile(from: profile),
        columnWidth: content.width,
        mermaidProvider: DisabledMermaidImageProvider(),  // never rasterize; imagesAsText short-circuits anyway
        mathProvider: DisabledMathImageProvider(),
        diagramLog: NullDiagramFailureLog(),
        reportRegistry: DiagramReportRegistry(),
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        fitTablesToWidth: true,
        imagesAsText: true
    )
}

static func rtfData(for document: LineformDocument, profile: ReadingProfile, paper: ExportPaperSize) throws -> Data {
    let attributed = makeRTFAttributedString(text: document.text, profile: profile, paper: paper)
    return try attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
}
```
(Use disabled providers since `imagesAsText:true` never calls them — belt-and-suspenders, and keeps the method print-free with no screen dependency.)

**TDD steps:**

- [ ] Write failing test `testRTFDataIsNonEmptyAndReadableRTF` in `DocumentExportRendererTests.swift`:
```swift
func testRTFDataIsNonEmptyAndReadableRTF() throws {
    let doc = LineformDocument(text: "# Heading\n\nBody paragraph.")
    let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
    XCTAssertFalse(data.isEmpty)
    // RTF documents start with the "{\rtf" control word.
    let prefix = String(data: data.prefix(5), encoding: .ascii)
    XCTAssertEqual(prefix, "{\\rtf")
    // Round-trips back into an attributed string.
    let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
    XCTAssertTrue(reread.string.contains("Heading"))
    XCTAssertTrue(reread.string.contains("Body paragraph."))
}
```
- [ ] Run to fail (compile error: no `rtfData`).
- [ ] Write failing test `testRTFRoundTripPreservesBoldItalicAndInlineCode`:
```swift
func testRTFRoundTripPreservesBoldItalicAndInlineCode() throws {
    let doc = LineformDocument(text: "This is **bold** and *italic* and `code` text.")
    let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
    let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))

    func hasTrait(_ trait: NSFontDescriptor.SymbolicTraits, around substring: String) -> Bool {
        let ns = reread.string as NSString
        let r = ns.range(of: substring)
        guard r.location != NSNotFound else { return false }
        var found = false
        reread.enumerateAttribute(.font, in: r) { value, _, _ in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(trait) { found = true }
        }
        return found
    }
    XCTAssertTrue(hasTrait(.bold, around: "bold"), "bold run survives RTF round-trip")
    XCTAssertTrue(hasTrait(.italic, around: "italic"), "italic run survives RTF round-trip")
    // Inline code renders in a monospaced face.
    let ns = reread.string as NSString
    let codeRange = ns.range(of: "code")
    var monospaced = false
    reread.enumerateAttribute(.font, in: codeRange) { value, _, _ in
        if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.monoSpace) { monospaced = true }
    }
    XCTAssertTrue(monospaced, "inline code keeps a monospaced font through RTF")
}
```
  - NOTE: if the app's inline-code face doesn't set the `.monoSpace` symbolic trait after round-trip, relax the code assertion to `font.isFixedPitch` or assert the code text is simply present; verify against the actual rendered attributes during implementation rather than guessing. Keep the bold/italic assertions firm.
- [ ] Write failing test `testRTFHasNoImageAttachmentsForMathAndMermaid`:
```swift
func testRTFHasNoImageAttachmentsForMathAndMermaid() throws {
    let doc = LineformDocument(text: "$$x^2$$\n\n```mermaid\nflowchart TD\nA-->B\n```")
    let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
    let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
    var attachmentCount = 0
    reread.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reread.length)) { value, _, _ in
        if value != nil { attachmentCount += 1 }
    }
    XCTAssertEqual(attachmentCount, 0, "RTF must contain no image attachments")
    XCTAssertTrue(reread.string.contains("x^2"), "math source present as text")
    XCTAssertTrue(reread.string.contains("flowchart TD"), "mermaid source present as text")
}
```
- [ ] Write failing test `testRTFRoundTripPreservesListsAndBlockquotes`:
```swift
func testRTFRoundTripPreservesListsAndBlockquotes() throws {
    let doc = LineformDocument(text: "- first\n- second\n\n> quoted line")
    let data = try DocumentExportRenderer.rtfData(for: doc, profile: .original, paper: .usLetter)
    let reread = try XCTUnwrap(NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
    XCTAssertTrue(reread.string.contains("first"))
    XCTAssertTrue(reread.string.contains("second"))
    XCTAssertTrue(reread.string.contains("quoted line"))
    // Blockquote indentation survives as a non-zero paragraph indent somewhere in the doc.
    var sawIndent = false
    reread.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reread.length)) { value, _, _ in
        if let p = value as? NSParagraphStyle, p.headIndent > 0 || p.firstLineHeadIndent > 0 { sawIndent = true }
    }
    XCTAssertTrue(sawIndent, "list/blockquote indent carries into RTF paragraph styles")
}
```
- [ ] Run all four to fail.
- [ ] Implement `makeRTFAttributedString` + `rtfData(for:profile:paper:)` in a new `extension DocumentExportRenderer` at the bottom of `DocumentExportRenderer.swift` (below the enum, above/below `ExportTextView` — keep the `@MainActor` annotations; `MarkdownPreviewRenderer().render` is main-actor via `NSScreen`/AppKit use in the emitters).
- [ ] Run each new test to pass. Example:
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentExportRendererTests/testRTFDataIsNonEmptyAndReadableRTF
```
- [ ] Run the whole `DocumentExportRendererTests` class (still DEFAULT plan, still print-free):
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentExportRendererTests
```
- [ ] Do not commit. Note completion.

---

## Task 3 — `exportRTF` notification + File ▸ Export As submenu (manual-verified)

Add the `exportRTF` app notification and regroup the File-menu Print slot: keep Print… (⌘P), and move "PDF…" and "Rich Text (RTF)…" into an `Export As` submenu.

**Files:**
- `Lineform/App/LineformAppNotification.swift`
- `Lineform/App/AppCommands.swift`

**Interfaces (exact additions):**
```swift
// LineformAppNotification.swift — add the case, and its Notification.Name in the switch:
case exportRTF
// ...
case .exportRTF:
    return Notification.Name("Lineform.exportRTF")
```
```swift
// AppMenuConfiguration — add titles (keep the existing exportPDFCommandTitle string but repurpose
// its label inside the submenu; add the submenu + RTF titles):
static let exportAsMenuTitle = "Export As"
static let exportPDFSubmenuTitle = "PDF…"
static let exportRTFCommandTitle = "Rich Text (RTF)…"
```

**Steps:**

- [ ] In `LineformAppNotification.swift`, add the `exportRTF` case to the enum (next to `exportPDF`) and the matching `Notification.Name("Lineform.exportRTF")` in the `name` switch.
- [ ] In `AppMenuConfiguration`, add `exportAsMenuTitle`, `exportPDFSubmenuTitle`, `exportRTFCommandTitle` string constants (near `exportPDFCommandTitle`).
- [ ] In `AppCommands.body`, rewrite the `CommandGroup(replacing: .printItem)` block (currently `AppCommands.swift` ~313–322) to:
```swift
CommandGroup(replacing: .printItem) {
    Button(AppMenuConfiguration.printCommandTitle) {
        LineformAppNotification.printDocument.post(object: LineformAppNotification.activeWindowPayload())
    }
    .keyboardShortcut("p", modifiers: .command)

    Menu(AppMenuConfiguration.exportAsMenuTitle) {
        Button(AppMenuConfiguration.exportPDFSubmenuTitle) {
            LineformAppNotification.exportPDF.post(object: LineformAppNotification.activeWindowPayload())
        }
        Button(AppMenuConfiguration.exportRTFCommandTitle) {
            LineformAppNotification.exportRTF.post(object: LineformAppNotification.activeWindowPayload())
        }
    }
}
```
- [ ] Build the app (Debug) to confirm it compiles:
```
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
- [ ] MANUAL VERIFY (ask the user or run the app per the debug-build-launch gotcha — use `BUILT_PRODUCTS_DIR` full path, not `open -a`): File menu shows **Print…** (⌘P) then **Export As ▸** with **PDF…** and **Rich Text (RTF)…**. PDF… still opens the existing PDF save panel (no behavior change). RTF… does nothing yet (handler lands in Task 4) — that's expected at this step.
- [ ] Do not commit. Note completion and that RTF… is inert until Task 4.

---

## Task 4 — `EditorContainerView` `exportRTF` handler + NSSavePanel([.rtf]) + .alert failure (manual-verified)

Wire the `exportRTF` notification to a handler that presents an `NSSavePanel` for `.rtf`, writes `DocumentExportRenderer.rtfData(...)`, and shows the native SwiftUI `.alert` on failure. Mirror `exportCurrentDocumentAsPDF()`.

**Files:**
- `Lineform/Editor/EditorContainerView.swift`

**Interfaces (exact additions):**
```swift
// State (sibling of pdfExportErrorFileName ~line 50): drives a native .alert on RTF write failure.
@State private var rtfExportErrorFileName: String?

// Handler (sibling of exportCurrentDocumentAsPDF):
private func exportCurrentDocumentAsRTF()

// Default file name helper (sibling of defaultExportFileName):
private var defaultRTFExportFileName: String  // "<base>.rtf" or "Untitled.rtf"
```

**Steps:**

- [ ] Add `@State private var rtfExportErrorFileName: String?` next to `pdfExportErrorFileName` (~line 50).
- [ ] Add the `.onReceive` for `exportRTF` next to the `exportPDF` receiver (~line 328):
```swift
.onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.exportRTF.name)) { notification in
    guard notificationMatchesActiveWindow(notification) else { return }
    exportCurrentDocumentAsRTF()
}
```
- [ ] Add the failure `.alert` next to the "Couldn't Export PDF" alert (~line 153), reusing the identical shape:
```swift
.alert(
    "Couldn\u{2019}t Export RTF",
    isPresented: Binding(
        get: { rtfExportErrorFileName != nil },
        set: { if !$0 { rtfExportErrorFileName = nil } }
    ),
    presenting: rtfExportErrorFileName
) { _ in
    Button("OK", role: .cancel) { rtfExportErrorFileName = nil }
} message: { fileName in
    Text("Lineform couldn\u{2019}t write \u{201C}\(fileName)\u{201D}. Choose a different location and try again.")
}
```
- [ ] Add `defaultRTFExportFileName` next to `defaultExportFileName` (~line 1596):
```swift
private var defaultRTFExportFileName: String {
    let base = currentFileURL?.deletingPathExtension().lastPathComponent
    return ((base?.isEmpty == false ? base! : "Untitled")) + ".rtf"
}
```
- [ ] Add `exportCurrentDocumentAsRTF()` next to `exportCurrentDocumentAsPDF()` (~line 1563). No paper-size accessory (RTF has no fixed page; use `defaultExportPaperSize` only for the wrap width):
```swift
/// Prompts for a destination and writes the rich rendered document as RTF (styled text; math and
/// mermaid degrade to caption/source text — RTF can't portably embed images). No paper accessory:
/// RTF reflows in the target app; the export paper only sets the render wrap width.
private func exportCurrentDocumentAsRTF() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.rtf]
    panel.nameFieldStringValue = defaultRTFExportFileName
    panel.canCreateDirectories = true

    let write: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { return }
        do {
            let data = try DocumentExportRenderer.rtfData(
                for: document,
                profile: readingProfileStore.activeProfile,
                paper: defaultExportPaperSize
            )
            try data.write(to: url)
        } catch {
            rtfExportErrorFileName = url.lastPathComponent
        }
    }

    if let window = activeWindow {
        panel.beginSheetModal(for: window, completionHandler: write)
    } else {
        write(panel.runModal())
    }
}
```
  - Confirm `UTType.rtf` resolves (import `UniformTypeIdentifiers` if not already imported at the top of `EditorContainerView.swift`; the PDF path uses `.pdf` so it is likely already available — verify and add the import only if the build complains).
  - Confirm `document`, `readingProfileStore`, `activeWindow`, and `currentFileURL` are the same members the PDF handler uses in scope (they are — reuse verbatim).
- [ ] Build:
```
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
- [ ] MANUAL VERIFY (run the fresh Debug build via `BUILT_PRODUCTS_DIR` path, kill stale copies first): open a rich document (headings, bold/italic, a list, a blockquote, a `$$…$$` block, a ```mermaid block), File ▸ Export As ▸ Rich Text (RTF)…, save, then open the `.rtf` in TextEdit AND Pages/Word. Confirm: headings/bold/italic/lists/blockquote styling present; math and mermaid appear as caption + source text (not images); PDF export still embeds the diagrams (unchanged). Confirm the failure `.alert` path by exporting into a read-only location (or a path you revoke write on) — it should show the in-window SwiftUI alert, no app-icon `NSAlert`.
- [ ] Run the FULL default plan to confirm no regressions across the suite:
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
```
  (Warn the user about the TCC "access Documents" prompt before running; do not run unattended.)
- [ ] Do not commit. Report exact pass/fail counts from the full run and the manual-verify results (which apps opened the RTF, whether styling/text-fallback/failure-alert all behaved).

---

## Done criteria
- `imagesAsText` flag added, tested (default false unchanged, true → no attachments + source text) — DEFAULT plan.
- `rtfData(for:profile:paper:)` added, round-trip tested (headings/bold/italic/inline-code/lists/blockquotes survive; no image attachments; math/mermaid as text) — DEFAULT plan.
- File ▸ Export As ▸ {PDF…, Rich Text (RTF)…} live; Print… ⌘P unchanged; `exportRTF` notification wired to the handler with an `NSSavePanel([.rtf])` and a native `.alert` failure path — manual-verified.
- Full default plan green; PDF/on-screen output byte-identical to before (imagesAsText defaults false everywhere the old paths call `render`).
- No changes to the hosted plan, the `.xctestplan` files, entitlements, or dependencies.
