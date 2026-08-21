# Jump to File (⌘K Quick-Open Palette) Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A ⌘K keyboard palette that fuzzy-searches filenames across the Files sidebar's Workspace + iCloud roots and opens the selected file exactly like a sidebar click (new tab, or switch to the existing tab).

**Architecture:** Pure flatten/fuzzy-rank logic in a new `QuickOpenIndex` (mirrors `EditorSearchResolver`'s tested-pure-logic pattern). A new `QuickOpenPalette` SwiftUI card presented via the existing `museModalLayer` scrim machinery in `EditorContainerView`. Triggered by a window-scoped `showQuickOpen` notification from a new File-menu command (the `showFindReplace` pattern). `OutlineFileBrowserStore` ownership is hoisted from `OutlineSidebarView` up to `EditorContainerView` so the palette can read the same scanned tree the sidebar shows.

**Tech Stack:** Swift / SwiftUI / AppKit, XCTest. macOS deployment target 14.0 (so `.onKeyPress` is available). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-17-quick-open-jump-to-file-design.md`

## Global Constraints

- ⌘K becomes **Jump to File…**; Format ▸ Link moves to **⌘L** (menu + the text view's right-click menu hint).
- Files on disk only — no open-tab list, no recents, no app actions, no heading jump.
- Selection opens via the existing private `EditorContainerView.openSidebarFile(_:)` — never a new open path.
- Never scan iCloud at launch/view construction (iCloud-laziness invariant). The palette may trigger the deferred scan only on explicit ⌘K, and only when it hasn't run this session.
- The palette starts no FSEvents watcher — it reads whatever the store last scanned.
- Xcode project uses hand-rolled pbxproj IDs (`1F0000xx…`, objectVersion 56, no synced groups): every new file must be added to 4 pbxproj sections (PBXBuildFile, PBXFileReference, its PBXGroup children list, the target's PBXSourcesBuildPhase files list).
- Verification gate: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO` (default plan). Warn the user before running — the ad-hoc re-signed test host can trigger a one-time TCC "access Documents" prompt they must click Allow on; never run unattended.
- CLI test runs re-sign the host ad-hoc (TCC re-prompt risk). Prefer `xcodebuild build` for intermediate checks; run the full test suite once per task where the task says to.

---

### Task 1: `QuickOpenIndex` pure logic (flatten + fuzzy search)

**Files:**
- Create: `Lineform/Outline/QuickOpenIndex.swift`
- Test: `LineformTests/QuickOpenIndexTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (register both files)

**Interfaces:**
- Consumes: `OutlineFileRoot` (has `title: String`, `items: [OutlineFileTreeItem]`) and `OutlineFileTreeItem` (has `url: URL`, `name: String`, `isDirectory: Bool`, `children: [OutlineFileTreeItem]`), both defined in `Lineform/Outline/OutlineSidebarView.swift` (same module — no import needed).
- Produces (used by Task 4):
  - `struct QuickOpenEntry: Identifiable, Equatable { let id: String; let url: URL; let name: String; let relativePath: String; let rootTitle: String }`
  - `QuickOpenIndex.flatten(iCloudRoot: OutlineFileRoot, workspaceRoot: OutlineFileRoot) -> [QuickOpenEntry]`
  - `QuickOpenIndex.search(_ entries: [QuickOpenEntry], query: String, limit: Int = 20) -> [QuickOpenEntry]`

- [ ] **Step 1: Register the two new files in the pbxproj**

Run `grep -n "OutlineSidebarTabTests.swift\|OutlineMarkdownBasicsTabView.swift" Lineform.xcodeproj/project.pbxproj` to locate the 4 sections (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase). Add, mirroring the neighbors exactly (tab/space style included):

PBXBuildFile section (near line 125, after `WindowCloseController.swift in Sources`):

```
		1F00000100000000000003A6 /* QuickOpenIndex.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000003A6 /* QuickOpenIndex.swift */; };
		1F00000100000000000003A7 /* QuickOpenIndexTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000003A7 /* QuickOpenIndexTests.swift */; };
```

PBXFileReference section (near line 266, after `SaveAndCloseCoordinator.swift`):

```
		1F00000200000000000003A6 /* QuickOpenIndex.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickOpenIndex.swift; sourceTree = "<group>"; };
		1F00000200000000000003A7 /* QuickOpenIndexTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickOpenIndexTests.swift; sourceTree = "<group>"; };
```

Groups: add `1F00000200000000000003A6 /* QuickOpenIndex.swift */,` to the `Outline` group's children (the group at `1F0000070000000000000016 /* Outline */`, ~line 420); add `1F00000200000000000003A7 /* QuickOpenIndexTests.swift */,` to the LineformTests group's children (find it via the existing `OutlineSidebarTabTests.swift` file-ref usage in a group).

Sources build phases: add `1F00000100000000000003A6 /* QuickOpenIndex.swift in Sources */,` to the app target's Sources list (where `WindowCloseController.swift in Sources` appears, ~line 719); add `1F00000100000000000003A7 /* QuickOpenIndexTests.swift in Sources */,` to the test target's Sources list (where `OutlineSidebarTabTests.swift in Sources` appears, ~line 792).

- [ ] **Step 2: Write the failing tests**

Create `LineformTests/QuickOpenIndexTests.swift`:

```swift
import XCTest
@testable import Lineform

