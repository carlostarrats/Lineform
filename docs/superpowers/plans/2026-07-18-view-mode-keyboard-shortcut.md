# View-Mode Keyboard Shortcut (⌘E) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `⌘E` menu command that toggles the active window between Write and Read (Split → Write), driving the existing mode-switch seam.

**Architecture:** A new pure, unit-tested helper `EditorDisplayMode.toggledWriteRead` computes the target mode; a new `Button` inside the existing `CommandGroup(after: .toolbar)` in `AppCommands.swift` reads `LineformDisplayModeMenuState.displayMode`, applies the toggle via the same `setDisplayMode` + `LineformAppNotification.setDisplayMode.post(...)` path the Mode picker already uses, and binds `⌘E`. No new notification, no new receiver — the toolbar segmented control, the View-menu Picker, and `⌘E` all stay in sync because they share `LineformDisplayModeMenuState` and post the same notification.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest

## Global Constraints

- Do not write any product behavior that uploads document contents, requires an account, collects analytics, or converts documents into an app-owned database (local-first privacy).
- Reuse the existing mode-switch seam — no new machinery, no new `LineformAppNotification` case, no change to `EditorContainerView`'s `setDisplayMode` receiver.
- The toggle rule is exactly: `.write → .read`; `.read → .write`; `.split → .write`. `⌘E` always lands in Write unless already in Write.
- Split stays reachable only via the toolbar/menu Picker — no keyboard path to Split.
- SwiftUI command wiring is NOT unit-testable; it is verified manually, consistent with every other menu command in the app.
- Follow existing patterns before introducing new abstractions; keep edits scoped to this feature; avoid unrelated refactors and metadata churn.
- Default test gate: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO` (pure default plan). Warn the user before any CLI test run (ad-hoc re-sign can trigger a TCC Documents prompt that blocks the run until answered).

---

## Task 1 — Pure helper `EditorDisplayMode.toggledWriteRead` (TDD)

**Files:**
- Modify: `Lineform/Editor/EditorDisplayMode.swift` (append an extension after the enum, currently ends at line 18)
- Test: `LineformTests/EditorDisplayModeTests.swift` (add one test method; the class already exists, ends ~line 790)

**Interfaces:**
- Produces: `extension EditorDisplayMode { var toggledWriteRead: EditorDisplayMode { get } }`
- Consumes: `EditorDisplayMode` cases `.write`, `.read`, `.split`

### Steps

- [ ] Add the failing test. In `LineformTests/EditorDisplayModeTests.swift`, insert this method immediately after `testDisplayModesStaySmallAndOrdered()` (the existing method at line 268):

```swift
    func testToggledWriteReadFlipsWriteToReadAndEverythingElseToWrite() {
        XCTAssertEqual(EditorDisplayMode.write.toggledWriteRead, .read)
        XCTAssertEqual(EditorDisplayMode.read.toggledWriteRead, .write)
        XCTAssertEqual(EditorDisplayMode.split.toggledWriteRead, .write)
    }
```

- [ ] Run the test and verify it FAILS to compile (the `toggledWriteRead` property does not exist yet — expect a build error like `value of type 'EditorDisplayMode' has no member 'toggledWriteRead'`):

```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/EditorDisplayModeTests/testToggledWriteReadFlipsWriteToReadAndEverythingElseToWrite
```

Expected: build failure / test does not pass (unresolved member `toggledWriteRead`).

- [ ] Add the minimal implementation. Append this extension to `Lineform/Editor/EditorDisplayMode.swift` after the closing brace of the enum (line 18):

```swift

