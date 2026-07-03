# Files Sidebar Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Files sidebar reflect external file-system changes live, add per-section sort (Name / Date Created / Date Modified), add right-click Rename/Delete/Show-in-Finder (rename only for folders) with Muse-style native dialogs, add File-menu Rename…/Delete… commands, investigate the spurious save-prompt report, and wire accessibility for all of it.

**Architecture:** `OutlineFileBrowserStore` (in `Lineform/Outline/OutlineSidebarView.swift`) gains per-root sort preferences, date capture in its scan, and an FSEvents-based watcher (behind a factory protocol, running only while the Files tab is visible). File operations (rename via `NSFileCoordinator` move, delete via trash-only) live in a new `Lineform/Outline/SidebarFileActions.swift` with pure logic separated from `NSAlert` presentation. The sidebar rows stay dumb: context-menu actions are closures supplied by `EditorContainerView`, which performs operations and broadcasts `LineformAppNotification`s so every window's sidebar refreshes and any window showing a renamed/deleted file retargets its document. Menu-bar commands follow the existing Show Hidden Folders notification pattern.

**Tech Stack:** SwiftUI + AppKit (NSAlert, FSEvents, NSFileCoordinator), XCTest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-03-files-sidebar-improvements-design.md`.
- Delete is ALWAYS `trashItem` — never `removeItem` — and always behind a confirmation dialog (Cancel is the Return-key default; Delete marked destructive).
- No folder delete. No manual sort. No file moving.
- The iCloud scan must never run for windows not showing the Files tab (preserve the deferred-scan invariant; watcher lifecycle is tied to Files-tab visibility).
- The workspace security scope stays HELD by the store for its lifetime — do not add transient start/stop access anywhere.
- Do not add an iCloud entitlement to Debug. No new entitlements at all.
- Build gate during execution: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'` (build-only; CLI *test* runs trigger a TCC prompt on this machine — run focused tests per task, full suite once at the end with the user present).
- Focused test command shape: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<ClassName>`.
- Commit after each task with a short imperative subject plus the standard Claude trailer lines used in this repo.

---

### Task 1: Sort model — `OutlineFileSortOrder`, dates on `OutlineFileTreeItem`, sorted scans, persisted per-root preference

**Files:**
- Create: `Lineform/Outline/OutlineFileSortOrder.swift`
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (`OutlineFileTreeItem` ~:11-41, `OutlineFileBrowserStore` ~:557-1038)
- Test: create `LineformTests/OutlineFileSortOrderTests.swift`

**Interfaces:**
- Produces: `enum OutlineFileSortOrder: String, CaseIterable, Identifiable { case name, dateCreated, dateModified }` with `var title: String` ("Name", "Date Created", "Date Modified"), `static func sorted(_ items: [OutlineFileTreeItem], by order: OutlineFileSortOrder) -> [OutlineFileTreeItem]`.
- Produces: `OutlineFileTreeItem.createdAt: Date?`, `OutlineFileTreeItem.modifiedAt: Date?` (Codable-tolerant of old snapshots).
- Produces: `OutlineFileBrowserStore.iCloudSortOrder` / `.workspaceSortOrder` (`@Published`), defaults keys `Lineform.outline.sortOrder.icloud` / `Lineform.outline.sortOrder.workspace` as `static let iCloudSortOrderDefaultsKey` / `workspaceSortOrderDefaultsKey`.

- [ ] **Step 1: Write failing tests** in `LineformTests/OutlineFileSortOrderTests.swift`:

```swift
import XCTest
@testable import Lineform

final class OutlineFileSortOrderTests: XCTestCase {
    private func item(_ name: String, isDirectory: Bool = false, created: Date? = nil, modified: Date? = nil, children: [OutlineFileTreeItem] = []) -> OutlineFileTreeItem {
        OutlineFileTreeItem(
            url: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            children: children,
            createdAt: created,
            modifiedAt: modified
        )
    }

    func testSortTitlesMatchMuseStyleMenuWithoutManual() {
        XCTAssertEqual(OutlineFileSortOrder.allCases.map(\.title), ["Name", "Date Created", "Date Modified"])
    }

    func testNameSortKeepsFoldersFirstThenNaturalNameOrder() {
        let items = [item("b.md"), item("10.md"), item("2.md"), item("Zed", isDirectory: true), item("Alpha", isDirectory: true)]
        let sorted = OutlineFileSortOrder.sorted(items, by: .name)
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Zed", "2.md", "10.md", "b.md"])
    }

    func testDateSortsAreNewestFirstWithinFoldersThenFiles() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let items = [
            item("old.md", created: old, modified: old),
            item("new.md", created: new, modified: new),
            item("OldFolder", isDirectory: true, created: old, modified: old),
            item("NewFolder", isDirectory: true, created: new, modified: new)
        ]
        XCTAssertEqual(OutlineFileSortOrder.sorted(items, by: .dateCreated).map(\.name), ["NewFolder", "OldFolder", "new.md", "old.md"])
        XCTAssertEqual(OutlineFileSortOrder.sorted(items, by: .dateModified).map(\.name), ["NewFolder", "OldFolder", "new.md", "old.md"])
    }

    func testMissingDatesSortLastAndFallBackToName() {
        let dated = Date(timeIntervalSince1970: 100)
        let items = [item("b-undated.md"), item("a-undated.md"), item("dated.md", created: dated, modified: dated)]
        XCTAssertEqual(OutlineFileSortOrder.sorted(items, by: .dateCreated).map(\.name), ["dated.md", "a-undated.md", "b-undated.md"])
    }

    func testSortRecursesIntoChildren() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let folder = item("Folder", isDirectory: true, children: [item("old.md", created: old, modified: old), item("new.md", created: new, modified: new)])
        let sorted = OutlineFileSortOrder.sorted([folder], by: .dateModified)
        XCTAssertEqual(sorted.first?.children.map(\.name), ["new.md", "old.md"])
    }

    func testTreeItemDecodingToleratesSnapshotsWithoutDates() throws {
        let json = #"[{"url":"file:///tmp/a.md","name":"a.md","isDirectory":false,"children":[]}]"#
        let items = try JSONDecoder().decode([OutlineFileTreeItem].self, from: Data(json.utf8))
        XCTAssertNil(items.first?.createdAt)
        XCTAssertNil(items.first?.modifiedAt)
    }
}
```

Also add store-level tests to `LineformTests/OutlineSidebarViewTests.swift` (same file, existing patterns — temp folder + isolated defaults suite + `iCloudDocumentsURLProvider: { _ in folder }`):

```swift
    @MainActor
    func testScanCapturesDatesAndAppliesPerRootSortOrder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try "# Old".write(to: folder.appendingPathComponent("Old.md"), atomically: true, encoding: .utf8)
        try "# New".write(to: folder.appendingPathComponent("New.md"), atomically: true, encoding: .utf8)
        // Push Old.md's modification date well into the past so the order is deterministic.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600), .creationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: folder.appendingPathComponent("Old.md").path
        )

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OutlineFileBrowserStore(defaults: defaults, fileManager: .default, iCloudDocumentsURLProvider: { _ in folder })
        store.refreshICloud()

        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["New.md", "Old.md"])
        XCTAssertNotNil(store.iCloudRoot.items.first?.modifiedAt)

        store.iCloudSortOrder = .name
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["New.md", "Old.md"])

        store.iCloudSortOrder = .dateModified
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["New.md", "Old.md"])
        XCTAssertEqual(defaults.string(forKey: OutlineFileBrowserStore.iCloudSortOrderDefaultsKey), OutlineFileSortOrder.dateModified.rawValue)
    }

    @MainActor
    func testSortPreferenceIsPersistedPerRootAndAppliedToLoadedSnapshots() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# B".write(to: folder.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        try "# A".write(to: folder.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: folder.appendingPathComponent("A.md").path
        )

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = OutlineFileBrowserStore(defaults: defaults, fileManager: .default, iCloudDocumentsURLProvider: { _ in folder })
        first.refreshICloud()
        first.iCloudSortOrder = .dateModified
        XCTAssertEqual(first.iCloudRoot.items.map(\.name), ["B.md", "A.md"])

        // A second store on the same defaults must come up with the persisted order,
        // and apply it to the cached snapshot at init.
        let second = OutlineFileBrowserStore(defaults: defaults, fileManager: .default, iCloudDocumentsURLProvider: { _ in folder })
        XCTAssertEqual(second.iCloudSortOrder, .dateModified)
        second.refreshICloud()
        XCTAssertEqual(second.iCloudRoot.items.map(\.name), ["B.md", "A.md"])
    }
