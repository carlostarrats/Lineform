# Save-State Status Communication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the editor's bottom status bar clearly communicate save state — red "Not saved yet" for untitled docs, amber "Unsaved changes" for dirty established docs, and a green "Saved"/"Autosaved" confirmation flash after a write — without ever recoloring the grey metadata.

**Architecture:** A pure presentation model (`EditorStatusIndicator` + `MetadataSegments`) computed from three signals — `savedAt` (nil = untitled), an `isDirty` comparison of live text vs. last-written text, and a transient save/reload `flash`. `DocumentSaveStatus` gains dirty detection and emits a `lastSaveEvent` on every real write (from `fileWrapper`), classified manual vs. autosave via a short-lived "manual save intent" flag set by a ⌘S/⌘⇧S key monitor and the Save As menu button. `EditorStatusBar` renders the segments (untitled label colored, metadata always grey) and a left indicator slot (extending today's "Updated" flash). Accessible red/amber/green colors are chosen per appearance and gated by a WCAG AA test against every built-in theme background.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSEvent` local monitor), XCTest. macOS document-based app.

## Global Constraints

- All new colors MUST clear WCAG AA (contrast ≥ 4.5) against **every** `Theme.builtIn` background in the appearance they render in (`theme.usesDarkChrome` selects dark vs. light variant). This is enforced by a test — no color ships that fails it.
- The metadata (word count, character count, `Last save: …` time) is ALWAYS grey (`.secondary`). Only added status words carry color.
- No new source or test **files** — add to `Lineform/Editor/EditorStatusPresentation.swift` and `LineformTests/EditorDisplayModeTests.swift` (both already in the target) to avoid `.pbxproj` edits.
- Do NOT alter save/autosave mechanics. The manual-vs-autosave signal only *observes* intent; it never intercepts or changes the save itself.
- Never call `markSaved` in a way that fires a green flash on document **load** or **external reload** — only real writes (`fileWrapper`) flash green; external reload keeps its own green "Updated".
- Default test gate (run after every task):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/EditorDisplayModeTests
  ```
  (Full default plan before final commit — see Task 6. Warn the user about the TCC "access Documents" prompt before any CLI test run.)

---

## File Structure

- `Lineform/Editor/EditorStatusPresentation.swift` — add: `EditorStatusIndicator` enum, `EditorStatusFlash` enum, `EditorStatusFormatter.MetadataSegments` + `metadataSegments(...)`, indicator text constants, `EditorStatusFormatter.indicator(...)` resolver, `EditorStatusColors` (NSColor+Color helpers), and extend `EditorStatusBar` to render segments + indicator. (~existing 108 lines → ~230.)
- `Lineform/Documents/LineformDocument.swift` — extend `DocumentSaveStatus`: `isDirty(...)`, manual-intent note/consume, `SaveKind`, `SaveEvent`, `lastSaveEvent` (`@Published`), `recordWrite(...)`; change `fileWrapper` to call `recordWrite`.
- `Lineform/Editor/EditorContainerView.swift` — compute `isDirty`, manage `flash` state, observe `lastSaveEvent`, pass `indicator` to `EditorStatusBar`; fold `showsUpdatedIndicator` into the flash.
- `Lineform/App/AppCommands.swift` — set manual-save intent on the Save As button; install the ⌘S/⌘⇧S local key monitor (or in the app root).
- `LineformTests/EditorDisplayModeTests.swift` — new tests for the resolver, segments, AA contrast, dirty detection, and save-event classification.

---

### Task 1: Pure status presentation model (indicator, segments, strings)

**Files:**
- Modify: `Lineform/Editor/EditorStatusPresentation.swift`
- Test: `LineformTests/EditorDisplayModeTests.swift`

**Interfaces:**
- Produces:
  - `enum EditorStatusFlash: Equatable { case saved, autosaved, updated }`
  - `enum EditorStatusIndicator: Equatable { case none, unsavedChanges, saved, autosaved, updated }` with `var text: String?`, `var showsReloadIcon: Bool`, `var accessibilityLabel: String?`
  - `EditorStatusFormatter.MetadataSegments: Equatable { var unsavedLabel: String?; var neutralText: String }`
  - `EditorStatusFormatter.metadataSegments(lastSavedDisplay:statisticsText:) -> MetadataSegments`
  - `EditorStatusFormatter.indicator(savedAt: Date?, isDirty: Bool, flash: EditorStatusFlash?) -> EditorStatusIndicator`
  - constants: `unsavedChangesText`, `savedIndicatorText`, `autosavedIndicatorText` (existing `updatedIndicatorText` reused)

- [ ] **Step 1: Write the failing tests**

Add to `EditorDisplayModeTests.swift`:

```swift
func testMetadataSegmentsColorOnlyTheUntitledLabel() {
    let untitled = EditorStatusFormatter.metadataSegments(
        lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay(label: "Not saved yet", detail: nil),
        statisticsText: "12 words — 68 characters"
    )
    XCTAssertEqual(untitled.unsavedLabel, "Not saved yet")
    XCTAssertEqual(untitled.neutralText, "  |  12 words — 68 characters")

    let saved = EditorStatusFormatter.metadataSegments(
        lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "3:41 PM"),
        statisticsText: "340 words — 1948 characters"
    )
    XCTAssertNil(saved.unsavedLabel, "Established doc metadata is never colored")
    XCTAssertEqual(saved.neutralText, "Last save: 3:41 PM  |  340 words — 1948 characters")
}

