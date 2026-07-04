# Settings Window — Sidebar & iCloud Preferences

Date: 2026-07-03

> **SUPERSEDED (same day, after user QA).** The shipped implementation deliberately
> differs from this spec on four points — do not "restore" the spec'd design:
> Settings presents as a Muse-style **in-window modal** (`SettingsModal`), not a
> native `Settings { }` scene; the iCloud row is **always visible** (disabled with
> "iCloud is not available on this Mac." when unavailable), not hidden; the collapse
> pref is **"Allow root folders to expand and collapse"** — tri-state with an
> adaptive default that auto-locks a lone Workspace root — not the default-off
> "Keep root folders expanded"; and locked mode reclaims the chevron column with
> QA-dialed geometry. The current truth lives in `Claude.md` (Main Features →
> Settings) and the code.

## Summary

Add a native macOS **Settings…** window (⌘,) to Lineform, reachable from the
Lineform (app) menu, holding a small **General** pane with three user
preferences:

1. **Show sidebar on launch** — whether new windows open with the Files/Outline
   sidebar showing.
2. **Keep root folders expanded** — locks the sidebar root sections open (hides
   their collapse chevron).
3. **Show iCloud in sidebar** — hides/shows the iCloud root in the sidebar.
   Turning it off is only allowed when the iCloud folder is empty, and it never
   modifies iCloud Drive.

There is no Settings/Preferences scene in the app today (confirmed: zero
`Settings`/`@AppStorage` usage). This is the first one.

## Goals

- Give users control over three existing behaviors that are currently fixed.
- Follow existing app conventions (native scene, `UserDefaults` + `@Published`
  `didSet`, shared `ObservableObject` state — **not** `@AppStorage`).
- Preserve the hard iCloud-safety and iCloud-laziness invariants documented in
  `CLAUDE.md`. In particular: **never delete or modify anything in the user's
  iCloud Drive**, and never run the expensive iCloud container scan on the main
  thread at view construction.

## Non-Goals

- No deletion of, or writes to, the iCloud container or its contents. "Turn off
  iCloud" is a sidebar-visibility preference only.
- No persistence of per-folder (non-root) collapse state.
- No new panes beyond **General**. YAGNI — three toggles in one pane.
- No change to the Outline-vs-Files tab behavior inside the sidebar.

## Where Settings Lives

Add a `Settings { SettingsView() }` scene to `Lineform/App/LineformApp.swift`,
alongside the existing `DocumentGroup`. SwiftUI's `Settings` scene automatically
installs the standard **Settings… (⌘,)** item in the app menu — no custom
`CommandGroup` plumbing in `AppCommands.swift` is required, and it opens a normal
macOS preferences window.

```swift
var body: some Scene {
    DocumentGroup(...) { ... }
        .defaultSize(...)
        .commands { AppCommands(...) }

    Settings {
        SettingsView(settings: LineformSettingsStore.shared)
    }
}
```

`SettingsView` is a new SwiftUI view under a new `Lineform/App/Settings/`
directory (or `Lineform/App/` if we prefer flat) rendering a single Form/`TabView`
"General" pane. Keep it restrained and native — a `Form` with three toggles and
their explanatory subtext.

## State: `LineformSettingsStore`

A new shared `ObservableObject` singleton, modeled on the existing
`HiddenFoldersMenuState` (`AppCommands.swift`) and `OutlineFileBrowserStore`
preference pattern: `static let ...DefaultsKey` constants, `@Published`
properties whose `didSet` writes through to `UserDefaults`, and initial values
read directly into backing storage in `init` (to avoid firing `didSet`
side-effects at construction, matching `OutlineFileBrowserStore.init`).

New `UserDefaults` keys (namespaced to match existing `Lineform.*` keys):

- `Lineform.settings.showSidebarOnLaunch` — Bool, **default `true`**
- `Lineform.settings.keepRootFoldersExpanded` — Bool, **default `false`**
- `Lineform.settings.showICloudInSidebar` — Bool, **default `true`**

```swift
final class LineformSettingsStore: ObservableObject {
    static let shared = LineformSettingsStore()

    static let showSidebarOnLaunchKey = "Lineform.settings.showSidebarOnLaunch"
    static let keepRootFoldersExpandedKey = "Lineform.settings.keepRootFoldersExpanded"
    static let showICloudInSidebarKey = "Lineform.settings.showICloudInSidebar"

    @Published var showSidebarOnLaunch: Bool { didSet { defaults.set(...) } }
    @Published var keepRootFoldersExpanded: Bool { didSet { defaults.set(...) } }
    @Published var showICloudInSidebar: Bool { didSet { defaults.set(...) } }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        // read backing storage directly; register defaults so first-launch
        // reads yield the intended defaults (true/false/true).
    }
}
```

