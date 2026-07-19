# Real Image Files in Styled PDF Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render real local image files in Styled PDF export and Print, with a Save As format description line and a consolidated grant-access prompt for images the app can't reach.

**Architecture:** The export renderer already accepts `documentDirectory` + an `imageProvider`; today the export path leaves them at disabled defaults so images fall to the `🖼` placeholder. This threads a real directory + `ImageAttachmentProvider` into the **Styled** path only (Normal PDF and RTF unchanged), adds a pure pre-flight helper that finds unreachable local image references, and wires a single `NSOpenPanel` grant prompt into the Save As / Print flows.

**Tech Stack:** Swift, AppKit, TextKit 1, XCTest. macOS document-based app.

## Global Constraints

- **Deploy target macOS 14** — no macOS 15+-only APIs.
- **Network-free invariant:** never fetch remote `http(s)`/`data:` images; they always stay placeholders and never trigger the grant prompt.
- **Normal PDF (`.standard`, `rendersMarkdown == false`) and RTF (`imagesAsText: true`) behavior is UNCHANGED.** Only the Styled (`.styled`) path gains images.
- **No new entitlement.** `user-selected.read-write` already covers picked files; the workspace scope already covers in-workspace images.
- **No `NSAlert` for the grant prompt** — project convention (NSAlert stamps the app icon). The prompt is the `NSOpenPanel`'s own `message` + Cancel.
- **Default test gate** (run from repo root; warn the user it may trigger a one-time TCC Documents prompt):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  Filter to one class with `-only-testing:LineformTests/<ClassName>`.
- **Hosted plan** adds `-testPlan LineformHosted`; run deliberately, Xcode quit.
- Add new source files to the hand-rolled pbxproj via the standard 4 insertions with sequential `1F0000xx` IDs (see the `pbxproj-handrolled-ids` convention).
- End every commit message body with the two trailer lines used in this repo (Co-Authored-By + Claude-Session).

---

## File Structure

- **Create** `Lineform/Preview/ImageExportPreflight.swift` — pure helper: enumerate image references in the document text, return those that are local, image-typed, but unresolvable against the current scopes.
- **Create** `LineformTests/ImageExportPreflightTests.swift` — unit tests for the helper.
- **Modify** `Lineform/Preview/ImageResolver.swift` — expose `hasImageExtension(_:)` for the helper.
- **Modify** `Lineform/Editor/SaveAsExport.swift` — add `SaveAsFormat.description` + a description `NSTextField` in the accessory, updated in `syncPanel()`.
- **Create** `LineformTests/SaveAsFormatDescriptionTests.swift` — unit test for the description mapping.
- **Modify** `Lineform/Preview/DocumentExportRenderer.swift` — thread `documentDirectory: URL?` + injectable `imageProvider` through `makeExportTextView`/`runOperation`/`runInteractivePrint`/`writePDF`/`pdfData`; Styled path passes a real provider.
- **Modify** `LineformTests/` (existing export test file) — a print-free `makeExportTextView` test proving image attachment vs placeholder.
- **Modify** `Lineform/Editor/EditorContainerView.swift` — pre-flight + grant prompt helper; pass `documentDirectory` into the Styled export/print calls.
- **Modify** `LineformTests/DocumentExportPDFHostedTests.swift` (hosted plan) — PDF-byte test that a resolvable image enlarges/changes the Styled PDF.

---

## Task 1: Pre-flight helper — find unreachable local image references

**Files:**
- Modify: `Lineform/Preview/ImageResolver.swift`
- Create: `Lineform/Preview/ImageExportPreflight.swift`
- Create: `LineformTests/ImageExportPreflightTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (register the two new files)

**Interfaces:**
- Consumes: `ImageResolver.resolve(path:documentDirectory:) -> ImageReferenceKind` (existing).
- Produces:
  - `ImageResolver.hasImageExtension(_ path: String) -> Bool`
  - `struct UnresolvedImageReference: Equatable { let path: String; let range: NSRange }`
  - `enum ImageExportPreflight { static func unresolvedLocalReferences(in text: String, documentDirectory: URL?) -> [UnresolvedImageReference] }`

- [ ] **Step 1: Write the failing test**

Create `LineformTests/ImageExportPreflightTests.swift`:

```swift
import XCTest
@testable import Lineform