final class QuickOpenIndexTests: XCTestCase {
    private func file(_ path: String) -> OutlineFileTreeItem {
        let url = URL(fileURLWithPath: path)
        return OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: false, children: [])
    }

    private func folder(_ path: String, children: [OutlineFileTreeItem]) -> OutlineFileTreeItem {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: true, children: children)
    }

    private func root(id: String, title: String, items: [OutlineFileTreeItem]) -> OutlineFileRoot {
        OutlineFileRoot(id: id, title: title, systemImage: "folder", state: .available, items: items)
    }

    // MARK: flatten

    func testFlattenMergesBothRootsAndRecursesIntoFolders() {
        let iCloud = root(id: "icloud", title: "Lineform", items: [file("/icloud/notes.md")])
        let workspace = root(id: "workspace", title: "Docs", items: [
            file("/ws/readme.md"),
            folder("/ws/projects", children: [file("/ws/projects/roadmap.md")]),
        ])

        let entries = QuickOpenIndex.flatten(iCloudRoot: iCloud, workspaceRoot: workspace)

        XCTAssertEqual(entries.map(\.name), ["notes.md", "readme.md", "roadmap.md"])
        XCTAssertEqual(entries.map(\.relativePath), ["notes.md", "readme.md", "projects/roadmap.md"])
        XCTAssertEqual(entries.map(\.rootTitle), ["Lineform", "Docs", "Docs"])
        XCTAssertEqual(entries.map(\.id), ["/icloud/notes.md", "/ws/readme.md", "/ws/projects/roadmap.md"])
    }

    func testFlattenExcludesDirectoriesThemselves() {
        let workspace = root(id: "workspace", title: "Docs", items: [
            folder("/ws/empty", children: []),
            folder("/ws/projects", children: [file("/ws/projects/a.md")]),
        ])
        let entries = QuickOpenIndex.flatten(
            iCloudRoot: root(id: "icloud", title: "Lineform", items: []),
            workspaceRoot: workspace
        )
        XCTAssertEqual(entries.map(\.name), ["a.md"])
    }

    func testFlattenOfEmptyRootsIsEmpty() {
        let entries = QuickOpenIndex.flatten(
            iCloudRoot: root(id: "icloud", title: "Lineform", items: []),
            workspaceRoot: root(id: "workspace", title: "Docs", items: [])
        )
        XCTAssertEqual(entries, [])
    }

    // MARK: search

    private var sampleEntries: [QuickOpenEntry] {
        QuickOpenIndex.flatten(
            iCloudRoot: root(id: "icloud", title: "Lineform", items: []),
            workspaceRoot: root(id: "workspace", title: "Docs", items: [
                file("/ws/roadmap.md"),
                file("/ws/readme.md"),
                file("/ws/release-notes.md"),
                folder("/ws/journal", children: [file("/ws/journal/2026.md")]),
            ])
        )
    }

    func testSearchMatchesSubsequence() {
        // "rdmp" is not a substring of "roadmap.md" but is an in-order subsequence.
        let results = QuickOpenIndex.search(sampleEntries, query: "rdmp")
        XCTAssertEqual(results.map(\.name), ["roadmap.md"])
    }

    func testSearchIsCaseInsensitive() {
        let results = QuickOpenIndex.search(sampleEntries, query: "README")
        XCTAssertEqual(results.first?.name, "readme.md")
    }

    func testSearchRanksPrefixMatchAboveMidStringMatch() {
        // "re" prefixes readme.md and release-notes.md but only appears mid-string
        // elsewhere; both prefix matches must rank above any subsequence-only match.
        let results = QuickOpenIndex.search(sampleEntries, query: "re")
        XCTAssertEqual(Set(results.prefix(2).map(\.name)), ["readme.md", "release-notes.md"])
    }

    func testSearchExactSubstringBeatsScatteredSubsequence() {
        let entries = [
            QuickOpenEntry(id: "/a", url: URL(fileURLWithPath: "/a"), name: "meeting-notes.md", relativePath: "meeting-notes.md", rootTitle: "Docs"),
            QuickOpenEntry(id: "/b", url: URL(fileURLWithPath: "/b"), name: "mail-sorting-hints.md", relativePath: "mail-sorting-hints.md", rootTitle: "Docs"),
        ]
        let results = QuickOpenIndex.search(entries, query: "notes")
        XCTAssertEqual(results.first?.name, "meeting-notes.md")
    }

    func testSearchEmptyOrWhitespaceQueryReturnsNothing() {
        XCTAssertEqual(QuickOpenIndex.search(sampleEntries, query: ""), [])
        XCTAssertEqual(QuickOpenIndex.search(sampleEntries, query: "   "), [])
    }

    func testSearchNoMatchesReturnsEmpty() {
        XCTAssertEqual(QuickOpenIndex.search(sampleEntries, query: "zzzz"), [])
    }

    func testSearchRespectsLimit() {
        let many = (0..<30).map { index in
            QuickOpenEntry(
                id: "/f\(index)",
                url: URL(fileURLWithPath: "/f\(index)"),
                name: "note-\(index).md",
                relativePath: "note-\(index).md",
                rootTitle: "Docs"
            )
        }
        XCTAssertEqual(QuickOpenIndex.search(many, query: "note", limit: 20).count, 20)
        XCTAssertEqual(QuickOpenIndex.search(many, query: "note", limit: 5).count, 5)
    }
}
```

- [ ] **Step 3: Build to verify the tests fail to compile (QuickOpenIndex not defined)**

Create `Lineform/Outline/QuickOpenIndex.swift` with ONLY a comment placeholder first? No — Swift test targets fail the whole build on a missing type, which is the expected "failing" state. Run:

```sh
xcodebuild build-for-testing -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: **BUILD FAILED** with `cannot find 'QuickOpenIndex' in scope` (this is the TDD red step for compiled languages).