```

- [ ] **Step 2: Run the new tests, verify they fail to compile** (missing type/members):
Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineFileSortOrderTests 2>&1 | tail -20`
Expected: build failure — `cannot find 'OutlineFileSortOrder' in scope`.

- [ ] **Step 3: Implement.** Create `Lineform/Outline/OutlineFileSortOrder.swift`:

```swift
import Foundation

/// Sidebar file-tree sort orders. Deliberately no "Manual" — the sidebar has no
/// drag-to-reorder, so offering it would be a dead option (Muse's Manual mode
/// exists only because Muse supports reordering).
enum OutlineFileSortOrder: String, CaseIterable, Identifiable {
    case name
    case dateCreated
    case dateModified

    var id: Self { self }

    var title: String {
        switch self {
        case .name: return "Name"
        case .dateCreated: return "Date Created"
        case .dateModified: return "Date Modified"
        }
    }

    /// Folders always group before files; within each group the chosen key applies.
    /// Date orders are newest-first; missing dates sort last; ties fall back to name.
    static func areInIncreasingOrder(_ first: OutlineFileTreeItem, _ second: OutlineFileTreeItem, order: OutlineFileSortOrder) -> Bool {
        if first.isDirectory != second.isDirectory {
            return first.isDirectory
        }
        switch order {
        case .name:
            break
        case .dateCreated:
            let lhs = first.createdAt ?? .distantPast
            let rhs = second.createdAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
        case .dateModified:
            let lhs = first.modifiedAt ?? .distantPast
            let rhs = second.modifiedAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
        }
        return first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    /// Returns a deep-sorted copy of the tree.
    static func sorted(_ items: [OutlineFileTreeItem], by order: OutlineFileSortOrder) -> [OutlineFileTreeItem] {
        items
            .map { item in
                var copy = item
                copy.children = sorted(item.children, by: order)
                return copy
            }
            .sorted { areInIncreasingOrder($0, $1, order: order) }
    }
}
```

In `OutlineSidebarView.swift`, extend `OutlineFileTreeItem`:
- Add `var createdAt: Date?` and `var modifiedAt: Date?` after `isHidden`.
- Extend the memberwise `init` with `createdAt: Date? = nil, modifiedAt: Date? = nil` trailing parameters.
- Add `case createdAt, modifiedAt` to `CodingKeys` and in `init(from:)` decode with `decodeIfPresent` (tolerating old snapshots, same comment style as `isHidden`).

In `OutlineFileBrowserStore`:
- Add defaults keys:
```swift
    static let iCloudSortOrderDefaultsKey = "Lineform.outline.sortOrder.icloud"
    static let workspaceSortOrderDefaultsKey = "Lineform.outline.sortOrder.workspace"
```
- Add published sort orders (pattern mirrors `showsHiddenFolders`; `didSet` re-sorts in memory — no disk re-scan needed):
```swift
    @Published var iCloudSortOrder = OutlineFileSortOrder.name {
        didSet {
            guard oldValue != iCloudSortOrder else { return }
            defaults.set(iCloudSortOrder.rawValue, forKey: Self.iCloudSortOrderDefaultsKey)
            lastICloudItems = OutlineFileSortOrder.sorted(lastICloudItems, by: iCloudSortOrder)
            if iCloudRoot.showsTree {
                iCloudRoot.items = filteredForDisplay(lastICloudItems)
            }
        }
    }
    @Published var workspaceSortOrder = OutlineFileSortOrder.name {
        didSet {
            guard oldValue != workspaceSortOrder else { return }
            defaults.set(workspaceSortOrder.rawValue, forKey: Self.workspaceSortOrderDefaultsKey)
            lastWorkspaceItems = OutlineFileSortOrder.sorted(lastWorkspaceItems, by: workspaceSortOrder)
            if workspaceRoot.showsTree {
                workspaceRoot.items = filteredForDisplay(lastWorkspaceItems)
            }
        }
    }
```
- In `init`, before `loadICloudSnapshot()` (didSet does not fire during init, same as `showsHiddenFolders`):
```swift
        iCloudSortOrder = OutlineFileSortOrder(rawValue: defaults.string(forKey: Self.iCloudSortOrderDefaultsKey) ?? "") ?? .name
        workspaceSortOrder = OutlineFileSortOrder(rawValue: defaults.string(forKey: Self.workspaceSortOrderDefaultsKey) ?? "") ?? .name
```
- In `loadICloudSnapshot`/`loadWorkspaceSnapshot`, wrap: `lastICloudItems = OutlineFileSortOrder.sorted(loadSnapshot(defaultsKey: ...), by: iCloudSortOrder)` (and workspace equivalent) so a changed preference applies to cached trees.
- In the scan `items(in:...)`: add `.creationDateKey, .contentModificationDateKey` to `resourceKeys`; add `let createdAt: Date?` / `let modifiedAt: Date?` to `Shallow` (from `values.creationDate` / `values.contentModificationDate`); thread them into the produced `OutlineFileTreeItem(... createdAt: item.createdAt, modifiedAt: item.modifiedAt)`. Add a `sortOrder: OutlineFileSortOrder` parameter to `items(in:...)` and replace the hard-coded `.sorted { ... }` comparator body with:
```swift
        .sorted { first, second in
            OutlineFileSortOrder.areInIncreasingOrder(
                OutlineFileTreeItem(url: first.url, name: first.name, isDirectory: first.isDirectory, children: [], createdAt: first.createdAt, modifiedAt: first.modifiedAt),
                OutlineFileTreeItem(url: second.url, name: second.name, isDirectory: second.isDirectory, children: [], createdAt: second.createdAt, modifiedAt: second.modifiedAt),
                order: sortOrder
            )
        }
```
(and pass `sortOrder: sortOrder` through the recursive call). Update the comment above `Shallow` — the sort now depends on `isDirectory`, `name`, and the two dates, all shallow attributes, so cap-then-recurse still holds.
- `refreshICloudRoot()` passes `sortOrder: iCloudSortOrder`; `refreshWorkspaceRoot()` passes `sortOrder: workspaceSortOrder`.

