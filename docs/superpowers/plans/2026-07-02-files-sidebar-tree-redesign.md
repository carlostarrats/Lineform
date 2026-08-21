# Files Sidebar Tree Redesign Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Files-tab sidebar so each root reads as a labelled container, nesting is unambiguous via one guide line per open folder, and the workspace label/action are clearer.

**Architecture:** All changes are in one file, `Lineform/Outline/OutlineSidebarView.swift` (the store + the three private Files-tab views), plus its test file `LineformTests/OutlineSidebarViewTests.swift`. Store changes: iCloud title "Lineform", dynamic workspace title, "Change" label. View changes: root leading icon + conditional chevron + dim-when-empty, one-step-per-level indent with a per-open-folder vertical guide line, direct-swap workspace button.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, `xcodebuild`.

## Global Constraints

- Scope is the Files tab only. Do NOT touch the Outline tab views (`OutlineSidebarNodeView`, `OutlineSidebarRow`), scanning (`items(in:)`), iCloud entitlement/laziness, security-scoped bookmarks, or file-open behavior.
- `maximumTreeDepth = 4` unchanged.
- Titles are the user-facing copy: iCloud root = `"Lineform"`, workspace unassigned = `"Workspace"`, workspace assigned/disconnected = the folder's `lastPathComponent`. Action button = `"Choose"` (unassigned) / `"Change"` (assigned).
- Follow existing patterns in the file (constants as `static let` on `OutlineSidebarView`, roots rebuilt via `OutlineFileRoot(...)` in the store refresh paths).
- Test gate (quit Xcode first): `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`.

---

### Task 1: Store — "Lineform" title, dynamic workspace title, "Change" constant

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (constants ~79-100; `refreshICloudRoot` ~729-774; `refreshWorkspaceRoot` ~776-831)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Produces: `OutlineFileBrowserStore.workspaceTitle(for url: URL?) -> String` (static, pure) returning `url?.lastPathComponent ?? "Workspace"`.
- Produces: `OutlineSidebarView.changeWorkspaceButtonTitle = "Change"` (replaces `replaceWorkspaceButtonTitle`).
- Produces: `store.iCloudRoot.title == "Lineform"`; `store.workspaceRoot.title` derived from the assigned folder.

- [ ] **Step 1: Write failing tests** in `OutlineSidebarViewTests.swift`.

Add a new test and adjust the constant test. New test:

```swift
@MainActor
func testWorkspaceTitleDerivesFromFolderNameElseWorkspace() {
    XCTAssertEqual(OutlineFileBrowserStore.workspaceTitle(for: nil), "Workspace")
    let url = URL(fileURLWithPath: "/tmp/Raw Files", isDirectory: true)
    XCTAssertEqual(OutlineFileBrowserStore.workspaceTitle(for: url), "Raw Files")
}
```

Update the existing constant test (`testFilesTabUsesICloudAndReplaceableWorkspaceRoots`, ~line 46) to expect the new label, and remove the dead `fileRootTitles` assertion (line 44 — the constant is unused by rendering and is being removed):

```swift
// remove:  XCTAssertEqual(OutlineSidebarView.fileRootTitles, ["Lineform iCloud", "Workspace"])
XCTAssertEqual(OutlineSidebarView.chooseWorkspaceButtonTitle, "Choose")
XCTAssertEqual(OutlineSidebarView.changeWorkspaceButtonTitle, "Change")
```

Update the two iCloud-title assertions (lines ~212, ~242) from `"Lineform iCloud"` to `"Lineform"`.

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: FAIL — `changeWorkspaceButtonTitle`/`workspaceTitle(for:)` undefined; title mismatches.

- [ ] **Step 3: Implement store changes.**

Constants (~79-81): remove the dead `fileRootTitles` line; rename the label constant:

```swift
static let chooseWorkspaceButtonTitle = "Choose"
static let changeWorkspaceButtonTitle = "Change"
```

Add the pure helper to `OutlineFileBrowserStore` (near `refreshWorkspaceRoot`):

```swift
/// The workspace root's display title: the chosen folder's name, or "Workspace" when unassigned.
static func workspaceTitle(for url: URL?) -> String {
    url?.lastPathComponent ?? "Workspace"
}
```

In `refreshICloudRoot`, change all three `title: "Lineform iCloud"` occurrences to `title: "Lineform"`.