- [ ] **Step 4: Write the implementation**

Create `Lineform/Outline/QuickOpenIndex.swift`:

```swift
import Foundation

/// One openable file in the quick-open (⌘K "Jump to File") palette.
struct QuickOpenEntry: Identifiable, Equatable {
    /// Full URL path — same identity rule as `OutlineFileTreeItem.id`.
    let id: String
    let url: URL
    /// File name, e.g. "roadmap.md". The fuzzy matcher runs against this only.
    let name: String
    /// Path within its root, e.g. "projects/roadmap.md" — shown to disambiguate
    /// same-named files in different folders or roots.
    let relativePath: String
    /// The owning root's display title ("Lineform" for iCloud, the workspace folder's name).
    let rootTitle: String
}

/// Pure flatten + fuzzy-rank logic behind the ⌘K palette. Operates on the trees the
/// Files sidebar's `OutlineFileBrowserStore` has already scanned — no I/O, no scanning,
/// fully unit-testable (the `EditorSearchResolver` pattern).
enum QuickOpenIndex {
    /// Flattens both roots' already-scanned trees into a flat list of files
    /// (directories recursed into, never listed themselves).
    static func flatten(iCloudRoot: OutlineFileRoot, workspaceRoot: OutlineFileRoot) -> [QuickOpenEntry] {
        var entries: [QuickOpenEntry] = []
        func walk(_ items: [OutlineFileTreeItem], pathPrefix: String, rootTitle: String) {
            for item in items {
                let path = pathPrefix.isEmpty ? item.name : "\(pathPrefix)/\(item.name)"
                if item.isDirectory {
                    walk(item.children, pathPrefix: path, rootTitle: rootTitle)
                } else {
                    entries.append(QuickOpenEntry(
                        id: item.url.path,
                        url: item.url,
                        name: item.name,
                        relativePath: path,
                        rootTitle: rootTitle
                    ))
                }
            }
        }
        walk(iCloudRoot.items, pathPrefix: "", rootTitle: iCloudRoot.title)
        walk(workspaceRoot.items, pathPrefix: "", rootTitle: workspaceRoot.title)
        return entries
    }

    /// Fuzzy-filters and ranks `entries` against `query` (matched against `name` only).
    /// Empty/whitespace query → []. Case-insensitive. Subsequence match with bonuses for
    /// exact substring, match at start of name, and contiguous runs; ties break toward
    /// shorter names, then lexicographic relative path (stable, deterministic).
    static func search(_ entries: [QuickOpenEntry], query: String, limit: Int = 20) -> [QuickOpenEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return entries
            .compactMap { entry in score(name: entry.name, query: trimmed).map { (entry: entry, score: $0) } }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.name.count != rhs.entry.name.count { return lhs.entry.name.count < rhs.entry.name.count }
                return lhs.entry.relativePath < rhs.entry.relativePath
            }
            .prefix(limit)
            .map(\.entry)
    }

    /// Nil when `query` is not an in-order subsequence of `name` (case-insensitive).
    /// Higher is better. Not exposed; ranking behavior is asserted via `search`.
    private static func score(name: String, query: String) -> Int? {
        let name = name.lowercased()
        let query = query.lowercased()

        // Exact substring: a large fixed bonus, better the earlier it starts.
        if let range = name.range(of: query) {
            var substringScore = 1000 - name.distance(from: name.startIndex, to: range.lowerBound) * 2 - name.count
            if range.lowerBound == name.startIndex {
                substringScore += 200
            }
            return substringScore
        }

        // Subsequence walk: every query character must appear, in order. Contiguous
        // pairs earn a run bonus; skipped characters cost a little each.
        var subsequenceScore = 0
        var searchStart = name.startIndex
        var previousMatch: String.Index?
        for character in query {
            guard let found = name[searchStart...].firstIndex(of: character) else { return nil }
            if let previous = previousMatch, name.index(after: previous) == found {
                subsequenceScore += 15
            }
            if found == name.startIndex {
                subsequenceScore += 50
            }
            subsequenceScore -= name.distance(from: searchStart, to: found)
            previousMatch = found
            searchStart = name.index(after: found)
        }
        return subsequenceScore - name.count
    }
}
```