- [ ] **Step 4: Run the focused tests, verify pass:**
Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineFileSortOrderTests -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: all pass (existing OutlineSidebarViewTests must stay green — the default `.name` order preserves today's behavior exactly).

- [ ] **Step 5: Commit** — `Sidebar: per-root sort model (Name/Date Created/Date Modified) with persisted preference`.

---

### Task 2: Sort UI row above each section

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (`OutlineFileBrowserView.rootView` ~:1065-1109, new private view)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Consumes: `store.iCloudSortOrder` / `store.workspaceSortOrder` bindings from Task 1.
- Produces: static constants on `OutlineSidebarView`: `filesSortRowShowsForAvailableRootsOnly = true`, `filesSortMenuLabelPrefix = "Sort: "`.

- [ ] **Step 1: Write failing constant-pinning test** (this codebase's style for UI wiring):

```swift
    @MainActor
    func testFilesSectionsGetAMuseStyleSortRowWithoutManualOption() {
        XCTAssertEqual(OutlineSidebarView.filesSortMenuLabelPrefix, "Sort: ")
        XCTAssertTrue(OutlineSidebarView.filesSortRowShowsForAvailableRootsOnly)
        XCTAssertEqual(OutlineFileSortOrder.allCases.count, 3)
    }
```

- [ ] **Step 2: Run, verify failure** (missing constants). Same `-only-testing:LineformTests/OutlineSidebarViewTests` command.

- [ ] **Step 3: Implement.** Add the constants near the other `files*` constants in `OutlineSidebarView`. Add a private view at the bottom of the file:

```swift
private struct OutlineFileSortRow: View {
    var rootTitle: String
    @Binding var sortOrder: OutlineFileSortOrder
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(OutlineFileSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(OutlineSidebarView.filesSortMenuLabelPrefix + sortOrder.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: colorScheme == .dark))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Sort \(rootTitle) files")
        .accessibilityValue(sortOrder.title)
    }
}
```

In `OutlineFileBrowserView.rootView`, insert the row between `OutlineFileRootRow` and the children, shown only for an expanded, available, non-empty section:

```swift
            if root.state == .available, !collapsedIDs.contains(root.id), !rootIsDimmed(root), !root.items.isEmpty {
                OutlineFileSortRow(rootTitle: root.title, sortOrder: sortBinding(for: root))
                    .padding(.leading, 28)
                    .padding(.bottom, 2)
            }
```

with

```swift
    private func sortBinding(for root: OutlineFileRoot) -> Binding<OutlineFileSortOrder> {
        root.id == "icloud" ? $store.iCloudSortOrder : $store.workspaceSortOrder
    }
```

(`store` is already `@ObservedObject`, so `$store.…` bindings exist.)

- [ ] **Step 4: Run focused tests → pass. Build the app** (build-only gate from Global Constraints) to confirm the view compiles.

- [ ] **Step 5: Commit** — `Sidebar: per-section Sort row (Name/Date Created/Date Modified)`.

---

### Task 3: External-change watcher + both-roots reconcile on Files-tab appear

**Files:**
- Create: `Lineform/Outline/DirectoryEventMonitor.swift`
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (store + the Files-tab `.onAppear` at ~:232-247)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Produces: `protocol DirectoryChangeMonitoring: AnyObject { func stop() }`, `typealias DirectoryChangeMonitorFactory = (URL, @escaping () -> Void) -> DirectoryChangeMonitoring?`, `final class DirectoryEventMonitor: DirectoryChangeMonitoring` with `static let coalescingLatency: TimeInterval = 0.5`.
- Produces: `OutlineFileBrowserStore.beginWatchingForExternalChanges()` / `.endWatchingForExternalChanges()`; store `init` gains `directoryMonitorFactory: DirectoryChangeMonitorFactory? = nil` (nil → real FSEvents factory).

- [ ] **Step 1: Write failing tests** (fake monitor factory; workspace configured via bookmark in defaults, the pattern at OutlineSidebarViewTests.swift:681-688):

```swift
    private final class FakeDirectoryMonitor: DirectoryChangeMonitoring {
        let url: URL
        let onChange: () -> Void
        private(set) var stopped = false
        init(url: URL, onChange: @escaping () -> Void) {
            self.url = url
            self.onChange = onChange
        }
        func stop() { stopped = true }
    }

    @MainActor
    func testWatcherRescansRootsWhenDirectoryEventsFireAndStopsOnEnd() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# A".write(to: folder.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var monitors: [FakeDirectoryMonitor] = []
        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in folder },
            directoryMonitorFactory: { url, onChange in
                let monitor = FakeDirectoryMonitor(url: url, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        store.refreshICloud()
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["A.md"])
        XCTAssertTrue(monitors.isEmpty, "watching must not start before beginWatchingForExternalChanges()")

        store.beginWatchingForExternalChanges()
        XCTAssertEqual(monitors.map(\.url), [folder])

        // A file appears externally; the event callback must re-scan and publish it.
        try "# B".write(to: folder.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        monitors[0].onChange()
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["A.md", "B.md"])

        // Re-begin is idempotent (no duplicate monitors for the same root).
        store.beginWatchingForExternalChanges()
        XCTAssertEqual(monitors.count, 1)

        store.endWatchingForExternalChanges()
        XCTAssertTrue(monitors[0].stopped)

        // After ending, a new begin creates a fresh monitor.
        store.beginWatchingForExternalChanges()
        XCTAssertEqual(monitors.count, 2)
    }

    @MainActor
    func testWatcherCoversWorkspaceRootViaHeldBookmark() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "# W".write(to: workspace.appendingPathComponent("W.md"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bookmark = try workspace.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: OutlineFileBrowserStore.workspaceBookmarkDefaultsKey)

        var monitors: [FakeDirectoryMonitor] = []
        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in nil },
            directoryMonitorFactory: { url, onChange in
                let monitor = FakeDirectoryMonitor(url: url, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        store.beginWatchingForExternalChanges()
        XCTAssertEqual(monitors.map(\.url.standardizedFileURL), [workspace.standardizedFileURL])

        try "# X".write(to: workspace.appendingPathComponent("X.md"), atomically: true, encoding: .utf8)
        monitors[0].onChange()
        XCTAssertEqual(store.workspaceRoot.items.map(\.name), ["W.md", "X.md"])
    }
```

Note: if the existing test at :681 uses different bookmark options, copy that exact pattern.

- [ ] **Step 2: Run → compile failure** (`directoryMonitorFactory` unknown).

- [ ] **Step 3: Implement.** Create `Lineform/Outline/DirectoryEventMonitor.swift`:

```swift
import CoreServices
import Foundation

/// Abstraction over recursive directory-change monitoring so the sidebar store can be
/// tested with synthetic events instead of real FSEvents latency.
protocol DirectoryChangeMonitoring: AnyObject {
    func stop()
}

typealias DirectoryChangeMonitorFactory = (_ url: URL, _ onChange: @escaping () -> Void) -> DirectoryChangeMonitoring?

/// Recursive FSEvents watcher for one directory tree. Events are coalesced by FSEvents
/// (`coalescingLatency`) and delivered on the main queue. Own-process events are ignored
/// (`kFSEventStreamCreateFlagIgnoreSelf`): document autosaves must not churn the sidebar
/// scan on every keystroke, and the app's own rename/delete/refresh paths broadcast
/// `LineformAppNotification.refreshSidebarFiles` explicitly instead.
final class DirectoryEventMonitor: DirectoryChangeMonitoring {
    static let coalescingLatency: TimeInterval = 0.5

    private var streamRef: FSEventStreamRef?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryEventMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.coalescingLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        streamRef = stream
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    deinit {
        stop()
    }
}
```

In `OutlineFileBrowserStore`:
- Add stored properties:
```swift
    private let directoryMonitorFactory: DirectoryChangeMonitorFactory
    private var workspaceMonitor: DirectoryChangeMonitoring?
    private var iCloudMonitor: DirectoryChangeMonitoring?
    /// The resolved iCloud Documents URL from the last successful refresh; nil until the
    /// deferred first scan has run (so watching can never resolve the container itself).
    private var resolvedICloudDocumentsURL: URL?
```
- `init` gains `directoryMonitorFactory: DirectoryChangeMonitorFactory? = nil` and stores `self.directoryMonitorFactory = directoryMonitorFactory ?? { url, onChange in DirectoryEventMonitor(url: url, onChange: onChange) }`.
- In `refreshICloudRoot()`: set `resolvedICloudDocumentsURL = url` in the success path, `resolvedICloudDocumentsURL = nil` in both failure paths.
- Add (after `refreshWorkspace()`):
```swift
    /// Starts watching both roots for external file-system changes. Called when the
    /// Files tab becomes visible, AFTER refreshICloud() has resolved the container —
    /// this never resolves or scans anything itself, preserving the deferred-scan
    /// invariant. Idempotent while watching.
    func beginWatchingForExternalChanges() {
        if workspaceMonitor == nil, let workspaceURL {
            workspaceMonitor = directoryMonitorFactory(workspaceURL) { [weak self] in
                self?.refreshWorkspaceRoot()
            }
        }
        if iCloudMonitor == nil, let url = resolvedICloudDocumentsURL {
            iCloudMonitor = directoryMonitorFactory(url) { [weak self] in
                self?.refreshICloudRoot()
            }
        }
    }

    /// Stops watching (Files tab hidden / view gone). Cheap to call repeatedly.
    func endWatchingForExternalChanges() {
        workspaceMonitor?.stop()
        workspaceMonitor = nil
        iCloudMonitor?.stop()
        iCloudMonitor = nil
    }
```
- In `setWorkspaceURL(_:)` (workspace changed via the Change button): retarget a live watcher — at the top capture `let wasWatching = workspaceMonitor != nil; workspaceMonitor?.stop(); workspaceMonitor = nil`, and after `refreshWorkspaceRoot()` add `if wasWatching { beginWatchingForExternalChanges() }`.
- In `deinit`, before `releaseWorkspaceScope()`: `workspaceMonitor?.stop()` and `iCloudMonitor?.stop()`.

In `OutlineSidebarView.body`, Files-tab branch:
- In the existing `.onAppear` (after the `refreshICloud()` reconcile): add
```swift
                            // Reconcile BOTH roots on every appearance (previously only iCloud
                            // refreshed here, so workspace changes made while the tab was hidden
                            // never showed), then start live watching for external changes.
                            fileBrowserStore.refreshWorkspace()
                            fileBrowserStore.beginWatchingForExternalChanges()
```
- Add `.onDisappear { fileBrowserStore.endWatchingForExternalChanges() }` on the `OutlineFileBrowserView`.

- [ ] **Step 4: Run focused tests → pass.** Also re-run the whole `OutlineSidebarViewTests` class (store behavior touched).

- [ ] **Step 5: Manual smoke check (deferred to final QA, noted here):** run the app, Files tab visible, `touch` a new `.md` in the workspace folder → appears within ~1s.

- [ ] **Step 6: Commit** — `Sidebar: live FSEvents refresh while Files tab visible; reconcile both roots on appear`.

---

### Task 4: File operations — pure rename/trash logic

**Files:**
- Create: `Lineform/Outline/SidebarFileActions.swift`
- Test: create `LineformTests/SidebarFileActionsTests.swift`

**Interfaces:**
- Produces:
```swift
protocol SidebarFileManaging {
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL) throws
    func fileExists(atPath path: String) -> Bool
}
extension FileManager: SidebarFileManaging  // trashItem(at:) wraps trashItem(at:resultingItemURL:)

enum SidebarFileRenaming {
    static func displayName(for url: URL, isDirectory: Bool) -> String
    static func validatedDestination(for url: URL, isDirectory: Bool, newDisplayName: String) -> URL?
}

struct SidebarFileOperations {
    var fileManager: SidebarFileManaging = FileManager.default
    func rename(_ url: URL, to destination: URL) throws
    func trash(_ url: URL) throws
}
```

- [ ] **Step 1: Write failing tests** in `LineformTests/SidebarFileActionsTests.swift`:

```swift
import XCTest
@testable import Lineform

final class SidebarFileActionsTests: XCTestCase {
    private final class RecordingFileManager: SidebarFileManaging {
        var moved: [(URL, URL)] = []
        var trashed: [URL] = []
        var existingPaths: Set<String> = []
        var errorToThrow: Error?
        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if let errorToThrow { throw errorToThrow }
            moved.append((srcURL, dstURL))
        }
        func trashItem(at url: URL) throws {
            if let errorToThrow { throw errorToThrow }
            trashed.append(url)
        }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
    }

    func testDisplayNameStripsExtensionForFilesButNotFolders() {
        XCTAssertEqual(SidebarFileRenaming.displayName(for: URL(fileURLWithPath: "/tmp/Notes.md"), isDirectory: false), "Notes")
        XCTAssertEqual(SidebarFileRenaming.displayName(for: URL(fileURLWithPath: "/tmp/Archive.old", isDirectory: true), isDirectory: true), "Archive.old")
    }

    func testValidatedDestinationPreservesExtensionAndDirectory() {
        let url = URL(fileURLWithPath: "/tmp/Docs/Notes.md")
        let destination = SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "Journal")
        XCTAssertEqual(destination?.path, "/tmp/Docs/Journal.md")
    }

    func testValidatedDestinationForFolderKeepsWholeName() {
        let url = URL(fileURLWithPath: "/tmp/Docs/Old", isDirectory: true)
        let destination = SidebarFileRenaming.validatedDestination(for: url, isDirectory: true, newDisplayName: "New Name")
        XCTAssertEqual(destination?.path, "/tmp/Docs/New Name")
    }

    func testValidatedDestinationRejectsEmptySlashColonAndUnchangedNames() {
        let url = URL(fileURLWithPath: "/tmp/Notes.md")
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "  "))
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "a/b"))
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "a:b"))
        XCTAssertNil(SidebarFileRenaming.validatedDestination(for: url, isDirectory: false, newDisplayName: "Notes"))
    }

    func testRenameMovesFileOnDiskViaCoordinatedMove() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("A.md")
        try "# A".write(to: source, atomically: true, encoding: .utf8)
        let destination = folder.appendingPathComponent("B.md")

        try SidebarFileOperations().rename(source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRenameRefusesToClobberAnExistingFile() {
        let recorder = RecordingFileManager()
        recorder.existingPaths = ["/tmp/B.md"]
        let operations = SidebarFileOperations(fileManager: recorder)
        XCTAssertThrowsError(try operations.rename(URL(fileURLWithPath: "/tmp/A.md"), to: URL(fileURLWithPath: "/tmp/B.md")))
        XCTAssertTrue(recorder.moved.isEmpty)
    }

    func testTrashUsesTrashItemNeverRemoveItem() throws {
        let recorder = RecordingFileManager()
        let operations = SidebarFileOperations(fileManager: recorder)
        let url = URL(fileURLWithPath: "/tmp/A.md")
        try operations.trash(url)
        XCTAssertEqual(recorder.trashed, [url])
    }
}
```

- [ ] **Step 2: Run → compile failure.**

- [ ] **Step 3: Implement** `Lineform/Outline/SidebarFileActions.swift` (operations half; dialogs come in Task 5):

```swift
import AppKit
import Foundation

/// File-system side of the sidebar's Rename/Delete actions, behind a protocol so unit
/// tests can observe calls without touching the real Trash. Delete is trash-only by
/// design — the app never permanently removes a user's file.
protocol SidebarFileManaging {
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL) throws
    func fileExists(atPath path: String) -> Bool
}

extension FileManager: SidebarFileManaging {
    func trashItem(at url: URL) throws {
        try trashItem(at: url, resultingItemURL: nil)
    }
}

enum SidebarFileRenaming {
    /// What the rename dialog's text field shows: files without their extension
    /// (the extension is preserved automatically), folders as their whole name.
    static func displayName(for url: URL, isDirectory: Bool) -> String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// The rename target for a user-entered name, or nil when the name is empty,
    /// unchanged, or contains a path separator ("/" or the legacy ":").
    static func validatedDestination(for url: URL, isDirectory: Bool, newDisplayName: String) -> URL? {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
            return nil
        }

        let ext = isDirectory ? "" : url.pathExtension
        let newName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        guard newName != url.lastPathComponent else {
            return nil
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: isDirectory)
    }
}

struct SidebarFileOperations {
    var fileManager: SidebarFileManaging = FileManager.default

    /// Coordinated move so other file presenters (open documents' reload watchers,
    /// other apps) observe the rename, matching what a Finder rename does.
    func rename(_ url: URL, to destination: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "A file named “\(destination.lastPathComponent)” already exists."
            ])
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.moveItem(at: coordinatedURL, to: destination)
                coordinator.item(at: coordinatedURL, didMoveTo: destination)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    /// Coordinated move to the Trash. Never `removeItem` — always recoverable.
    func trash(_ url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.trashItem(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}
```

- [ ] **Step 4: Run focused tests → pass:** `-only-testing:LineformTests/SidebarFileActionsTests`.

- [ ] **Step 5: Commit** — `Sidebar: rename/trash file operations (coordinated, trash-only) with validation`.

---

### Task 5: Dialogs, context menus, and document retarget on rename/delete

**Files:**
- Modify: `Lineform/Outline/SidebarFileActions.swift` (add presenter)
- Modify: `Lineform/App/LineformAppNotification.swift` (new cases + payload)
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (context menus + closure plumbing + refresh observer)
- Modify: `Lineform/Editor/EditorContainerView.swift` (action handlers + retarget observers)
- Test: `LineformTests/SidebarFileActionsTests.swift`, `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Produces (presenter, `@MainActor`, in SidebarFileActions.swift):
```swift
enum SidebarFileActionPresenter {
    static let renameFileTitle = "Rename File"
    static let renameFolderTitle = "Rename Folder"
    static let renameFileMessage = "Renames the file. Its contents are kept."
    static let renameFolderMessage = "Renames the folder. Its files are kept."
    static let renameButtonTitle = "Rename"
    static let cancelButtonTitle = "Cancel"
    static let deleteButtonTitle = "Delete"
    static func deleteTitle(for url: URL) -> String        // "Delete “Notes.md”?"
    static let deleteMessage = "It will be moved to the Trash."
    static func promptRename(of url: URL, isDirectory: Bool, operations: SidebarFileOperations = SidebarFileOperations()) -> URL?
    static func promptDelete(of url: URL, operations: SidebarFileOperations = SidebarFileOperations()) -> Bool
    static func showInFinder(_ url: URL)
}
```
- Produces (notifications): `LineformAppNotification` cases `refreshSidebarFiles`, `sidebarItemRenamed`, `sidebarFileDeleted`, plus
```swift
    struct RenamePayload {          // object of sidebarItemRenamed
        var from: URL
        var to: URL
        var isDirectory: Bool
        /// Where `url` now lives if it was `from` or inside a renamed folder; nil if unaffected.
        func rebased(_ url: URL?) -> URL?
    }
```
(`sidebarFileDeleted` posts the trashed file URL as its object.)
- Produces (sidebar plumbing): `OutlineSidebarView`/`OutlineFileBrowserView`/`OutlineFileTreeNodeView` gain `renameItem: (OutlineFileTreeItem) -> Void`, `deleteItem: (OutlineFileTreeItem) -> Void`, `revealItem: (OutlineFileTreeItem) -> Void` closure props (default `{ _ in }`), threaded exactly like `openFile`. `OutlineSidebarView.init` gains the three parameters with defaults.
- Consumes: Task 4 operations, Task 3 store refresh methods.

- [ ] **Step 1: Write failing tests.**

In `SidebarFileActionsTests` (dialog copy + payload rebasing — pure logic; the NSAlert flow itself is manual-QA):

```swift
    func testDialogCopyMatchesMuseStyleSpec() {
        XCTAssertEqual(SidebarFileActionPresenter.renameFileTitle, "Rename File")
        XCTAssertEqual(SidebarFileActionPresenter.renameFolderTitle, "Rename Folder")
        XCTAssertEqual(SidebarFileActionPresenter.renameFileMessage, "Renames the file. Its contents are kept.")
        XCTAssertEqual(SidebarFileActionPresenter.renameFolderMessage, "Renames the folder. Its files are kept.")
        XCTAssertEqual(SidebarFileActionPresenter.deleteTitle(for: URL(fileURLWithPath: "/tmp/Notes.md")), "Delete “Notes.md”?")
        XCTAssertEqual(SidebarFileActionPresenter.deleteMessage, "It will be moved to the Trash.")
        XCTAssertEqual(SidebarFileActionPresenter.deleteButtonTitle, "Delete")
        XCTAssertEqual(SidebarFileActionPresenter.cancelButtonTitle, "Cancel")
    }

    func testRenamePayloadRebasesTheRenamedItemAndDescendants() {
        let payload = LineformAppNotification.RenamePayload(
            from: URL(fileURLWithPath: "/tmp/Docs", isDirectory: true),
            to: URL(fileURLWithPath: "/tmp/Notes", isDirectory: true),
            isDirectory: true
        )
        XCTAssertEqual(payload.rebased(URL(fileURLWithPath: "/tmp/Docs"))?.path, "/tmp/Notes")
        XCTAssertEqual(payload.rebased(URL(fileURLWithPath: "/tmp/Docs/a/b.md"))?.path, "/tmp/Notes/a/b.md")
        XCTAssertNil(payload.rebased(URL(fileURLWithPath: "/tmp/Docs-other/b.md")))
        XCTAssertNil(payload.rebased(URL(fileURLWithPath: "/tmp/Other.md")))
        XCTAssertNil(payload.rebased(nil))

        let filePayload = LineformAppNotification.RenamePayload(
            from: URL(fileURLWithPath: "/tmp/A.md"),
            to: URL(fileURLWithPath: "/tmp/B.md"),
            isDirectory: false
        )
        XCTAssertEqual(filePayload.rebased(URL(fileURLWithPath: "/tmp/A.md"))?.path, "/tmp/B.md")
        XCTAssertNil(filePayload.rebased(URL(fileURLWithPath: "/tmp/C.md")))
    }
```

- [ ] **Step 2: Run → compile failure.**

- [ ] **Step 3: Implement.**

**(a) `LineformAppNotification.swift`:** add cases `refreshSidebarFiles`, `sidebarItemRenamed`, `sidebarFileDeleted` with names `"Lineform.refreshSidebarFiles"` etc. (extend the `switch`), and:

```swift
    /// Object of `sidebarItemRenamed`. Not window-scoped: every window checks whether its
    /// own document lives at (or under) the renamed path and retargets itself.
    struct RenamePayload {
        var from: URL
        var to: URL
        var isDirectory: Bool

        /// The new location of `url` after this rename: the destination itself for an
        /// exact match, a re-prefixed path for descendants of a renamed folder, nil if
        /// the rename does not affect `url`.
        func rebased(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let target = url.standardizedFileURL.path
            let source = from.standardizedFileURL.path
            if target == source {
                return to
            }
            guard isDirectory, target.hasPrefix(source + "/") else {
                return nil
            }
            return URL(fileURLWithPath: to.standardizedFileURL.path + String(target.dropFirst(source.count)))
        }
    }
```

**(b) `SidebarFileActions.swift`:** add the `@MainActor` presenter:

```swift
@MainActor
enum SidebarFileActionPresenter {
    static let renameFileTitle = "Rename File"
    static let renameFolderTitle = "Rename Folder"
    static let renameFileMessage = "Renames the file. Its contents are kept."
    static let renameFolderMessage = "Renames the folder. Its files are kept."
    static let renameButtonTitle = "Rename"
    static let cancelButtonTitle = "Cancel"
    static let deleteButtonTitle = "Delete"
    static let deleteMessage = "It will be moved to the Trash."
    static let renameFieldWidth: CGFloat = 230

    static func deleteTitle(for url: URL) -> String {
        "Delete “\(url.lastPathComponent)”?"
    }

    /// Muse-style rename dialog: native alert, pre-selected name field, Cancel/Rename.
    /// Returns the new URL on success (operation already performed), nil on cancel or
    /// invalid/unchanged name. Failures present a standard error alert and return nil.
    static func promptRename(
        of url: URL,
        isDirectory: Bool,
        operations: SidebarFileOperations = SidebarFileOperations()
    ) -> URL? {
        let alert = NSAlert()
        alert.messageText = isDirectory ? renameFolderTitle : renameFileTitle
        alert.informativeText = isDirectory ? renameFolderMessage : renameFileMessage
        alert.addButton(withTitle: renameButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: renameFieldWidth, height: 24))
        field.stringValue = SidebarFileRenaming.displayName(for: url, isDirectory: isDirectory)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        guard let destination = SidebarFileRenaming.validatedDestination(
            for: url,
            isDirectory: isDirectory,
            newDisplayName: field.stringValue
        ) else {
            return nil
        }

        do {
            try operations.rename(url, to: destination)
            return destination
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Delete confirmation: Cancel is the Return-key default; Delete is destructive and
    /// never the default. Returns true when the file was moved to the Trash.
    static func promptDelete(
        of url: URL,
        operations: SidebarFileOperations = SidebarFileOperations()
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = deleteTitle(for: url)
        alert.informativeText = deleteMessage
        let deleteButton = alert.addButton(withTitle: deleteButtonTitle)
        let cancelButton = alert.addButton(withTitle: cancelButtonTitle)
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        do {
            try operations.trash(url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

**(c) `OutlineSidebarView.swift` plumbing:**
- `OutlineSidebarView` gains three props + init params (defaults `{ _ in }`), passed into `OutlineFileBrowserView`, which passes them into every `OutlineFileTreeNodeView`.
- `OutlineFileTreeNodeView.row` gains, after `.onHover`:
```swift
        .contextMenu {
            Button("Rename…") { renameItem(item) }
            if !item.isDirectory {
                Button("Delete…", role: .destructive) { deleteItem(item) }
            }
            Divider()
            Button("Show in Finder") { revealItem(item) }
        }
```
- In the Files-tab branch of `OutlineSidebarView.body`, add next to the `toggleHiddenFolders` observer:
```swift
                        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.refreshSidebarFiles.name)) { _ in
                            // An in-app rename/delete happened (any window). FSEvents ignores
                            // own-process events, so refresh explicitly. Only visible Files
                            // tabs observe this, preserving the deferred-scan invariant.
                            fileBrowserStore.refreshWorkspace()
                            fileBrowserStore.refreshICloud()
                        }
```

**(d) `EditorContainerView.swift`:**
- Pass the closures into `OutlineSidebarView` (init call at :41-47): `renameItem: { renameSidebarItem(at: $0.url, isDirectory: $0.isDirectory) }, deleteItem: { deleteSidebarItem(at: $0.url) }, revealItem: { SidebarFileActionPresenter.showInFinder($0.url) }`.
- Add handlers near `openSidebarFile`:
```swift
    private func renameSidebarItem(at url: URL, isDirectory: Bool) {
        guard let destination = SidebarFileActionPresenter.promptRename(of: url, isDirectory: isDirectory) else {
            return
        }
        LineformAppNotification.sidebarItemRenamed.post(
            object: LineformAppNotification.RenamePayload(from: url, to: destination, isDirectory: isDirectory)
        )
        LineformAppNotification.refreshSidebarFiles.post()
    }

    private func deleteSidebarItem(at url: URL) {
        guard SidebarFileActionPresenter.promptDelete(of: url) else {
            return
        }
        LineformAppNotification.sidebarFileDeleted.post(object: url)
        LineformAppNotification.refreshSidebarFiles.post()
    }
```
- Add observers (near the other `.onReceive`s). Rename retarget — every window checks its own document:
```swift
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.sidebarItemRenamed.name)) { notification in
            guard
                let payload = notification.object as? LineformAppNotification.RenamePayload,
                let newURL = payload.rebased(currentFileURL),
                let backingDocument = activeWindow?.windowController?.document as? NSDocument
            else {
                return
            }
            backingDocument.fileURL = newURL
            backingDocument.fileModificationDate = LineformDocument.modificationDate(at: newURL)
            activeWindow?.representedURL = newURL
            activeWindow?.setTitleWithRepresentedFilename(newURL.path)
            registerReloadWatcher()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.sidebarFileDeleted.name)) { notification in
            guard
                let deletedURL = notification.object as? URL,
                currentFileURL?.standardizedFileURL == deletedURL.standardizedFileURL,
                let backingDocument = activeWindow?.windowController?.document as? NSDocument
            else {
                return
            }
            // The file is in the Trash; keep the text in the window as unsaved content
            // (nothing is lost — the next save prompts for a location). Without this,
            // the next autosave would silently resurrect the file the user just deleted.
            backingDocument.fileURL = nil
            backingDocument.updateChangeCount(.changeDone)
            activeWindow?.representedURL = nil
            backingDocument.windowControllers.first?.synchronizeWindowTitleWithDocumentName()
            registerReloadWatcher()
        }
```

- [ ] **Step 4: Run focused tests → pass** (`SidebarFileActionsTests`, `OutlineSidebarViewTests`). Build the app.

- [ ] **Step 5: Commit** — `Sidebar: right-click Rename/Delete/Show in Finder with native Muse-style dialogs`.

---

### Task 6: File-menu Rename… / Delete… commands

**Files:**
- Modify: `Lineform/App/LineformAppNotification.swift` (cases `renameCurrentFile`, `deleteCurrentFile`)
- Modify: `Lineform/App/AppCommands.swift` (menu state + buttons)
- Modify: `Lineform/Editor/EditorContainerView.swift` (observers + key-window state upkeep)
- Test: create `LineformTests/AppCommandsSidebarFileTests.swift`

**Interfaces:**
- Produces: `AppMenuConfiguration.renameFileCommandTitle = "Rename…"`, `AppMenuConfiguration.deleteFileCommandTitle = "Delete…"`.
- Produces: `LineformCurrentFileMenuState` (pattern-copy of `LineformDisplayModeMenuState`):
```swift
@MainActor
final class LineformCurrentFileMenuState: ObservableObject {
    static let shared = LineformCurrentFileMenuState()
    @Published private(set) var currentFileURL: URL?
    func setCurrentFileURL(_ url: URL?)   // no-op when unchanged; calls NSApp.mainMenu?.update()
}
```
- Consumes: Task 5's `renameSidebarItem`/`deleteSidebarItem` handlers.

- [ ] **Step 1: Write failing tests:**

```swift
import XCTest
@testable import Lineform

final class AppCommandsSidebarFileTests: XCTestCase {
    @MainActor
    func testFileMenuGetsRenameAndDeleteCommandsWithEllipsisTitles() {
        XCTAssertEqual(AppMenuConfiguration.renameFileCommandTitle, "Rename…")
        XCTAssertEqual(AppMenuConfiguration.deleteFileCommandTitle, "Delete…")
    }

    @MainActor
    func testCurrentFileMenuStateTracksURLAndIgnoresRedundantSets() {
        let state = LineformCurrentFileMenuState()
        XCTAssertNil(state.currentFileURL)
        let url = URL(fileURLWithPath: "/tmp/A.md")
        state.setCurrentFileURL(url)
        XCTAssertEqual(state.currentFileURL, url)
        state.setCurrentFileURL(nil)
        XCTAssertNil(state.currentFileURL)
    }
}
```

- [ ] **Step 2: Run → compile failure.**

- [ ] **Step 3: Implement.**
- Notification cases `renameCurrentFile` / `deleteCurrentFile` (names `"Lineform.renameCurrentFile"` / `"Lineform.deleteCurrentFile"`).
- `AppMenuConfiguration` constants as above.
- `LineformCurrentFileMenuState` in `AppCommands.swift` beside the other menu states (init takes no arguments; guard `url != currentFileURL`).
- `AppCommands`: add `@ObservedObject private var currentFileMenuState: LineformCurrentFileMenuState` (init param defaulting to `.shared`, same pattern as the others). In the `CommandGroup(after: .saveItem)` (after the Save As button):
```swift
            Divider()

            Button(AppMenuConfiguration.renameFileCommandTitle) {
                LineformAppNotification.renameCurrentFile.post(object: LineformAppNotification.activeWindowPayload())
            }
            .disabled(currentFileMenuState.currentFileURL == nil)

            Button(AppMenuConfiguration.deleteFileCommandTitle) {
                LineformAppNotification.deleteCurrentFile.post(object: LineformAppNotification.activeWindowPayload())
            }
            .disabled(currentFileMenuState.currentFileURL == nil)
```
(No keyboard shortcuts — Delete must never have an accidental destructive shortcut.)
- `EditorContainerView`:
  - Keep the shared state pointed at the key window's file. Add:
```swift
        .onChange(of: currentFileURL) { _, newValue in
            if activeWindow?.isKeyWindow == true {
                LineformCurrentFileMenuState.shared.setCurrentFileURL(newValue)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            LineformCurrentFileMenuState.shared.setCurrentFileURL(currentFileURL)
        }
```
  - Menu-command observers (window-matched like the others):
```swift
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.renameCurrentFile.name)) { notification in
            guard notificationMatchesActiveWindow(notification), let url = currentFileURL else { return }
            renameSidebarItem(at: url, isDirectory: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.deleteCurrentFile.name)) { notification in
            guard notificationMatchesActiveWindow(notification), let url = currentFileURL else { return }
            deleteSidebarItem(at: url)
        }
```

- [ ] **Step 4: Run focused tests → pass** (`AppCommandsSidebarFileTests`). Build the app.

- [ ] **Step 5: Commit** — `File menu: Rename…/Delete… for the current file (disabled for untitled)`.

---

### Task 7: Save-prompt investigation (spurious dirty on sidebar switch)

**Files:**
- Investigate: `Lineform/Outline/OutlineSidebarView.swift:1430-1457` (`replaceCurrentDocument`), `Lineform/Editor/EditorContainerView.swift:325-335` (`replaceDocumentFromSidebar`), `Lineform/Documents/LineformDocument.swift`
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Hypothesis:** `replaceDocumentFromSidebar` mutates the SwiftUI `@Binding var document` (text/format), and SwiftUI's `DocumentGroup` registers that mutation with the document's undo/change machinery **asynchronously** — after `replaceCurrentDocument` has already called `updateChangeCount(.changeCleared)`. Result: the freshly swapped-in document is marked edited though the user typed nothing, and the *next* sidebar click shows the unsaved-changes sheet for a file the user never touched — exactly the user's report.

- [ ] **Step 1: Code audit.** Read `LineformDocument.swift` and any `fileDocument`/`DocumentGroup` glue to confirm how binding mutations reach `updateChangeCount`. Trace the exact ordering of (a) `updateEditorDocument` → binding writes, (b) `updateChangeCount(.changeCleared)`, (c) SwiftUI's deferred change registration.

- [ ] **Step 2: Manual reproduction (with the user or via `run` on the packaged Debug app):** open clean file A from the sidebar, click file B, then immediately click file C. Record whether the sheet appears for B without any typing. Repeat with a beat of idle time between clicks.

- [ ] **Step 3: If reproduced, fix.** The minimal fix consistent with existing patterns (async retargets already used in `replaceDocumentFromSidebar` / `noteSavedToReloadWatcher`): re-clear the change count one runloop turn after the swap, in `LineformSidebarFileOpener.replaceCurrentDocument` after the synchronous clear:

```swift
        // SwiftUI registers the binding writes from updateEditorDocument with the change
        // machinery asynchronously; without this deferred clear the swapped-in document
        // reads as edited though the user typed nothing (spurious save prompt on the
        // NEXT sidebar switch).
        DispatchQueue.main.async { [weak backingDocument, weak targetWindow] in
            backingDocument?.undoManager?.removeAllActions()
            backingDocument?.updateChangeCount(.changeCleared)
            targetWindow?.isDocumentEdited = false
        }
```
(`targetWindow` is a local `NSWindow?`; adjust capture as needed.) Then add a regression test in `OutlineSidebarViewTests` that calls `replaceCurrentDocument` on a `TestDocument`, spins the main runloop (`RunLoop.main.run(until: Date().addingTimeInterval(0.1))`), and asserts `isDocumentEdited == false` — plus, if the audit finds the dirtying is reproducible in the harness, a failing-first version demonstrating it.

- [ ] **Step 4: If NOT reproduced** after a genuine attempt: keep the runloop-spin regression test anyway (it pins the invariant), and record the conclusion — the prompt the user saw most likely reflected a real edit — in the final summary. Do not change Apple's sheet or its wording either way.

- [ ] **Step 5: Run `OutlineSidebarViewTests` → pass. Commit** — `Sidebar: pin/fix change-count invariant across sidebar file swaps` (adjust subject to findings).

---

### Task 8: Accessibility on rows, sort control, and actions

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (`OutlineFileTreeNodeView.row` ~:1304-1351)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Consumes: Task 5 closures on `OutlineFileTreeNodeView`.
- Produces: `OutlineSidebarView.fileRowAccessibilityLabel(name:isDirectory:isHidden:) -> String`.

- [ ] **Step 1: Write failing test:**

```swift
    @MainActor
    func testFileRowsGetRealAccessibilityLabels() {
        XCTAssertEqual(OutlineSidebarView.fileRowAccessibilityLabel(name: "Notes.md", isDirectory: false, isHidden: false), "Notes.md")
        XCTAssertEqual(OutlineSidebarView.fileRowAccessibilityLabel(name: "Drafts", isDirectory: true, isHidden: false), "Drafts, folder")
        XCTAssertEqual(OutlineSidebarView.fileRowAccessibilityLabel(name: ".claude", isDirectory: true, isHidden: true), ".claude, hidden folder")
        XCTAssertEqual(OutlineSidebarView.fileRowAccessibilityLabel(name: ".env.md", isDirectory: false, isHidden: true), ".env.md, hidden")
    }
```

- [ ] **Step 2: Run → failure.**

- [ ] **Step 3: Implement.** Static helper on `OutlineSidebarView`:

```swift
    /// VoiceOver label for a Files-tab row. Rows previously exposed only text + selection
    /// trait; folders and de-emphasized hidden items need to say what they are.
    static func fileRowAccessibilityLabel(name: String, isDirectory: Bool, isHidden: Bool) -> String {
        switch (isDirectory, isHidden) {
        case (true, true): return "\(name), hidden folder"
        case (true, false): return "\(name), folder"
        case (false, true): return "\(name), hidden"
        case (false, false): return name
        }
    }
```

On `OutlineFileTreeNodeView.row`, after the existing `.accessibilityAddTraits`:

```swift
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OutlineSidebarView.fileRowAccessibilityLabel(name: item.name, isDirectory: item.isDirectory, isHidden: item.isHidden))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(item.isDirectory ? (isCollapsed ? "Expands the folder" : "Collapses the folder") : "Opens the file")
        .accessibilityAction { item.isDirectory ? toggleCollapsed() : openFile(item.url) }
        .accessibilityAction(named: "Rename") { renameItem(item) }
        .accessibilityAction(named: "Show in Finder") { revealItem(item) }
```
plus, only for files (SwiftUI conditional modifier — apply on the same chain):
```swift
        .accessibilityActions {
            if !item.isDirectory {
                Button("Delete") { deleteItem(item) }
            }
        }
```
(If mixing `.accessibilityAction(named:)` and `.accessibilityActions` misbehaves, put all three named actions inside one `.accessibilityActions { }` block with the Delete button conditional.)

The sort row's label/value were already added in Task 2; verify with the Accessibility Inspector during final QA.

- [ ] **Step 4: Run `OutlineSidebarViewTests` → pass. Build.**

- [ ] **Step 5: Commit** — `Sidebar: VoiceOver labels, hints, and custom Rename/Delete actions on file rows`.

---

### Task 9: Full verification, docs, final commit

- [ ] **Step 1: Build gate:** `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -5` → `BUILD SUCCEEDED`.

- [ ] **Step 2: Focused test sweep** (all classes touched): `-only-testing:LineformTests/OutlineFileSortOrderTests -only-testing:LineformTests/SidebarFileActionsTests -only-testing:LineformTests/AppCommandsSidebarFileTests -only-testing:LineformTests/OutlineSidebarViewTests` → report exact pass counts.

- [ ] **Step 3: Manual QA in the running app** (use the `run`/`verify` skills; warn the user about the TCC prompt if a full suite run is wanted):
  1. Files tab visible → `touch` a new `.md` into the workspace folder in Terminal → row appears within ~1s.
  2. Add a file to a *subfolder* that is expanded → appears; delete it in Finder → disappears.
  3. Sort rows: switch each section between Name/Date Created/Date Modified; relaunch → preference persists per section.
  4. Right-click file → Rename… (dialog matches Muse style; extension preserved; Esc cancels; Return renames). Rename the *open* file → window title + selection highlight follow.
  5. Right-click file → Delete… (Cancel is Return default; file lands in Trash). Delete the *open* file → window becomes untitled with content intact; no resurrection on autosave.
  6. Right-click folder → Rename works, no Delete item; Show in Finder reveals.
  7. File menu: Rename…/Delete… enabled with a real file, disabled on a fresh untitled window.
  8. Save-prompt check (Task 7 flow): A→B→C clean clicks, no sheet.
  9. VoiceOver spot-check (VO-arrow over rows; VO actions menu shows Rename/Delete/Show in Finder; sort control announces label+value).

- [ ] **Step 4: Full suite (user present, Xcode quit):** the standard serial `xcodebuild test` gate from CLAUDE.md; user clicks Allow on the TCC prompt. Report exact counts.

- [ ] **Step 5: Docs.** Update `CLAUDE.md` Main Features with one bullet covering: live sidebar refresh (FSEvents, Files-tab-visible only, IgnoreSelf + refreshSidebarFiles notification), per-section sort, context-menu Rename/Delete(trash-only)/Show in Finder, File-menu commands, and the no-folder-delete rule. Keep it in the existing terse house style. No README change (user-facing README doesn't enumerate sidebar minutiae).

- [ ] **Step 6: Final commit** of docs + any QA fixes.

---

## Self-Review Notes

- Spec coverage: refresh (§1→Task 3), save-prompt (§2→Task 7), file menu ctx (§3→Tasks 4-5), folder ctx (§4→Task 5), sort (§5→Tasks 1-2), menu bar (§6→Task 6), accessibility (§7→Tasks 2, 8), architecture/testing sections woven through. Deleting-open-file autosave-resurrection risk (found during planning, not in spec) handled in Task 5d — an improvement over the spec's "document stays in memory" line, same user-visible guarantee.
- Type consistency: `OutlineFileSortOrder.sorted`, `DirectoryChangeMonitorFactory`, `SidebarFileOperations`, `RenamePayload.rebased`, `renameSidebarItem(at:isDirectory:)` used consistently across tasks.
- FSEvents `IgnoreSelf` decision and its compensating `refreshSidebarFiles` broadcast are documented in both Task 3 (monitor doc comment) and Task 5 (observer comment).
