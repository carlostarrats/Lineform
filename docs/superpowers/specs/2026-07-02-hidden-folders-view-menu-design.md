# Move "Show Hidden Folders" from the sidebar eyeball to the View menu

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

Date: 2026-07-02
Status: Approved, ready for implementation

## Problem

The "Show hidden folders" control is an eyeball button (`eye` / `eye.slash`) pinned
to the top-right of the Files sidebar (`OutlineHiddenFoldersToggle` in
`Lineform/Outline/OutlineSidebarView.swift`). It reads as visual noise in an app
whose whole posture is a calm, quiet sidebar. A discoverable, conventional home
for an app-wide view preference is the menu bar's **View** menu, with a keyboard
shortcut and native accessibility.

## Goal

Replace the sidebar eyeball with a checkmarked **View ▸ Show Hidden Folders**
menu item, toggled with **⌘⇧.** (period — matching Finder's own show-hidden-files
gesture), fully accessible via VoiceOver, preserving the current behavior in every
other respect.

## Behavior (unchanged except for the control's location)

- Default **off**, persisted per app in the existing UserDefaults key
  `Lineform.outline.showsHiddenFolders`.
- When on: dot-directories (`.claude/`, `.agents/`, `.github/`, …) and their
  Markdown/text files appear in the tree, de-emphasized. `node_modules` and `.git`
  stay excluded regardless.
- The preference is **app-wide**: toggling it updates every open window at once, and
  a newly opened window starts in the current state.
- The menu item shows a **checkmark** reflecting the current state.
- VoiceOver announces the item and its checked/unchecked state automatically (native
  SwiftUI menu `Toggle`); no custom accessibility label is required.

## Why this shape

`OutlineFileBrowserStore` is a **per-window** `@StateObject`, not a singleton, so a
menu command cannot mutate "the one store" directly — there is one per document
window. The app already solves exactly this with two established patterns:

- **Shared observable menu-state** (`LineformDisplayModeMenuState`,
  `LineformTextFormatMenuState`): a `@MainActor final class … : ObservableObject`
  with `static let shared`, a `@Published` value, and a setter that calls
  `NSApp.mainMenu?.update()`. `AppCommands` observes it, so menu state (checkmark)
  stays live.
- **Window-scoped `NotificationCenter` broadcast** (`toggleOutline`, reading, find):
  a menu button posts a notification each open window observes.

We combine them: a shared observable owns the checkmark state and the single source
of truth; a broadcast tells every live store to re-scan. The broadcast is
**not** window-scoped (unlike `toggleOutline`) because this is a global preference
that must reach all windows, not just the active one.

## Components

### 1. `HiddenFoldersMenuState` (new) — `Lineform/App/`

Modeled on `LineformDisplayModeMenuState`.

```
@MainActor final class HiddenFoldersMenuState: ObservableObject {
    static let shared = HiddenFoldersMenuState()
    @Published private(set) var isOn: Bool

    // Reads initial value from UserDefaults key
    // "Lineform.outline.showsHiddenFolders".
    // Testable init takes an injected UserDefaults + defaults key.

    func setShowsHiddenFolders(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: key)          // persist (same key as the store)
        NSApp.mainMenu?.update()                // refresh the checkmark
        LineformAppNotification.toggleHiddenFolders.post()  // broadcast to all windows
    }
}
```

Single source of truth: the menu-state and the store share the UserDefaults key.
The menu is now the only user-facing writer; the store sets its property only
programmatically (from its own `init` reading the key, and from the broadcast).

### 2. `LineformAppNotification.toggleHiddenFolders` (new) — `Lineform/App/LineformAppNotification.swift`

A new case with a stable `rawValue` (e.g. `"Lineform.toggleHiddenFolders"`).
Posted **without** a window payload (app-wide). Add a no-argument `post()` path or
post with `object: nil`.

### 3. View menu item — `Lineform/App/AppCommands.swift`

Inside the existing `CommandGroup(after: .toolbar)` View group, next to
"Toggle Outline":

```
Toggle(Self.showHiddenFoldersTitle, isOn: hiddenFoldersBinding)
    .keyboardShortcut(".", modifiers: [.command, .shift])
```

- `AppCommands` observes `@ObservedObject … HiddenFoldersMenuState.shared` so the
  checkmark updates live.
- `hiddenFoldersBinding` reads `HiddenFoldersMenuState.shared.isOn` and on set calls
  `setShowsHiddenFolders(_:)`.
- Title constant `showHiddenFoldersTitle = "Show Hidden Folders"` (Title Case for a
  menu item; the old sidebar constant used sentence case).

### 4. Window observer — `Lineform/Outline/OutlineSidebarView.swift`

`OutlineSidebarView` (alive for the whole window, unlike the Files-tab-only subview)
observes the broadcast and applies it to its store, triggering the store's existing
re-scan `didSet`:

```
.onReceive(NotificationCenter.default.publisher(for:
        LineformAppNotification.toggleHiddenFolders.name)) { _ in
    fileBrowserStore.showsHiddenFolders = HiddenFoldersMenuState.shared.isOn
}
```

No loop: the store does not post back to the menu-state.

### 5. Removals

- Delete the `OutlineHiddenFoldersToggle` view and the `HStack` that places it in
  `OutlineFileBrowserView`.
- The store's `showsHiddenFolders` property, its `didSet` re-scan logic, the
  UserDefaults key, and `showsHiddenFoldersDefaultsKey` are **unchanged**.
- Retire/rename the old `showHiddenFoldersToggleTitle` constant (moved to the menu).

## Testing

- **Unchanged & must stay green:** `OutlineSidebarViewTests`
  (`testShowHiddenFoldersRevealsDotFoldersButNotBlocklist`,
  `testTogglingHiddenFoldersOffFiltersInMemory`,
  `testShowHiddenFoldersPreferencePersists`). The store's behavior is untouched.
- **New:** `HiddenFoldersMenuState` round-trip on an isolated `UserDefaults` suite —
  `setShowsHiddenFolders(true)` sets `isOn` and persists to the key; a fresh state
  reading the same suite reports `isOn == true`.
- **New:** menu assertion in `AppCommandNotificationTests` following the existing
  precedent (`testReadingCommandsLiveInViewMenu`): assert the title constant and the
  new notification `rawValue`.

## Non-goals

- No change to what "hidden" means or to the exclusion blocklist.
- No per-window hidden-folder state (it stays global).
- No new About/Help surfaces; no doc-facing behavior changes beyond the control moving.

## Docs

- `CLAUDE.md` "Show hidden folders" feature bullet mentions it as a
  "Files-sidebar toggle"; update that phrasing to "a **View menu** item (⌘⇧.)"
  after implementation.