- [ ] **Step 5: Run the new tests and verify they pass**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/QuickOpenIndexTests 2>&1 | tail -5
```

Expected: **TEST SUCCEEDED**, 10 tests passing. (Warn the user about the possible one-time TCC prompt before the first CLI test run of the session.)

- [ ] **Step 6: Commit**

```sh
git add Lineform/Outline/QuickOpenIndex.swift LineformTests/QuickOpenIndexTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add QuickOpenIndex: pure flatten + fuzzy-rank logic for the Cmd+K palette"
```

---

### Task 2: Menu wiring — `showQuickOpen` notification, ⌘K command, Link → ⌘L

**Files:**
- Modify: `Lineform/App/LineformAppNotification.swift` (case list ~line 4-23, name switch ~line 25-66)
- Modify: `Lineform/App/AppCommands.swift` (AppMenuConfiguration constants near line 43; Link shortcut line 372; `CommandGroup(after: .newItem)` lines 436-441)
- Modify: `Lineform/Editor/LineformTextView.swift:411` (context-menu keyEquivalent hint)
- Test: `LineformTests/AppCommandNotificationTests.swift`

**Interfaces:**
- Produces (used by Task 4): `LineformAppNotification.showQuickOpen` with `name.rawValue == "Lineform.showQuickOpen"`, posted with the standard `activeWindowPayload()`.
- Produces: `AppMenuConfiguration.jumpToFileCommandTitle == "Jump to File…"`, `AppMenuConfiguration.jumpToFileCommandKeyEquivalent == "k"`.

- [ ] **Step 1: Write the failing tests**

In `LineformTests/AppCommandNotificationTests.swift`, after `testFindReplaceCommandUsesWindowScopedNotification()` (line ~124), add:

```swift
    func testJumpToFileCommandUsesWindowScopedNotification() {
        XCTAssertEqual(AppMenuConfiguration.jumpToFileCommandTitle, "Jump to File…")
        XCTAssertEqual(AppMenuConfiguration.jumpToFileCommandKeyEquivalent, "k")
        XCTAssertEqual(
            LineformAppNotification.showQuickOpen.name.rawValue,
            "Lineform.showQuickOpen"
        )
    }

    func testLinkFormattingShortcutMovedToCommandL() {
        // Cmd+K now belongs to Jump to File; Format > Link (and its context-menu hint)
        // must claim Cmd+L instead.
        XCTAssertEqual(AppMenuConfiguration.linkCommandKeyEquivalent, "l")
    }
```

- [ ] **Step 2: Build to verify it fails**

```sh
xcodebuild build-for-testing -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: **BUILD FAILED** — `showQuickOpen`, `jumpToFileCommandTitle`, `linkCommandKeyEquivalent` not found.

- [ ] **Step 3: Implement the notification case**

In `Lineform/App/LineformAppNotification.swift`, add to the case list (after `case showFindReplace`):

```swift
    case showQuickOpen
```

and to the `name` switch (after the `.showFindReplace` return):

```swift
        case .showQuickOpen:
            return Notification.Name("Lineform.showQuickOpen")
```

- [ ] **Step 4: Implement the menu constants and commands**

In `Lineform/App/AppCommands.swift`, in `AppMenuConfiguration` (near the existing `renameFileCommandTitle`/`deleteFileCommandTitle` constants at lines 43-44), add:

```swift
    static let jumpToFileCommandTitle = "Jump to File…"
    static let jumpToFileCommandKeyEquivalent = "k"
    /// Format > Link's shortcut letter. Was "k" until quick-open claimed Cmd+K
    /// (2026-07-17 spec); the text view's right-click menu hint must stay in sync.
    static let linkCommandKeyEquivalent = "l"
```

Change the Link shortcut (line 369-372) from:

```swift
                Button("Link") {
                    NSApp.sendAction(#selector(LineformTextView.toggleLinkMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
```

