# Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS Settings… (⌘,) window with three preferences — show sidebar on launch, keep root folders expanded, and show iCloud in sidebar (hide-only) — persisted in `UserDefaults` and applied to the Files sidebar.

**Architecture:** A shared `LineformSettingsStore` `ObservableObject` (modeled on `HiddenFoldersMenuState`) backs three `UserDefaults` keys. A SwiftUI `Settings` scene renders a General pane. The two sidebar-affecting settings are applied live where `OutlineFileBrowserView` reads them (SwiftUI observation, no notifications); the launch setting seeds `EditorContainerView` at window construction. The iCloud toggle is gated by an off-main-thread emptiness probe behind a protocol, surfaced as an inline "Checking…" state.

**Tech Stack:** SwiftUI, AppKit, `UserDefaults`, XCTest. macOS document-based app. No new dependencies.

## Global Constraints

- **No `@AppStorage`.** Persist via `static let ...DefaultsKey` + `UserDefaults` + `@Published didSet`, mirroring `OutlineFileBrowserStore` / `HiddenFoldersMenuState`. Read initial values into backing storage in `init` (didSet fires on init assignments).
- **Never write to or delete anything in iCloud Drive.** "Turn off iCloud" only hides the sidebar root (a persisted Bool). The probe only *reads*.
- **Preserve iCloud laziness.** No iCloud container scan at view construction / launch. The probe runs only when the Settings pane appears, off the main thread, and touches no window's `OutlineFileBrowserStore`.
- **iCloud container id:** `iCloud.com.lineform.app` (Debug has no iCloud entitlement → resolves nil → unavailable).
- **UserDefaults key namespace:** `Lineform.settings.*`.
- **New defaults:** `showSidebarOnLaunch = true`, `keepRootFoldersExpanded = false`, `showICloudInSidebar = true`.
- **Xcode project is hand-rolled** (objectVersion 56, no synced groups). Every new `.swift` file must be registered in `Lineform.xcodeproj/project.pbxproj` by editing 4 sections (PBXBuildFile, PBXFileReference, the group's `children`, and PBXSourcesBuildPhase `files`) with fresh sequential `1F0000xx` IDs. App-target files go in the Lineform target's sources phase; test files go in the LineformTests target's sources phase and the `LineformTests` group.
- **Test command:** `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`. QUIT XCODE before full-suite runs. To run one class: add `-only-testing:LineformTests/<ClassName>`.

## File Structure

**New files:**
- `Lineform/App/LineformSettings.swift` — settings model/logic: `LineformSettingsStore` (store), `ICloudFolderStatus` (enum), `ICloudFolderProbing` (protocol), `ICloudFolderProbe` (production impl), `ICloudSettingViewModel` (async toggle-state view-model). All non-View settings concerns, cohesive and small.
- `Lineform/App/SettingsView.swift` — the SwiftUI General pane (view only) + its static copy constants.
- `LineformTests/LineformSettingsTests.swift` — tests for the store, probe, view-model, and the sidebar composition helpers.

**Modified files:**
- `Lineform/App/LineformApp.swift` — add the `Settings` scene.
- `Lineform/Editor/EditorContainerView.swift` — seed `isShowingOutline` from the launch setting.
- `Lineform/Outline/OutlineSidebarView.swift` — add pure composition helpers; `OutlineFileBrowserView` observes the store and applies the two live settings; `OutlineFileRootRow` gains a `lockExpanded` flag.
- `CLAUDE.md` — document the new Settings surface + the changed default launch behavior.
- `Lineform.xcodeproj/project.pbxproj` — register the 3 new files.

---

### Task 1: `LineformSettingsStore`

**Files:**
- Create: `Lineform/App/LineformSettings.swift`
- Test: `LineformTests/LineformSettingsTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (register both new files)

**Interfaces:**
- Produces: `LineformSettingsStore: ObservableObject` with `static let shared`, `@Published var showSidebarOnLaunch/keepRootFoldersExpanded/showICloudInSidebar: Bool`, `init(defaults: UserDefaults = .standard)`, and `static let showSidebarOnLaunchKey/keepRootFoldersExpandedKey/showICloudInSidebarKey: String`.

- [ ] **Step 1: Write the failing test**

Create `LineformTests/LineformSettingsTests.swift`:

```swift
import XCTest
@testable import Lineform

@MainActor
final class LineformSettingsTests: XCTestCase {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsAreSidebarOnLockOffICloudOn() {
        let store = LineformSettingsStore(defaults: freshDefaults("LineformSettingsDefaults"))
        XCTAssertTrue(store.showSidebarOnLaunch)
        XCTAssertFalse(store.keepRootFoldersExpanded)
        XCTAssertTrue(store.showICloudInSidebar)
    }

    func testEachSettingPersistsAcrossStoreInstances() {
        let defaults = freshDefaults("LineformSettingsPersist")
        let store = LineformSettingsStore(defaults: defaults)
        store.showSidebarOnLaunch = false
        store.keepRootFoldersExpanded = true
        store.showICloudInSidebar = false

        let restored = LineformSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.showSidebarOnLaunch)
        XCTAssertTrue(restored.keepRootFoldersExpanded)
        XCTAssertFalse(restored.showICloudInSidebar)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — `LineformSettingsStore` is undefined. (After creating the store in Step 3 and before registering files in pbxproj, compilation still fails; register in Step 4.)

- [ ] **Step 3: Write minimal implementation**

Create `Lineform/App/LineformSettings.swift`:

```swift
import Foundation

/// App-wide user preferences surfaced in the Settings window. Mirrors the
/// `HiddenFoldersMenuState` pattern: a shared `ObservableObject`, `UserDefaults`
/// keys, and `@Published didSet` write-through. No `@AppStorage`, to match the
/// rest of the app. `UserDefaults` is injectable for tests.
@MainActor
final class LineformSettingsStore: ObservableObject {
    static let shared = LineformSettingsStore()

    static let showSidebarOnLaunchKey = "Lineform.settings.showSidebarOnLaunch"
    static let keepRootFoldersExpandedKey = "Lineform.settings.keepRootFoldersExpanded"
    static let showICloudInSidebarKey = "Lineform.settings.showICloudInSidebar"

    @Published var showSidebarOnLaunch: Bool {
        didSet {
            guard oldValue != showSidebarOnLaunch else { return }
            defaults.set(showSidebarOnLaunch, forKey: Self.showSidebarOnLaunchKey)
        }
    }
    @Published var keepRootFoldersExpanded: Bool {
        didSet {
            guard oldValue != keepRootFoldersExpanded else { return }
            defaults.set(keepRootFoldersExpanded, forKey: Self.keepRootFoldersExpandedKey)
        }
    }
    @Published var showICloudInSidebar: Bool {
        didSet {
            guard oldValue != showICloudInSidebar else { return }
            defaults.set(showICloudInSidebar, forKey: Self.showICloudInSidebarKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Defaults that are `true` when the key is absent can't rely on
        // `bool(forKey:)` returning false, so read via `object(forKey:)` with an
        // explicit fallback. Assign backing storage directly (didSet fires on
        // init assignments — see OutlineFileBrowserStore.init).
        func boolOrDefault(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        _showSidebarOnLaunch = Published(initialValue: boolOrDefault(Self.showSidebarOnLaunchKey, true))
        _keepRootFoldersExpanded = Published(initialValue: boolOrDefault(Self.keepRootFoldersExpandedKey, false))
        _showICloudInSidebar = Published(initialValue: boolOrDefault(Self.showICloudInSidebarKey, true))
    }
}
```

- [ ] **Step 4: Register both new files in `project.pbxproj`**

Read `Lineform.xcodeproj/project.pbxproj`. Find the highest existing `1F0000xx` id. For `Lineform/App/LineformSettings.swift` (app target) and `LineformTests/LineformSettingsTests.swift` (test target), add entries in all four required sections each (PBXBuildFile, PBXFileReference, containing group `children`, correct target's PBXSourcesBuildPhase `files`). Put `LineformSettings.swift` in the `App` group; `LineformSettingsTests.swift` in the `LineformTests` group. Use fresh sequential ids. (Match the existing surrounding entries exactly for `isa`, `sourceTree = "<group>"`, `lastKnownFileType = sourcecode.swift`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Lineform/App/LineformSettings.swift LineformTests/LineformSettingsTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add LineformSettingsStore with three persisted preferences"
```

---

### Task 2: iCloud emptiness helper on the store

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (add a static helper on `OutlineFileBrowserStore`)
- Test: `LineformTests/LineformSettingsTests.swift` (add cases)

**Interfaces:**
- Produces: `static func OutlineFileBrowserStore.documentsFolderIsEmpty(at url: URL, fileManager: FileManager) -> Bool` — true when a scan of `url` yields zero display items (reuses the existing private `items(in:...)` scan so "empty" matches exactly what the sidebar would show, hidden files excluded).

- [ ] **Step 1: Write the failing test**

Add to `LineformSettingsTests.swift`:

```swift
extension LineformSettingsTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformSettingsProbe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDocumentsFolderIsEmptyForEmptyDirectory() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(OutlineFileBrowserStore.documentsFolderIsEmpty(at: dir, fileManager: .default))
    }

    func testDocumentsFolderIsEmptyIgnoresNonMarkdownFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("image.png"))
        XCTAssertTrue(OutlineFileBrowserStore.documentsFolderIsEmpty(at: dir, fileManager: .default))
    }

    func testDocumentsFolderIsNotEmptyWithMarkdown() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Hi".data(using: .utf8)!.write(to: dir.appendingPathComponent("note.md"))
        XCTAssertFalse(OutlineFileBrowserStore.documentsFolderIsEmpty(at: dir, fileManager: .default))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — `documentsFolderIsEmpty` is undefined.

