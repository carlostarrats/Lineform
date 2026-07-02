# Live Reload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An open document automatically reloads its text from disk when the file changes externally (an agent rewrites the `.md`), on clean documents only, debounced, preserving scroll and mode, with a quiet "Updated" status.

**Architecture:** Lineform is a SwiftUI `FileDocument` (value type), not `NSDocument`, so file-change observation is implemented as a dedicated `NSFilePresenter` object (`DocumentFileWatcher`) registered via `NSFileCoordinator`, owned by a `@StateObject` controller (`DocumentReloadController`) inside `EditorContainerView`. The reload decision is a pure value type (`DocumentReloadPolicy`) that gates on the framework document's `isDocumentEdited` and a disk-vs-memory text comparison. Reloaded text is pushed through the existing `$document.text` binding; because the reload path sets **no** `requestedSelection`, `updateNSView` recognizes it and preserves proportional scroll.

**Tech Stack:** Swift, SwiftUI, AppKit, TextKit, `NSFilePresenter`/`NSFileCoordinator`, Xcode (`xcodebuild`), macOS 14+, XCTest.

## Global Constraints

- Verification gate (serial, per CLAUDE.md; quit Xcode first):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
- The app must **build green** at every commit.
- No watch toggle; live reload is default behavior for every open document.
- Only reload when the document is clean: gate on `window.windowController?.document?.isDocumentEdited` (the framework `NSDocument`), NOT `DocumentSaveStatus` (which is only a last-saved timestamp).
- Skip reload when disk text equals in-memory text (prevents the app's own autosave from causing reload churn).
- Debounce trailing interval = `0.3` s (burst-write coalescing).
- No merge/conflict UI; dirty documents defer entirely to existing behavior.
- Deleted/moved file: never crash, never blank the editor; keep in-memory text.
- Respect Reduce Motion via `EditorMotionPolicy.animation(_:reduceMotion:)` (`EditorPresentation.swift:215`).
- Do NOT change autosave, the sidebar file-swap semantics, or Writing Tools protection.
- The Xcode project uses classic explicit file references (no synchronized groups): every new `.swift` file must be added to `Lineform.xcodeproj/project.pbxproj` (target membership) or the build/test breaks.
- Spec: `docs/superpowers/specs/2026-07-01-live-reload-design.md`. Index: `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`.

## File structure

**Create:**
- `Lineform/Documents/DocumentReloadPolicy.swift` — pure: `ReloadOutcome`, `DocumentReloadPolicy` (decision + debounce constant), `ProportionalScrollMath`.
- `Lineform/Documents/DocumentReloadController.swift` — `DocumentReloadController` (`@MainActor ObservableObject`), `DocumentFileWatcher` (`NSFilePresenter`), the `DocumentDirtyProviding` and `DocumentDiskReading` seams + their real implementations, `ReloadResult`.
- `LineformTests/DocumentReloadPolicyTests.swift` — pure policy, scroll math, debounce constant.
- `LineformTests/DocumentReloadControllerTests.swift` — controller with injected fakes.

**Modify:**
- `Lineform/Editor/LineformTextView.swift` — add `captureProportionalScrollOffset()` / `restoreProportionalScrollOffset(_:)`.
- `Lineform/Editor/MarkdownTextViewRepresentable.swift:56-59` — preserve proportional scroll when replacing string with `requestedSelection == nil`.
- `Lineform/Editor/EditorStatusPresentation.swift` — transient "Updated" indicator support on `EditorStatusBar` + formatter constant.
- `Lineform/Editor/EditorContainerView.swift` — `@StateObject` controller, registration wiring, reload application, "Updated" `@State`, re-register on sidebar swap.
- `LineformTests/EditorDisplayModeTests.swift` — one hosted integration test for scroll-preserving reload (harness lives here).
- `Lineform.xcodeproj/project.pbxproj` — add the four new files to their targets.

---

### Task 1: Pure reload policy + scroll math

**Files:**
- Create: `Lineform/Documents/DocumentReloadPolicy.swift`
- Create: `LineformTests/DocumentReloadPolicyTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
  - `enum ReloadOutcome: Equatable { case reload, ignoreDirty, ignoreUnchanged }`
  - `enum DocumentReloadPolicy { static let debounceInterval: TimeInterval; static func decide(isDocumentEdited: Bool, diskText: String, currentText: String) -> ReloadOutcome }`
  - `enum ProportionalScrollMath { static func ratio(originY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat; static func originY(ratio: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat }`

- [ ] **Step 1: Write the failing tests**

Create `LineformTests/DocumentReloadPolicyTests.swift`:

```swift
import XCTest
@testable import Lineform

final class DocumentReloadPolicyTests: XCTestCase {
    func testDirtyDocumentIsNeverReloaded() {
        XCTAssertEqual(
            DocumentReloadPolicy.decide(isDocumentEdited: true, diskText: "new", currentText: "old"),
            .ignoreDirty
        )
    }

    func testUnchangedDiskContentIsIgnored() {
        XCTAssertEqual(
            DocumentReloadPolicy.decide(isDocumentEdited: false, diskText: "same", currentText: "same"),
            .ignoreUnchanged
        )
    }

    func testCleanChangedContentReloads() {
        XCTAssertEqual(
            DocumentReloadPolicy.decide(isDocumentEdited: false, diskText: "new", currentText: "old"),
            .reload
        )
    }

    func testDebounceIntervalIsThreeHundredMilliseconds() {
        XCTAssertEqual(DocumentReloadPolicy.debounceInterval, 0.3, accuracy: 0.0001)
    }

    func testScrollRatioAtTopIsZero() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 0, documentHeight: 1000, viewportHeight: 200), 0, accuracy: 0.0001)
    }

    func testScrollRatioAtBottomIsOne() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 800, documentHeight: 1000, viewportHeight: 200), 1, accuracy: 0.0001)
    }

    func testScrollRatioMidpoint() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 400, documentHeight: 1000, viewportHeight: 200), 0.5, accuracy: 0.0001)
    }

    func testScrollRatioWithNoScrollableRangeIsZero() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 0, documentHeight: 100, viewportHeight: 200), 0, accuracy: 0.0001)
    }

    func testOriginYRoundTripsFromRatio() {
        XCTAssertEqual(ProportionalScrollMath.originY(ratio: 0.5, documentHeight: 1000, viewportHeight: 200), 400, accuracy: 0.0001)
    }

    func testOriginYClampsRatioAboveOne() {
        XCTAssertEqual(ProportionalScrollMath.originY(ratio: 1.5, documentHeight: 1000, viewportHeight: 200), 800, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Add the test file to the LineformTests target and run to verify it fails**

Add `DocumentReloadPolicyTests.swift` to the `LineformTests` target in `project.pbxproj` (see Task 6 for the pbxproj procedure; do the same three-entry add here). Then:

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentReloadPolicyTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'DocumentReloadPolicy' in scope` (types not defined yet).

- [ ] **Step 3: Write the implementation**

Create `Lineform/Documents/DocumentReloadPolicy.swift`:

```swift
import CoreGraphics
import Foundation

/// The result of deciding whether an externally-changed file should reload the open document.
enum ReloadOutcome: Equatable {
    case reload
    case ignoreDirty
    case ignoreUnchanged
}

/// Pure decision logic for live reload. Gated so a dirty document is never clobbered and the
/// app's own saves (disk == memory) never trigger a pointless reload.
enum DocumentReloadPolicy {
    /// Trailing debounce interval that coalesces burst writes into a single reload.
    static let debounceInterval: TimeInterval = 0.3

    static func decide(isDocumentEdited: Bool, diskText: String, currentText: String) -> ReloadOutcome {
        if isDocumentEdited { return .ignoreDirty }
        if diskText == currentText { return .ignoreUnchanged }
        return .reload
    }
}

/// Proportional (ratio-based) scroll preservation for wholesale text replacement, where
/// character-range anchors are invalid because ranges shift.
enum ProportionalScrollMath {
    /// Fraction (0...1) of the scrollable range currently scrolled.
    static func ratio(originY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollable = documentHeight - viewportHeight
        guard scrollable > 0 else { return 0 }
        return min(max(originY / scrollable, 0), 1)
    }

    /// The origin Y that restores `ratio` against (possibly new) content metrics.
    static func originY(ratio: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollable = documentHeight - viewportHeight
        guard scrollable > 0 else { return 0 }
        return min(max(ratio, 0), 1) * scrollable
    }
}
```

- [ ] **Step 4: Add the source file to the Lineform target and run to verify it passes**

Add `DocumentReloadPolicy.swift` to the `Lineform` target in `project.pbxproj` (Task 6 procedure). Then:

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentReloadPolicyTests 2>&1 | tail -20`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Documents/DocumentReloadPolicy.swift LineformTests/DocumentReloadPolicyTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add pure reload policy and proportional scroll math"
```

---

### Task 2: Proportional scroll helpers on LineformTextView

**Files:**
- Modify: `Lineform/Editor/LineformTextView.swift`

**Interfaces:**
- Consumes: `ProportionalScrollMath` (Task 1).
- Produces (on `LineformTextView`):
  - `func captureProportionalScrollOffset() -> CGFloat`
  - `func restoreProportionalScrollOffset(_ ratio: CGFloat)`

There is no cheap pure-unit test for AppKit scroll geometry; this is covered by the pure math (Task 1) plus the hosted integration test (Task 5). Verify by compile + reuse.

- [ ] **Step 1: Add the helpers**

In `Lineform/Editor/LineformTextView.swift`, near the existing scroll-restoration helpers (around `restoreVerticalScrollOrigin`, `LineformTextView.swift:794-809`), add:

```swift
extension LineformTextView {
    /// Capture the current scroll position as a fraction (0...1) of the scrollable range,
    /// for restoration across a wholesale text replacement.
    func captureProportionalScrollOffset() -> CGFloat {
        guard let scrollView = enclosingScrollView else { return 0 }
        return ProportionalScrollMath.ratio(
            originY: scrollView.contentView.bounds.origin.y,
            documentHeight: bounds.height,
            viewportHeight: scrollView.contentView.bounds.height
        )
    }

    /// Restore a previously-captured proportional scroll offset against current metrics.
    func restoreProportionalScrollOffset(_ ratio: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let originY = ProportionalScrollMath.originY(
            ratio: ratio,
            documentHeight: bounds.height,
            viewportHeight: scrollView.contentView.bounds.height
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: originY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Lineform/Editor/LineformTextView.swift
git commit -m "Add proportional scroll capture/restore to LineformTextView"
```

---

### Task 3: Preserve scroll on external text reload in the representable

**Files:**
- Modify: `Lineform/Editor/MarkdownTextViewRepresentable.swift:46-73`

**Interfaces:**
- Consumes: `LineformTextView.captureProportionalScrollOffset()` / `.restoreProportionalScrollOffset(_:)` (Task 2).

**Rationale:** The only time `updateNSView` sees `textView.string != text` is a programmatic full replacement (typing keeps them in sync via `textDidChange`). The sidebar swap drives that path but sets `requestedSelection = (0,0)` to scroll to top (`EditorContainerView.resetTransientDocumentState`, `:301`). Live reload sets **no** `requestedSelection`. So: when replacing the string and `requestedSelection == nil`, preserve proportional scroll; otherwise leave scroll to the `requestedSelection` handler.

- [ ] **Step 1: Modify the string-replacement block**

Replace the block at `MarkdownTextViewRepresentable.swift:56-59`:

```swift
        if textView.string != text {
            textView.string = text
            textView.refreshMarkdownHighlighting()
        }
```

with:

```swift
        if textView.string != text {
            // A programmatic full-text replacement. When no explicit selection/scroll target
            // is requested (live reload), preserve the reader's place proportionally; the
            // sidebar swap requests (0,0) instead and is handled below.
            let preservesScroll = requestedSelection == nil
            let scrollRatio = preservesScroll ? textView.captureProportionalScrollOffset() : 0
            textView.string = text
            textView.refreshMarkdownHighlighting()
            if preservesScroll {
                DispatchQueue.main.async {
                    textView.restoreProportionalScrollOffset(scrollRatio)
                }
            }
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Lineform/Editor/MarkdownTextViewRepresentable.swift
git commit -m "Preserve proportional scroll on external text reload"
```

---

### Task 4: The reload controller + file watcher

**Files:**
- Create: `Lineform/Documents/DocumentReloadController.swift`
- Create: `LineformTests/DocumentReloadControllerTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DocumentReloadPolicy`, `ReloadOutcome` (Task 1); `LineformDocument.modificationDate(at:)` (`LineformDocument.swift:230`).
- Produces:
  - `struct ReloadResult: Equatable { let text: String; let modificationDate: Date? }`
  - `protocol DocumentDirtyProviding { var isDocumentEdited: Bool { get } }`
  - `protocol DocumentDiskReading { func readText(at url: URL) -> String?; func modificationDate(at url: URL) -> Date? }`
  - `@MainActor final class DocumentReloadController: ObservableObject` with:
    - `@Published private(set) var lastReload: ReloadResult?`
    - `var currentText: String`
    - `init(diskReader: DocumentDiskReading = FileSystemDiskReader(), debounceInterval: TimeInterval = DocumentReloadPolicy.debounceInterval)`
    - `func update(url: URL?, dirtyProvider: DocumentDirtyProviding?)`
    - `func fileDidChange()` — presenter entry (schedules debounced `evaluate()`)
    - `func evaluate()` — runs the decision, sets `lastReload` on `.reload`
    - `func stop()`
  - `final class DocumentFileWatcher: NSObject, NSFilePresenter`

- [ ] **Step 1: Write the failing tests**

Create `LineformTests/DocumentReloadControllerTests.swift`:

```swift
import XCTest
@testable import Lineform

@MainActor
final class DocumentReloadControllerTests: XCTestCase {
    private final class FakeDirty: DocumentDirtyProviding {
        var isDocumentEdited: Bool
        init(_ v: Bool) { isDocumentEdited = v }
    }

    private final class FakeReader: DocumentDiskReading {
        var text: String?
        var date: Date?
        init(text: String?, date: Date? = nil) { self.text = text; self.date = date }
        func readText(at url: URL) -> String? { text }
        func modificationDate(at url: URL) -> Date? { date }
    }

    private func url() -> URL { URL(fileURLWithPath: "/tmp/lineform-test.md") }

    func testCleanChangedFilePublishesReload() {
        let reader = FakeReader(text: "disk", date: Date(timeIntervalSince1970: 100))
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertEqual(controller.lastReload?.text, "disk")
        XCTAssertEqual(controller.lastReload?.modificationDate, Date(timeIntervalSince1970: 100))
    }

    func testDirtyFileDoesNotReload() {
        let reader = FakeReader(text: "disk")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(true))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testUnchangedFileDoesNotReload() {
        let reader = FakeReader(text: "same")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "same"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testNoURLDoesNotReload() {
        let reader = FakeReader(text: "disk")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: nil, dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testUnreadableDiskDoesNotReload() {
        let reader = FakeReader(text: nil)
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testDebouncedChangeEventuallyReloads() {
        let reader = FakeReader(text: "disk")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0.05)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.fileDidChange()
        let expectation = expectation(description: "reload")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if controller.lastReload?.text == "disk" { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
```

- [ ] **Step 2: Add the test file to the LineformTests target and run to verify it fails**

Add `DocumentReloadControllerTests.swift` to `LineformTests` in `project.pbxproj`. Then:

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentReloadControllerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'DocumentReloadController' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Lineform/Documents/DocumentReloadController.swift`:

```swift
import AppKit
import Foundation

/// The text + modification date to apply when a live reload fires.
struct ReloadResult: Equatable {
    let text: String
    let modificationDate: Date?
}

/// Abstracts "does the open document have unsaved edits?" so the controller is testable
/// without a real window/NSDocument.
protocol DocumentDirtyProviding: AnyObject {
    var isDocumentEdited: Bool { get }
}

/// Real dirty-state provider: reads the framework NSDocument reachable from the window.
final class WindowDocumentDirtyProvider: DocumentDirtyProviding {
    private weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }
    var isDocumentEdited: Bool { window?.windowController?.document?.isDocumentEdited ?? false }
}

/// Abstracts the coordinated disk read so the controller is testable without real files.
protocol DocumentDiskReading {
    func readText(at url: URL) -> String?
    func modificationDate(at url: URL) -> Date?
}

/// Real disk reader: sandbox-safe coordinated read + UTF-8 decode.
struct FileSystemDiskReader: DocumentDiskReading {
    func readText(at url: URL) -> String? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var text: String?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                text = String(data: data, encoding: .utf8)
            }
        }
        return text
    }

    func modificationDate(at url: URL) -> Date? {
        LineformDocument.modificationDate(at: url)
    }
}

/// Owns the file watcher + debounce, decides via `DocumentReloadPolicy`, and publishes a
/// `ReloadResult` the view applies. Never mutates the document itself.
@MainActor
final class DocumentReloadController: ObservableObject {
    @Published private(set) var lastReload: ReloadResult?

    /// The current in-memory text, kept up to date by the view; used for the disk-vs-memory
    /// comparison that suppresses reloads from the app's own saves.
    var currentText: String = ""

    private let diskReader: DocumentDiskReading
    private let debounceInterval: TimeInterval
    private var url: URL?
    private weak var dirtyProvider: DocumentDirtyProviding?
    private var watcher: DocumentFileWatcher?
    private var debounceWorkItem: DispatchWorkItem?

    init(
        diskReader: DocumentDiskReading = FileSystemDiskReader(),
        debounceInterval: TimeInterval = DocumentReloadPolicy.debounceInterval
    ) {
        self.diskReader = diskReader
        self.debounceInterval = debounceInterval
    }

    /// Point the controller at the current document's URL + dirty provider. Re-registers the
    /// file watcher when the URL changes. Passing a nil URL stops watching (untitled doc).
    func update(url newURL: URL?, dirtyProvider: DocumentDirtyProviding?) {
        self.dirtyProvider = dirtyProvider
        guard newURL != url else { return }
        stop()
        url = newURL
        guard let newURL else { return }
        let watcher = DocumentFileWatcher(url: newURL) { [weak self] in
            Task { @MainActor in self?.fileDidChange() }
        }
        self.watcher = watcher
        NSFileCoordinator.addFilePresenter(watcher)
    }

    /// Presenter entry point: schedule a trailing-debounced evaluation.
    func fileDidChange() {
        debounceWorkItem?.cancel()
        guard debounceInterval > 0 else { evaluate(); return }
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Run the reload decision and publish a result on `.reload`.
    func evaluate() {
        guard let url else { return }
        guard let diskText = diskReader.readText(at: url) else { return }
        let isDirty = dirtyProvider?.isDocumentEdited ?? false
        switch DocumentReloadPolicy.decide(isDocumentEdited: isDirty, diskText: diskText, currentText: currentText) {
        case .reload:
            lastReload = ReloadResult(text: diskText, modificationDate: diskReader.modificationDate(at: url))
        case .ignoreDirty, .ignoreUnchanged:
            break
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let watcher { NSFileCoordinator.removeFilePresenter(watcher) }
        watcher = nil
    }

    deinit {
        if let watcher { NSFileCoordinator.removeFilePresenter(watcher) }
    }
}

/// A minimal NSFilePresenter that forwards change/move/delete to the controller. Handling a
/// move by re-pointing is done by the controller's `update`; here we simply signal a change.
final class DocumentFileWatcher: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.onChange = onChange
    }

    func presentedItemDidChange() { onChange() }
}
```

Note on `deinit`: `NSFileCoordinator.removeFilePresenter` is safe to call from deinit; the `watcher` is a plain reference so no main-actor hop is needed for the removal call itself.

- [ ] **Step 4: Add the source file to the Lineform target and run to verify tests pass**

Add `DocumentReloadController.swift` to the `Lineform` target in `project.pbxproj`. Then:

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/DocumentReloadControllerTests 2>&1 | tail -20`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Documents/DocumentReloadController.swift LineformTests/DocumentReloadControllerTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add live-reload controller and NSFilePresenter file watcher"
```

---

### Task 5: The "Updated" status indicator

**Files:**
- Modify: `Lineform/Editor/EditorStatusPresentation.swift`

**Interfaces:**
- Produces: `EditorStatusFormatter.updatedIndicatorText: String` (= `"Updated"`); `EditorStatusBar` gains a `showsUpdatedIndicator: Bool` parameter.

- [ ] **Step 1: Read the current status bar**

Read `Lineform/Editor/EditorStatusPresentation.swift` in full (it is small) to see the exact `EditorStatusFormatter` enum and `EditorStatusBar` initializer/body before editing.

- [ ] **Step 2: Add the formatter constant**

In `EditorStatusFormatter` (the enum), add:

```swift
    static let updatedIndicatorText = "Updated"
```

- [ ] **Step 3: Add the transient indicator to EditorStatusBar**

Add a `var showsUpdatedIndicator: Bool = false` stored property to `EditorStatusBar` (with a default so existing call sites still compile), and render it inside the existing `HStack` (the body around `EditorStatusPresentation.swift:68-80`) as a leading, secondary-styled element shown only when true. Example shape (adapt names to the real body):

```swift
HStack(spacing: 8) {
    if showsUpdatedIndicator {
        Text(EditorStatusFormatter.updatedIndicatorText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
            .accessibilityLabel("Document updated from disk")
    }
    Text(EditorStatusFormatter.metadataText(lastSavedDisplay: lastSavedDisplay, statisticsText: statisticsText))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
}
```

Keep the existing accessibility label wiring intact.

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED` (existing `EditorStatusBar(...)` call site still compiles via the defaulted parameter).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorStatusPresentation.swift
git commit -m "Add transient Updated indicator to editor status bar"
```

---

### Task 6: Wire the controller into EditorContainerView

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift`

**Interfaces:**
- Consumes: `DocumentReloadController`, `WindowDocumentDirtyProvider`, `ReloadResult` (Task 4); `EditorStatusBar.showsUpdatedIndicator` (Task 5); the `activeWindow` computed property (`EditorContainerView.swift:292`).

**Behavior to wire:**
1. Register/re-register the watcher when the window resolves and after a sidebar swap.
2. Keep `controller.currentText` synced.
3. Apply `controller.lastReload`: clear `plainTextConversion`, set `document.text` (no `requestedSelection`, so scroll is preserved by Task 3), update the framework `NSDocument` (`fileModificationDate` + `updateChangeCount(.changeCleared)`), `DocumentSaveStatus.markSaved`, and flash "Updated".

- [ ] **Step 1: Add state**

Near the other `@State`/`@StateObject` declarations (`EditorContainerView.swift:5-19`), add:

```swift
    @StateObject private var reloadController = DocumentReloadController()
    @State private var showsUpdatedIndicator = false
    @State private var updatedIndicatorWorkItem: DispatchWorkItem?
```

- [ ] **Step 2: Add a registration helper + reload application helpers**

Add these private methods (near `replaceDocumentFromSidebar`, `EditorContainerView.swift:283`):

```swift
    private func registerReloadWatcher() {
        let window = activeWindow
        let provider = window.map { WindowDocumentDirtyProvider(window: $0) }
        reloadController.currentText = document.text
        reloadController.update(url: window?.windowController?.document?.fileURL, dirtyProvider: provider)
    }

    private func applyReload(_ result: ReloadResult) {
        // No requestedSelection is set, so MarkdownTextViewRepresentable preserves scroll.
        document.plainTextConversion = nil
        document.text = result.text
        reloadController.currentText = result.text

        if let backingDocument = activeWindow?.windowController?.document {
            backingDocument.fileModificationDate = result.modificationDate
            backingDocument.updateChangeCount(.changeCleared)
        }
        DocumentSaveStatus.shared.markSaved(documentID: document.id, at: result.modificationDate ?? Date())
        flashUpdatedIndicator()
        reloadController.clearLastReload()
    }

    private func flashUpdatedIndicator() {
        updatedIndicatorWorkItem?.cancel()
        withAnimation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
            showsUpdatedIndicator = true
        }
        let work = DispatchWorkItem {
            withAnimation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
                showsUpdatedIndicator = false
            }
        }
        updatedIndicatorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
```

Add a `clearLastReload()` method to `DocumentReloadController` (Task 4) so the view can reset the published value after applying:

```swift
    func clearLastReload() { lastReload = nil }
```

(Confirm the `EditorMotionPolicy.animation(_:reduceMotion:)` signature matches `EditorPresentation.swift:215`; if it takes/returns a different `Animation?` shape, adapt the two call sites accordingly. If no matching helper exists for this call shape, gate manually: `withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2))`.)

- [ ] **Step 3: Add lifecycle wiring to the view body**

Add these modifiers alongside the existing `.onAppear`/`.onChange` block (`EditorContainerView.swift:112-125`):

```swift
        .onChange(of: windowNumber) { _, _ in
            registerReloadWatcher()
        }
        .onChange(of: reloadController.lastReload) { _, result in
            guard let result else { return }
            applyReload(result)
        }
        .onChange(of: documentSaveStatus.savedAt(for: document.id)) { _, _ in
            // A first save on an untitled doc (or any save) can create/replace the file URL;
            // re-point the watcher. Cheap + idempotent (no-op when the URL is unchanged).
            registerReloadWatcher()
        }
        .onDisappear {
            reloadController.stop()
        }
```

And extend the existing `.onChange(of: document.text)` handler (`:121`) to keep the controller's snapshot fresh — add this line inside that closure:

```swift
            reloadController.currentText = newValue
```

- [ ] **Step 4: Re-register after a sidebar swap**

In `replaceDocumentFromSidebar` (`:283-290`), after the `document.plainTextConversion = replacement.plainTextConversion` line, append:

```swift
        DispatchQueue.main.async { registerReloadWatcher() }
```

(Async so it runs after the window's `NSDocument.fileURL` has been retargeted by the sidebar opener, `OutlineSidebarView.swift:1120`.)

- [ ] **Step 5: Pass the indicator into the status bar**

Update the `EditorStatusBar(...)` instantiation (`EditorContainerView.swift:195-201`) to pass `showsUpdatedIndicator: showsUpdatedIndicator`.

- [ ] **Step 6: Build**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift Lineform/Documents/DocumentReloadController.swift
git commit -m "Wire live-reload controller into the editor"
```

---

### Task 7: Hosted integration test — scroll-preserving clean reload

**Files:**
- Modify: `LineformTests/EditorDisplayModeTests.swift` (the `makeEditorDrawerHarness()` harness lives here, `:711`).

**Interfaces:**
- Consumes: `makeEditorDrawerHarness()` and the `descendants(ofType:)` helper used in that file.

**Note on flakiness:** this test asserts final scroll position, not a sub-second animation, so it is not subject to the load-sensitive timing the CLAUDE.md note warns about — but still quit Xcode for the full run.

- [ ] **Step 1: Read the harness**

Read `LineformTests/EditorDisplayModeTests.swift:700-760` to confirm the exact `makeEditorDrawerHarness()` signature, how it exposes the `LineformTextView` and the document `Binding`, and the `runMainLoop(for:)` helper.

- [ ] **Step 2: Write the integration test**

Add to `EditorDisplayModeTests` a test that: builds a harness with a long document, scrolls to the middle, replaces `document.text` with different long content **without** setting `requestedSelection`, pumps the run loop, and asserts the scroll offset ratio is approximately preserved (not reset to top). Adapt the harness accessors to the real API discovered in Step 1:

```swift
    @MainActor
    func testExternalReloadPreservesProportionalScroll() {
        let longText = (0..<400).map { "Line \($0)" }.joined(separator: "\n")
        let harness = makeEditorDrawerHarness(text: longText)   // adapt to real signature
        runMainLoop(for: 0.2)

        guard let textView = harness.hostingView.descendants(ofType: LineformTextView.self).first,
              let scrollView = textView.enclosingScrollView else {
            return XCTFail("no text view")
        }

        // Scroll to the middle.
        let midOrigin = (textView.bounds.height - scrollView.contentView.bounds.height) * 0.5
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: midOrigin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        runMainLoop(for: 0.1)
        let ratioBefore = textView.captureProportionalScrollOffset()
        XCTAssertGreaterThan(ratioBefore, 0.2)

        // Simulate an external reload: replace text, no requestedSelection.
        let newText = (0..<400).map { "Reloaded line \($0)" }.joined(separator: "\n")
        harness.document.wrappedValue.text = newText   // adapt to real binding accessor
        runMainLoop(for: 0.3)

        let ratioAfter = textView.captureProportionalScrollOffset()
        XCTAssertEqual(ratioAfter, ratioBefore, accuracy: 0.1, "reload should preserve scroll, not jump to top")
    }
```

- [ ] **Step 3: Run the test to verify it passes**

Quit Xcode, then:
Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/EditorDisplayModeTests/testExternalReloadPreservesProportionalScroll 2>&1 | tail -20`
Expected: PASS. If the harness signature differs, fix the accessors (Step 1) — do not weaken the assertion.

- [ ] **Step 4: Commit**

```bash
git add LineformTests/EditorDisplayModeTests.swift
git commit -m "Add hosted test: external reload preserves scroll"
```

---

### Task 8: Final verification, docs, and index

**Files:**
- Modify (if needed): `CLAUDE.md` (Main Features), `README.md`.
- Modify: `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`.

- [ ] **Step 1: Full serial suite**

Quit Xcode; run the Global-Constraints gate:
```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -40
```
Expected: PASS, 0 failures. Record exact "Executed N tests" counts. The total should be the prior baseline + 16 new tests (10 policy + 6 controller) + 1 integration.

- [ ] **Step 2: Build Release config**

```bash
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -configuration Release -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual smoke (per spec)**

Launch the app, open a saved `.md`, and from Terminal:
- `echo "appended line" >> /path/to/open.md` → window updates within ~½s; "Updated" shows in Write/Preview; scroll roughly preserved.
- Burst: `for i in $(seq 1 5); do echo "x$i" >> /path/to/open.md; done` → a single reload.
- Type an unsaved edit, then `echo z >> file.md` externally → in-memory edit NOT clobbered.
- `mv file.md file2.md` then `rm` an open file externally → no crash, editor keeps text.
- Sidebar-swap to another file, edit *that* file externally → it reloads.

Report which checks passed. If any manual state could not be exercised, say so explicitly (per CLAUDE.md quality bar).

- [ ] **Step 4: Docs**

Only if warranted: add a one-line "Live reload" entry to the **Main Features** list in `CLAUDE.md` and to `README.md`'s feature list. Keep copy restrained and native. Do not add docs just to add them; if the feature list already implies it, skip. Note the NSFilePresenter-object approach is spec-documented, so no architecture-map change is required unless a reviewer flags it.

- [ ] **Step 5: Update the decomposition index**

In `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`, check off `- [x] 1 — Live reload`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Mark live reload complete in agent-reader index"
```

---

## Notes for the implementer

- **The self-write guard is load-bearing.** Without the `diskText == currentText` check (`.ignoreUnchanged`), the app's own autosave triggers our presenter and causes reload churn. It is tested (`testUnchangedFileDoesNotReload`).
- **Dirty gate reads the framework NSDocument**, not `DocumentSaveStatus`. `WindowDocumentDirtyProvider` bridges via `window.windowController?.document?.isDocumentEdited`.
- **Scroll discriminator:** live reload preserves scroll precisely because it sets no `requestedSelection`; the sidebar swap sets `(0,0)` and keeps its scroll-to-top. Do not add a `requestedSelection` to the reload path.
- **pbxproj is the sneaky failure mode:** four new files must be in their targets. If the build errors "Build input file cannot be found" or a test type is "not found", a pbxproj entry was missed. Prefer the `xcodeproj` ruby gem (`ruby -e 'require "xcodeproj"'` to check); else add the `PBXBuildFile`, `PBXFileReference`, and group-`children` lines by hand, mirroring an existing sibling file's three entries.
- **Read mode limitation is intended:** the status bar is hidden in Read mode, so "Updated" text is not shown there; the content still reloads. Do not add a banner.
- **Do not weaken `EditorDisplayModeTests`** to accommodate the new hosted test; it asserts final scroll position and should be stable. Quit Xcode for full runs.