extension EditorDisplayMode {
    /// ⌘E toggle target: `.write` flips to `.read`; every other mode (`.read`, `.split`)
    /// flips to `.write`. So ⌘E always lands in Write unless already in Write.
    var toggledWriteRead: EditorDisplayMode {
        self == .write ? .read : .write
    }
}
```

- [ ] Run the test again and verify it PASSES:

```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/EditorDisplayModeTests/testToggledWriteReadFlipsWriteToReadAndEverythingElseToWrite
```

Expected: `Test Suite 'EditorDisplayModeTests' passed` with `Executed 1 test, with 0 failures` for the selected test.

- [ ] Commit:

```
git add Lineform/Editor/EditorDisplayMode.swift LineformTests/EditorDisplayModeTests.swift
git commit -m "Add EditorDisplayMode.toggledWriteRead pure helper for ⌘E toggle"
```

---

## Task 2 — Wire the `⌘E` menu command (not unit-testable; manual verification)

**Files:**
- Modify: `Lineform/App/AppCommands.swift` (inside `CommandGroup(after: .toolbar)`, lines 401–425 — specifically after the `Picker("Mode", …)` block that ends at line 406)

**Interfaces:**
- Consumes: `displayModeMenuState: LineformDisplayModeMenuState` (already an `@ObservedObject` on the commands type, declared at line 215), `EditorDisplayMode.toggledWriteRead` (Task 1), `LineformAppNotification.setDisplayMode`, `LineformAppNotification.activeWindowPayload(value:)`
- Produces: a `Button("Toggle Write / Read")` with `.keyboardShortcut("e", modifiers: .command)` that posts the same notification the Mode `Picker` posts

> **Why no unit test:** SwiftUI `Commands`/`CommandGroup` wiring cannot be exercised in XCTest — there is no way to synthesize the menu button tap or the `⌘E` key event against a `@main` `App`'s command tree in the unit-test process. This matches how every other menu command in the app (Toggle Outline, Reading Experience, Find, tab commands) is treated: the pure logic is tested (Task 1) and the command binding is verified manually. Do NOT invent a hosted/AppKit test for this — it would be brittle and is explicitly out of the app's testing model.

### Steps

- [ ] Add the command. In `Lineform/App/AppCommands.swift`, inside `CommandGroup(after: .toolbar)`, insert this `Button` immediately after the closing brace of the `Picker("Mode", selection: displayModeSelection) { … }` block (after line 406) and before the `Button("Toggle Outline")` at line 408:

```swift
            Button("Toggle Write / Read") {
                let target = displayModeMenuState.displayMode.toggledWriteRead
                displayModeMenuState.setDisplayMode(target)
                LineformAppNotification.setDisplayMode.post(
                    object: LineformAppNotification.activeWindowPayload(value: target.rawValue)
                )
            }
            .keyboardShortcut("e", modifiers: .command)
```

- [ ] Verify the whole default suite still builds and passes (the new command must not break compilation or any existing test):

```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
```

Expected: build succeeds; `Test Suite 'All tests' passed`, roughly ~370 tests, `0 failures`. (Warn the user first: the ad-hoc-resigned test host may trigger a one-time "Lineform would like to access files in your Documents folder" TCC prompt that blocks the run until they click Allow.)

- [ ] Manual verification (run the app — the wiring cannot be unit-tested). Confirm ALL of the following in a running Debug build:
  - The **View** menu shows **Toggle Write / Read** with the **⌘E** shortcut displayed next to it, positioned directly under the **Mode** submenu/picker.
  - With a document open in **Write** mode, press **⌘E** → editor switches to **Read**; the toolbar segmented control and the Mode picker checkmark both move to Read.
  - Press **⌘E** again from **Read** → switches back to **Write**; toolbar + picker stay in sync.
  - Select **Split (Preview)** via the toolbar/Mode picker, then press **⌘E** → lands in **Write** (not Read).
  - In **Write** or **Split** mode with the caret in the text, confirm **⌘E** switches mode and does NOT type a character or move the caret unexpectedly (⌘E is not a text key; the menu command intercepts it).
  - With **no document / no window open**, pressing ⌘E (if the menu item is enabled) is a harmless no-op — no crash, no spurious window.

- [ ] Commit:

```
git add Lineform/App/AppCommands.swift
git commit -m "Add ⌘E menu command to toggle Write/Read display mode"
```

---

## Notes for the executor

- Do NOT add a new `LineformAppNotification` case — the command reuses `setDisplayMode`, exactly like the Mode `Picker`'s `displayModeSelection` setter (`AppCommands.swift:489–499`).
- Do NOT touch `EditorContainerView`'s `setDisplayMode` receiver (~line 270) — it already handles this notification for the toolbar/menu path; the new command produces an identical notification.
- Keep the button label and shortcut exactly as written; the spec fixes `⌘E` (Obsidian edit↔reading convention) and the "Split → Write" rule.
- The plan file itself is not committed as part of these tasks.