- [ ] **Step 3: Write minimal implementation**

In `Lineform/Outline/OutlineSidebarView.swift`, inside `OutlineFileBrowserStore`, near the existing private `items(in:...)` static (around line 1171), add:

```swift
/// Whether a documents folder has no display-worthy content — used by the
/// Settings iCloud toggle to decide if the user may hide the iCloud root.
/// Reuses the same scan the sidebar tree uses (hidden files excluded, default
/// name sort) so "empty" here matches exactly what the sidebar would render.
/// Read-only; never writes to the folder.
static func documentsFolderIsEmpty(at url: URL, fileManager: FileManager) -> Bool {
    items(in: url, fileManager: fileManager, showsHiddenFolders: false).isEmpty
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (5 tests total).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/LineformSettingsTests.swift
git commit -m "Add documentsFolderIsEmpty helper for the iCloud settings guard"
```

---

### Task 3: iCloud folder probe

**Files:**
- Modify: `Lineform/App/LineformSettings.swift` (add enum + protocol + production impl)
- Test: `LineformTests/LineformSettingsTests.swift` (add cases)

**Interfaces:**
- Produces: `enum ICloudFolderStatus { case unavailable, empty, notEmpty }`; `protocol ICloudFolderProbing { func status() async -> ICloudFolderStatus }`; `struct ICloudFolderProbe: ICloudFolderProbing` with `init(documentsURLProvider: @escaping () -> URL?, fileManager: FileManager = .default)`.

