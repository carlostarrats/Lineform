# Hidden Folder Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted, default-off "Show hidden folders" toggle to the Files sidebar that reveals dot-directories and their `.md`/`.markdown`/`.txt` files (de-emphasized), while always excluding `node_modules`/`.git`.

**Architecture:** All changes are in the single file `Lineform/Outline/OutlineSidebarView.swift` (plus tests). The one pure filter function `OutlineFileBrowserStore.items(in:fileManager:depth:)` gains a `showsHiddenFolders` flag; the node model gains an `isHidden` flag (decode-tolerant); the store gains a persisted `@Published showsHiddenFolders` that re-scans on change; the browser view gains a quiet toggle and the node view de-emphasizes hidden rows.

**Tech Stack:** Swift, SwiftUI, AppKit, FileManager, XCTest, macOS 14+.

## Global Constraints

- Verification gate (serial, per CLAUDE.md; quit Xcode first):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
- No new files → **no `project.pbxproj` changes**. Everything lives in existing, already-targeted files.
- Toggle default OFF; behavior with it off is byte-identical to today except the always-on `node_modules`/`.git` blocklist.
- Persist per app via the injected `defaults` under `"Lineform.outline.showsHiddenFolders"`. No `@AppStorage`.
- Preserve the CLAUDE.md iCloud laziness rule: do NOT add an iCloud scan at construction. Loading the persisted bool in `init` must not trigger a scan (Swift suppresses `didSet` during initialization — rely on that; do not call refresh from init beyond the existing `refreshWorkspaceRoot()`).
- Keep the extension whitelist, volume caps, iCloud/workspace root logic, and `ensureDownloaded` behavior unchanged.
- Testing runs launch the app (TCC re-prompts on each fresh debug build); keep scratch fixtures in temp dirs (the tests already do), never `~/Documents`.
- Spec: `docs/superpowers/specs/2026-07-01-hidden-folders-design.md`. Index: `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`.

---

### Task 1: `OutlineFileTreeItem.isHidden` with decode-tolerant Codable

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift:11-18`
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Produces: `OutlineFileTreeItem` gains `var isHidden: Bool` (defaults false; tolerant decode of legacy snapshots).

- [ ] **Step 1: Write the failing test**

Add to `OutlineSidebarViewTests`:

```swift
func testLegacyTreeItemSnapshotDecodesWithHiddenFalse() throws {
    // A snapshot written before isHidden existed (no "isHidden" key).
    let legacyJSON = """
    [{"url":"file:///tmp/Draft.md","name":"Draft.md","isDirectory":false,"children":[]}]
    """.data(using: .utf8)!
    let items = try JSONDecoder().decode([OutlineFileTreeItem].self, from: legacyJSON)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.name, "Draft.md")
    XCTAssertEqual(items.first?.isHidden, false)
}