func testMetadataTextStillMatchesSegments() {
    // Existing metadataText output must be unchanged (a11y string).
    let display = EditorStatusFormatter.LastSavedDisplay(label: "Not saved yet", detail: nil)
    XCTAssertEqual(
        EditorStatusFormatter.metadataText(lastSavedDisplay: display, statisticsText: "12 words — 68 characters"),
        "Not saved yet  |  12 words — 68 characters"
    )
}

func testLeftIndicatorReflectsSaveState() {
    let now = Date()
    // Untitled: never a left indicator (red lives in main text).
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: nil, isDirty: false, flash: nil), .none)
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: nil, isDirty: true, flash: .saved), .none)
    // Established dirty: amber, and dirty wins over a lingering flash.
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: true, flash: nil), .unsavedChanges)
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: true, flash: .autosaved), .unsavedChanges)
    // Established clean with a flash: show the flash.
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: .saved), .saved)
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: .autosaved), .autosaved)
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: .updated), .updated)
    // Established clean, no flash: nothing.
    XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: nil), .none)
}

func testIndicatorPresentationTextAndIcon() {
    XCTAssertEqual(EditorStatusIndicator.unsavedChanges.text, "Unsaved changes")
    XCTAssertEqual(EditorStatusIndicator.saved.text, "Saved")
    XCTAssertEqual(EditorStatusIndicator.autosaved.text, "Autosaved")
    XCTAssertEqual(EditorStatusIndicator.updated.text, "Updated")
    XCTAssertNil(EditorStatusIndicator.none.text)
    XCTAssertTrue(EditorStatusIndicator.updated.showsReloadIcon)
    XCTAssertFalse(EditorStatusIndicator.unsavedChanges.showsReloadIcon)
    XCTAssertFalse(EditorStatusIndicator.saved.showsReloadIcon)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the Task gate command with `-only-testing:LineformTests/EditorDisplayModeTests/testLeftIndicatorReflectsSaveState` (and siblings).
Expected: FAIL — `EditorStatusIndicator` / `metadataSegments` / `indicator` do not exist (compile error).

- [ ] **Step 3: Implement the model in `EditorStatusPresentation.swift`**

Add inside `enum EditorStatusFormatter` (near `updatedIndicatorText`):

```swift
static let unsavedChangesText = "Unsaved changes"
static let savedIndicatorText = "Saved"
static let autosavedIndicatorText = "Autosaved"

struct MetadataSegments: Equatable {
    /// The unsaved-state label ("Not saved yet") when the document has never been
    /// saved; nil for established documents. This is the only colored part of the
    /// metadata line — everything in `neutralText` stays grey.
    var unsavedLabel: String?
    var neutralText: String
}

static func metadataSegments(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> MetadataSegments {
    if let detail = lastSavedDisplay.detail {
        return MetadataSegments(
            unsavedLabel: nil,
            neutralText: "\(lastSavedDisplay.label): \(detail)  |  \(statisticsText)"
        )
    }
    return MetadataSegments(
        unsavedLabel: lastSavedDisplay.label,
        neutralText: "  |  \(statisticsText)"
    )
}

static func indicator(savedAt: Date?, isDirty: Bool, flash: EditorStatusFlash?) -> EditorStatusIndicator {
    // Untitled documents show red "Not saved yet" in the main metadata text,
    // never a left-slot indicator.
    guard savedAt != nil else { return .none }
    // A live edit always outranks a lingering green flash.
    if isDirty { return .unsavedChanges }
    switch flash {
    case .saved: return .saved
    case .autosaved: return .autosaved
    case .updated: return .updated
    case nil: return .none
    }
}
```

Change `metadataText` to delegate (keeps identical output):

```swift
static func metadataText(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> String {
    let segments = metadataSegments(lastSavedDisplay: lastSavedDisplay, statisticsText: statisticsText)
    if let label = segments.unsavedLabel {
        return label + segments.neutralText
    }
    return segments.neutralText
}
```

Add at file scope (after the `EditorStatusFormatter` enum):

```swift
enum EditorStatusFlash: Equatable {
    case saved
    case autosaved
    case updated
}

enum EditorStatusIndicator: Equatable {
    case none
    case unsavedChanges
    case saved
    case autosaved
    case updated

    var text: String? {
        switch self {
        case .none: return nil
        case .unsavedChanges: return EditorStatusFormatter.unsavedChangesText
        case .saved: return EditorStatusFormatter.savedIndicatorText
        case .autosaved: return EditorStatusFormatter.autosavedIndicatorText
        case .updated: return EditorStatusFormatter.updatedIndicatorText
        }
    }

    var showsReloadIcon: Bool { self == .updated }

    var accessibilityLabel: String? {
        switch self {
        case .none: return nil
        case .unsavedChanges: return "Unsaved changes"
        case .saved: return "Saved"
        case .autosaved: return "Autosaved"
        case .updated: return "Document updated from disk"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Task gate command. Expected: PASS (all four new tests).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorStatusPresentation.swift LineformTests/EditorDisplayModeTests.swift
git commit -m "Add pure save-state presentation model (indicator + metadata segments)"
```

---

### Task 2: Accessible status colors + WCAG AA gate

**Files:**
- Modify: `Lineform/Editor/EditorStatusPresentation.swift`
- Test: `LineformTests/EditorDisplayModeTests.swift`

**Interfaces:**
- Produces `enum EditorStatusColors` with:
  - `static func notSaved(dark: Bool) -> NSColor` (red)
  - `static func unsavedChanges(dark: Bool) -> NSColor` (amber)
  - `static func saved(dark: Bool) -> NSColor` (green; == existing "Updated" green)
  - and `Color` wrappers `notSavedColor(dark:)`, `unsavedChangesColor(dark:)`, `savedColor(dark:)`.

- [ ] **Step 1: Write the failing test**

Add to `EditorDisplayModeTests.swift`:

```swift
func testStatusStateColorsMeetAAAgainstEveryThemeBackground() {
    for theme in Theme.builtIn {
        let dark = theme.usesDarkChrome
        let background = theme.backgroundColor
        for color in [
            EditorStatusColors.notSaved(dark: dark),
            EditorStatusColors.unsavedChanges(dark: dark),
            EditorStatusColors.saved(dark: dark)
        ] {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(color, background), 4.5,
                "Status color fails AA on theme \(theme.name) (dark=\(dark))"
            )
        }
    }
}
```

Ensure `contrastRatio` / `relativeLuminance` (already private static in this test class) convert to sRGB first — update `relativeLuminance` to:

```swift
private static func relativeLuminance(_ color: NSColor) -> CGFloat {
    let rgb = color.usingColorSpace(.sRGB) ?? color
    func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearized(rgb.redComponent)
        + 0.7152 * linearized(rgb.greenComponent)
        + 0.0722 * linearized(rgb.blueComponent)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the gate with `-only-testing:LineformTests/EditorDisplayModeTests/testStatusStateColorsMeetAAAgainstEveryThemeBackground`.
Expected: FAIL — `EditorStatusColors` does not exist.

- [ ] **Step 3: Implement `EditorStatusColors`**

Add to `EditorStatusPresentation.swift` (file scope). Values hand-checked to clear AA against white/paper/calm (light) and quiet 0.19 / night 0.09 (dark) with margin; the test is the real gate — if any fails, nudge the offending value darker (light) or brighter (dark) until green:

```swift
enum EditorStatusColors {
    // Red — "Not saved yet" (untitled). Deep red on light, salmon on dark.
    static func notSaved(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 1.00, green: 0.50, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.10, blue: 0.10, alpha: 1)
    }

    // Amber — "Unsaved changes" (dirty established). Softer than red.
    static func unsavedChanges(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 1.00, green: 0.72, blue: 0.28, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.34, blue: 0.02, alpha: 1)
    }

    // Green — save confirmation / "Updated". Matches the prior updated-flash green.
    static func saved(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.40, green: 0.82, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.47, blue: 0.24, alpha: 1)
    }

    static func notSavedColor(dark: Bool) -> Color { Color(nsColor: notSaved(dark: dark)) }
    static func unsavedChangesColor(dark: Bool) -> Color { Color(nsColor: unsavedChanges(dark: dark)) }
    static func savedColor(dark: Bool) -> Color { Color(nsColor: saved(dark: dark)) }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the gate. Expected: PASS. If a color fails on a specific theme, adjust that variant and re-run until green.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorStatusPresentation.swift LineformTests/EditorDisplayModeTests.swift
