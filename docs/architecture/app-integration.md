# App shell & OS integration

Settings, updates, the CLI helper, App Intents, Quick Look, diagram reporting, and app identity.

Extracted from `CLAUDE.md` so the always-loaded file stays scannable. Content is verbatim —
these are the same load-bearing notes, not a summary. Read this file before changing anything
in this area.

- Settings: **Lineform › Settings… (⌘,)** presents `SettingsModal` (`Lineform/App/SettingsView.swift`) as a **Muse-style in-window modal** (a `MuseModalChrome` light card over a `MuseModalScrim`, close button, Esc/outside-click dismissal), deliberately **not** a native `Settings { }` scene or window, so every modal in the app matches. `MuseModalScrim` (and the presented card, via `View.modalArrowCursor()` / `onContinuousHover`) actively reasserts the **arrow cursor** while a modal is up, so the editor `NSTextView`'s I-beam doesn't linger over the scrim or buttons (suppressing it at the text view was tried and didn't work — the text view's `cursorUpdate` doesn't fire over the on-top modal; the cursor was simply stuck, so it must be re-set over the modal surfaces). `onContinuousHover` alone is **not enough over AppKit-backed controls**: the settings switches and the header's close button swallow the mouse-moved stream, so the stuck I-beam survived on exactly the things you click. Those two surfaces additionally carry `CursorRectView(cursor: .arrow)` (`Lineform/Editor/EditorFloatingControlSupport.swift`) — a zero-hit-test layer whose tracking area is **geometric**, so it keeps reporting under controls layered above it, and which seeds its hover state from the pointer's current position in `updateTrackingAreas` (a tracking area installed while the pointer is already inside sends no `mouseEntered`, so ⌘, under a resting pointer would otherwise keep the I-beam until the user moved). It is deliberately attached to `MuseModalHeader` and the settings rows, **never** to `MuseModalCard` itself: ⌘K's search field shares that card and must keep its I-beam. The menu item lives in `AppCommands` (`CommandGroup(replacing: .appInfo)`) and posts `LineformAppNotification.showSettings` (no payload); the **main** window's `EditorContainerView` presents the modal (main-window matching, not key-window payloads — it still works when a panel like About is key and can't match several windows at once). With zero documents open, the menu item creates a new document first (what ⌘N would do) so ⌘, always works. The card width clamps to the window (`SettingsModal.cardWidth(availableWidth:)`) so narrow windows don't clip it. State lives in `LineformSettingsStore` (`Lineform/App/LineformSettings.swift`) — a shared `ObservableObject` backed by `UserDefaults` (`Lineform.settings.*` keys) via `@Published didSet`, **not** `@AppStorage`, mirroring `HiddenFoldersMenuState`; init reads backing storage directly (didSet fires on init assignments) with explicit fallbacks so absent keys yield the intended defaults. Three prefs: **Show sidebar on launch** (default on — a deliberate change from the old always-closed-on-launch behavior; seeds `EditorContainerView.isShowingOutline` at window construction, governing new windows only); **Allow root folders to expand and collapse** (tri-state, default nil/adaptive: `allowRootFolderCollapseChoice` is nil until the user touches the toggle, and the effective behavior — `LineformSettingsStore.effectiveAllowRootFolderCollapse(choice:iCloudRootVisible:)` — adapts: with no explicit choice, a lone Workspace root (iCloud unavailable or hidden) auto-locks open since one section has nothing to collapse against, so the EFFECTIVE default is off on Debug/signed-out Macs and on when iCloud shows; an explicit choice is persisted and always wins, and clearing it to nil `removeObject`s the key so a reset actually sticks. The "iCloud root visible" input is `OutlineFileBrowserStore.lastKnownICloudAvailable` — a **persisted** last-known fact every iCloud scan records (`Lineform.outline.lastKnownICloudAvailable`, optimistic true when never recorded) — NOT live root state, which is `.unavailable` until the deferred Files-tab scan and would flash locked geometry on first tab reveals; `ICloudSettingViewModel` seeds from the same persisted fact so the Settings toggle and sidebar agree from frame one. Locked geometry: locking only hides the root's disclosure chevron — the chevron slot is **always reserved** so root/file/folder icons stay pinned to the shared sidebar icon column (`OutlineSidebarView.sidebarIconColumnLeading`, 24pt) whether or not a chevron is drawn (no section left-shift on lock; the older `filesLockedDescendantShift` reclaim was removed when the sidebar adopted the unified icon column in the 2026-07-17 nav cleanup). The whole root header — chevron, icon, title — is the collapse click target, not just the title); and **Show iCloud in sidebar** (a **hide-only** persisted toggle that never writes to or deletes anything in iCloud Drive; hiding is render-only, so a live Files tab still scans/watches the container as usual — trivial cost since the folder must be empty to hide, and deliberately simpler than gating the store on the setting). The settings store is **injected down the view tree** (`EditorContainerView` → `OutlineSidebarView` → `OutlineFileBrowserView`, defaulting to `.shared` in production) so tests isolate it on their own defaults suite; the two sidebar prefs apply **live** via observation (no notification plumbing), composed through pure, tested helpers `OutlineSidebarView.iCloudRootVisible` / `rootDisclosureVisible` / `rootIsCollapsed`. The iCloud toggle is gated by `ICloudFolderProbe` (behind the `ICloudFolderProbing` protocol, read-only, resolves the container via the same `lineformICloudDocumentsURL` helper the sidebar uses, and checks emptiness with `OutlineFileBrowserStore.documentsFolderIsEmpty` — **conservative**: hidden/dot-folder content counts as non-empty regardless of the Show Hidden Folders setting; top-level-only scan since directories count regardless of contents; run **off-main** in a `Task.detached` fired only from the modal's `.task`) surfaced as an inline **"Checking…"** note through `ICloudSettingViewModel` (caches the last-known status across opens; latest-wins generation guard on refresh): the row is **always visible** — when iCloud is unavailable (Debug / not signed in) it renders disabled with "iCloud is not available on this Mac." (hiding it entirely read as a missing feature) — and the toggle is otherwise disabled only to block turning **off** a non-empty folder; re-showing a hidden root is always allowed (`ICloudSettingViewModel.isToggleDisabled(currentlyShown:)`), so a user can never get stuck unable to bring iCloud back. This preserves the iCloud-laziness invariant: the probe is self-contained, touches no window's `OutlineFileBrowserStore`, and never runs at launch/construction. Hosted editor motion tests inject an isolated store with `showSidebarOnLaunch=false` so the default-open sidebar doesn't perturb their geometry.

- Modal visual language (`MuseModalChrome` / `MuseModalCard` / `MuseModalScrim` in `Lineform/Editor/EditorChromeAndControls.swift`): both in-window modals — Settings and ⌘K Jump to File — render a **card over an atmospheric field**, per a Paper design whose hex stops are asserted literally in `EditorDisplayModeTests` (the effect lives in a ~10-value range, so a well-meaning "rounding" flattens it). The **field** is three layers: a vertical base wash, plus two 20% diagonal washes crossing TL→BR and BL→TR whose overlap is where the soft corner shading comes from — laid at `MuseModalScrim.fieldOpacity` (0.90) over a within-window `NSVisualEffectView` blur, so the page survives only as a faint ghost. The blur's appearance **follows the field**, not the window: a light blur under the dark field glows through the 10% the field doesn't cover. The **card** is a vertical wash with a 1pt outline. Light: field `#FFFFFF→#F1F7FF`, diagonals `#F4F4F4→#D5D5D5`, card `#FFFFFF→#F1F1F1`. Dark: field `#313030→#121212`, diagonals `#2C2C2C→#121212`, card `#313131→#202020`. The light **base wash** additionally follows the reader theme's hue (`MuseModalScrim.fieldGradientColors(for:usesDarkChrome:)`, threaded as `themeID` beside `usesDarkChrome`): Original keeps the design's cool `#FFFFFF→#F1F7FF`, Paper wears a warm `#FEFDFA→#FBF6ED`, Calm a cool-green `#FAFEFC→#ECFAF2`. Only the **hue** moves — all three bottoms sit at the same ~0.966 relative luminance and the same tint magnitude, so the field never reads lighter or heavier when the theme changes (asserted in `EditorDisplayModeTests`); the tops step off pure white by roughly a quarter of the bottom's deviation, enough to carry the hue through the whole field without reading as a color. The diagonal washes and the card stay **neutral** in every theme — the hue lives in one layer, so a new theme means one pair of stops, not three. Two things these stops are easy to get wrong. First, they are the **base** wash and only ~58% of their chroma reaches the screen (`0.64 × base` after the two neutral diagonals, then `× 0.90` field opacity over the blurred page), so channel separation has to be authored **wide**: Calm's first pass put green 3/255 above blue, which arrived as ~1.7/255 — measurably not-blue, visibly gray — and now leads by 8 with red trailing blue, so it reads as mint rather than as a slightly-off neutral. Screen-verified composited feet: Original `#F2F4F8`, Paper `#F6F3EF`, Calm `#EFF6F2`. Second, the field keys off `Theme.chromeTintID`, **not** `Theme.id`: high contrast deliberately strips theme color from the page, but `Theme.theme(for:)` keeps the user's `themeID` so the theme picker still shows their pick, so keying off `id` would tint a surface that is supposed to be neutral (`Theme.usesThemeTintedChrome` is false only for the high-contrast theme). Both appearances share **one** outline (⌘K's `black 0.08` / `white 0.14`) — the two modals must never carry different outlines. ⌘K formerly hand-rolled a copy of this recipe, which is exactly how the two drifted apart; it now goes through `museModalCard` with `padding`/`usesDarkChrome` parameters, and a modal needing different chrome should add a parameter rather than a second copy. `usesDarkChrome` is **threaded** from `currentTheme` into the scrim, the card, and Settings' text colors — never read from `@Environment(\.colorScheme)`, the same rule the sidebar is documented against; a test asserts the light and dark text colors differ so an environment read fails loudly instead of rendering invisible text. The All-Files search results page is deliberately **excluded**: it is a full-bleed opaque page, not a floating card.