In `refreshWorkspaceRoot`, set the title from the resolved URL in every rebuilt `OutlineFileRoot`:
- unassigned branch (no `workspaceURL`): keep `title: "Workspace"` (equivalently `Self.workspaceTitle(for: nil)`).
- disconnected branch: `title: Self.workspaceTitle(for: workspaceURL)`.
- available branch: `title: Self.workspaceTitle(for: workspaceURL)`.

Also update the default `@Published var iCloudRoot` initializer (~line 539) `title: "Lineform iCloud"` → `title: "Lineform"`.

- [ ] **Step 4: Run tests, verify pass**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineSidebarViewTests.swift
git commit -m "Files sidebar: rename iCloud root to Lineform, derive workspace title from folder"
```

---

### Task 2: View — root leading icon, conditional chevron, dim-when-empty, "Change" direct swap

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` — `OutlineFileRootRow` (~1009-1131), `OutlineFileBrowserView.rootView` (~957-994)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Consumes: `changeWorkspaceButtonTitle`, `workspaceTitle(for:)` from Task 1; `store.chooseWorkspaceFolder`.
- Produces: static helpers on `OutlineSidebarView`:
  - `rootShowsDisclosure(state:isEmpty:) -> Bool` = `(state == .available || state == .disconnected) && !isEmpty`
  - `iCloudRootIsDimmed(state:isEmpty:) -> Bool` = `state == .unavailable || (state == .available && isEmpty)`

- [ ] **Step 1: Write failing tests** in `OutlineSidebarViewTests.swift`.

```swift
func testRootDisclosureShownOnlyWhenExpandableChildrenExist() {
    XCTAssertTrue(OutlineSidebarView.rootShowsDisclosure(state: .available, isEmpty: false))
    XCTAssertFalse(OutlineSidebarView.rootShowsDisclosure(state: .available, isEmpty: true))
    XCTAssertFalse(OutlineSidebarView.rootShowsDisclosure(state: .unavailable, isEmpty: false))
    XCTAssertFalse(OutlineSidebarView.rootShowsDisclosure(state: .unassigned, isEmpty: true))
    XCTAssertTrue(OutlineSidebarView.rootShowsDisclosure(state: .disconnected, isEmpty: false))
}

func testICloudRootDimmedWhenUnavailableOrConnectedEmpty() {
    XCTAssertTrue(OutlineSidebarView.iCloudRootIsDimmed(state: .unavailable, isEmpty: true))
    XCTAssertTrue(OutlineSidebarView.iCloudRootIsDimmed(state: .available, isEmpty: true))
    XCTAssertFalse(OutlineSidebarView.iCloudRootIsDimmed(state: .available, isEmpty: false))
}

func testRootRowsShowLeadingIcons() {
    XCTAssertTrue(OutlineSidebarView.filesRootRowsShowLeadingIcons)
}
```

Also flip the existing assertion (line ~58) `XCTAssertFalse(OutlineSidebarView.filesRootRowsShowLeadingIcons)` → `XCTAssertTrue(...)` (or delete it, since the new test covers it — delete to avoid duplication).

- [ ] **Step 2: Run tests, verify fail**

Run: `... -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: FAIL — helpers undefined; `filesRootRowsShowLeadingIcons` still false.

- [ ] **Step 3: Implement.**

Add the helpers next to the other `static let`/`static func` members on `OutlineSidebarView`, and set `filesRootRowsShowLeadingIcons = true`.

```swift
static let filesRootRowsShowLeadingIcons = true

static func rootShowsDisclosure(state: OutlineFileRootState, isEmpty: Bool) -> Bool {
    (state == .available || state == .disconnected) && !isEmpty
}