`UserDefaults` is injectable so the store is unit-testable with an isolated
suite.

## The Three Controls

### 1. Show sidebar on launch (default ON)

- Toggle. Default **on** — this is a deliberate change from today's behavior,
  where `EditorContainerView.isShowingOutline` is hardcoded `false` (windows open
  with the sidebar closed). After this change, new windows open with the sidebar
  **showing** unless the user turns the toggle off.
- Applied by seeding `EditorContainerView.isShowingOutline`'s initial value from
  `LineformSettingsStore.shared.showSidebarOnLaunch` at window construction
  (in `EditorContainerView.init`, converting the `@State` initial value from a
  hardcoded `false` to `State(initialValue: settings.showSidebarOnLaunch)`).
- Semantics: this is a **launch/new-window** preference ("on load"), so changing
  it does not retroactively open/close already-open windows. It takes effect for
  the next new window. Once a window is open, the user's manual toggle (⌥⌘0 /
  drag) governs, exactly as today.

### 2. Keep root folders expanded (default OFF)

- Toggle. Default **off** — current behavior (roots are collapsible) is
  preserved for anyone who never opens Settings.
- When **on**: the sidebar root sections (iCloud "Lineform", Workspace) cannot be
  collapsed. Their disclosure chevron is hidden and roots render always-expanded.
- Applied in `OutlineSidebarView`:
  - `OutlineSidebarView` observes `LineformSettingsStore.shared`.
  - The root disclosure gate (`rootShowsDisclosure`) is combined with the
    setting at the call site: a root shows its chevron only when
    `rootShowsDisclosure(...) && !keepRootFoldersExpanded`. The pure static
    helper stays pure/testable; the setting is applied where it's read.
  - When the setting is on, root ids are treated as never-collapsed regardless
    of the in-memory `collapsedIDs` set (root children always render). We do not
    mutate `collapsedIDs`; we ignore it for roots while the setting is on, so
    turning the setting back off restores whatever prior in-session state existed.
- This applies live to open windows via SwiftUI observation of the shared store.

### 3. Show iCloud in sidebar (default ON)

- Toggle. Default **on**.
- When **off**: the iCloud root is hidden from the sidebar (persisted,
  reversible). **Nothing in iCloud Drive is deleted or modified** — the empty
  folder remains in iCloud; the user can remove it in Finder if they wish.
- Applied in `OutlineSidebarView`: the iCloud root render gate combines the
  existing visibility rule with the setting at the call site —
  `rootIsVisible(id:state:) && showICloudInSidebar` (for the iCloud root).
  `rootIsVisible` stays pure; the setting is applied where it's read. Applies
  live to open windows.
- **Guard — only turn OFF when the folder is empty.** The toggle is disabled
  (greyed) whenever the iCloud folder is not empty, with subtext:
  *"Only available when your Lineform iCloud folder is empty. This hides iCloud
  in Lineform's sidebar; it does not delete anything from iCloud Drive."*
  (Turning it back **on** is always allowed and needs no check.)
- **Availability.** When iCloud is unavailable (Debug builds have no iCloud
  entitlement; a Release user may not be signed into iCloud), the iCloud root is
  already hidden by `rootIsVisible`, so this whole control is **hidden entirely**
  in Settings — there is no root to govern. Detected via the same
  container-resolution check the store uses (see probe below).

## The iCloud Emptiness Probe

To enable/disable the "Show iCloud in sidebar" toggle, Settings must know whether
the iCloud folder is empty and whether iCloud is even available. Resolving the
ubiquity container and enumerating its Documents directory is the **expensive
scan** `CLAUDE.md` forbids on the main thread at view construction.

Design:

- The Settings window **opens immediately**. There is no pre-modal blocking
  check.
- The iCloud toggle renders an **inline "Checking…" state** inside the window
  while an async probe runs off the main thread (triggered from the pane's
  `.task`/`.onAppear`), then settles into: hidden (unavailable), enabled+empty,
  or disabled+not-empty.
- The probe is isolated behind a small protocol so it is unit-testable without
  real iCloud, mirroring the existing `UbiquitousItemDownloader` protocol:

  ```swift
  enum ICloudFolderStatus { case unavailable, empty, notEmpty }

  protocol ICloudFolderProbing {
      func status() async -> ICloudFolderStatus
  }
  ```