git commit -m "Add accessible red/amber/green status colors with AA test across themes"
```

---

### Task 3: DocumentSaveStatus — dirty detection + classified write events

**Files:**
- Modify: `Lineform/Documents/LineformDocument.swift`
- Test: `LineformTests/EditorDisplayModeTests.swift`

**Interfaces:**
- Produces on `DocumentSaveStatus`:
  - `enum SaveKind { case manual, autosave }`
  - `struct SaveEvent: Equatable { let documentID: UUID; let kind: SaveKind; let sequence: Int }`
  - `@Published private(set) var lastSaveEvent: SaveEvent?`
  - `func isDirty(documentID: UUID, currentText: String) -> Bool`
  - `func noteManualSaveIntent()`
  - `func recordWrite(documentID: UUID, text: String)` — updates saved date/text AND publishes a classified `lastSaveEvent`.
- Consumes: existing `savedAtByDocumentID`, `savedTextByDocumentID`, `markSaved`.

- [ ] **Step 1: Write the failing tests**

Add to `EditorDisplayModeTests.swift`:

```swift
@MainActor
func testDocumentDirtyReflectsTextVsLastWrite() {
    let status = DocumentSaveStatus.testInstance()
    let id = UUID()
    // Untitled (never saved): never "dirty" — the untitled state is signaled separately.
    XCTAssertFalse(status.isDirty(documentID: id, currentText: "hello"))
    // After a write, matching text is clean; changed text is dirty.
    status.recordWrite(documentID: id, text: "hello")
    XCTAssertFalse(status.isDirty(documentID: id, currentText: "hello"))
    XCTAssertTrue(status.isDirty(documentID: id, currentText: "hello world"))
}