func testTreeItemRoundTripsHiddenFlag() throws {
    let item = OutlineFileTreeItem(url: URL(fileURLWithPath: "/tmp/.claude"), name: ".claude", isDirectory: true, children: [], isHidden: true)
    let data = try JSONEncoder().encode([item])
    let decoded = try JSONDecoder().decode([OutlineFileTreeItem].self, from: data)
    XCTAssertEqual(decoded.first?.isHidden, true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineSidebarViewTests/testLegacyTreeItemSnapshotDecodesWithHiddenFalse 2>&1 | tail -15`
Expected: FAIL — extra/missing argument `isHidden` (compile) or decode assertion.

- [ ] **Step 3: Implement**

Replace `OutlineFileTreeItem` (`:11-18`) with:

```swift
struct OutlineFileTreeItem: Identifiable, Equatable, Codable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var children: [OutlineFileTreeItem]
    var isHidden: Bool = false

    var id: String { url.path }

    init(url: URL, name: String, isDirectory: Bool, children: [OutlineFileTreeItem], isHidden: Bool = false) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, children, isHidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        name = try container.decode(String.self, forKey: .name)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        children = try container.decode([OutlineFileTreeItem].self, forKey: .children)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
```

(The explicit memberwise `init` is required because adding a custom `init(from:)` otherwise suppresses the synthesized memberwise initializer that call sites use. `encode(to:)` stays synthesized.)

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test ... -only-testing:LineformTests/OutlineSidebarViewTests/testLegacyTreeItemSnapshotDecodesWithHiddenFalse -only-testing:LineformTests/OutlineSidebarViewTests/testTreeItemRoundTripsHiddenFlag 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineSidebarViewTests.swift
git commit -m "Add decode-tolerant isHidden to OutlineFileTreeItem"
```

---

### Task 2: Filtering — `showsHiddenFolders`, blocklist, hidden marking

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift:731-778` (the `items` function) and add `excludedDirectoryNames` near the other static constants (`:447-449`).
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Consumes: `OutlineFileTreeItem.isHidden` (Task 1).
- Produces: `static func items(in:fileManager:depth:showsHiddenFolders:inheritedHidden:) -> [OutlineFileTreeItem]`; `static let excludedDirectoryNames: Set<String>`.

**Note:** the two call sites (`refreshICloudRoot` `:633`, `refreshWorkspaceRoot` `:693`) pass `showsHiddenFolders:` in Task 3. For this task, give the new parameters defaults (`showsHiddenFolders: Bool = false`, `inheritedHidden: Bool = false`) so existing call sites still compile and the tests can call `items` behavior indirectly via a store (Task 3) — but the pure-filtering tests here drive it through a store constructed in Task 3's helper. To keep Task 2 independently testable, test the filtering by constructing a store pointed at a temp dir (the store already defaults `showsHiddenFolders` to false until Task 3; add the store field in Task 3). **Therefore fold the store field into Task 3 and test filtering there.** Task 2 delivers the pure function + blocklist and is verified by build + Task 3's tests.

- [ ] **Step 1: Add the blocklist constant**

After `supportedFileExtensions` (`:449`) add:

```swift
    /// Directory names always hidden from the tree, even with "Show hidden folders" on —
    /// build/vcs noise that is never useful reading material.
    static let excludedDirectoryNames: Set<String> = ["node_modules", ".git"]
```

- [ ] **Step 2: Rewrite `items` to filter, mark, and recurse**

Replace `items(in:fileManager:depth:)` (`:731-778`) with:

```swift
    private static func items(
        in url: URL,
        fileManager: FileManager,
        depth: Int = 0,
        showsHiddenFolders: Bool = false,
        inheritedHidden: Bool = false
    ) -> [OutlineFileTreeItem] {
        guard depth < maximumTreeDepth else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = showsHiddenFolders ? [] : [.skipsHiddenFiles]
        let urls = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )) ?? []

        return urls.compactMap { childURL -> OutlineFileTreeItem? in
            guard let values = try? childURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            let name = childURL.lastPathComponent
            let isDirectory = values.isDirectory == true

            // Always exclude build/vcs noise directories.
            if isDirectory, excludedDirectoryNames.contains(name) {
                return nil
            }

            // When showing hidden folders we drop .skipsHiddenFiles, so also drop genuinely
            // OS-hidden items that are NOT dot-prefixed (system junk), while keeping dotfiles.
            let isDotPrefixed = name.hasPrefix(".")
            if showsHiddenFolders, values.isHidden == true, !isDotPrefixed {
                return nil
            }

            let isSupportedFile = values.isRegularFile == true
                && supportedFileExtensions.contains(childURL.pathExtension.lowercased())

            guard isDirectory || isSupportedFile else {
                return nil
            }

            let itemHidden = inheritedHidden || isDotPrefixed

            return OutlineFileTreeItem(
                url: childURL,
                name: name,
                isDirectory: isDirectory,
                children: isDirectory
                    ? items(
                        in: childURL,
                        fileManager: fileManager,
                        depth: depth + 1,
                        showsHiddenFolders: showsHiddenFolders,
                        inheritedHidden: itemHidden
                    )
                    : [],
                isHidden: itemHidden
            )
        }
        .sorted { first, second in
            if first.isDirectory != second.isDirectory {
                return first.isDirectory
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        .prefix(maximumChildrenPerFolder)
        .map { $0 }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED` (existing call sites still compile via the defaulted params).

- [ ] **Step 4: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift
git commit -m "Filter hidden folders + node_modules/.git blocklist in tree scan"
```

---

### Task 3: Store — persisted `showsHiddenFolders` + re-scan wiring

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (store `:438-492`, and the two `items(...)` call sites `:633`, `:693`)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Consumes: `items(..., showsHiddenFolders:)` (Task 2).
- Produces: `OutlineFileBrowserStore.showsHiddenFolders: Bool` (`@Published`, persisted); `static let showsHiddenFoldersDefaultsKey`.

- [ ] **Step 1: Write the failing tests**

Add to `OutlineSidebarViewTests` (mirror the existing temp-dir + injected-suite + `iCloudDocumentsURLProvider` pattern used around `:218-262`):

```swift
func testHiddenFoldersExcludedByDefault() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try "# Notes".write(to: folder.appendingPathComponent(".claude/notes.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try "# Readme".write(to: folder.appendingPathComponent("node_modules/readme.md"), atomically: true, encoding: .utf8)

    let (store, _) = makeStore(iCloudFolder: folder)
    store.refreshICloud()
    XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["Draft.md"])
}

func testShowHiddenFoldersRevealsDotFoldersButNotBlocklist() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try "# Notes".write(to: folder.appendingPathComponent(".claude/notes.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try "# Readme".write(to: folder.appendingPathComponent("node_modules/readme.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "# Git".write(to: folder.appendingPathComponent(".git/config.md"), atomically: true, encoding: .utf8)

    let (store, _) = makeStore(iCloudFolder: folder)
    store.showsHiddenFolders = true
    store.refreshICloud()

    let names = store.iCloudRoot.items.map(\.name)
    XCTAssertEqual(names, [".claude", "Draft.md"])   // dirs sort first
    let claude = try XCTUnwrap(store.iCloudRoot.items.first { $0.name == ".claude" })
    XCTAssertTrue(claude.isHidden)
    XCTAssertEqual(claude.children.map(\.name), ["notes.md"])
    XCTAssertTrue(claude.children.first?.isHidden == true)
    let draft = try XCTUnwrap(store.iCloudRoot.items.first { $0.name == "Draft.md" })
    XCTAssertFalse(draft.isHidden)
}

func testShowHiddenFoldersPreferencePersists() throws {
    let suiteName = "LineformTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in nil })
    first.showsHiddenFolders = true

    let second = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in nil })
    XCTAssertTrue(second.showsHiddenFolders)
}
```

Add helpers if not already present in the file (reuse existing ones if they exist — check the file first):

```swift
private func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeStore(iCloudFolder: URL) -> (OutlineFileBrowserStore, UserDefaults) {
    let suiteName = "LineformTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in iCloudFolder })
    return (store, defaults)
}
```

(If the existing tests already define equivalent helpers, use those instead of redefining — inspect `OutlineSidebarViewTests.swift` first.)

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test ... -only-testing:LineformTests/OutlineSidebarViewTests/testShowHiddenFoldersPreferencePersists 2>&1 | tail -15`
Expected: FAIL — `value of type 'OutlineFileBrowserStore' has no member 'showsHiddenFolders'`.

- [ ] **Step 3: Add the persisted property + key**

Add the key beside `:444-446`:

```swift
    static let showsHiddenFoldersDefaultsKey = "Lineform.outline.showsHiddenFolders"
```

Add the published property beside the roots (`:451-464`):

```swift
    @Published var showsHiddenFolders = false {
        didSet {
            guard oldValue != showsHiddenFolders else { return }
            defaults.set(showsHiddenFolders, forKey: Self.showsHiddenFoldersDefaultsKey)
            // Hidden entries were never enumerated, so a re-scan is required. This runs the
            // same refresh path used when the Files tab appears (main-actor, user-initiated).
            refreshICloudRoot()
            refreshWorkspaceRoot()
        }
    }
```

In `init` (after `self.iCloudDownloader = ...`, before `loadICloudSnapshot()`, `:483-484`) load the persisted value. Because Swift does not fire `didSet` during initialization, this will not trigger a scan:

```swift
        showsHiddenFolders = defaults.bool(forKey: Self.showsHiddenFoldersDefaultsKey)
```

- [ ] **Step 4: Thread the flag into both scan call sites**

`refreshICloudRoot` (`:633`):
```swift
        let items = Self.items(in: url, fileManager: fileManager, showsHiddenFolders: showsHiddenFolders)
```
`refreshWorkspaceRoot` (`:693`):
```swift
        let items = Self.items(in: workspaceURL, fileManager: fileManager, showsHiddenFolders: showsHiddenFolders)
```

- [ ] **Step 5: Run to verify tests pass**

Run: `xcodebuild test ... -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: PASS (all OutlineSidebarViewTests, including the new ones and the pre-existing ones).

- [ ] **Step 6: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineSidebarViewTests.swift
git commit -m "Persist showsHiddenFolders and re-scan on toggle"
```

---

### Task 4: UI — toggle control + de-emphasized rows

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` — `OutlineFileBrowserView.body` (`:787-799`) and `OutlineFileTreeNodeView.row` (`:1019-1027`).

**Interfaces:**
- Consumes: `store.showsHiddenFolders` (Task 3); `item.isHidden` (Task 1); `OutlineSidebarView.secondaryTextColor(usesDarkChrome:)` (`:238-243`).

There is no lightweight unit test for SwiftUI rendering here; this task is verified by build + the manual smoke in Task 5.

- [ ] **Step 1: Add a quiet Files-only toggle at the top of the browser body**

In `OutlineFileBrowserView.body` (`:787-799`), add a header row above the `ScrollView` (wrap in a `VStack(spacing: 0)`), binding to the store:

```swift
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    store.showsHiddenFolders.toggle()
                } label: {
                    Image(systemName: store.showsHiddenFolders ? "eye" : "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                }
                .buttonStyle(.plain)
                .help("Show hidden folders")
                .accessibilityLabel("Show hidden folders")
                .accessibilityAddTraits(store.showsHiddenFolders ? [.isSelected] : [])
            }
            .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding)
            .padding(.top, 4)

            ScrollView {
                // ... existing LazyVStack unchanged ...
            }
            .scrollContentBackground(.hidden)
        }
    }
```

Keep the existing `ScrollView { LazyVStack { ... } }` body exactly as-is inside the new `VStack`.

- [ ] **Step 2: De-emphasize hidden rows**

In `OutlineFileTreeNodeView.row`, gate the icon (`:1021`) and name (`:1026`) color on `item.isHidden`:

```swift
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(rowForegroundColor)
                .frame(width: 18)

            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(rowForegroundColor)
                .lineLimit(1)
```

Add a computed helper on `OutlineFileTreeNodeView`:

```swift
    private var rowForegroundColor: Color {
        item.isHidden
            ? OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome)
            : OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift
git commit -m "Add Files hidden-folders toggle and de-emphasized rows"
```

---

### Task 5: Verify, docs, index

**Files:** `CLAUDE.md` (Main Features), `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`, optionally `README.md`.

- [ ] **Step 1: Full serial suite**

Quit Xcode; run the Global-Constraints gate. Report exact counts. Expected: all pass except the two documented load-sensitive `EditorDisplayModeTests` (harness fragility). If those two fail, confirm they also fail without this change (already established) and do not weaken them.

- [ ] **Step 2: Manual smoke (scratchpad, not ~/Documents)**

Assign the workspace root to a temp folder containing `.claude/plan.md` and `Draft.md`. Toggle on → `.claude` appears de-emphasized, `plan.md` opens and live-reloads; `node_modules`/`.git` never appear. Toggle off → `.claude` disappears. Relaunch → toggle state persisted. If not exercised, say so explicitly.

- [ ] **Step 3: Docs**

Add a one-line "Show hidden folders" entry to `CLAUDE.md` Main Features (and README feature list if it improves user clarity — skip if redundant). Update the iCloud/architecture note only if a reviewer flags a gap.

- [ ] **Step 4: Index**

Check off `- [x] 2 — Hidden folders` in `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Docs: note hidden folders; mark unit 2 complete in index"
```

---

## Notes for the implementer

- **`didSet` won't fire during `init`** — loading the persisted bool in `init` is safe and won't trigger a scan. Do not add any other scan to `init`.
- **Re-scan on toggle is required** (hidden entries were never enumerated); it reuses the same synchronous refresh path used on Files-tab appear, so it matches existing behavior and cost.
- **Blocklist applies regardless of the toggle** — `node_modules`/`.git` never show. This is a deliberate, product-aligned tightening of today's behavior.
- **Snapshot compatibility** is handled by the decode-tolerant `init(from:)` (Task 1); no snapshot-key version bump is needed.
- **Single file**: all product changes are in `OutlineSidebarView.swift`; there are no new files and therefore no `project.pbxproj` edits.
