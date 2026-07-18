# View-mode keyboard shortcut (⌘E toggle Write↔Read)

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** G

## Problem

Lineform has three display modes — Write, Read, Split (`EditorDisplayMode`) — but switching
between them is **mouse-only**: the toolbar segmented control (`EditorModePrincipalControl`)
and a `Picker("Mode")` in the View menu (`AppCommands.swift:402`), which carries **no
`.keyboardShortcut`**. This is a conspicuous gap: every adjacent View-menu item already has a
key (Toggle Outline `⌥⌘0`, Reading Experience `⌥⌘R`). Changing views is a high-frequency
action and today it always requires the mouse.

The pattern that inspired this (a spacebar raw↔rendered flip in read-only viewers like
Markdown Peek / Mud) does **not** transplant to an editor: in Write/Split there is an active
insertion point and spacebar must type a space. So the on-brand solution is an ordinary
modifier shortcut, not a bare key.

## Decision

Add **`⌘E`** as a **toggle between Write and Read**. `⌘E` matches Obsidian's edit↔reading
toggle (a recognized convention), is free in-app, and collides with no editor navigation key.

**Toggle rule (the only genuinely open edge):**

- Write → Read
- Read → Write
- **Split → Write**

i.e. `⌘E` always lands you in Write, *unless* you are already in Write, in which case it goes
to Read. This keeps it a dead-simple two-state flip and makes the rule stateable in one
sentence.

**Split stays reachable only via the toolbar/menu Picker.** It is the rarely-used third state;
folding it into a `⌘E` cycle (Write→Read→Split→…) was considered and rejected — a one-key
3-way cycle is not a common convention and would surprise Obsidian muscle memory (pressing the
"preview" key and landing in a split view).

**Rejected key alternatives (recorded so they are not re-proposed):** `⌃1/2/3` (slow
pinky-stretch; `⌘1`/`⌘2` already taken by Format Title/Section), `fn`+arrows (= Home/End on
macOS), `⌃`+arrows (= Mission Control Spaces gesture). `⌘R` / `⌘/` are equally valid keys but
`⌘E` was chosen for the Obsidian-convention match.

## Design

The whole feature drives the **existing** mode-switch seam — no new machinery.

Today the Mode picker sets a mode via (`AppCommands.swift:489-499`):

```swift
displayModeMenuState.setDisplayMode(mode)
LineformAppNotification.setDisplayMode.post(
    object: LineformAppNotification.activeWindowPayload(value: mode.rawValue)
)
```

`LineformDisplayModeMenuState.shared` (`AppCommands.swift:135`) tracks the active window's
current mode; `EditorContainerView` receives `setDisplayMode` (`EditorContainerView.swift:270`)
and applies it to the active tab, and syncs the menu state back on tab/mode changes
(`EditorContainerView.swift:291,438,1050,1096`). So the menu state is an accurate mirror of the
active window's active-tab mode.

### New pure helper (unit-tested)

In `Lineform/Editor/EditorDisplayMode.swift`:

```swift
extension EditorDisplayMode {
    /// ⌘E toggle target: `.write` flips to `.read`; every other mode (`.read`, `.split`)
    /// flips to `.write`. So ⌘E always lands in Write unless already in Write.
    var toggledWriteRead: EditorDisplayMode {
        self == .write ? .read : .write
    }
}
```

### New command

In `AppCommands.swift`, inside the existing `CommandGroup(after: .toolbar)` (next to the Mode
picker), add:

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

This reuses the picker's exact set-path, so the toolbar control, the menu picker, and `⌘E`
all stay in sync automatically (they all read/write the same `LineformDisplayModeMenuState` and
post the same notification).

### Edge cases

- **No document / no active window:** the command posts to the active window; with none, the
  notification is a harmless no-op (same as the other active-window-scoped menu commands). No
  explicit disable needed, matching existing menu behavior.
- **Split active:** resolves to `.write` per the rule above.

## Testing

- **Unit:** `EditorDisplayMode.toggledWriteRead` — `.write→.read`, `.read→.write`,
  `.split→.write`. Pure, deterministic, default plan.
- SwiftUI command wiring is not unit-tested (consistent with every other menu command in the
  app); verified manually.

## Out of scope

- A keyboard path to Split (stays toolbar/menu-only).
- Any change to the toolbar segmented control or the Mode picker UI.
- Per-mode direct-jump shortcuts (rejected in favor of the single toggle).

## Risk

Low. One pure helper + one menu button on an existing seam; no caret/typing collision (`⌘E`
is not a text-navigation key).