@MainActor
func testRecordWriteClassifiesManualVsAutosave() {
    let status = DocumentSaveStatus.testInstance()
    let id = UUID()
    // No intent → autosave.
    status.recordWrite(documentID: id, text: "a")
    XCTAssertEqual(status.lastSaveEvent?.kind, .autosave)
    let firstSeq = status.lastSaveEvent?.sequence
    // Manual intent → manual, consumed once.
    status.noteManualSaveIntent()
    status.recordWrite(documentID: id, text: "ab")
    XCTAssertEqual(status.lastSaveEvent?.kind, .manual)
    // A distinct event each time, so .onChange fires even for repeated kinds.
    XCTAssertNotEqual(status.lastSaveEvent?.sequence, firstSeq)
    // Intent is one-shot: the next write is autosave again.
    status.recordWrite(documentID: id, text: "abc")
    XCTAssertEqual(status.lastSaveEvent?.kind, .autosave)
}
```

Add a test-only factory (the shared singleton has a private init) at the bottom of `DocumentSaveStatus` in `LineformDocument.swift`:

```swift
#if DEBUG
extension DocumentSaveStatus {
    /// Isolated instance for tests so they don't mutate the shared singleton.
    static func testInstance() -> DocumentSaveStatus { DocumentSaveStatus() }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the gate with the two new test names. Expected: FAIL — `recordWrite`, `isDirty`, `lastSaveEvent`, `testInstance` don't exist.

- [ ] **Step 3: Implement in `DocumentSaveStatus`**

Add properties/types and methods:

```swift
enum SaveKind: Equatable { case manual, autosave }

struct SaveEvent: Equatable {
    let documentID: UUID
    let kind: SaveKind
    let sequence: Int
}

@Published private(set) var lastSaveEvent: SaveEvent?
private var manualSaveIntentAt: Date?
private var writeSequence = 0

/// True when the live text differs from the last text written to disk. Untitled
/// documents (no recorded save) are never "dirty" — their state is shown as
/// "Not saved yet" instead.
func isDirty(documentID: UUID, currentText: String) -> Bool {
    guard savedAtByDocumentID[documentID] != nil else { return false }
    guard let saved = savedTextByDocumentID[documentID] else { return false }
    return saved != currentText
}

/// Records that the user just invoked Save / Save As. The next `recordWrite`
/// (within a short window) is attributed to the user; anything else is an autosave.
func noteManualSaveIntent() {
    manualSaveIntentAt = Date()
}

private func consumeManualSaveIntent(within window: TimeInterval = 2) -> Bool {
    guard let at = manualSaveIntentAt else { return false }
    manualSaveIntentAt = nil
    return Date().timeIntervalSince(at) <= window
}

/// Called from the document write path for a real save. Updates the saved
/// date/text baseline and publishes a classified event for the status flash.
func recordWrite(documentID: UUID, text: String) {
    let manual = consumeManualSaveIntent()
    markSaved(documentID: documentID, at: Date(), text: text)
    writeSequence += 1
    lastSaveEvent = SaveEvent(documentID: documentID, kind: manual ? .manual : .autosave, sequence: writeSequence)
}
```

Change `fileWrapper(configuration:)` in `LineformDocument` to call `recordWrite` instead of `markSaved`:

```swift
func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let data = try data(for: configuration.contentType)
    if recordsSourceSave(for: configuration.contentType) {
        let documentID = id
        let savedText = text
        Task { @MainActor in
            DocumentSaveStatus.shared.recordWrite(documentID: documentID, text: savedText)
        }
    }
    return FileWrapper(regularFileWithContents: data)
}
```

Leave the `markSaved` calls on **load** (`LineformDocument` init path) and **external reload** (`EditorContainerView.applyReload`) unchanged — they must not publish a green save flash.

- [ ] **Step 4: Run the tests to verify they pass**

Run the gate. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Documents/LineformDocument.swift LineformTests/EditorDisplayModeTests.swift
git commit -m "DocumentSaveStatus: dirty detection + classified write events"
```

---

### Task 4: Manual-save intent capture (⌘S / ⌘⇧S + Save As button)

**Files:**
- Modify: `Lineform/App/AppCommands.swift`

**Interfaces:**
- Consumes: `DocumentSaveStatus.shared.noteManualSaveIntent()`.
- Produces: intent is set before any user-initiated save reaches the document.

**Note on testing:** This task is imperative AppKit wiring (a global `NSEvent` local monitor + a menu-button call). Its *effect* is covered by Task 3's classification tests; correctness of the monitor itself is verified in Task 6 QA (⌘S → "Saved", pause → "Autosaved"). No new unit test.

- [ ] **Step 1: Set intent on the Save As button**

In `AppCommands.swift`, the existing Save As button (~line 250) sends `saveDocumentAs:`. Set intent immediately before:

```swift
Button(AppMenuConfiguration.saveAsCommandTitle) {
    DocumentSaveStatus.shared.noteManualSaveIntent()
    NSApp.sendAction(AppMenuConfiguration.saveAsCommandSelector, to: nil, from: nil)
}
```

- [ ] **Step 2: Install a ⌘S / ⌘⇧S local key monitor**

The plain Save (⌘S) is a system menu item, so capture it by observing the keystroke (pure observation — it does not consume or alter the event). Add a one-time installer and call it once from the app root. In `AppCommands.swift` (or the `@main` App struct's `init`), add:

```swift
enum ManualSaveIntentMonitor {
    private static var installed = false