static func iCloudRootIsDimmed(state: OutlineFileRootState, isEmpty: Bool) -> Bool {
    state == .unavailable || (state == .available && isEmpty)
}
```

In `OutlineFileRootRow.body`, render the chevron only when disclosure applies, and add the leading type-icon after it. Replace the leading chevron block (~1021-1025) so it reserves the chevron slot but only draws the glyph when expandable, then add the icon:

```swift
HStack(spacing: 8) {
    Group {
        if OutlineSidebarView.rootShowsDisclosure(state: root.state, isEmpty: root.items.isEmpty) {
            Image(systemName: chevronSystemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
        } else {
            Color.clear
        }
    }
    .frame(width: 10)
    .accessibilityHidden(true)

    Image(systemName: root.systemImage)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
        .frame(width: 18)
        .accessibilityHidden(true)

    Button(action: toggleCollapsed) {
        Text(root.title)
        // ...unchanged...
```

Gate the `toggleCollapsed` button so tapping a non-expandable header does nothing:
- Wrap the `Button`'s `.accessibilityLabel` and disable the toggle when `!rootShowsDisclosure`. Simplest: keep the Button but make `toggleCollapsed` a no-op when disclosure is hidden — implement by disabling: add `.disabled(!OutlineSidebarView.rootShowsDisclosure(state: root.state, isEmpty: root.items.isEmpty))` to the title Button.

Change the workspace action button (~1052-1082): title from `workspaceActionTitle` and the tap must direct-swap. Replace the tap closure body:

```swift
Button {
    chooseWorkspaceFolder()          // opens picker; assigns or swaps in place; cancel = no change
} label: {
    Text(workspaceActionTitle)
    // ...unchanged pill styling...
}
```

(`chooseWorkspaceFolder` already handles both first-assign and swap; `replaceWorkspaceFolder` is no longer needed by the button.) Update `workspaceActionTitle` (~1102-1106):

```swift
private var workspaceActionTitle: String {
    root.state == .unassigned
        ? OutlineSidebarView.chooseWorkspaceButtonTitle
        : OutlineSidebarView.changeWorkspaceButtonTitle
}
```

In `OutlineFileBrowserView.rootView` (~992), replace the unavailable-only dim with the shared iCloud rule and keep workspace dimming for unavailable only:

```swift
.opacity(rootIsDimmed(root) ? OutlineSidebarView.filesUnavailableRootOpacity : 1)
```

with a local helper in `OutlineFileBrowserView`:

```swift
private func rootIsDimmed(_ root: OutlineFileRoot) -> Bool {
    if root.id == "icloud" {
        return OutlineSidebarView.iCloudRootIsDimmed(state: root.state, isEmpty: root.items.isEmpty)
    }
    return root.state == .unavailable
}
```

Also in `rootView`, the child area must not render an expandable tree/empty-line for a dimmed iCloud root. Change the child gate (~969):

```swift
if root.showsTree, !collapsedIDs.contains(root.id), !rootIsDimmed(root) {
    if root.items.isEmpty {
        Text("No Markdown files")   // only reached for available-empty workspace (iCloud-empty is dimmed out above)
        // ...unchanged...
```

The `replaceWorkspaceFolder:` parameter passed to `OutlineFileRootRow` (~965) is now unused by the row; remove it from the initializer call and from `OutlineFileRootRow`'s stored properties. Leave `store.clearWorkspaceAssignment` in place (it is public API; verify no other caller before any removal — do not remove in this task).

- [ ] **Step 4: Run tests, verify pass**

Run: `... -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineSidebarViewTests.swift
git commit -m "Files sidebar: root type-icons, conditional chevron, dim empty iCloud, Change swaps in place"
```

---

### Task 3: View — one-step indent grid with per-open-folder guide line

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` — `OutlineFileTreeNodeView` (~1133-1253), `OutlineFileBrowserView.rootView` child ForEach (~978-988)
- Test: `LineformTests/OutlineSidebarViewTests.swift`

**Interfaces:**
- Produces: `OutlineSidebarView.filesTreeIndentStep: CGFloat = 12`, `OutlineSidebarView.filesGuideLineDepthZeroInset: CGFloat = 33`, `OutlineSidebarView.filesGuideLineInset(forParentDepth:) -> CGFloat = filesGuideLineDepthZeroInset + CGFloat(depth) * filesTreeIndentStep`.

- [ ] **Step 1: Write failing test.**

```swift
func testGuideLineInsetTracksIndentStep() {
    XCTAssertEqual(OutlineSidebarView.filesTreeIndentStep, 12)
    XCTAssertEqual(OutlineSidebarView.filesGuideLineInset(forParentDepth: 0), 33)
    XCTAssertEqual(OutlineSidebarView.filesGuideLineInset(forParentDepth: 1), 45)
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `... -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Implement.**

Add constants/helper to `OutlineSidebarView`:

```swift
static let filesTreeIndentStep: CGFloat = 12
/// x of the guide line for a depth-0 parent's children: row-content leading (6) + chevron (10)
/// + gap (8) + half icon (9) = the parent icon's horizontal center.
static let filesGuideLineDepthZeroInset: CGFloat = 33
static func filesGuideLineInset(forParentDepth depth: Int) -> CGFloat {
    filesGuideLineDepthZeroInset + CGFloat(depth) * filesTreeIndentStep
}
```

In `OutlineFileTreeNodeView.row`, replace `.padding(.leading, CGFloat(depth) * 14)` with `.padding(.leading, CGFloat(depth) * OutlineSidebarView.filesTreeIndentStep)`.

In `OutlineFileTreeNodeView.body`, wrap the children in a guide-lined container (parent depth = this node's `depth`):

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 1) {
        row
        if item.isDirectory, !isCollapsed {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(item.children) { child in
                    OutlineFileTreeNodeView(
                        item: child,
                        depth: depth + 1,
                        collapsedIDs: $collapsedIDs,
                        openFile: openFile,
                        currentFileURL: currentFileURL
                    )
                }
            }
            .overlay(alignment: .leading) { guideLine(forParentDepth: depth) }
        }
    }
}

@ViewBuilder
private func guideLine(forParentDepth depth: Int) -> some View {
    Rectangle()
        .fill(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.25))
        .frame(width: 1)
        .padding(.leading, OutlineSidebarView.filesGuideLineInset(forParentDepth: depth))
        .allowsHitTesting(false)
}
```

In `OutlineFileBrowserView.rootView`, pass `depth: 1` to direct children (was `0`) and wrap them with the root's guide line (parent depth 0 → inset 33):

```swift
} else {
    VStack(alignment: .leading, spacing: 1) {
        ForEach(root.items) { item in
            OutlineFileTreeNodeView(
                item: item,
                depth: 1,
                collapsedIDs: $collapsedIDs,
                openFile: openFile,
                currentFileURL: currentFileURL
            )
            .opacity(root.state == .disconnected ? 0.48 : 1)
            .allowsHitTesting(root.state != .disconnected)
        }
    }
    .overlay(alignment: .leading) {
        Rectangle()
            .fill(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.25))
            .frame(width: 1)
            .padding(.leading, OutlineSidebarView.filesGuideLineInset(forParentDepth: 0))
            .allowsHitTesting(false)
    }
}
```

(The `.padding(.leading, 28)` on the "No Markdown files" empty-state stays; it only renders for available-empty workspace and its alignment is unaffected.)

- [ ] **Step 4: Run test, verify pass**

Run: `... -only-testing:LineformTests/OutlineSidebarViewTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineSidebarViewTests.swift
git commit -m "Files sidebar: one-step indent grid with a guide line per open folder"
```

---

### Task 4: Full suite + manual QA of the Files tab

**Files:** none (verification only; fix regressions in the file above if any).

- [ ] **Step 1: Quit Xcode** (per AGENTS.md — hosted editor tests are load-sensitive).

- [ ] **Step 2: Run the full deterministic gate.**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -30`
Expected: all tests pass. Report exact pass/fail counts.