- [ ] **Step 1: Write the failing test**

Add to `LineformSettingsTests.swift`:

```swift
extension LineformSettingsTests {
    func testProbeReportsUnavailableWhenNoContainer() async {
        let probe = ICloudFolderProbe(documentsURLProvider: { nil })
        let status = await probe.status()
        XCTAssertEqual(status, .unavailable)
    }

    func testProbeReportsEmptyForEmptyFolder() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = ICloudFolderProbe(documentsURLProvider: { dir })
        let status = await probe.status()
        XCTAssertEqual(status, .empty)
    }

    func testProbeReportsNotEmptyWithMarkdown() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Hi".data(using: .utf8)!.write(to: dir.appendingPathComponent("note.md"))
        let probe = ICloudFolderProbe(documentsURLProvider: { dir })
        let status = await probe.status()
        XCTAssertEqual(status, .notEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — `ICloudFolderProbe` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `Lineform/App/LineformSettings.swift`:

```swift
/// Availability + emptiness of the app's iCloud folder, for the Settings iCloud toggle.
enum ICloudFolderStatus: Equatable {
    case unavailable   // no iCloud / not signed in / Debug (no entitlement)
    case empty         // container resolves, no display content — may hide the root
    case notEmpty      // container resolves and has content — hiding is disallowed
}