    /// Observes ⌘S / ⌘⇧S so a keyboard-initiated Save is attributed to the user.
    /// Returns the event unchanged — it never swallows the keystroke.
    @MainActor
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandS = mods.contains(.command)
                && !mods.contains(.option)
                && !mods.contains(.control)
                && event.charactersIgnoringModifiers?.lowercased() == "s"
            if isCommandS {
                DocumentSaveStatus.shared.noteManualSaveIntent()
            }
            return event
        }
    }
}
```

Call `ManualSaveIntentMonitor.installIfNeeded()` from the App's `init()` (find the `@main struct` in `Lineform/App/`). If `init` is not `@MainActor`, wrap in `Task { @MainActor in ManualSaveIntentMonitor.installIfNeeded() }`.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Lineform/App/AppCommands.swift Lineform/App/*.swift
git commit -m "Capture manual-save intent from ⌘S/⌘⇧S and Save As"
```

---

### Task 5: Render the status bar — untitled red label, left indicator, flash

**Files:**
- Modify: `Lineform/Editor/EditorStatusPresentation.swift` (`EditorStatusBar`)
- Modify: `Lineform/Editor/EditorContainerView.swift`

**Interfaces:**
- `EditorStatusBar` gains `var indicator: EditorStatusIndicator` and drops `showsUpdatedIndicator`. It renders `metadataSegments` (untitled label colored via `EditorStatusColors`, neutral grey) and the left indicator.
- `EditorContainerView` computes `isDirty`, owns `@State private var statusFlash: EditorStatusFlash?`, observes `documentSaveStatus.lastSaveEvent`, and passes `indicator`.