to:

```swift
                Button("Link") {
                    NSApp.sendAction(#selector(LineformTextView.toggleLinkMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(AppMenuConfiguration.linkCommandKeyEquivalent)),
                    modifiers: .command
                )
```

Add the Jump to File command to the existing `CommandGroup(after: .newItem)` (lines 436-441), after the New Tab button:

```swift
        // Tab commands live in the File menu, alongside the standard document commands.
        // Close Tab uses ⌘⇧W so it does not collide with the system Close Window (⌘W).
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                LineformAppNotification.newTab.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut("t", modifiers: .command)

            // Jump to File lives beside New Tab: both are "get to a document" actions,
            // unlike the Save As/Rename/Delete group that acts on the current file.
            Button(AppMenuConfiguration.jumpToFileCommandTitle) {
                LineformAppNotification.showQuickOpen.post(object: LineformAppNotification.activeWindowPayload())
            }
            .keyboardShortcut(
                KeyEquivalent(Character(AppMenuConfiguration.jumpToFileCommandKeyEquivalent)),
                modifiers: .command
            )
        }
```

- [ ] **Step 5: Update the context-menu hint**

In `Lineform/Editor/LineformTextView.swift:411`, change:

```swift
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.linkTitle, action: #selector(toggleLinkMarkdown(_:)), keyEquivalent: "k"))
```

to:

```swift
            menu.addItem(NSMenuItem(title: LineformTextContextMenuPresentation.linkTitle, action: #selector(toggleLinkMarkdown(_:)), keyEquivalent: AppMenuConfiguration.linkCommandKeyEquivalent))
```

- [ ] **Step 6: Run the tests and verify they pass**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/AppCommandNotificationTests 2>&1 | tail -5
```

Expected: **TEST SUCCEEDED** (existing tests in the class plus the 2 new ones).

- [ ] **Step 7: Commit**

```sh
git add Lineform/App/LineformAppNotification.swift Lineform/App/AppCommands.swift Lineform/Editor/LineformTextView.swift LineformTests/AppCommandNotificationTests.swift
git commit -m "Wire Cmd+K to a Jump to File command; move Format > Link to Cmd+L"
```

---

### Task 3: Hoist `OutlineFileBrowserStore` to `EditorContainerView` + scan-session flag

The palette needs the scanned file tree, but the store is currently a `@StateObject` **inside** `OutlineSidebarView` (`OutlineSidebarView.swift:218`, created at line 344 as `fileBrowserStore ?? OutlineFileBrowserStore(runsScanInBackground: true)`); `EditorContainerView` holds only an optional injected reference (nil in production). Hoist creation up one level so the container owns the store and passes it down. This is behaviorally equivalent (same init, same window-construction timing, still exactly one store per window) and test injection keeps working unchanged.

Also add a flag so ⌘K can trigger the deferred iCloud scan exactly once: the store's init already scans the **workspace** synchronously (`refreshWorkspaceRoot()` at the end of init) and loads cached snapshots for both roots, but the expensive **iCloud** scan is deferred to `refreshICloud()`.

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (store class, ~line 834+)
- Modify: `Lineform/Editor/EditorContainerView.swift` (lines 55, 69, 87)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Consumes: `OutlineFileBrowserStore.refreshICloud()` (line ~1054).
- Produces (used by Task 4): `fileBrowserStore` as a `@StateObject` member of `EditorContainerView`; `OutlineFileBrowserStore.hasPerformedICloudScan: Bool` (read-only, false until `refreshICloud()` first runs this session).

- [ ] **Step 1: Write the failing test**

In `LineformTests/OutlineSidebarViewTests.swift`, near `testFilesTabReportsLineformICloudUnavailableWhenContainerCannotResolve` (line ~246), add:

```swift
    @MainActor
    func testICloudScanFlagFlipsOnFirstRefreshOnly() {
        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in nil }
        )
        // Init scans the workspace and loads snapshots but must NOT count as an
        // iCloud scan (the deferred-scan invariant).
        XCTAssertFalse(store.hasPerformedICloudScan)

        store.refreshICloud()
        XCTAssertTrue(store.hasPerformedICloudScan)
    }
```

- [ ] **Step 2: Build to verify it fails**

```sh
xcodebuild build-for-testing -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: **BUILD FAILED** — `hasPerformedICloudScan` not found.

- [ ] **Step 3: Add the flag to the store**

In `Lineform/Outline/OutlineSidebarView.swift`, add a stored property to `OutlineFileBrowserStore` (next to `lastKnownICloudAvailable`, ~line 907; plain property, deliberately not `@Published` — nothing renders from it):

```swift
    /// True once refreshICloud() has run this session. Quick-open (⌘K) reads this to
    /// trigger the deferred iCloud scan exactly once per session instead of on every
    /// palette open — the Files tab's every-appearance refresh is unchanged.
    private(set) var hasPerformedICloudScan = false
```