- [ ] **Step 3: Build and launch; visually confirm** (release-style not required; Debug run is fine):
  - iCloud root shows cloud icon + "Lineform"; when empty/unavailable it is dimmed with no chevron.
  - Workspace root shows folder icon; label is "Workspace" until a folder is chosen, then the folder name; button reads "Change" and swaps the folder in one step (cancel keeps the current folder).
  - A subfolder's chevron sits clearly to the right of its root; one faint vertical line runs down each open folder's direct children; files inside a subfolder indent one further step; sibling files/folders share a left edge.

- [ ] **Step 4: Commit** any regression fixes discovered in Step 2/3 with a descriptive message.

## Self-Review

- **Spec coverage:** §1 indent+guide line → Task 3. §2 root icons+grid → Task 2 (icons) + Task 3 (grid). §3 dim/no-chevron empty iCloud → Task 2. §4 dynamic workspace title → Task 1. §5 "Change" direct swap → Task 1 (constant) + Task 2 (behavior). Testing/verification → Task 4. All covered.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `changeWorkspaceButtonTitle`, `workspaceTitle(for:)`, `rootShowsDisclosure(state:isEmpty:)`, `iCloudRootIsDimmed(state:isEmpty:)`, `filesTreeIndentStep`, `filesGuideLineInset(forParentDepth:)` used consistently across tasks.