/// Read-only probe of the iCloud folder. Behind a protocol so the Settings
/// view-model is testable without a real iCloud container.
protocol ICloudFolderProbing: Sendable {
    func status() async -> ICloudFolderStatus
}

struct ICloudFolderProbe: ICloudFolderProbing {
    /// Returns the app's iCloud Documents URL, or nil when unavailable. Resolving
    /// the ubiquity container is the expensive call, so this runs off the main
    /// thread (see the view-model). Defaults to the same resolution the sidebar uses.
    private let documentsURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager

    init(
        documentsURLProvider: @escaping @Sendable () -> URL? = ICloudFolderProbe.defaultDocumentsURL,
        fileManager: FileManager = .default
    ) {
        self.documentsURLProvider = documentsURLProvider
        self.fileManager = fileManager
    }

    static let defaultDocumentsURL: @Sendable () -> URL? = {
        FileManager.default
            .url(forUbiquityContainerIdentifier: OutlineFileBrowserStore.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    func status() async -> ICloudFolderStatus {
        guard let url = documentsURLProvider() else { return .unavailable }
        return OutlineFileBrowserStore.documentsFolderIsEmpty(at: url, fileManager: fileManager) ? .empty : .notEmpty
    }
}
```

Note: if `iCloudContainerIdentifier` is not accessible from this file, change its declaration in `OutlineFileBrowserStore` from the default (internal) to remain internal — it already is `static let` internal, so it is visible module-wide. No change needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
git add Lineform/App/LineformSettings.swift LineformTests/LineformSettingsTests.swift
git commit -m "Add ICloudFolderProbe for the Settings iCloud emptiness check"
```

---

### Task 4: iCloud settings view-model

**Files:**
- Modify: `Lineform/App/LineformSettings.swift` (add view-model)
- Test: `LineformTests/LineformSettingsTests.swift` (add cases)

**Interfaces:**
- Produces: `@MainActor final class ICloudSettingViewModel: ObservableObject` with `@Published private(set) var status: ICloudFolderStatus?` (nil = checking), `init(probe: ICloudFolderProbing)`, `func refresh() async`, and computed `var isChecking: Bool`, `var isControlVisible: Bool`, `var isToggleEnabled: Bool`.

- [ ] **Step 1: Write the failing test**

Add to `LineformSettingsTests.swift`:

```swift
private struct StubProbe: ICloudFolderProbing {
    let result: ICloudFolderStatus
    func status() async -> ICloudFolderStatus { result }
}

extension LineformSettingsTests {
    func testViewModelStartsChecking() {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty))
        XCTAssertNil(vm.status)
        XCTAssertTrue(vm.isChecking)
        XCTAssertFalse(vm.isToggleEnabled)   // disabled while unknown
        XCTAssertTrue(vm.isControlVisible)   // visible (as "Checking…") until proven unavailable
    }

    func testViewModelUnavailableHidesControl() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .unavailable))
        await vm.refresh()
        XCTAssertFalse(vm.isChecking)
        XCTAssertFalse(vm.isControlVisible)
    }

    func testViewModelEmptyEnablesToggle() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .empty))
        await vm.refresh()
        XCTAssertTrue(vm.isControlVisible)
        XCTAssertTrue(vm.isToggleEnabled)
    }

    func testViewModelNotEmptyDisablesToggle() async {
        let vm = ICloudSettingViewModel(probe: StubProbe(result: .notEmpty))
        await vm.refresh()
        XCTAssertTrue(vm.isControlVisible)
        XCTAssertFalse(vm.isToggleEnabled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — `ICloudSettingViewModel` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `Lineform/App/LineformSettings.swift`:

```swift
import SwiftUI

/// Drives the "Show iCloud in sidebar" control's enabled/visible/checking state
/// from an async probe. `status == nil` means the probe hasn't finished (inline
/// "Checking…"). The Settings pane owns one of these and calls `refresh()` from
/// `.task` when the window appears — never at app launch.
@MainActor
final class ICloudSettingViewModel: ObservableObject {
    @Published private(set) var status: ICloudFolderStatus?

    private let probe: ICloudFolderProbing

    init(probe: ICloudFolderProbing = ICloudFolderProbe()) {
        self.probe = probe
    }

    var isChecking: Bool { status == nil }

    /// Hidden only once we KNOW iCloud is unavailable. While checking we keep the
    /// row visible (showing "Checking…") so it doesn't flicker in/out.
    var isControlVisible: Bool { status != .unavailable }

    /// The toggle may be operated only when we've confirmed the folder is empty.
    var isToggleEnabled: Bool { status == .empty }

    func refresh() async {
        status = nil
        status = await probe.status()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (12 tests total).

- [ ] **Step 5: Commit**

```bash
git add Lineform/App/LineformSettings.swift LineformTests/LineformSettingsTests.swift
git commit -m "Add ICloudSettingViewModel for the inline Checking state"
```

---

### Task 5: Sidebar composition helpers

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (add 3 pure static helpers next to the existing `rootIsVisible`/`rootShowsDisclosure`)
- Test: `LineformTests/LineformSettingsTests.swift` (add cases)

**Interfaces:**
- Produces on `OutlineSidebarView`:
  - `static func iCloudRootVisible(state: OutlineFileRootState, showICloudInSidebar: Bool) -> Bool`
  - `static func rootDisclosureVisible(state: OutlineFileRootState, isEmpty: Bool, lockExpanded: Bool) -> Bool`
  - `static func rootIsCollapsed(isInCollapsedSet: Bool, lockExpanded: Bool) -> Bool`

- [ ] **Step 1: Write the failing test**

Add to `LineformSettingsTests.swift`:

```swift
extension LineformSettingsTests {
    func testICloudRootVisibleRequiresBothAvailabilityAndSetting() {
        // Available + setting on → visible
        XCTAssertTrue(OutlineSidebarView.iCloudRootVisible(state: .available, showICloudInSidebar: true))
        // Available + setting off → hidden
        XCTAssertFalse(OutlineSidebarView.iCloudRootVisible(state: .available, showICloudInSidebar: false))
        // Unavailable → hidden regardless of setting
        XCTAssertFalse(OutlineSidebarView.iCloudRootVisible(state: .unavailable, showICloudInSidebar: true))
    }

    func testRootDisclosureHiddenWhenLocked() {
        // Non-empty available root normally shows a chevron...
        XCTAssertTrue(OutlineSidebarView.rootDisclosureVisible(state: .available, isEmpty: false, lockExpanded: false))
        // ...but not when roots are locked expanded.
        XCTAssertFalse(OutlineSidebarView.rootDisclosureVisible(state: .available, isEmpty: false, lockExpanded: true))
    }

    func testRootIsCollapsedForcedFalseWhenLocked() {
        XCTAssertTrue(OutlineSidebarView.rootIsCollapsed(isInCollapsedSet: true, lockExpanded: false))
        XCTAssertFalse(OutlineSidebarView.rootIsCollapsed(isInCollapsedSet: true, lockExpanded: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — the three helpers are undefined.

- [ ] **Step 3: Write minimal implementation**

In `Lineform/Outline/OutlineSidebarView.swift`, right after `rootIsVisible(id:state:)` (line 139), add:

```swift
/// The iCloud root shows only when its container resolves AND the user hasn't
/// hidden it in Settings. Workspace visibility is unaffected by this setting.
static func iCloudRootVisible(state: OutlineFileRootState, showICloudInSidebar: Bool) -> Bool {
    rootIsVisible(id: "icloud", state: state) && showICloudInSidebar
}

/// A root's collapse chevron is suppressed entirely when the user has locked
/// roots expanded (Settings › Keep root folders expanded).
static func rootDisclosureVisible(state: OutlineFileRootState, isEmpty: Bool, lockExpanded: Bool) -> Bool {
    rootShowsDisclosure(state: state, isEmpty: isEmpty) && !lockExpanded
}

/// When roots are locked expanded, a root is never treated as collapsed even if
/// its id lingers in the in-memory collapsed set (so toggling the setting back
/// off restores the prior in-session state).
static func rootIsCollapsed(isInCollapsedSet: Bool, lockExpanded: Bool) -> Bool {
    !lockExpanded && isInCollapsedSet
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (15 tests total).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/LineformSettingsTests.swift
git commit -m "Add pure sidebar composition helpers for the new settings"
```

---

### Task 6: Apply the two live settings in `OutlineFileBrowserView`

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (`OutlineFileBrowserView` ~line 1254, `OutlineFileRootRow` ~line 1361)

**Interfaces:**
- Consumes: `LineformSettingsStore.shared`, and the helpers from Task 5.

- [ ] **Step 1: Observe the settings store in `OutlineFileBrowserView`**

In `OutlineFileBrowserView` (line 1254), add near the other stored properties (after line 1262):

```swift
@ObservedObject private var settings = LineformSettingsStore.shared
```

- [ ] **Step 2: Gate the iCloud root render**

Replace lines 1269–1271:

```swift
if OutlineSidebarView.iCloudRootVisible(state: store.iCloudRoot.state, showICloudInSidebar: settings.showICloudInSidebar) {
    rootView(store.iCloudRoot)
}
```

- [ ] **Step 3: Route root-collapse checks through the lock setting**

Add a helper in `OutlineFileBrowserView` (near `toggle(_:)`, line 1348):

```swift
private func isRootCollapsed(_ id: String) -> Bool {
    OutlineSidebarView.rootIsCollapsed(
        isInCollapsedSet: collapsedIDs.contains(id),
        lockExpanded: settings.keepRootFoldersExpanded
    )
}
```

In `rootView(_:)`, replace every `collapsedIDs.contains(root.id)` with `isRootCollapsed(root.id)` — the three occurrences at lines 1287, 1295, and 1301. (Leave the per-node `$collapsedIDs` binding threaded into `OutlineFileTreeNodeView` at line 1320 unchanged; the lock only governs *root* sections.)

- [ ] **Step 4: Pass the lock flag into the root row**

In `rootView(_:)`, update the `OutlineFileRootRow(...)` call (line 1285) to add:

```swift
lockExpanded: settings.keepRootFoldersExpanded,
```

Then in `OutlineFileRootRow` (line 1361), add the stored property:

```swift
var lockExpanded: Bool = false
```

and change its `showsDisclosure` computed var (line 1460):

```swift
private var showsDisclosure: Bool {
    OutlineSidebarView.rootDisclosureVisible(
        state: root.state,
        isEmpty: root.items.isEmpty,
        lockExpanded: lockExpanded
    )
}
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Run the full sidebar test class to confirm no regressions**

Run: `xcodebuild test ... -only-testing:LineformTests/OutlineSidebarViewTests -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift
git commit -m "Apply Show iCloud + Keep roots expanded settings live in the sidebar"
```

---

### Task 7: Seed sidebar-on-launch in `EditorContainerView`

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift` (lines 11, 29-37)
- Test: `LineformTests/LineformSettingsTests.swift`

**Interfaces:**
- Produces: `static func EditorContainerView.initialOutlineVisible(settings: LineformSettingsStore) -> Bool`.

- [ ] **Step 1: Write the failing test**

Add to `LineformSettingsTests.swift`:

```swift
extension LineformSettingsTests {
    func testInitialOutlineVisibleFollowsSetting() {
        let defaults = freshDefaults("LineformSettingsLaunchSeed")
        let store = LineformSettingsStore(defaults: defaults)

        store.showSidebarOnLaunch = true
        XCTAssertTrue(EditorContainerView.initialOutlineVisible(settings: store))

        store.showSidebarOnLaunch = false
        XCTAssertFalse(EditorContainerView.initialOutlineVisible(settings: store))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — `initialOutlineVisible` undefined.

- [ ] **Step 3: Write minimal implementation**

In `EditorContainerView.swift`, change line 11 from:

```swift
@State private var isShowingOutline = false
```

to:

```swift
@State private var isShowingOutline: Bool
```

Add the static helper (near the top of the struct, before `init`):

```swift
/// New windows open with the sidebar in the user's preferred launch state
/// (Settings › Show sidebar on launch, default on). This governs the initial
/// value only; once open, the user's ⌥⌘0 toggle takes over.
static func initialOutlineVisible(settings: LineformSettingsStore) -> Bool {
    settings.showSidebarOnLaunch
}
```

Update `init` (lines 29-37) to seed the state, adding a `settings` parameter defaulting to the shared store:

```swift
init(
    document: Binding<LineformDocument>,
    readingProfileStore: ReadingProfileStore = ReadingProfileStore(),
    fileBrowserStore: OutlineFileBrowserStore? = nil,
    settings: LineformSettingsStore = .shared
) {
    _document = document
    _readingProfileStore = StateObject(wrappedValue: readingProfileStore)
    injectedFileBrowserStore = fileBrowserStore
    _isShowingOutline = State(initialValue: Self.initialOutlineVisible(settings: settings))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (17 tests total).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift LineformTests/LineformSettingsTests.swift
git commit -m "Seed sidebar-on-launch from the new setting (default open)"
```

---

### Task 8: `SettingsView` General pane

**Files:**
- Create: `Lineform/App/SettingsView.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (register the new file)
- Test: `LineformTests/LineformSettingsTests.swift` (copy constants)

**Interfaces:**
- Consumes: `LineformSettingsStore`, `ICloudSettingViewModel`.
- Produces: `struct SettingsView: View` with `init(settings: LineformSettingsStore, iCloudViewModel: ICloudSettingViewModel = ICloudSettingViewModel())`; static copy constants used in the test.

- [ ] **Step 1: Write the failing test**

Add to `LineformSettingsTests.swift`:

```swift
extension LineformSettingsTests {
    func testSettingsCopyIsAccurateAndHonest() {
        XCTAssertEqual(SettingsView.showSidebarOnLaunchTitle, "Show sidebar on launch")
        XCTAssertEqual(SettingsView.keepRootsExpandedTitle, "Keep root folders expanded")
        XCTAssertEqual(SettingsView.showICloudTitle, "Show iCloud in sidebar")
        // The iCloud note must promise no destructive iCloud action.
        XCTAssertTrue(SettingsView.iCloudDisabledNote.contains("empty"))
        XCTAssertTrue(SettingsView.iCloudDisabledNote.lowercased().contains("does not delete"))
        XCTAssertEqual(SettingsView.iCloudCheckingNote, "Checking…")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: FAIL to compile — `SettingsView` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Lineform/App/SettingsView.swift`:

```swift
import SwiftUI

/// The app's Settings window (⌘,). A single restrained "General" pane with the
/// three preferences. Native `Form`; no custom chrome.
struct SettingsView: View {
    @ObservedObject var settings: LineformSettingsStore
    @StateObject private var iCloud: ICloudSettingViewModel

    static let showSidebarOnLaunchTitle = "Show sidebar on launch"
    static let keepRootsExpandedTitle = "Keep root folders expanded"
    static let keepRootsExpandedNote = "Root sections stay open and can't be collapsed."
    static let showICloudTitle = "Show iCloud in sidebar"
    static let iCloudCheckingNote = "Checking…"
    static let iCloudDisabledNote = "Only available when your Lineform iCloud folder is empty. This hides iCloud in Lineform's sidebar; it does not delete anything from iCloud Drive."

    init(
        settings: LineformSettingsStore,
        iCloudViewModel: ICloudSettingViewModel = ICloudSettingViewModel()
    ) {
        self.settings = settings
        _iCloud = StateObject(wrappedValue: iCloudViewModel)
    }

    var body: some View {
        Form {
            Toggle(Self.showSidebarOnLaunchTitle, isOn: $settings.showSidebarOnLaunch)

            VStack(alignment: .leading, spacing: 2) {
                Toggle(Self.keepRootsExpandedTitle, isOn: $settings.keepRootFoldersExpanded)
                Text(Self.keepRootsExpandedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if iCloud.isControlVisible {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(Self.showICloudTitle, isOn: $settings.showICloudInSidebar)
                        .disabled(!iCloud.isToggleEnabled)
                    if iCloud.isChecking {
                        Text(Self.iCloudCheckingNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !iCloud.isToggleEnabled {
                        Text(Self.iCloudDisabledNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await iCloud.refresh() }
    }
}
```

- [ ] **Step 4: Register the new file in `project.pbxproj`**

Add `Lineform/App/SettingsView.swift` to the app target (4 sections, fresh `1F0000xx` id, in the `App` group), as in Task 1 Step 4.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/LineformSettingsTests`
Expected: PASS (18 tests total).

- [ ] **Step 6: Commit**

```bash
git add Lineform/App/SettingsView.swift LineformTests/LineformSettingsTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add SettingsView General pane with inline iCloud Checking state"
```

---

### Task 9: Wire the `Settings` scene into `LineformApp`

**Files:**
- Modify: `Lineform/App/LineformApp.swift` (body, after the `DocumentGroup`)

- [ ] **Step 1: Add the scene**

In `LineformApp.body` (after the `DocumentGroup`'s `.commands { ... }` closure at line 26, still inside `body`), add:

```swift
Settings {
    SettingsView(settings: LineformSettingsStore.shared)
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Lineform/App/LineformApp.swift
git commit -m "Add Settings scene (Settings… ⌘,) to the app menu"
```

---

### Task 10: Full-suite gate + manual QA

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

QUIT XCODE first. Warn the user a TCC "access your Documents folder" prompt will appear near the end — they must click Allow.

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: all tests PASS. Record exact pass/fail counts.

- [ ] **Step 2: Manual QA (drive the running app)**

Build & launch, then verify:
1. **Settings… (⌘,)** appears in the Lineform menu and opens the window.
2. A new window opens with the sidebar **showing** (new default). Toggle **Show sidebar on launch** off → open a new window (⌘N) → sidebar is **closed**.
3. Toggle **Keep root folders expanded** on → the Files-tab root chevrons disappear and roots can't be collapsed; toggle off → chevrons return, prior collapse state intact.
4. **Show iCloud in sidebar**: with an empty iCloud folder, toggle is enabled; turning it off hides the iCloud root live; turning on restores it. With a non-empty iCloud folder, the toggle is disabled with the "…does not delete anything…" note. In Debug (no entitlement) the whole iCloud control is absent, and no iCloud file is ever modified.
5. Confirm the pane shows **Checking…** briefly on open when signed into iCloud.

- [ ] **Step 3: Commit any QA fixes** (only if issues found; otherwise skip).

---

### Task 11: Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `CLAUDE.md`**

Add a "Settings window" bullet to Main Features describing: native Settings… (⌘,) scene backed by `LineformSettingsStore` (UserDefaults, not `@AppStorage`); the three prefs and their defaults; that **Show sidebar on launch defaults on** (a change from the old closed-on-launch behavior); that **Show iCloud in sidebar** is hide-only and **never touches iCloud Drive** (guarded by an off-main-thread `ICloudFolderProbe`, disabled unless the folder is empty, preserving the iCloud-laziness invariant); and that the two sidebar settings apply live via SwiftUI observation while launch is read at window construction. Keep it consistent with the existing iCloud-safety and laziness notes.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Docs: document the Settings window and its preferences"
```

---

## Self-Review

**Spec coverage:**
- Settings scene / ⌘, placement → Task 9. ✓
- `LineformSettingsStore` (UserDefaults, no @AppStorage, defaults true/false/true) → Task 1. ✓
- Show sidebar on launch (default on, seeds EditorContainerView) → Task 7. ✓
- Keep root folders expanded (default off, hides chevron, locks open) → Tasks 5-6. ✓
- Show iCloud in sidebar (hide-only, disabled when not empty, hidden when unavailable, never touches iCloud) → Tasks 3-6, 8. ✓
- Inline "Checking…" off-main-thread probe behind a protocol → Tasks 3-4, 8. ✓
- Live-apply via observation; launch read at construction → Tasks 6-7. ✓
- iCloud-laziness preserved (probe self-contained, only on pane appear) → Tasks 3-4, 8 (`.task`). ✓
- Tests for store defaults/persistence, visibility composition, disclosure composition, probe → Tasks 1-5, 8. ✓
- Docs → Task 11. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `ICloudFolderStatus` (`.unavailable/.empty/.notEmpty`), `ICloudFolderProbing.status() async`, `ICloudSettingViewModel` (`status`/`isChecking`/`isControlVisible`/`isToggleEnabled`/`refresh()`), `documentsFolderIsEmpty(at:fileManager:)`, `iCloudRootVisible`/`rootDisclosureVisible`/`rootIsCollapsed`, `initialOutlineVisible(settings:)`, `LineformSettingsStore` property/key names — all consistent across tasks. ✓

**Note on the emptiness definition:** `documentsFolderIsEmpty` reuses the store's private `items(in:...)` scan with `showsHiddenFolders: false`, matching the default sidebar view exactly (a folder containing only hidden or non-Markdown files reads as empty — acceptable and consistent).