and set it in `refreshICloud()` (line ~1054):

```swift
    func refreshICloud() {
        hasPerformedICloudScan = true
        refreshICloudRoot()
    }
```

- [ ] **Step 4: Hoist store ownership in `EditorContainerView`**

In `Lineform/Editor/EditorContainerView.swift`:

Replace (line 55):

```swift
    private let injectedFileBrowserStore: OutlineFileBrowserStore?
```

with:

```swift
    /// Owned here (not in the sidebar) so quick-open can read the scanned tree even with
    /// the sidebar closed. Passed down to OutlineSidebarView, which adopts an injected
    /// store instead of creating its own — one store per window either way.
    @StateObject private var fileBrowserStore: OutlineFileBrowserStore
```

Replace (line 69, in `init`):

```swift
        injectedFileBrowserStore = fileBrowserStore
```

with:

```swift
        _fileBrowserStore = StateObject(
            wrappedValue: fileBrowserStore ?? OutlineFileBrowserStore(runsScanInBackground: true)
        )
```

Replace (line 87, in `body`):

```swift
                fileBrowserStore: injectedFileBrowserStore,
```

with:

```swift
                fileBrowserStore: fileBrowserStore,
```

`OutlineSidebarView`'s init (line ~344, `_fileBrowserStore = StateObject(wrappedValue: fileBrowserStore ?? OutlineFileBrowserStore(runsScanInBackground: true))`) needs no change — it now always receives the container's instance in production, and its `?? ...` fallback still covers direct construction in tests/previews.

- [ ] **Step 5: Run the store tests and verify they pass**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -5
```

Expected: **TEST SUCCEEDED** (all existing sidebar-store tests plus the new flag test — the hoist must not break any of them).

- [ ] **Step 6: Commit**

```sh
git add Lineform/Outline/OutlineSidebarView.swift Lineform/Editor/EditorContainerView.swift LineformTests/OutlineSidebarViewTests.swift
git commit -m "Hoist OutlineFileBrowserStore to EditorContainerView; add iCloud scan-session flag"
```

---

### Task 4: The `QuickOpenPalette` view + presentation wiring

**Files:**
- Create: `Lineform/Editor/QuickOpenPalette.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (register the new file — app target only)
- Modify: `Lineform/Editor/EditorContainerView.swift` (state ~line 25-28, `.onReceive` chain ~line 224, `editorShell` ~line 477-511, `resetTransientDocumentState` line 1224)
- Modify: `docs/superpowers/specs/2026-07-17-quick-open-jump-to-file-design.md` (one line — see Step 6)

**Interfaces:**
- Consumes: `QuickOpenEntry` / `QuickOpenIndex.flatten` / `QuickOpenIndex.search` (Task 1); `LineformAppNotification.showQuickOpen` (Task 2); `fileBrowserStore` + `hasPerformedICloudScan` (Task 3); existing `museModalLayer(scrimZIndex:modalZIndex:onDismiss:modal:)` (`EditorContainerView.swift:518`), `openSidebarFile(_:)` (line 834), `notificationMatchesActiveWindow(_:)`, `currentTheme`, `MuseModalChrome.backgroundWhiteComponent`/`.cornerRadius`, `View.modalArrowCursor()`.
- Produces: `QuickOpenPalette` view; no downstream consumers.

- [ ] **Step 1: Register the new file in the pbxproj**

Same 4-section procedure as Task 1, app target only. IDs:

```
		1F00000100000000000003A8 /* QuickOpenPalette.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000003A8 /* QuickOpenPalette.swift */; };
```

```
		1F00000200000000000003A8 /* QuickOpenPalette.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickOpenPalette.swift; sourceTree = "<group>"; };
```