- The production implementation resolves
  `iCloud.com.lineform.app` via
  `FileManager.url(forUbiquityContainerIdentifier:)` (→ `.unavailable` if nil),
  then enumerates the container's `Documents` directory for any relevant items
  (using the same relevance rules the store uses for what counts as content),
  returning `.empty` / `.notEmpty`. Runs off the main thread.
- "Empty" here means "no user-visible content items," consistent with how the
  store already computes `isEmpty` for the iCloud root. Reuse the store's
  notion of emptiness/relevance rather than inventing a second rule, to avoid
  drift. (Implementation detail: factor the relevance predicate so both the
  store and the probe share it, or have the probe defer to store logic.)

## How Settings Reach Windows

- **Show iCloud in sidebar** and **Keep root folders expanded**: `OutlineSidebarView`
  holds a reference to `LineformSettingsStore.shared` (as `@ObservedObject`), so
  both apply **live** to every open window via normal SwiftUI observation. No
  notification plumbing is required for these.
- **Show sidebar on launch**: read once at `EditorContainerView.init`. No live
  broadcast — it governs the next new window, which is the intended "on load"
  semantics.

This keeps the design free of the `LineformAppNotification` broadcast machinery
except where genuinely needed (here, nowhere).

## iCloud-Laziness Invariant

The Settings probe must not perturb the existing laziness guarantee: the store's
expensive iCloud scan still only runs when the Files tab is shown. The Settings
probe is a **separate, self-contained** off-main-thread read that happens only
when the Settings window is open. It does not touch any window's
`OutlineFileBrowserStore` and does not start any FSEvents/monitor. This preserves
the invariant that no iCloud scan runs for windows on the Outline tab or with the
sidebar collapsed.

## Testing

Pure-logic / injectable unit tests (XCTest, in `LineformTests`):

1. **`LineformSettingsStore`** — with an isolated `UserDefaults` suite: default
   values are `true / false / true`; each setter writes through and round-trips;
   re-reading a fresh store from the same suite restores persisted values.
2. **Root-visibility composition** — `rootIsVisible(...) && showICloudInSidebar`:
   iCloud root shows only when available AND setting on; workspace root
   unaffected by the iCloud setting.
3. **Root-disclosure composition** — `rootShowsDisclosure(...) && !keepRootFoldersExpanded`:
   chevron suppressed when the lock setting is on, even for a non-empty available
   root; restored when off.
4. **iCloud emptiness probe** — behind `ICloudFolderProbing` with a fake:
   `.unavailable` → control hidden; `.empty` → toggle enabled; `.notEmpty` →
   toggle disabled. Verify the async state transitions from "checking" to the
   resolved state.

No hosted-view/animation tests are needed for this feature.

## Files Touched (anticipated)

- `Lineform/App/LineformApp.swift` — add `Settings` scene.
- `Lineform/App/Settings/LineformSettingsStore.swift` — new store (or flat in
  `Lineform/App/`).
- `Lineform/App/Settings/SettingsView.swift` — new General pane.
- `Lineform/App/Settings/ICloudFolderProbing.swift` — new probe protocol + impl
  (or colocated).
- `Lineform/Editor/EditorContainerView.swift` — seed `isShowingOutline` from the
  setting.
- `Lineform/Outline/OutlineSidebarView.swift` — observe the store; apply the two
  live settings at the root render/disclosure call sites; expose/share the
  emptiness-relevance predicate for the probe.
- `LineformTests/…` — new test file(s) for the four test areas above.
- `Lineform.xcodeproj/project.pbxproj` — register new source + test files
  (hand-rolled 1F0000xx IDs, per repo convention).
- `CLAUDE.md` — document the new Settings surface and the three preferences.

## Open Risks / Notes

- **Default sidebar change is user-visible.** Windows now open with the sidebar
  showing by default. Intended and confirmed. Existing users who had grown used
  to the closed-on-launch behavior can turn it off in Settings.
- **`Settings` scene + `NSApplicationDelegateAdaptor`.** The app uses an
  app-delegate adaptor; a `Settings` scene coexists fine with it. Verify the
  ⌘, item appears and the window opens (manual check during implementation).
- **Emptiness definition drift.** The probe and the store must agree on what
  "empty" means; share the predicate to prevent the toggle from disagreeing with
  what the sidebar shows.