- [ ] **Step 1: Rework `EditorStatusBar` body**

Replace the `showsUpdatedIndicator` property and body in `EditorStatusBar` with:

```swift
var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay
var statisticsText: String
var statusAccessibilityLabel: String
var indicator: EditorStatusIndicator = .none

@Environment(\.colorScheme) private var colorScheme

private var isDark: Bool { colorScheme == .dark }

private func indicatorColor(_ indicator: EditorStatusIndicator) -> Color {
    switch indicator {
    case .unsavedChanges: return EditorStatusColors.unsavedChangesColor(dark: isDark)
    case .saved, .autosaved, .updated: return EditorStatusColors.savedColor(dark: isDark)
    case .none: return .secondary
    }
}

var body: some View {
    let segments = EditorStatusFormatter.metadataSegments(
        lastSavedDisplay: lastSavedDisplay,
        statisticsText: statisticsText
    )
    return HStack(spacing: 16) {
        Spacer(minLength: 16)

        if let text = indicator.text {
            HStack(spacing: 4) {
                if indicator.showsReloadIcon {
                    Image(systemName: "arrow.clockwise")
                }
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(indicatorColor(indicator))
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(indicator.accessibilityLabel ?? text)
        }

        metadataText(segments)
            .font(.caption)
            .lineLimit(1)
            .accessibilityLabel("\(lastSavedDisplay.accessibilityText), \(statusAccessibilityLabel)")
    }
    .padding(.horizontal, Self.horizontalInset)
    .padding(.vertical, 6)
}

@ViewBuilder
private func metadataText(_ segments: EditorStatusFormatter.MetadataSegments) -> some View {
    if let label = segments.unsavedLabel {
        (Text(label).foregroundColor(EditorStatusColors.notSavedColor(dark: isDark))
            + Text(segments.neutralText).foregroundColor(.secondary))
    } else {
        Text(segments.neutralText).foregroundStyle(.secondary)
    }
}
```

Delete the now-unused `updatedIndicatorColor` computed property (its green moved to `EditorStatusColors.saved`).

- [ ] **Step 2: Update `EditorContainerView` to drive the indicator**

In `EditorContainerView.swift`:

1. Replace `@State private var showsUpdatedIndicator = false` with `@State private var statusFlash: EditorStatusFlash?`.
2. Add a computed dirty flag and indicator:

```swift
private var isDocumentDirty: Bool {
    documentSaveStatus.isDirty(documentID: document.id, currentText: document.text)
}

private var statusIndicator: EditorStatusIndicator {
    EditorStatusFormatter.indicator(
        savedAt: documentSaveStatus.savedAt(for: document.id),
        isDirty: isDocumentDirty,
        flash: statusFlash
    )
}
```

3. Change the `EditorStatusBar(...)` call to pass `indicator: statusIndicator` (remove `showsUpdatedIndicator:`).
4. Replace `flashUpdatedIndicator()` body so it sets `statusFlash = .updated` and clears after 4s. Rename to `flashStatus(_:)`:

```swift
private func flashStatus(_ flash: EditorStatusFlash) {
    withAnimation { statusFlash = flash }
    let token = flash
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        // Only clear if still showing the same flash (a newer edit/flash may have replaced it).
        if statusFlash == token {
            withAnimation { statusFlash = nil }
        }
    }
}
```

(Keep the exact existing timing/animation style used by the old `flashUpdatedIndicator`; match its `withAnimation`/`asyncAfter` shape.)

5. In `applyReload(_:)`, replace the `flashUpdatedIndicator()` call with `flashStatus(.updated)`.
6. Add an observer for save events (near the other `.onChange`/`.onReceive` on the same view) — flash green for this document's writes:

```swift
.onChange(of: documentSaveStatus.lastSaveEvent) { _, event in
    guard let event, event.documentID == document.id else { return }
    flashStatus(event.kind == .manual ? .saved : .autosaved)
}
```

7. When the user types (dirty), the amber indicator appears automatically because `statusIndicator` recomputes from `document.text`. No extra wiring needed. If a green flash is still showing when an edit makes the doc dirty, `EditorStatusFormatter.indicator` already prefers `.unsavedChanges` (dirty wins), so amber shows immediately.

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED. Fix any references to the removed `showsUpdatedIndicator` / `flashUpdatedIndicator` / `updatedIndicatorColor`.

- [ ] **Step 4: Run the default test plan**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
```
Expected: PASS (report exact counts). Warn the user about the TCC Documents prompt first.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorStatusPresentation.swift Lineform/Editor/EditorContainerView.swift
git commit -m "Render save-state in status bar: red untitled label, amber/green indicator"
```

---

### Task 6: QA in the running app + review loop

**Files:** none (verification) — plus any fixes surfaced.

- [ ] **Step 1: Launch the app and drive every state** (use the `run` skill / build+launch)
  - New untitled doc → main text shows **red** "Not saved yet"; counts grey; no left indicator.
  - Type in an established doc → **amber** "Unsaved changes" appears instantly on the left; metadata stays grey.
  - Pause for autosave → amber replaced by **green** "Autosaved", fades ~4s; `Last save:` time updates.
  - ⌘S on a dirty established doc → **green** "Saved" (not "Autosaved").
  - Save an untitled doc (⌘S → choose location) → red "Not saved yet" becomes grey "Last save: …"; green "Saved" flash.
  - Externally edit the file on disk (clean doc) → **green** "Updated" + reload icon (unchanged behavior).
  - Toggle a few reader themes (Original / Paper / Calm / Quiet / Night) and light/dark → confirm red/amber/green are all legible.
- [ ] **Step 2: Code review** — run `/code-review` (or a review subagent) over the diff for correctness, reuse, and the manual-vs-autosave edge cases (stale intent flag, flash cl/ token races).
- [ ] **Step 3: Fix any issues found**, re-running the affected tests. Loop review → fix until clean and the default plan is green.
- [ ] **Step 4: Hosted plan (only if motion touched)** — this change adds a fading indicator to the status bar. Run the hosted plan to confirm no editor-text vertical jump regression (quiet machine, Xcode quit):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -testPlan LineformHosted
  ```
  Treat known harness flakiness per `CLAUDE.md` (re-run at a known-good commit before calling it a regression).
- [ ] **Step 5: Docs** — update `CLAUDE.md`'s status-bar/feature description ONLY if the save-state behavior isn't already covered (it currently isn't). Keep it to the feature list; don't add churn.
- [ ] **Step 6: Final commit** of any QA fixes + docs.

---

## Self-Review

**Spec coverage:**
- Red untitled "Not saved yet" → Task 1 (segments), Task 2 (red color), Task 5 (render). ✓
- Amber established "Unsaved changes" → Task 1 (indicator), Task 2 (amber), Task 3 (isDirty), Task 5. ✓
- Green "Saved" (manual) / "Autosaved" (auto) → Task 3 (classification), Task 4 (intent capture), Task 5 (flash). ✓
- Metadata always grey → Task 1 (segments split), Task 5 (only `unsavedLabel` colored). ✓
- Colors accessible light+dark, all themes → Task 2 AA test. ✓
- Additive, not replacement (left slot) → Task 1 resolver + Task 5 layout. ✓
- Existing "Updated" external-reload flash preserved → Task 5 (`.updated`, icon retained). ✓
- Don't break save mechanics; don't flash on load/reload → Task 3 constraint (recordWrite only from fileWrapper). ✓
- Manual-vs-autosave risk with fallback → Task 4 note + Task 6 QA confirms; graceful degradation (rare mouse-menu Save labels as autosave). ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `EditorStatusIndicator`, `EditorStatusFlash`, `MetadataSegments`, `SaveEvent`, `SaveKind`, `recordWrite`, `isDirty`, `noteManualSaveIntent`, `EditorStatusColors`, `flashStatus` used consistently across tasks. `metadataText` retained for the a11y string; `metadataSegments` added for rendering.