Group: the `Editor` group (find it via `WindowCloseController.swift`'s group membership, ~line 370). Sources: the app target's Sources list (~line 719).

- [ ] **Step 2: Write the palette view**

Create `Lineform/Editor/QuickOpenPalette.swift`:

```swift
import SwiftUI

/// The ⌘K "Jump to File" palette: a centered modal card with a search field over a
/// live-filtered, keyboard-navigable list of every file the sidebar's store has scanned.
/// Pure presentation — flatten/rank logic lives in QuickOpenIndex; opening goes through
/// the same path as a sidebar click (the container's openSidebarFile).
struct QuickOpenPalette: View {
    let entries: [QuickOpenEntry]
    @Binding var query: String
    var usesDarkChrome: Bool
    var availableWidth: CGFloat
    var onOpen: (QuickOpenEntry) -> Void
    var onDismiss: () -> Void

    @State private var selectionIndex = 0
    @FocusState private var isFieldFocused: Bool

    static let maximumCardWidth: CGFloat = 560
    static let listMaximumHeight: CGFloat = 320

    private var results: [QuickOpenEntry] {
        QuickOpenIndex.search(entries, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to file…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .onSubmit { openSelection() }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .accessibilityLabel("Jump to file")

            Divider()

            resultsList
        }
        .frame(width: min(Self.maximumCardWidth, max(280, availableWidth - 48)))
        // Same two fixed chrome variants as the Find & Replace card, at modal weight.
        .environment(\.colorScheme, usesDarkChrome ? .dark : .light)
        .background(
            RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius)
                .fill(
                    usesDarkChrome
                        ? Color(white: 0.15)
                        : Color(white: MuseModalChrome.backgroundWhiteComponent)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius)
                .strokeBorder(
                    usesDarkChrome ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
                )
        )
        .modalArrowCursor()
        .onExitCommand { onDismiss() }
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in
            selectionIndex = 0
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = results
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hintRow("Type to search files…")
        } else if results.isEmpty {
            hintRow("No matches")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        resultRow(entry, isSelected: index == selectionIndex)
                            .onTapGesture { onOpen(entry) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: Self.listMaximumHeight)
        }
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private func resultRow(_ entry: QuickOpenEntry, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.relativePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.22))
                : nil
        )
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(entry.relativePath)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectionIndex = min(max(selectionIndex + delta, 0), count - 1)
    }

    private func openSelection() {
        let results = results
        guard results.indices.contains(selectionIndex) else { return }
        onOpen(results[selectionIndex])
    }
}
```

- [ ] **Step 3: Wire presentation in `EditorContainerView`**

Add state (next to `isShowingFindReplace`, ~line 25):

```swift
    @State private var isShowingQuickOpen = false
    @State private var quickOpenQuery = ""
```

Add the `.onReceive` (after the `showFindReplace` one at line ~236):

```swift
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showQuickOpen.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            // First ⌘K of a session triggers the deferred iCloud scan — the same
            // user-gesture trigger the Files tab uses, so the iCloud-laziness
            // invariant (never scan at launch/construction) holds. Workspace was
            // already scanned at store init; refresh it here too so a session-old
            // tree gets one catch-up walk (background-scanning store, no hitch).
            if !fileBrowserStore.hasPerformedICloudScan {
                fileBrowserStore.refreshICloud()
                fileBrowserStore.refreshWorkspace()
            }
            quickOpenQuery = ""
            isShowingQuickOpen = true
        }
```

In `editorShell` (line ~477), add the palette layer to the ZStack after the Settings block (`if isShowingSettings { … }`, lines 499-505), giving it higher z-indices so it stacks above Settings if both are ever up:

```swift
            // Quick open (⌘K) uses the same shared Muse modal language as Settings:
            // scrim + centered card + Esc/outside-click dismissal.
            if isShowingQuickOpen {
                museModalLayer(scrimZIndex: 5, modalZIndex: 6, onDismiss: { dismissQuickOpen() }) { geometry in
                    QuickOpenPalette(
                        entries: QuickOpenIndex.flatten(
                            iCloudRoot: fileBrowserStore.iCloudRoot,
                            workspaceRoot: fileBrowserStore.workspaceRoot
                        ),
                        query: $quickOpenQuery,
                        usesDarkChrome: theme.usesDarkChrome,
                        availableWidth: geometry.size.width,
                        onOpen: { entry in
                            openSidebarFile(entry.url)
                            dismissQuickOpen()
                        },
                        onDismiss: { dismissQuickOpen() }
                    )
                }
            }
```

and extend the shell's animation so the palette gets the same entrance/exit treatment as Settings — after the existing `.animation(..., value: isShowingSettings)` (line ~507-510), add:

```swift
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: SettingsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingQuickOpen
        )
```

Add the dismiss helper (next to `dismissFindReplace()`, line ~686):

```swift
    private func dismissQuickOpen() {
        isShowingQuickOpen = false
        quickOpenQuery = ""
    }
```

In `resetTransientDocumentState()` (line 1224), add:

```swift
        isShowingQuickOpen = false
        quickOpenQuery = ""
```

- [ ] **Step 4: Build**

```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -3
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Run the full default test plan**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -5
```

Expected: **TEST SUCCEEDED**, ~380+ tests, 0 failures. (Remind the user about the possible TCC prompt.) The palette itself has no automated view test — open/dismiss/keyboard-nav/selection are covered by the manual QA task below, consistent with how Find & Replace's view behavior was verified.

- [ ] **Step 6: Sync the spec's "Scanning…" line with reality**

The spec mentions a "Scanning…" row for a scan in flight. Implementation reality: the store loads cached snapshots at init and scans the workspace synchronously, so the only empty-while-scanning case is a first-ever launch with an unscanned iCloud container — not worth scan-progress plumbing in the store. In `docs/superpowers/specs/2026-07-17-quick-open-jump-to-file-design.md`, replace the sentence

```
If a scan is still in flight when results are needed, show a quiet "Scanning…" row (see Error handling below).
```

with:

```
No scan-in-flight indicator: the store loads cached snapshots at init and scans the
workspace synchronously, so an in-flight-scan-with-empty-results state only exists on a
first-ever launch before iCloud has ever scanned — "No matches" is acceptable there and
the list fills in when the background scan publishes.
```

- [ ] **Step 7: Commit**

```sh
git add Lineform/Editor/QuickOpenPalette.swift Lineform/Editor/EditorContainerView.swift Lineform.xcodeproj/project.pbxproj docs/superpowers/specs/2026-07-17-quick-open-jump-to-file-design.md
git commit -m "Add Cmd+K Jump to File palette over the sidebar's scanned file tree"
```

---

### Task 5: Manual QA in the running app + docs

**Files:**
- Modify: `CLAUDE.md` (Main Features list)

- [ ] **Step 1: Build and launch the FRESH Debug build**

Per the debug-launch gotcha (agent memory): resolve `BUILT_PRODUCTS_DIR` from `xcodebuild -showBuildSettings`, kill any running Lineform, and `open` that exact path — never `open -a Lineform` (stale copy risk):

```sh
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -2
APP="$(xcodebuild -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/Lineform.app"
pkill -x Lineform || true
open "$APP"
```

- [ ] **Step 2: Ask the user to drive the QA checklist**

GUI automation is blocked on this machine (System Events unauthorized — agent memory), so ask the user to verify, with a workspace folder assigned:

1. ⌘K opens the centered palette with the field focused; the sidebar can be closed.
2. Typing filters live; a scattered subsequence (e.g. "rdmp" for roadmap.md) matches; nested files show their `folder/file.md` path.
3. ↑/↓ move the highlight; Return opens the highlighted file in a tab (or switches to its existing tab); Esc and scrim-click dismiss.
4. ⌘K in a dark theme (Quiet/Night) shows the dark card variant; toolbar/header color does not change when the palette opens.
5. Format ▸ Link now shows ⌘L in the menu and still wraps the selection; ⌘K no longer inserts a link.
6. ⌘K works in Read mode without switching modes.

- [ ] **Step 3: Update `CLAUDE.md`**

Add a Main Features bullet (after the Find & Replace bullet), matching the file's style:

```markdown
- Jump to File (⌘K): a centered quick-open palette that fuzzy-searches filenames across the Workspace + iCloud roots (the Files sidebar's scanned tree) and opens the selection exactly like a sidebar click (new tab, or switch to the existing tab). Pure flatten/rank logic in `QuickOpenIndex` (`Lineform/Outline/QuickOpenIndex.swift`); the card is `QuickOpenPalette` (`Lineform/Editor/QuickOpenPalette.swift`), presented through the shared `museModalLayer` scrim in `EditorContainerView`. The first ⌘K of a session triggers the deferred iCloud scan (`OutlineFileBrowserStore.hasPerformedICloudScan` guard) — the laziness invariant holds; the palette starts no FSEvents watcher and inherits the sidebar's 80-per-folder cap. Freeing ⌘K moved **Format ▸ Link to ⌘L** (`AppMenuConfiguration.linkCommandKeyEquivalent`, shared with the editor's right-click menu hint). The store is owned by `EditorContainerView` (hoisted 2026-07-17) and injected into the sidebar. See `docs/superpowers/specs/2026-07-17-quick-open-jump-to-file-design.md`.
```

- [ ] **Step 4: Commit**

```sh
git add CLAUDE.md
git commit -m "Document the Cmd+K Jump to File palette"
```

---

## Self-Review Notes

- **Spec coverage:** shortcut swap (Task 2), files-on-disk-only palette + hint empty state + top-20 + relative paths (Tasks 1/4), sidebar-identical open path via `openSidebarFile` (Task 4), lazy-scan guard (Tasks 3/4), scrim/chrome variants + accessibility labels (Task 4), pure-logic tests + menu wiring tests (Tasks 1-3), manual QA for view behavior (Task 5). The spec's "Scanning…" row is explicitly amended in Task 4 Step 6 rather than silently dropped.
- **Spec deviation (deliberate, surfaced during planning):** the spec assumed `EditorContainerView` already had store access; it doesn't — Task 3's hoist is the minimal correction. The spec's suggestion to guard the scan on `OutlineFileRoot.state` was replaced by an explicit `hasPerformedICloudScan` flag, because cached snapshots make root state indistinguishable from "scanned this session."
- **Type consistency:** `QuickOpenEntry` fields, `flatten`/`search` signatures, `hasPerformedICloudScan`, and `jumpToFileCommandTitle`/`linkCommandKeyEquivalent` are used with identical names/signatures across Tasks 1-5.