- Sparkle-backed update checks in release builds when a real EdDSA public key and appcast are configured. The in-app updater uses Sparkle's standard UI (`SPUStandardUpdaterController`, `Lineform/App/AppUpdater.swift`), which includes a **"What's New" release-notes pane**. Notes are authored per release as `docs/release-notes/Lineform-<version>.html` (user-facing highlights only — see `docs/release-notes/TEMPLATE.html`); `packaging/generate-appcast.sh` stages the file next to the DMG and `generate_appcast --embed-release-notes` embeds it **inline** into `docs/appcast.xml` as the item's `<description>` (self-contained, nothing extra to host, no app code change). The script warns if the newest DMG has no notes file. When hand-merging the new top item into `docs/appcast.xml`, carry its `<description>` along. See `docs/release/github-sparkle-release.md`.

- Standard macOS About panel showing `V1.3.0` (`AppMenuConfiguration.aboutVersionDisplay`, asserted by `AppCommandNotificationTests`). This is a HAND-MAINTAINED literal, not derived from `MARKETING_VERSION` — it silently drifted and shipped as `V1.2.0` while the app was 1.3.0 (caught 2026-07-25). Bump it, and the test, in the same change as any version bump.

- **Main-menu SF Symbol icons** (`Lineform/App/MainMenuIconDecorator.swift`, installed from `LineformAppDelegate.applicationDidFinishLaunching`): every row in every menu carries a glyph, matching Apple's own iconed menus on macOS 26. This is an **AppKit pass over `NSMenu`, not SwiftUI `Label`s in `AppCommands`** — SwiftUI only owns the items we declare, while Undo/Redo, Cut/Copy/Paste, Services, Hide/Quit, Minimize/Zoom, the Window menu and AppKit's injected **Writing Tools** and **AutoFill** submenus never pass through `Commands`. Partial coverage is worse than none: a File menu where our rows have glyphs and the inherited ones don't reads as broken, so the whole bar is decorated in one place. Two lookup tables: `symbolsByAction` keyed by selector (stable and localization-proof — used for every standard AppKit item) and `symbolsByTitle` keyed by `normalizedTitle` (lowercased, trailing ellipses/periods stripped, app name removed) for SwiftUI's command items, which all share one private action and expose no other handle. Unmapped rows are deliberately left bare rather than given a filler glyph. The menu bar's own top-level row is skipped (Apple's apps don't icon it, and an image there spreads the titles). **The load-bearing part is *when* decoration runs.** A launch pass plus `didBeginTracking` is not enough: SwiftUI builds a replacement menu for `CommandMenu("Format")` **detached**, fills it, and only then swaps it in — so a walk of `NSApp.mainMenu` at that moment decorates the *outgoing* menu while the fresh bare one is what gets drawn. The symptom was Format alone rendering iconless while its `NSMenuItem`s provably had images set. The fix is to decorate **the menu that posted the notification**, which requires the selector-based observer (`MenuNotificationObserver`) — the block-based API can't hand a non-Sendable `NSMenu` into a main-actor closure. **`didAddItem` alone turned out to be insufficient (fixed 2026-07-26).** When a `CommandMenu` is about to open, SwiftUI now updates its EXISTING items in place instead of inserting fresh ones, and that update clears `image`. No `didAddItem` fires for an in-place update, and it lands after `didBeginTracking`, so Format regressed to drawing bare on every row — verified by rebuilding an older commit, and by `LINEFORM_DUMP_MAIN_MENU=1` showing every Format row holding an image two seconds after launch that was gone by the time the menu drew. `didChangeItem` is therefore observed too, despite being the notification our own writes post: an `isDecorating` re-entrancy guard swallows the round trip, and the identity check means a settled row is never written twice. `MainMenuIconDecoratorTests` pins both halves — that a cleared icon is re-applied, and that decoration does not recurse through its own notifications. Images are cached per symbol name so the repeated passes (one per inserted row) settle into a pointer comparison. Verification: `MainMenuIconDecoratorTests` asserts every symbol name resolves via `NSImage(systemSymbolName:)` — a typo fails silently and just renders a bare row, and this test caught two non-existent names on first run. To re-check the mapping against what AppKit and SwiftUI actually build, launch with `LINEFORM_DUMP_MAIN_MENU=1` (run the binary directly, not `open`) and read the stderr dump of title / selector / resolved symbol / whether an image is actually applied, where unmapped rows print `MISSING` and undecorated ones print `NO IMAGE` (resolution and application are different failures — the 2026-07-26 regression resolved perfectly and applied nothing).