final class ImageExportPreflightTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testResolvableLocalImageIsNotFlagged() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("pic.png").path, contents: Data())

        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "text\n![cat](pic.png)\nmore", documentDirectory: dir)
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingLocalImageIsFlagged() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![cat](missing.png)", documentDirectory: dir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.path, "missing.png")
    }

    func testRemoteImageIsNeverFlagged() {
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![x](https://example.com/a.png)\n![y](data:image/png;base64,AAAA)",
            documentDirectory: makeTempDir())
        XCTAssertTrue(result.isEmpty)
    }

    func testNonImageExtensionIsNotFlagged() {
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![notes](notes.txt)", documentDirectory: makeTempDir())
        XCTAssertTrue(result.isEmpty)
    }

    func testMultipleUnresolvedAreAllReturned() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![a](a.png) inline ![b](sub/b.jpg)", documentDirectory: dir)
        XCTAssertEqual(result.map(\.path).sorted(), ["a.png", "sub/b.jpg"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/ImageExportPreflightTests`
Expected: FAIL — `ImageExportPreflight` / `unresolvedLocalReferences` undefined (won't compile).

- [ ] **Step 3: Expose the extension check on ImageResolver**

In `Lineform/Preview/ImageResolver.swift`, add inside `enum ImageResolver` (the private `isImageExtension` stays; this is a public-to-module wrapper taking a full path):

```swift
    /// True when `path`'s extension is one of the recognized raster image extensions.
    /// Lets the export pre-flight tell "image reference we couldn't resolve" apart from
    /// "link to a non-image file" without duplicating the extension set.
    static func hasImageExtension(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (trimmed as NSString).pathExtension
        return isImageExtension(ext)
    }
```

- [ ] **Step 4: Write the helper**

Create `Lineform/Preview/ImageExportPreflight.swift`:

```swift
import Foundation

/// One `![alt](path)` reference in a document that could not be resolved to a readable local
/// image file (either missing, or existing but outside every granted sandbox scope — the two are
/// indistinguishable under the sandbox, so both surface here).
struct UnresolvedImageReference: Equatable {
    let path: String
    let range: NSRange
}

/// Pure pre-flight scan for Styled PDF export / Print: finds local image references the app can't
/// currently read, so the caller can offer a single grant-access prompt. Never touches the
/// network; remote (`http(s)`/`data:`) references are ignored, and non-image link targets
/// (`![x](notes.txt)`) are ignored — only genuine image references that fail to resolve are
/// returned.
enum ImageExportPreflight {
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)

    static func unresolvedLocalReferences(in text: String, documentDirectory: URL?) -> [UnresolvedImageReference] {
        let ns = text as NSString
        let matches = imageRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [UnresolvedImageReference] = []
        for match in matches where match.numberOfRanges >= 3 {
            let pathRange = match.range(at: 2)
            let rawPath = ns.substring(with: pathRange)
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

            let lowered = path.lowercased()
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("data:") {
                continue // remote — never fetched, never prompted
            }
            guard ImageResolver.hasImageExtension(path) else { continue } // not an image target
            if case .localFile = ImageResolver.resolve(path: path, documentDirectory: documentDirectory) {
                continue // already readable → will render, no prompt
            }
            result.append(UnresolvedImageReference(path: path, range: match.range))
        }
        return result
    }
}
```

- [ ] **Step 5: Register both new files in the pbxproj**

Add `ImageExportPreflight.swift` (app target, `Lineform/Preview` group) and `ImageExportPreflightTests.swift` (test target, `LineformTests` group) via the standard 4 insertions (PBXBuildFile, PBXFileReference, group children, Sources build phase) with the next sequential `1F0000xx` IDs.

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/ImageExportPreflightTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Lineform/Preview/ImageResolver.swift Lineform/Preview/ImageExportPreflight.swift LineformTests/ImageExportPreflightTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add ImageExportPreflight: find unreachable local image references"
```

---

## Task 2: Save As format description line

**Files:**
- Modify: `Lineform/Editor/SaveAsExport.swift`
- Create: `LineformTests/SaveAsFormatDescriptionTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (register the new test file)

**Interfaces:**
- Produces: `SaveAsFormat.description: String` (one short line per format).

- [ ] **Step 1: Write the failing test**

Create `LineformTests/SaveAsFormatDescriptionTests.swift`:

```swift
import XCTest
@testable import Lineform

final class SaveAsFormatDescriptionTests: XCTestCase {
    func testEachFormatHasADistinctNonEmptyDescription() {
        let descriptions = SaveAsFormat.allCases.map(\.description)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
        XCTAssertEqual(Set(descriptions).count, SaveAsFormat.allCases.count)
    }

    func testStyledPDFDescriptionMentionsImages() {
        XCTAssertTrue(SaveAsFormat.styledPDF.description.lowercased().contains("image"))
    }

    func testNormalPDFDescriptionMentionsSource() {
        XCTAssertTrue(SaveAsFormat.pdf.description.lowercased().contains("source"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/SaveAsFormatDescriptionTests`
Expected: FAIL — `SaveAsFormat` has no `description` (won't compile).

- [ ] **Step 3: Add the description property**

In `Lineform/Editor/SaveAsExport.swift`, add to `enum SaveAsFormat` after `title`:

```swift
    /// One-line explanation shown under the Format popup in the Save As panel, so the difference
    /// between PDF and Styled PDF is legible before choosing.
    var description: String {
        switch self {
        case .markdown: return "The editable source file."
        case .pdf: return "Plain markdown source — shows #, ** as typed."
        case .styledPDF: return "Rendered like Read mode — with images, tables, math & diagrams."
        case .rtf: return "Styled text for Word, Pages & Google Docs."
        }
    }
```

- [ ] **Step 4: Show the description in the accessory**

In `SaveAsPanelController`, add a stored description field and render it. Add the property near the popups:

```swift
    private let descriptionLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        field.alignment = .center
        field.isSelectable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.preferredMaxLayoutWidth = 280
        return field
    }()
```

In `makeAccessory()`, insert the description label into the vertical stack under the format row (before the paper row):

```swift
        let stack = NSStackView(views: [formatRow, descriptionLabel, paperRow])
```

In `syncPanel()`, keep it in sync (add at the end):

```swift
        descriptionLabel.stringValue = format.description
```

- [ ] **Step 5: Register the test file in the pbxproj**

Add `SaveAsFormatDescriptionTests.swift` to the test target via the standard 4 insertions with the next `1F0000xx` IDs.

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/SaveAsFormatDescriptionTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Lineform/Editor/SaveAsExport.swift LineformTests/SaveAsFormatDescriptionTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add Save As format description line under the Format popup"
```

---

## Task 3: Thread documentDirectory + image provider through the Styled export path

**Files:**
- Modify: `Lineform/Preview/DocumentExportRenderer.swift`
- Modify: `LineformTests/DocumentExportRendererTests.swift` (existing pure export test file — append the new tests + the `StubImageProvider` here; NO new file, NO pbxproj change. The existing tests already pass `profile: .original`, confirming that spelling.)

**Interfaces:**
- Consumes: `ImageAttachmentProviding`, `ImageAttachmentProvider`, `DisabledImageAttachmentProvider` (existing), `BlockRenderedAttachment` (existing).
- Produces (new/changed signatures — defaults keep every existing caller byte-identical):
  - `makeExportTextView(text:profile:paper:preset:documentDirectory:imageProvider:) -> NSTextView`
    (`documentDirectory: URL? = nil`, `imageProvider: ImageAttachmentProviding = ImageAttachmentProvider()`)
  - `runInteractivePrint(text:profile:paper:preset:documentDirectory:)` (`documentDirectory: URL? = nil`)
  - `writePDF(text:profile:paper:preset:documentDirectory:to:)` (`documentDirectory: URL? = nil`)
  - `pdfData(text:profile:paper:preset:documentDirectory:)` (`documentDirectory: URL? = nil`)

- [ ] **Step 1: Write the failing test**

Append to the existing `LineformTests/DocumentExportRendererTests.swift`. First add this stub provider at file scope (below the imports, before the test class):

```swift
/// A stub provider that returns a fixed image for any URL, so the export wiring can be proven
/// without decoding a real image file (ImageResolver only checks existence + extension).
private final class StubImageProvider: ImageAttachmentProviding {
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        NSImage(size: NSSize(width: 10, height: 10))
    }
}
```

Then add these three methods inside the existing `DocumentExportRendererTests` class (it is already `@MainActor`; if it is not, add `@MainActor` to these methods). Also add the two private helpers if not already present:

```swift
    // --- image export coverage (added for Styled PDF image rendering) ---
    private func makeDirWithImage() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-img-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("pic.png").path, contents: Data())
        return dir
    }

    private func attachmentCount(_ view: NSTextView) -> Int {
        var count = 0
        let storage = view.textStorage!
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }

    func testStyledExportRendersResolvableLocalImage() {
        let dir = makeDirWithImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = DocumentExportRenderer.makeExportTextView(
            text: "![cat](pic.png)", profile: .original, paper: .usLetter,
            preset: .styled, documentDirectory: dir, imageProvider: StubImageProvider())
        XCTAssertGreaterThanOrEqual(attachmentCount(view), 1)
        XCTAssertFalse(view.textStorage!.string.contains("🖼"))
    }

    func testStyledExportWithDisabledProviderKeepsPlaceholder() {
        let dir = makeDirWithImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = DocumentExportRenderer.makeExportTextView(
            text: "![cat](pic.png)", profile: .original, paper: .usLetter,
            preset: .styled, documentDirectory: dir, imageProvider: DisabledImageAttachmentProvider())
        XCTAssertTrue(view.textStorage!.string.contains("🖼"))
    }

    func testNormalExportNeverRendersImage() {
        let dir = makeDirWithImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = DocumentExportRenderer.makeExportTextView(
            text: "![cat](pic.png)", profile: .original, paper: .usLetter,
            preset: .standard, documentDirectory: dir, imageProvider: StubImageProvider())
        // Normal prints raw source: the literal reference text is present, no image attachment.
        XCTAssertTrue(view.textStorage!.string.contains("![cat](pic.png)"))
        XCTAssertEqual(attachmentCount(view), 0)
    }
```

(These three methods and the two helpers go INSIDE the existing `DocumentExportRendererTests` class — do not add an extra closing brace; the class already has one.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentExportRendererTests`
Expected: FAIL — `makeExportTextView` has no `documentDirectory:`/`imageProvider:` labels (won't compile).

- [ ] **Step 3: Add the parameters and wire the Styled path**

In `Lineform/Preview/DocumentExportRenderer.swift`:

Change `makeExportTextView` signature and the Styled `render(...)` call:

```swift
    @MainActor
    static func makeExportTextView(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset = .standard,
        documentDirectory: URL? = nil,
        imageProvider: ImageAttachmentProviding = ImageAttachmentProvider()
    ) -> NSTextView {
        let content = contentSize(for: paper, preset: preset)
        let attributed: NSAttributedString
        if preset.rendersMarkdown {
            attributed = MarkdownPreviewRenderer().render(
                text,
                profile: preset.exportReadingProfile(basedOn: profile),
                columnWidth: content.width,
                mermaidProvider: MermaidImageProvider(),
                mathProvider: MathImageProvider(),
                diagramLog: NullDiagramFailureLog(),
                reportRegistry: DiagramReportRegistry(),
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                fitTablesToWidth: true,
                highlightsCode: false,
                documentDirectory: documentDirectory,
                imageProvider: imageProvider,
                headingScale: preset.headingScale
            )
        } else {
            attributed = rawSourceAttributedString(text, preset: preset)
        }
        // ... rest of the function body unchanged ...
```

Thread `documentDirectory` through `runOperation`, `runInteractivePrint`, `writePDF`, and `pdfData` (each gains `documentDirectory: URL? = nil` and forwards it; `runOperation` passes it into `makeExportTextView`, letting `makeExportTextView`'s `imageProvider` default apply for the real render):

```swift
    @MainActor @discardableResult
    private static func runOperation(
        text: String, profile: ReadingProfile, paper: ExportPaperSize,
        preset: ExportTypographyPreset = .standard, printInfo: NSPrintInfo,
        showsPanel: Bool, documentDirectory: URL? = nil
    ) -> Bool {
        let view = makeExportTextView(text: text, profile: profile, paper: paper,
                                      preset: preset, documentDirectory: documentDirectory)
        // ... unchanged window/operation code ...
    }

    @MainActor
    static func runInteractivePrint(text: String, profile: ReadingProfile, paper: ExportPaperSize,
                                    preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil) {
        runOperation(text: text, profile: profile, paper: paper, preset: preset,
                     printInfo: makePrintInfo(for: paper, preset: preset), showsPanel: true,
                     documentDirectory: documentDirectory)
    }

    @MainActor @discardableResult
    static func writePDF(text: String, profile: ReadingProfile, paper: ExportPaperSize,
                         preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil, to url: URL) -> Bool {
        let info = makePrintInfo(for: paper, preset: preset)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        return runOperation(text: text, profile: profile, paper: paper, preset: preset,
                            printInfo: info, showsPanel: false, documentDirectory: documentDirectory)
    }

    @MainActor
    static func pdfData(text: String, profile: ReadingProfile, paper: ExportPaperSize,
                        preset: ExportTypographyPreset = .standard, documentDirectory: URL? = nil) -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-export-\(UUID().uuidString)").appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        writePDF(text: text, profile: profile, paper: paper, preset: preset,
                 documentDirectory: documentDirectory, to: tempURL)
        return (try? Data(contentsOf: tempURL)) ?? Data()
    }
```

Update the type doc comment (line ~59) from "Real image files stay the `🖼 alt` placeholder…" to note that the Styled preset now renders resolvable local images (Normal/RTF still placeholder/text).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentExportRendererTests`
Expected: PASS (all existing tests + the 3 new image tests).

- [ ] **Step 5: Confirm no existing export test regressed**

Run the whole default plan for the export area:
`xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests`
Expected: PASS (report exact counts).

- [ ] **Step 6: Commit**

```bash
git add Lineform/Preview/DocumentExportRenderer.swift LineformTests/DocumentExportRendererTests.swift
git commit -m "Render local images in Styled PDF/Print export path"
```

---

## Task 4: Wire pre-flight + grant prompt into Save As and Print

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift`

**Interfaces:**
- Consumes: `ImageExportPreflight.unresolvedLocalReferences(in:documentDirectory:)`, `DocumentExportRenderer.writePDF(...documentDirectory:to:)`, `DocumentExportRenderer.runInteractivePrint(...documentDirectory:)`.
- Produces: a private helper `withImageAccessGrantsIfNeeded(documentDirectory:perform:)` used by both the Save As Styled branch and Print.

This task is UI wiring around already-tested pure logic (Task 1 covers the decision; Task 3 covers the render). Verify manually per the steps.

- [ ] **Step 1: Add the grant-prompt helper**

In `EditorContainerView`, add:

```swift
    /// Styled export/print pre-flight: if the document references local images the app can't
    /// currently read, present ONE NSOpenPanel (its `message` is the whole explanation; Cancel =
    /// "continue without") so the user can grant access to include them. Retains the granted
    /// security scopes for the duration of `perform`, then releases them. In-scope documents (the
    /// common case) never see a prompt.
    private func withImageAccessGrantsIfNeeded(documentDirectory: URL?, perform: () -> Void) {
        let unresolved = ImageExportPreflight.unresolvedLocalReferences(
            in: document.text, documentDirectory: documentDirectory)
        var granted: [URL] = []
        if !unresolved.isEmpty {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Grant Access"
            panel.message = "This document uses \(unresolved.count) image\(unresolved.count == 1 ? "" : "s") "
                + "stored outside the folders Lineform can access. Choose the folder or files to "
                + "include them in the PDF, or Cancel to export without them."
            if panel.runModal() == .OK {
                for url in panel.urls where url.startAccessingSecurityScopedResource() {
                    granted.append(url)
                }
            }
        }
        defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }
        perform()
    }
```

- [ ] **Step 2: Use it in the Save As Styled branch**

In `saveAsDocument()`'s `write` closure, replace the `.pdf, .styledPDF` case body with a version that pre-flights ONLY for Styled (Normal never renders images, so it must not prompt):

```swift
            case .pdf, .styledPDF:
                let preset: ExportTypographyPreset = (format == .styledPDF) ? .styled : .standard
                let dir = currentFileURL?.deletingLastPathComponent()
                let runExport = {
                    let succeeded = DocumentExportRenderer.writePDF(
                        text: document.text,
                        profile: readingProfileStore.activeProfile,
                        paper: paper,
                        preset: preset,
                        documentDirectory: dir,
                        to: url
                    )
                    if !succeeded { pdfExportErrorFileName = url.lastPathComponent }
                }
                if format == .styledPDF {
                    withImageAccessGrantsIfNeeded(documentDirectory: dir, perform: runExport)
                } else {
                    runExport()
                }
```

- [ ] **Step 3: Use it in Print**

Replace `printCurrentDocument()` body:

```swift
    private func printCurrentDocument() {
        let dir = currentFileURL?.deletingLastPathComponent()
        withImageAccessGrantsIfNeeded(documentDirectory: dir) {
            DocumentExportRenderer.runInteractivePrint(
                text: document.text,
                profile: readingProfileStore.activeProfile,
                paper: defaultExportPaperSize,
                preset: .styled,
                documentDirectory: dir
            )
        }
    }
```

- [ ] **Step 4: Build to confirm it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual verification (report results honestly)**

Ask the user to drive, or drive via the run skill if possible:
1. A doc with an image beside it in the workspace → **Save As ▸ Styled PDF** → image appears, **no prompt**.
2. The same doc as **Normal PDF** → raw `![alt](path)` text, no image, no prompt.
3. A doc referencing an image on the Desktop (outside the workspace) → **Styled PDF** → one grant prompt; **Cancel** → placeholder in PDF; **Grant Access ▸ pick Desktop** → image appears.
4. **⌘P** on the Desktop-image doc → same single prompt.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift
git commit -m "Pre-flight grant prompt for out-of-scope images in Styled export/print"
```

---

## Task 5: Hosted PDF-byte regression test

**Files:**
- Modify: `LineformTests/DocumentExportPDFHostedTests.swift`

**Interfaces:**
- Consumes: `DocumentExportRenderer.pdfData(...documentDirectory:)`.

- [ ] **Step 1: Add the test**

Append to `DocumentExportPDFHostedTests` (which lives at the bottom of `LineformTests/DocumentExportRendererTests.swift`).

**IMPORTANT (learned during execution):** the baseline must be an image-FREE document, NOT the same document rendered with `documentDirectory: nil`. The `🖼` placeholder path embeds a color-emoji font subset that inflates the "no image" PDF *beyond* a small raster (measured: placeholder ≈ 68 KB vs a 40×40 raster ≈ 15 KB), so comparing image-vs-placeholder is inverted and unsound. Compare image-doc vs a plain-text doc with no `![...]` at all, and use a larger deterministic-noise raster for an unambiguous byte margin:

```swift
    func testStyledPDFEmbedsResolvableLocalImage() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-img-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 240x240 deterministic-noise PNG: poorly compressible, so the embedded raster adds an
        // unambiguous number of bytes (a tiny flat-color image compresses to ~nothing → flaky margin).
        let side = 240
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<side {
            for x in 0..<side {
                let v = (x * 31 + y * 17) & 0xFF
                rep.setColor(NSColor(
                    deviceRed: CGFloat(v) / 255.0,
                    green: CGFloat((v &* 7) & 0xFF) / 255.0,
                    blue: CGFloat((v &* 13) & 0xFF) / 255.0, alpha: 1), atX: x, y: y)
            }
        }
        let png = rep.representation(using: .png, properties: [:])!
        try! png.write(to: dir.appendingPathComponent("pic.png"))

        // Image doc vs an image-FREE doc (no `![...]`, so no 🖼 placeholder / emoji-font subset to
        // confound the size). The only difference is the embedded raster, so the image doc must be
        // larger — proving the resolvable local image survives into the actual PDF bytes.
        let withImage = DocumentExportRenderer.pdfData(
            text: "# Title\n\n![cat](pic.png)\n",
            profile: .original, paper: .usLetter, preset: .styled, documentDirectory: dir)
        let noImage = DocumentExportRenderer.pdfData(
            text: "# Title\n\nplain paragraph text\n",
            profile: .original, paper: .usLetter, preset: .styled, documentDirectory: nil)

        XCTAssertFalse(withImage.isEmpty)
        XCTAssertGreaterThan(withImage.count, noImage.count,
            "A rendered raster image should add bytes over an image-free document.")
    }
```

- [ ] **Step 2: Run the hosted plan (Xcode quit, quiet machine)**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -testPlan LineformHosted -only-testing:LineformTests/DocumentExportPDFHostedTests`
Expected: PASS. (If the host crashes at process-exit teardown per the known SwiftUI-window-in-XCTest issue, re-run; that crash never affects the shipped app.)

- [ ] **Step 3: Commit**

```bash
git add LineformTests/DocumentExportPDFHostedTests.swift
git commit -m "Hosted test: Styled PDF embeds a resolvable local image"
```

---

## Task 6: Full-suite gate + docs

**Files:**
- Modify: `CLAUDE.md` (the inline-image bullet's "Export (PDF/RTF) still shows the 🖼 placeholder" note)

- [ ] **Step 1: Run the full default plan**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: PASS. Report exact pass/fail counts. Warn the user this may trigger a one-time TCC Documents prompt.

- [ ] **Step 2: Update CLAUDE.md**

In the inline-local-image bullet, change the sentence "**Export (PDF/RTF) still shows the `🖼` placeholder** — real images in exports are a deferred v1 follow-up, not shipped here." to reflect: **Styled PDF and Print now render resolvable local images** (with a consolidated grant prompt for out-of-scope/missing ones); **Normal PDF stays raw source and RTF stays `imagesAsText`** (placeholder/text). Reference this plan.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Docs: Styled PDF/Print now render local images"
```

---

## Self-Review Notes

- **Spec coverage:** images in Styled PDF (Task 3) + wiring (Task 4); Normal/RTF unchanged (asserted in Task 3 Step 1 `testNormalExportNeverRendersImage` and left untouched in Task 4); Save As description line (Task 2); consolidated grant prompt with explanatory copy (Task 4 helper); pre-flight partition of remote/resolvable/unresolvable (Task 1); hosted byte test (Task 5). All spec sections map to a task.
- **Detection ambiguity** (missing vs out-of-scope) is handled by neutral copy in the Task 4 panel `message` and the Task 1 doc comment — consistent with the spec.
- **Type consistency:** `documentDirectory: URL?` and `imageProvider: ImageAttachmentProviding` names/labels are identical across Tasks 3 and 4; `unresolvedLocalReferences(in:documentDirectory:)` and `UnresolvedImageReference` are used verbatim in Tasks 1 and 4.
- **Placeholder scan:** no TBD/TODO; every code step shows complete code. The only conditional note is the `ReadingProfile.original` spelling caveat (Tasks 3 & 5), which instructs the implementer to match the existing export tests rather than guess.