- App icon presentation is driven by the Icon Composer source `Lineform/Resources/AppIcon.icon` (built via `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`), which Xcode compiles into both the Tahoe dynamic icon in `Assets.car` and a correctly-inset legacy `AppIcon.icns` fallback for older macOS. The `.icon` art is intentionally full-bleed; Xcode bakes the standard macOS margin into the generated sizes, so do not drop full-bleed PNGs straight into an `.appiconset` (they render oversized on pre-Tahoe Macs). `Lineform/Resources/IconSource/*.png` holds flattened appearance previews of the same design for reference only. Do not set `NSApplication.shared.applicationIconImage` at runtime unless there is a proven platform bug and a regression test/release note covers it.

- Command line tool: a bundled `lineform` helper (`Contents/Helpers/lineform`) opens files (`lineform file.md`) or stdin (`… | lineform -`) in the app via `open`. Pure logic lives in `Lineform/CommandLineTool/LineformCommandLine.swift` (app module, tested); the entry point is `HelperTool/main.swift` (no Xcode target), compiled+signed universal by `packaging/build-release.sh` (so the helper is present only in packaged release builds, not plain Debug). Installed via **Lineform → Install Command Line Tool…** (symlink through an NSSavePanel). Piped input is written to `~/Library/Application Support/Lineform/Piped/` and housekept on each helper invocation (deleted after ~7 days without modification or access; the helper is a separate process and cannot know the app's open documents).

- Apple Shortcuts / App Intents (2026-07-18): two local-first App Intents in `Lineform/App/LineformAppIntents.swift` — **New Lineform Note** (a `text` parameter → opens a note pre-filled with it) and **Open in Lineform** (an `IntentFile` → opens that Markdown/text file) — registered via `LineformAppShortcuts: AppShortcutsProvider` so they appear in the Shortcuts app, Spotlight, and Siri with no user setup. Because Raycast can run any Apple Shortcut, this also covers Raycast (no separate extension). Both are foreground intents (`static let openAppWhenRun = true`) and open through Launch Services targeting `Bundle.main.bundleURL` (`NSWorkspace.open(_:withApplicationAt:configuration:)`) so a `.txt` can't open in TextEdit and a user-picked file gets a Powerbox grant like a Finder double-click — **no new entitlement** (`user-selected.read-write` already covers the picked-file read). "New note" **stages** the text into the app's OWN container (`Application Support/Lineform/ShortcutNotes/`, always sandbox-writable, pruned after 7 days) and opens it as a real autosaving document the user can Save As anywhere — mirroring the `lineform -` piped-stdin CLI path (a truly untitled DocumentGroup doc can't be created pre-filled). **Swift 6 gotchas (build-blocking):** the `AppIntent` `title`/`description`/`openAppWhenRun` requirements must be `static let` (a `static var` trips strict-concurrency "nonisolated global mutable state"), and `@Parameter(... supportedContentTypes:)` on an `IntentFile` is macOS 15+ — omitted here since the deploy target is 14. The build runs `ExtractAppIntentsMetadata` automatically (no pbxproj phase needed) and emits `Contents/Resources/Metadata.appintents` — **but only if `AppIntents.framework` is explicitly LINKED in the app target's Frameworks build phase.** `import AppIntents` alone is not enough: without the link, `appintentsmetadataprocessor` prints "Metadata extraction skipped. No AppIntents.framework dependency found," no `Metadata.appintents` is produced, and the Shortcuts/Spotlight/Siri actions silently never register (this shipped broken until the framework was added). `AppIntents.framework` is linked via the hand-rolled pbxproj (IDs `…04B0`: a `PBXFileReference` with `sourceTree = SDKROOT`, a `PBXBuildFile`, and an entry in the app's Frameworks phase); the source file itself is registered at IDs `…04AF`. Verify after any build-config change that `Contents/Resources/Metadata.appintents` exists in the built app. No AppIntents *extension* target — the intents live in the app target and run in-process on the main actor.

- **Quick Look extension**: a bundled app extension (`LineformQuickLook.appex`) that renders Markdown files with formatted previews in Finder (Space bar) and Spotlight. Implemented as a view controller-based extension (`PreviewViewController` in `LineformQuickLook/QuickLookPreviewProvider.swift`) using `QLPreviewingController` from `QuickLookUI`. Renders Markdown **directly to an `NSAttributedString`** with a custom lightweight converter (`QuickLookMarkdownRenderer`; headings, code blocks, lists, blockquotes, inline formatting, links, horizontal rules) shown in a read-only `NSTextView` — there is **no HTML string and no web view**, so no script/HTML injection surface. Link runs are restricted to `http`/`https`/`mailto` schemes (`styledToken`) — a preview in Finder/Spotlight never makes `file://` or arbitrary-scheme links from doc content clickable. Images render as their **alt text**: the appex has no access to the document's folder and never fetches a remote URL, so there is nothing to draw. Its `.image` pattern must stay ordered before `.link` — see `rendering.md` for why omitting it left a stray `!` in the preview. The extension is sandboxed with read-only file access (`LineformQuickLook/LineformQuickLook.entitlements`). Its `CFBundleVersion`/`CFBundleShortVersionString` track the app via `$(CURRENT_PROJECT_VERSION)`/`$(MARKETING_VERSION)` (the QuickLook target sets both build settings), since an embedded extension's version must match the parent app. Bundle identifiers: `com.lineform.app.quicklook` (Release) and `com.lineform.app.debug.quicklook` (Debug), both prefixed with the parent app's identifier as required for embedded extensions. The extension is embedded in the main app via a "Embed Extensions" copy files build phase.

- **Diagram failure reporting was REMOVED on 2026-07-29.** A failed Mermaid block used to offer a "Report this" link that POSTed `{source, error, appVersion}` to a Cloudflare Worker, which filed a private GitHub issue. It was cut because it was the only feature in Lineform that transmitted document content off the device, which made "no data collected" unclaimable — on the App Store privacy label and in the app's own privacy copy. It was worth roughly nothing in exchange (no users had ever sent a report). The local, anonymous diagram log at `~/Library/Application Support/Lineform/DiagramLog/` is UNCHANGED and still records failures for debugging; there is simply no longer any way to send it. `MermaidRenderingTests.testFailedDiagramOffersNoWayToSendTheSource` guards the removal — a failed diagram must emit the captioned source and no link at all. The Worker (`worker/`, `lineform-diagram-report`) and the private `lineform-reports` repo are now unused; the design doc `docs/superpowers/specs/2026-07-01-diagram-report-design.md` is historical.

- **In-app announcements (2026-07-29)**: a pull-based channel for occasional product news — the app reads a small static `announcements.json` from the marketing site and shows at most one dismissible card. Built deliberately as a **pull**, not APNs push: real push needs a server, stored device tokens, and a `Device ID` entry on the App Privacy label, and — because "there's a new app" is promotional — App Store guideline **4.5.4** consent copy plus an in-app opt-out. A static file fetched over HTTPS needs none of that, keeps the label at **Data Not Collected**, and survives the Sparkle removal (Sparkle's appcast was the obvious host and has a known expiry date). Four pieces: `AnnouncementFeed` (pure decode + validation), `AnnouncementFetcher` (the one non-Sparkle network call, behind `AnnouncementFetching` so no test touches the network), `AnnouncementStore` (`@MainActor ObservableObject`, throttle + dismissed ids + selection), and `AnnouncementCard` (the overlay). **The Settings toggle gates the REQUEST, not the display** — `checkIfNeeded(isEnabled:)` returns before touching the network, so "off" means the app makes no outbound call at all; that is the honest answer to what `network.client` is for and is asserted by a spy fetcher, not assumed. Turning the setting off ALSO retracts the display: the toggle calls `retractForDisabledSetting()` (clears `visible` mid-session), and `init` gates its cache restore on the setting, so a user who turns announcements off does not see the card again this session or have it come back from cache next launch. The request gate is the promise; the display gate is what makes "off" match the user's expectation. Hardening, all because the feed is remote input: streamed with a hard 64 KB abort **counted as bytes land** (`expectedContentLength` is server-supplied and therefore untrusted), 200-only, `Content-Type` must be JSON (a captive portal's HTML login page is never buffered), entry count capped, every string length-bounded and **rejected** — never truncated or stripped — if it carries a control character OR a Unicode line separator (U+2028/U+2029/U+0085 are Zl/Zp/Cc-NEL, NOT in `CharacterSet.controlCharacters`, yet SwiftUI `Text` still breaks a line on them; the sanitizer unions `controlCharacters` with `newlines` so a one-liner stays one line), and `actionURL` restricted to a single-scheme **allowlist** (`https`) rather than a denylist of dangerous schemes. Titles/bodies render as plain `Text`, never Markdown or HTML, so there is no rendering surface at all. Version gating compares **numerically per component** so 1.10 sorts above 1.9, and each component is bounded before any `Int` conversion (the ordered-list `Int.max` rule, generalized). Dismissed ids are kept **forever and never pruned against the live feed** — an id that fell out of the feed costs a few bytes, whereas pruning eventually re-shows something the user already dismissed. A failed check still **stamps** the interval, so an offline Mac doesn't retry on a hot loop. **The throttle governs the network call, not the card**: the last good feed is cached (`Lineform.announcements.cachedFeed`, re-read through `AnnouncementFeed.decode` so cached bytes face the same validation as fetched ones — one validator, no second way in) and `visible` is restored in `init`. Without that cache an announcement the user never dismissed vanished on the next launch and stayed gone until the check fell due again, up to a day later. `fetch()` therefore distinguishes **nil (learned nothing: offline, timeout, unusable payload) from [] (read fine, publisher is showing nothing)** — nil leaves the cache and the screen untouched, [] clears both. Collapsing the two let one offline launch, or one malformed deploy, silently pull a live announcement off every screen. `AnnouncementFeed.encode`/`decode` are a matched pair on one wire format and a round-trip test pins them, including at maximum feed size: if they drift the cache stops decoding and every relaunch loses the card, which is the exact failure the cache exists to prevent. Feed decoding is lenient per-entry: one malformed entry is skipped without discarding the valid ones around it, so a single typo can't kill the channel. Debug-only QA seam `LINEFORM_ANNOUNCEMENT_FEED_JSON` injects a feed with no network (compiled out of Release). Placement is load-bearing — see `AnnouncementCard`'s header and the note in `tabs-and-windows.md` about top-edge chrome.

## Localization (Phase 1, 2026-08-05)

App chrome is localized into Spanish, French, German, Japanese, and Simplified Chinese; document
content (rendered Markdown, callout labels, HTML/PDF export output) never is — see the invariant in
`CLAUDE.md`. Three String Catalogs carry the strings, one per Xcode target concern:
`Lineform/Localizable.xcstrings` (UI strings, keyed by the English literal), `Lineform/InfoPlist.xcstrings`
(the `Markdown Document` and `Plain Text Document` type names plus the `NSHumanReadableCopyright`
About-panel string — the spec forbids adding a localized bundle display name), and
`Lineform/AppShortcuts.xcstrings` (the two
App Intents' Shortcuts-app copy). `knownRegions` in the pbxproj and the six `<lang>.lproj` folders the
build emits are the ground truth for which locales actually ship — verify with `ls
Contents/Resources/*.lproj` in a built app, not by reading the catalog.

**Populating a catalog from code is a two-step, CLI-only procedure — Xcode's "write back to .xcstrings
on build" only happens inside the Xcode GUI.** Build with a scratch `-derivedDataPath`, then sync the
stringsdata it emits into the catalog:

```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -derivedDataPath build-loc
find build-loc -name '*.stringsdata' -print0 | xargs -0 -I{} echo --stringsdata {} > /tmp/sd-args.txt
xcrun xcstringstool sync Lineform/Localizable.xcstrings $(tr '\n' ' ' < /tmp/sd-args.txt)
rm -rf build-loc
```

Two traps, both silent (no error, no non-zero exit):
- **`--skip-marking-strings-stale` is mandatory whenever the sync is scoped to specific
  `--stringsdata` files** (as opposed to the file-list form above, which covers everything at once).
  Without it, syncing one file's stringsdata DELETES every key contributed by other files that
  weren't in this pass — this happened once during development and wiped an entire prior task's keys.
  Always `git diff Lineform/Localizable.xcstrings` after syncing and confirm the change is purely
  additive.
- **`sync` matches a stringsdata entry's table name against the target file's BASENAME.** Syncing into
  a renamed scratch copy of the catalog silently no-ops rather than erroring — don't "test the
  procedure safely" on a copy, test on the real catalog and rely on `git diff`/`git checkout` to undo.

`SWIFT_EMIT_LOC_STRINGS` is already `YES` in both configurations; nothing else needs to change to make
a new `String(localized:)` call show up in the next sync.

**`MainMenuIconDecorator`'s localized-title resolution** (`Lineform/App/MainMenuIconDecorator.swift`):
108 of its icon mappings key off `symbolsByTitle` (`normalizedTitle` — lowercased, ellipses/periods and
the app name stripped) rather than a selector, because SwiftUI `CommandMenu` rows share one private
action and expose no other handle. Matching by title only works if the decorator knows each row's
*localized* title, so it builds a per-language alias map at process start
(`localizedSymbolsByNormalizedTitle(languageCode:)`) from two sources: `SystemMenuItemTitles.titles`
(AppKit-provided rows — Writing Tools, Services, window management) and the app's own
`Lineform/Localizable.xcstrings` catalog (`allEnglishTitleKeys`, read back via
`Bundle(path:).localizedString(forKey:value:table:)`). The runtime language comes from
`Bundle.main.preferredLocalizations.first`, never `Locale.current.language.languageCode` — the latter
collapses `zh-Hans` to `zh`, which matches no `.lproj` and no catalog entry, silently reverting every
title-keyed icon to bare in Chinese. `SystemMenuItemTitles.swift` is generated, not hand-written: run
`packaging/extract-system-menu-titles.py`, which reads AppKit's `.loctable` files under
`AppKit.framework/Versions/C/Resources` for es/fr/de/ja/zh_CN and regenerates the Swift table. Two
built-in exception mechanisms in that script matter if system wording changes on a future macOS:
`EXCLUDED_TABLES` drops `FunctionKeyNames.loctable` (keycap legends like "Find"/"Print"/"Pause", not
menu commands — several languages leave them in English, which the sweep would otherwise mistake for a
real translation), and an `OVERRIDES` block replaces Apple's own inconsistent Format ▸ Heading wording
(fr/es abbreviation drift, and zh-Hans rendering both "Title" and "Heading" as 标题, which collided two
rows in one submenu) — non-binding for Apple's own menus but load-bearing here because Heading 3–6 are
Lineform's own `CommandMenu` rows matched against this table as an alias, not a title AppKit ever draws.
**`Passwords` and `Credit Card`** (AutoFill submenu rows) were recorded as permanent icon losses on the
grounds that Apple ships no translation for them. That is false: macOS 26.5's `InputManager.loctable`
carries both, they are in the generated `SystemMenuItemTitles.swift`, and they resolve in all five
languages today — `MainMenuIconDecoratorTests` asserts it rather than exempting them.

**`localizedAliases(languageCode:)` prefers the CATALOG value over AppKit's.** For ~25 titles the two
sources disagree — Spanish "Preview" is `Previsualizar` in Apple's table and `Vista previa` in ours —
and the catalog value is the one the app actually displays, so a test reading Apple's asserted a title
Spanish Lineform shows nowhere. The preference is safe to state because
`localizedSymbolsByNormalizedTitle` registers BOTH alias sets regardless (asserted: Spanish resolves
the Preview symbol under `vista previa` AND `previsualizar`). The catalog lookup must distinguish
"untranslated" from "translated to the English word" — hence the sentinel in `catalogTitle(_:in:)` —
or an untranslated catalog key would shadow a real Apple translation with the English fallback.

`Preview` is in `lineform-glossary.json`, so a translator choosing a second word for it now fails
`testGlossaryTermsTranslateConsistently` instead of quietly splitting the term across screens.
`Split`, by contrast, has a glossary row but no catalog key — its row is inert, kept for the day the
mode gains a menu title.

**Test locale.** The default test plan pins the process to `en`/`US` (`EditorDisplayModeTests`,
`ReadingProfileStoreTests` and others read `Locale(identifier: "en_US")` explicitly) so date formatting,
plural rules, and string assertions stay byte-identical regardless of the machine running them.
Non-English behavior — the decorator's alias resolution, plural category selection, format-specifier
agreement — is asserted by feeding a language code into the pure functions above
(`localizedAliases(languageCode:)`, catalog decode) rather than by flipping the process locale.

**The first-launch intro overlay** (`Lineform/App/FirstLaunchIntroOverlay.swift`) draws its copy in a
bundled `WKWebView` page, and the catalog cannot reach bundled HTML — that, not the window's
borderless/screen-saver-level nature, is the constraint (its native button localizes normally). So
`localizationUserScript()` BUILDS a small string table from the catalog at runtime via
`String(localized:)` and injects it; nothing is kept in sync with the catalog by hand. The one
hand-maintained coupling is the `data-l10n-id` attributes in
`Lineform/Resources/FirstLaunchIntro/index.html`: a new or renamed id has to be added on both sides.

**CJK word counting** (`Lineform/Editor/DocumentStatistics.swift`): the status bar switches from a word
count to a character count when text `isPredominantlyCJK` — a **content-based**, not locale-based,
decision (`counts.hanKana * 2 > counts.wordForming`), so it applies correctly to a CJK document opened
under any app language and leaves a non-CJK document alone under a CJK app language. Hangul is
deliberately excluded from the Han/Kana scan: Korean is space-separated and already counts correctly as
words, so folding it in would misclassify ordinary Korean prose as needing a character count.

**Two glossaries under `docs/notes/`** back the terminology-consistency gate: `apple-terminology-glossary.json`
(Apple's own translations for OS-level terms, extracted via `packaging/extract-apple-glossary.py`, so
Lineform's copy doesn't invent a different word for something the OS already named) and
`lineform-glossary.json` (Lineform-specific terms — "Workspace", "Reading Experience" — that must
translate identically everywhere they appear, since a translator choosing a synonym on one screen breaks
the decorator's title-matching on another).

**Five gate tests in `LineformTests/LocalizationCatalogTests.swift`** enforce catalog integrity on every
run of the default plan: every catalog key is translated in every shipped language
(`testEveryKeyIsTranslatedInEveryLanguage`), format specifiers (`%@`, `%lld`, …) match in count and order
across languages (`testFormatSpecifiersMatchAcrossLanguages`), glossary terms translate consistently
(`testGlossaryTermsTranslateConsistently`), each language's catalog plural `variations` follow that
language's actual plural rules rather than copying English's two-category shape
(`testPluralCategoriesFollowEachLanguagesRules`), and multi-argument counted strings vary each argument
independently (`testMultiArgumentCountedStringsVaryEveryArgumentIndependently`). `MainMenuIconDecoratorTests`
separately asserts the decorator's per-language alias resolution.

**A sixth gate scans the SOURCE, not the catalog** (`LineformTests/LocalizationSourceSweepTests.swift`).
The five above all pass on a display string that never reached the catalog at all, which is how ~40
strings shipped English with every gate green — including `Rename`, `Cancel` and `Delete`, which WERE
catalog keys and still drew English because they are declared as `String` constants and
`Button(_:)` / `.alert(_:…)` read a `String` with their VERBATIM overload. The gate lexes every
`Lineform/**.swift` (comments, multi-line literals and interpolation included — regex handles none of
the three) and requires each display-copy-shaped literal to be either a catalog key at a
`LocalizedStringKey` position or a `String(localized:)` call at its definition site. Everything else
needs an explicit allowlist entry with a one-line reason; a second test fails any entry that stops
matching, and a third re-checks the "no UI consumer" entries by probing for reads of those symbols,
so neither the allowlist nor its reasons can quietly rot into the hole they were written to close.

**It is a strong default-deny check, not an airtight one** — treat a green run as "nothing obvious
escaped", not as proof. Its "is this display copy?" filter cannot see: literals containing a
character outside `alnum` + `` ,.'?!:;&()-/ `` + curly quotes/ellipsis (an em dash, a straight quote,
a stray `%` — a literal like `"Draft — do not ship"` would slip past hidden by its em dash);
hyphen/slash single tokens (`Auto-Save`); intercapped words (`AutoFill`); lowercase-initial copy of
fewer than three words (`selected`, `iCloud`); `"""` multi-line literals, which the lexer skips;
and enum `rawValue`s, skipped structurally and therefore invisible if one is ever drawn directly.
The full list is on `isDisplayCopy` in the test. Widening the filter trades against false positives
on the ~500 identifier-shaped literals it currently rejects, so widen deliberately.

## Localization (Phase 2, 2026-08-05)

Phase 2 shipped three of the spec's five items: the sidebar's Markdown Basics prose (item 1), the
CJK font cascade (item 2), and read-aloud voice selection (item 4). Items 3 (bundling BIZ UDGothic)
and 5 (CJK reading-preset tuning) remain deferred for the reasons already in
`docs/superpowers/specs/2026-08-05-localization-phase-2-prose-and-fonts-design.md` — 8.9 MB paid by
every user for item 3, and no mechanism to vary a preset by script without minting new persisted
profile identities for item 5. The catalog grew 264 → 299 keys.

**`String(localized:…locale:)` cannot select an `.lproj`** — its `locale:` argument formats
interpolated values, nothing more. Anything that must be *asserted* per language resolves through
`Bundle.main.path(forResource: languageCode, ofType: "lproj")` → `Bundle(path:)`, which is why
`MarkdownReference.sections(in bundle:)` and `Row.accessibilityLabel(in bundle:)`
(`Lineform/Outline/MarkdownReference.swift`) take a bundle at all, defaulting to `.main` so no
production call site changed. `MarkdownReferenceTests.testLanguageResolutionComesFromTheBundleNotTheLocale`
pins the distinction; the English-asserting tests resolve through an explicit `en.lproj` bundle
rather than `.main`, so the suite survives being run on a non-English Mac.

**`rendersSyntaxAsCode == false` is the predicate deciding which syntax-column cells localize.**
Four rows put an English *label* where the other 25 put literal Markdown — `Tab`, `Block Spacing`,
`Spelling`, `Skipped` — and those four localize (the row's copy button otherwise puts an English
word on the pasteboard in a Japanese sidebar). The 25 syntax rows never do: they are document
content. A new label row must be localized and a new syntax row must not;
`testLabelRowsLocalizeAndSyntaxRowsDoNot` and `testExactlyFourRowsAreLabelsNotSyntax` assert the
split in both directions, so neither side can drift by accident. `"Return"` and `"flowchart LR"`
are the two syntax literals that read as display copy to the source sweep and carry explicit
allowlist entries; the whole-file exemption for `MarkdownReference.swift` is gone.

**The 90-character sidebar ceiling holds in all six languages**
(`testExplanationsStayConciseInEveryLanguage`) — the column does not get wider in German. German
expansion of 30–35% put roughly eight rows over the cap, and the fix was to shorten the *English*,
not to raise the ceiling. Measured headroom at the end of the pass: de 86, fr 87, es 82.

**The ceiling measures DISPLAY WIDTH, not `String.count`.** A CJK character occupies two columns, so
counting `Character`s measured ja and zh-Hans at half their real width — the gate was tight for Latin
(2 characters of headroom) and permitted ~2× overflow for CJK, which is the one direction it was never
meant to be loose in. `MarkdownReferenceTests.displayWidth(of:)` sums UAX #11 East Asian Wide and
Fullwidth scalars as 2 and everything else as 1, measured on each grapheme's first scalar so a
combining mark never widens the cluster it attaches to. Same 90 limit, now comparable across scripts.

**Keyboard glyphs survive translation, connective prose does not.** `⌘1`, `⌘2 to ⌘6` and the like
are glyphs, not words — but the English word joining two of them is not, and shipping it as a
protected token left "⌘2 to ⌘6" untranslated in all five languages. Protect the glyph, translate
the sentence around it.

**A cold translation review changed 51 values across the five languages** (`3d3c32a`), reviewed one
language per reviewer with no knowledge of provenance. Two were outright wrong and both were
product claims, not style: German rendered "Callout" as `Hinweis`, which is the NOTE label rather
than the construct, and Spanish said the app draws a *bookmark* for a remote image where the
English promises a **placeholder** — that sentence is the app's never-fetch-remote-images privacy
promise, so a wording drift there misstates what the app does. French carried the same loss.

**Spanish "Vista previa" is now the one word for the Preview mode.** The app had three for one
thing: `Previsualizar` on the toolbar, `Previsualización` in Phase 1's chrome, and Apple's own
standard `Vista previa`. Standardized on Apple's, deliberately reaching back into Phase 1's keys to
do it. `SystemMenuItemTitles.swift` still contains `Previsualizar` and must keep it — that file is
a generated record of AppKit's own wording, not Lineform copy.

**Glossary exemptions match on the WHOLE CATALOG KEY, not the term.** The `Tab` exemption (keycap
vs. document tab) therefore does not cover a different string that also contains "Tab"; a second
exemption was needed for the Shift-Tab explanation. It also means an exemption disables the
consistency gate for *every* term in that string, so a later reword of an exempted key can hide a
real inconsistency.

**Editing `Localizable.xcstrings` by hand: never round-trip it through a JSON serializer.** It
reflows the entire file and buries the change. Insert new key blocks as text at their sorted
positions.

## CJK fallback: why Lineform declares NO font cascade (2026-08-05)

Lineform attaches no `.cascadeList` to any font. CJK reaches a face through CoreText's implicit
substitution, which is what the unmodified platform does. This section exists because the opposite
was built on this branch — `MarkdownFontCascade`, an explicit `["Hiragino Sans", "PingFang SC"]`
attached to every resolved font and re-attached after every `NSFontManager` trait conversion — and
was then measured and **removed**. Do not rebuild it.

**The premise was false.** The feature's rationale was that implicit substitution is "unchosen" and
the app should choose deliberately. Measured on macOS 26 with `CTFontCreateForString`:

| primary face | what CJK resolves to, bare |
|---|---|
| `.systemFont` | `.PingFang UI SC` / `.PingFangUITextSC-Regular` |
| `.systemFont` + `.boldFontMask` | `.PingFangUITextSC-Bold` — **traitBold set** |
| `.monospacedSystemFont` + `.boldFontMask` | `.PingFangUITextSC-Semibold` — traitBold set |
| `withDesign(.serif)` (the New York reading font) | `Songti SC`, a SERIF Han face |
| Helvetica, Comic Sans MS | `PingFang SC`, `Songti SC` |

So `NSFontManager.convert` dropping an attached cascade — the finding the whole design was built
around — was a problem that existed **only because we attached one**. Bare, the converted font
resolves CJK to a correctly-weighted CJK face with no help from us.

**It degraded typography.** The system substitutes optically-sized UI variants (`.PingFang UI Text
SC`, `.CJK Symbols Fallback SC`) whose metrics match the Latin primary. The public families a
hardcoded list can name are taller. One mixed EN/zh/ja document at 16pt, line-fragment heights:

- bare: `18, 18, 18, 18, 18`
- with the cascade: `18, 24, 18, 24, 24` — three different line heights on one page

PDF export re-paginated with it (+11% height on a CJK block), and the serif reading font lost its
serif Han face (Songti SC → PingFang/Hiragino). The cascade also cost 2× per `convert` call on a
per-keystroke path in Split mode, which is what the `NSCache` memo on `monospaced(ofSize:)` existed
to offset — a cost that only existed because of the feature.

**The `japaneseFirst` branch bought nothing.** Deriving the order from
`Bundle.main.preferredLocalizations` was an attempt to rescue the feature after a hardcoded
Hiragino-first order was found rendering pure Chinese in a Japanese face (most characters of a
Chinese sentence are shared Han). But under a Japanese interface that branch simply reproduces the
original bug, and under the PingFang-first default Japanese still reaches Hiragino through kana,
which is script-exclusive. Both branches were strictly worse than doing nothing.

**What the tests pin now.** `LineformTests/CJKFontFallbackTests.swift` replaces
`MarkdownFontCascadeTests`. It asserts, bare: every `FontOption` resolves the CJK samples to a real
glyph in a real family (never LastResort); a bold conversion of system/mono/serif resolves CJK to a
face with `traitBold`; the serif reading font keeps a serif Han face; a mixed EN/zh/ja document has
ONE line height at a fixed size; and no font the app resolves or renders with declares a cascade
list at all. One counterfactual test asserts that a declared cascade *does* break the line-height
uniformity, so the rule keeps its reason attached rather than remembered.

The old suite is the cautionary half of this: 18 of its assertions checked only that a list was
ATTACHED, which is how a Japanese-first order shipped green, and none of them measured a line
height, which is how the degradation shipped green too.

**What survived the removal**, because it was never about the cascade:
`FontOption.resolved(for:)` is non-optional (`option(for:) ?? defaultOption`). A `FontID` can be
RETIRED — still declared so persisted `ReadingProfile`s decode, but removed from `groupedOptions`
(`.lexend` today) — and the old `?? .systemFont(…)` tails at the render sites were reachable
through exactly that gap, drawing a bare face while the picker showed SF Pro. `ReadingProfileStore`
still persists a retired id with no self-heal on decode: a pre-existing divergence, unchanged.

## Read-aloud voice (2026-08-05)

`AVSpeechUtterance` with no `voice` follows the **UI** language, so a Japanese-UI user reading an
English document heard English spoken by a Japanese voice. `SpeechLanguageDetector`
(`Lineform/ReadingExperience/SpeechLanguageDetector.swift`) runs `NLLanguageRecognizer` over the
extracted spoken text and returns a BCP-47 code, or nil. The `SpeechSynthesizing` seam widened to
`speak(_:languageCode:)` so the protocol, `SystemSpeechSynthesizer`, `SpeechController.startSpeaking`
and `FakeSynthesizer` move together — and the fake still models the SHIPPING stop/pause semantics
(a stopped utterance reports `didFinish`; pause defers to a word boundary), which is the standing
invariant in `CLAUDE.md`.

Two conservative gates: a 12-character minimum and a 0.65 confidence floor, below which the voice
is left alone. Both are load-bearing rather than padding — gibberish scored Polish at 0.48, which
the floor rejects. `AVSpeechSynthesisVoice(language:)` returns nil for an uninstalled language and
that nil is fine: it lands back on the system default. The single floor applies to every script
even though 12 characters of Japanese carries more evidence than 12 of English; that is heuristic
tuning, not a defect. `NaturalLanguage` auto-links, so no pbxproj Frameworks-phase edit was needed
(verified with `otool -L`).

**Detecting a language is not a reason to override the voice.** The first version assigned
`AVSpeechSynthesisVoice(language: detected)` whenever detection succeeded, which fixed the edge
case by breaking the common one: an en-GB or en-AU user reading ordinary English prose lost the
voice they chose in System Settings ▸ Accessibility ▸ Spoken Content and got en-US Samantha,
because that initializer picks an arbitrary region for a bare tag. Measured on this machine:
`fr` → fr-CA Amélie (fr-FR Thomas installed), `zh-Hant` → zh-CN Tingting (zh-TW Meijia installed),
`en` → en-US Samantha, `pt` → pt-BR, `nl` → nl-BE.

`SpeechVoiceResolver` (`Lineform/ReadingExperience/SpeechVoiceResolver.swift`) is the pure decision:
detected language + `AVSpeechSynthesisVoice.currentLanguageCode()` + `Locale.current.region` +
`speechVoices()` → `.keepSystemDefault` / `.voice(identifier:)` / `.language(_:)`. Two rules:

- **The user's selection wins unless the document disagrees with it.** When the detected language is
  compatible with the system voice's tag, `utterance.voice` is left nil — which IS the user's own
  Spoken Content selection. Only a genuine mismatch overrides.
- **An override keeps the region.** An installed voice is chosen by identifier (document's explicit
  region first, then the user's region, then any region, then a region-less tag, ties broken by
  `speechVoices()` order so the answer is deterministic). `AVSpeechSynthesisVoice(language:)` is the
  last resort, for a language with nothing installed; its nil is still fine — it lands back on the
  system default.

Compatibility is script-aware, and that is load-bearing for Chinese: `zh-Hant` and `zh-CN` share a
language subtag, so without inferring the script from the region (CN/SG/MY → Hans, TW/HK/MO → Hant)
a Traditional document "agrees with" a Simplified system voice and is read in Simplified. Voices
take a supplied `[SpeechVoiceCandidate]` rather than calling `speechVoices()` themselves, so
`SpeechVoiceResolverTests` asserts region and script preference without depending on which voices
the running machine has installed. `"Hans"`/`"Hant"` are exempted in `LocalizationSourceSweepTests`
as ISO 15924 subtags — they are compared against BCP-47 tags, never displayed.

## Accessibility (2026-07-27 audit)

- **The first-launch intro must be dismissable without a mouse.** It is a borderless,
  screen-saver-level window covering the display that orders every other app window out, and its
  only control is a hand-drawn `NSView`. Two things made it a dead end: a `.borderless` `NSWindow`
  answers `false` to `canBecomeKey`, so no key event ever reached the content
  (`FirstLaunchIntroWindow` overrides it), and the button had no accessibility identity or key
  handling (it is now `.button` with a label, `accessibilityPerformPress`, focus-ring drawing, and
  Space/Return in `keyDown` — a plain `NSView` never routes keys through `interpretKeyEvents`, so
  `insertNewline(_:)` is never sent). A VoiceOver, keyboard-only, or Switch Control user could not
  get past first launch. Escape is deliberately not wired: leaving marks the intro complete and
  opens the first document, so it should be a deliberate press.
- **Do not put SwiftUI accessibility modifiers on `MarkdownTextViewRepresentable`.** `LineformTextView`
  sets its own label, role, and help through AppKit and is a real `NSTextView`, so VoiceOver reads it
  by character, word, and line and tracks the caret. Restating the label through SwiftUI buys nothing
  and risks flattening that. The search summary in particular is NOT the editor's AX value — the value
  of a text area is its text — so it is spoken as an `.announcementRequested` from
  `announceSearchStatus`, which is also what gives a VoiceOver user any feedback at all when pressing
  Return in the find field. Announcements are dropped when VoiceOver is off.
- **An icon that is the only signal for a state carries a label** (the workspace-disconnected glyph).
  Decorative icons that sit beside their own text label do not.
- **Contrast has a gate, not an opinion.** Body text and caret vs. every theme background, and the
  high-contrast profile over every theme, are asserted in `ThemeTests` alongside the existing code-token,
  diagram-ink, and Info-tab checks. Body text was the one pairing that had only ever been asserted
  "not equal".
- Read-mode overlay affordances (code copy, image Reconnect, task checkboxes) are drawn geometry
  activated by hit-testing, so they exist for assistive tech only through
  `accessibilityCustomActions`; sidebar row actions are mirrored from the context menu into
  `.accessibilityActions`. Keep both mirrors when adding an affordance of either kind.

## Release gates, menus, CLI, intents (audited 2026-07-27)

**The release gates were opt-in.** `RESIGN_WITH_DEVELOPER_ID` defaulted to `NO`, and it gates one
`if` containing the exit-66 profile check, the exit-68 cert-in-`DeveloperCertificates` hard gate,
the `cp` of `embedded.provisionprofile`, and every `codesign` in the nested-bundle re-sign list
(helper, Quick Look appex with its own `--entitlements`, Sparkle's Autoupdate / Downloader.xpc /
Installer.xpc / Updater.app / framework, and the app). Unset, the script printed one stderr warning
and continued to the DMG — exit 0. The variable appeared in exactly one file in the repo (the script
itself) while `docs/release/github-sparkle-release.md` gave the release command WITHOUT it and
asserted on the same page that the gates run. These are the two failure classes that already shipped:
1.1.0's AMFI brick (cert not in profile) and 1.3.0's notary rejection (appex signed with Apple
Development). It now defaults to `YES`, the opt-out additionally requires `ALLOW_UNSIGNED_DMG=YES`
and exits 70 without it, and the flag is documented beside the release command.

Worth recording: on the manual path a bad DMG does not silently ship, because `notarize-dmg.sh` is a
separate step and the notary rejects it — which is exactly how the 1.3.0 appex regression was caught.
The damage was a false guarantee in two docs plus a late, confusing notarization failure, with the
cert-vs-profile assurance silently absent from every build not run with an undocumented flag.

**The clean-Release rule was enforced by nothing.** `Contents/Helpers/lineform` is written into the
bundle after `xcodebuild`, so a copy left by a previous run is present when the next build's CodeSign
step runs and fails it with "code object is not signed at all". The script now `rm -rf`s `$APP_PATH`
before building.

**`generate-appcast.sh` clobbered the tracked appcast.** It ended with an unconditional
`cp "$UPDATES_DIR/appcast.xml" docs/appcast.xml`. `generate_appcast` rewrites EVERY entry's enclosure
URL with the single `--download-url-prefix` it was given, so that copy retags historical releases
with the current version's URL and old versions point at a download that does not exist for them. It
now writes `docs/appcast.generated.xml`, leaves the tracked file alone, and prints a diff plus the
hand-merge instruction the release doc already specified.

**The icon decorator stamped context menus.** Its observers register with `object: nil` — every
`NSMenu` in the process — which is deliberate and load-bearing: SwiftUI builds a replacement
`CommandMenu` DETACHED and swaps it in, so the posting menu is the only reliable handle and a
supermenu-chain test would reject exactly the case the decorator exists for. The cost was that the
editor's right-click menu came up wearing semantic SF Symbols on rows that read as main-menu
commands. Fixed by tagging the app's own context menu with
`MainMenuIconDecorator.excludedMenuIdentifier` rather than by narrowing the observation. Separately,
the Spelling and Grammar submenu's three rows had no icon mapping — it was the only bare submenu in
the bar, and it is the app's only off switch for spell checking.

**`lineform -` accepted input the app then refused.** The pipe guard checked for NUL bytes only, so
any non-UTF-8 sequence passed: `printf 'caf\xe9\n' | lineform -` wrote a file the app rejected with
a corrupt-file error, far from the pipe that caused it. It now validates with the same
`String(data:encoding:.utf8)` the document loader uses. The NUL check stays — NUL is valid UTF-8.

**App Intents filenames dropped every non-ASCII letter.** `noteTitle(from:)` allow-listed ASCII
alphanumerics, so an accented title lost its accents and a CJK, Cyrillic, or Arabic note reduced to
an empty string and was filed as "New Note" — every such note colliding on one name. It now rejects
only what a filename cannot carry (`/`, NUL, `:`, newlines, default-ignorable scalars) and refuses a
leading dot, which would have made the note a hidden file.

**Refuted, for the record.** Three claims did not survive: that `.github/workflows/release.yml`
could publish an un-notarized DMG (the job cannot reach `gh release upload` on its runner); that
`verify-update.sh` can pass without checking the app that ships (the verifier ran the real delta path
and got a byte-identical CDHash); and that the launch smoke test's `rm -rf` of a Release copy trips
the iCloud-container uninstall purge (the mechanism does not hold, and it has run ~30 times already).
