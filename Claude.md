# Lineform Agent Guide

This file is for AI coding agents working in the Lineform repo. Read it before making changes. It explains what the app is, what quality means here, and how to verify work.

## Product Context

Lineform is a free native macOS Markdown editor for calm writing, real local files, and readable long-form text. V1.0 is the first public version of the app. The app should feel quiet, native, file-based, and trustworthy. It is not a web editor, not a note-taking database, and not a cloud writing service.

Public-facing links:

- Product website: `https://lineform-site.vercel.app`
- GitHub repo: `https://github.com/carlostarrats/Lineform`
- Public download target: `https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.1.1.dmg`

Core product principles:

- Real files: documents are plain UTF-8 Markdown or text files that remain portable across Finder, iCloud Drive, Git, and other editors.
- Native autosave: existing files use macOS document autosave and are written to their real `.md`, `.markdown`, or `.txt` file as the user writes. Untitled documents still need a user-chosen save location before they can become real files.
- Local-first privacy: there is no account system, no analytics by default, and no document upload.
- Native macOS behavior: prefer SwiftUI, AppKit, TextKit, document-based app patterns, system controls, and platform conventions.
- Calm writing: UI should reduce noise and support long drafting/review sessions.

## Main Features

- Document-based macOS app for Markdown and plain text files.
- Native macOS autosave for existing files, with Save/Save As still available and untitled files prompting for a destination when needed.
- Files selected from the left Files sidebar switch in the current window, Apple Notes-style. Do not describe this as a guaranteed manual save prompt before navigation; existing files are usually already autosaved by the document system.
- Live reload: an open document refreshes from disk when its file changes externally (e.g. an agent rewrites the `.md`), on clean documents only, debounced, preserving scroll and mode, with a quiet "Updated" status. Implemented as a dedicated `NSFilePresenter` (`Lineform/Documents/DocumentReloadController`), not on the value-type `FileDocument`. Documents with unsaved edits defer to standard behavior — never clobbered.
- Show hidden folders: a per-app **View menu** item, **Show Hidden Folders** (⌘⇧., default off, persisted) that reveals dot-directories (`.claude/`, `.agents/`, `.github/`, …) and their Markdown/text files, de-emphasized. `node_modules` and `.git` stay excluded regardless (`excludedDirectoryNames` in `OutlineFileBrowserStore`). Toggling re-scans; hidden files open/watch/render like any other. The menu checkmark is driven by the shared `HiddenFoldersMenuState` (backed by the same `showsHiddenFoldersDefaultsKey`); toggling broadcasts `LineformAppNotification.toggleHiddenFolders` app-wide. A window applies it to its per-window store **only while its Files tab is visible** (the observer lives on the Files-tab view, not the always-present sidebar), and otherwise reconciles on the tab's next `.onAppear`. This deliberately preserves the iCloud-laziness invariant above: the store's expensive scan still only runs when the Files tab is shown, never for windows on the Outline tab or with the sidebar collapsed. (There is no in-sidebar toggle; the older eyeball button was removed.)
- Mermaid rendering: ```mermaid fenced blocks render as native diagrams in Read and Preview modes (Write shows source), via the `BeautifulMermaid` SPM package (`lukilabs/beautiful-mermaid-swift`, MIT, pinned 1.0.4, native — no WebView). Themed from the reader theme's bg/fg, width-constrained, cached, size-guarded (>20,000 chars → fallback). BeautifulMermaid 1.0.4 draws its macOS raster into a bottom-left-origin `CGContext` while assuming a top-left origin, so every diagram comes back vertically mirrored; `MermaidImageOrientation.uprightForMacOS` flips the finished raster upright at the seam. This correction is unconditional — **if the pin is ever bumped, re-check orientation and remove the flip if upstream fixes the y-origin, or diagrams will render upside down again.** On any parse/render failure it falls back to a captioned "Mermaid diagram (source)" block and records a **local, anonymous** entry in `~/Library/Application Support/Lineform/DiagramLog/` (source snippet + error + app version + count + last-seen; no file names/paths). This log is a silent backing store only — it is the "Saved locally" fallback when a user-initiated report can't be sent — and is deliberately **not** surfaced in any menu (the former Export/Clear Diagram Log menu items were removed as user-facing plumbing with no writer value). The library is isolated behind `MermaidImageProvider`; failures are always safe.
- Math / LaTeX rendering: inline `$…$` and block `$$…$$` LaTeX render as native typeset equations in Read and Preview modes (Write shows source), via the `SwiftMath` SPM package (`mgriebling/SwiftMath`, MIT, pinned 1.7.3, native — no WebView/JavaScript/KaTeX). Isolated behind `MathImageProvider` (`Lineform/Preview/MathRendering.swift`), mirroring `MermaidImageProvider`: renders each equation to a cached raster `NSImage` (via SwiftMath's `MathImage.asImage()`), themed to the reader theme foreground, size-guarded (>20,000 chars → fallback). Delimiters follow pandoc/GitHub `$` rules so prose dollar amounts ("it costs $5 to $10") stay literal — the opener may precede a digit; only the closing side guards against prose. Inline math is a **first-class token in the existing inline tokenizer** (`inlineWithMath`/`inlineSpans`), so it loses to an earlier code span or emphasis run by position (```` `$x$` ```` stays literal code; math is never detected inside another inline token) and is baseline-aligned by offsetting the attachment `-descent` (from `MathImage`'s ascent/descent). Unlike Mermaid, SwiftMath's macOS path draws into a y-up context matching its typesetter, so **no orientation flip is needed** — re-check if the pin is bumped. On any parse/typeset failure it falls back to a captioned "Math (source)" block (or inline-code-styled source), with **no logging, no report affordance, and no network** — math failures are the user's own LaTeX, not a library bug worth collecting. Math regions are protected from Writing Tools like fenced code (`MarkdownWritingToolsProtection.mathRanges`). SwiftMath bundles libre math fonts (GUST Font License + SIL OFL); see `Lineform/Resources/FontLicenseReview.md`. The raw LaTeX is attached as the image's VoiceOver `accessibilityDescription` (a known limitation: VoiceOver reads source, not spoken math — see `docs/superpowers/specs/2026-07-02-math-latex-support-design.md`).
- Diagram failure reporting (user-initiated, anonymous): a failed Mermaid block shows a quiet "Report this" link; tapping it presents a Report/Not Now dialog and, on Report, POSTs exactly `{source, error, appVersion}` to a Cloudflare Worker (`worker/`, `lineform-diagram-report`) that files/comments a private GitHub issue (`carlostarrats/lineform-reports`) via a Worker-secret token, deduped by source hash, IP-rate-limited (IPs never stored). App payload built by `DiagramReportService` (exactly 3 fields); `network.client` entitlement already present. **Live as of 2026-07-02** (see `docs/superpowers/specs/2026-07-01-diagram-report-design.md`): the `lineform` workers.dev subdomain is registered, the private `lineform-reports` repo exists, the Worker is deployed at `https://lineform-diagram-report.lineform.workers.dev`, and `GITHUB_TOKEN` (a fine-grained PAT scoped to `lineform-reports` Issues read/write only) is set as a Worker secret. Verified end-to-end (POST → issue filed; duplicate → count-bump comment). Keep the Worker name + subdomain stable — the URL is baked into shipped builds. If the Worker or its token is removed, reports fail closed → "Saved locally."
- Command line tool: a bundled `lineform` helper (`Contents/Helpers/lineform`) opens files (`lineform file.md`) or stdin (`… | lineform -`) in the app via `open`. Pure logic lives in `Lineform/CommandLineTool/LineformCommandLine.swift` (app module, tested); the entry point is `HelperTool/main.swift` (no Xcode target), compiled+signed universal by `packaging/build-release.sh` (so the helper is present only in packaged release builds, not plain Debug). Installed via **Lineform → Install Command Line Tool…** (symlink through an NSSavePanel). Piped input is written to `~/Library/Application Support/Lineform/Piped/` and housekept on each helper invocation (deleted after ~7 days without modification or access; the helper is a separate process and cannot know the app's open documents).
- Write mode for editing source Markdown.
- Read mode for rendered, calmer reading.
- Split/Preview mode for side-by-side writing and preview.
- Markdown outline navigation from document headings.
- Markdown formatting commands for common writing actions.
- Markdown syntax highlighting and range analysis.
- Reading profiles for type size, line height, block spacing, margins, column width, caret width, focus, ruler, and themes.
- Apple Books-style reader themes plus accessibility-oriented font and contrast options.
- Native Writing Tools protection around Markdown regions such as fenced code and front matter.
- Local release/help resources bundled in the app.
- Sparkle-backed update checks in release builds when a real EdDSA public key and appcast are configured.
- Standard macOS About panel showing `V1.1.1`.
- App icon presentation is driven by the Icon Composer source `Lineform/Resources/AppIcon.icon` (built via `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`), which Xcode compiles into both the Tahoe dynamic icon in `Assets.car` and a correctly-inset legacy `AppIcon.icns` fallback for older macOS. The `.icon` art is intentionally full-bleed; Xcode bakes the standard macOS margin into the generated sizes, so do not drop full-bleed PNGs straight into an `.appiconset` (they render oversized on pre-Tahoe Macs). `Lineform/Resources/IconSource/*.png` holds flattened appearance previews of the same design for reference only. Do not set `NSApplication.shared.applicationIconImage` at runtime unless there is a proven platform bug and a regression test/release note covers it.

## Architecture Map

Important directories:

- `Lineform/App`: app entry point, menu commands, notifications, and update-check wiring.
- `Lineform/Documents`: document model, UTF-8 Markdown/text file read/write, save status.
- `Lineform/Editor`: editing container, TextKit bridge, syntax highlighting, formatting commands, writing tools protections.
- `Lineform/Preview`: Markdown preview rendering and preview view bridge.
- `Lineform/Outline`: Markdown heading parser and outline sidebar UI.
- `Lineform/ReadingExperience`: reading profiles, presets, themes, fonts, and reading experience controls.
- `Lineform/Resources`: bundled privacy/help/release/accessibility docs.
- `LineformTests`: XCTest coverage for app behavior, editor behavior, reading experience, and Markdown handling.
- `docs`: deeper project docs, including implementation specs and plans.

Prefer existing module boundaries. Do not move responsibilities across directories unless the change clearly improves maintainability and is directly needed.

## iCloud Storage

The Files sidebar's iCloud root (shown as **"Lineform"** with a cloud icon) is backed by an app-owned iCloud Drive container declared in `Info.plist` (`NSUbiquitousContainers`, public document scope) and entitlements. `OutlineFileBrowserStore` (in `Lineform/Outline`) owns this behavior.

- Only the Release/production build carries an iCloud entitlement (`iCloud.com.lineform.app`, in `Lineform/Lineform.entitlements`). Debug builds intentionally ship **no** iCloud entitlement (`LineformDebug.entitlements` has none), so `iCloudContainerIdentifier` resolves to nil there and the iCloud root is treated as unavailable. When the iCloud container can't resolve (no entitlement in Debug, or a Release user not signed into iCloud), the Files sidebar **hides the iCloud root entirely** (`OutlineSidebarView.rootIsVisible`) rather than showing a dead entry — so **Debug never shows an iCloud root at all**, and only the Workspace root appears. (Connected-but-empty iCloud is instead shown dimmed with no chevron via `iCloudRootIsDimmed`.) This is deliberate isolation: dev/CI build churn can never touch (and let macOS purge) the real users' production container, and — critically — a restricted iCloud entitlement cannot be satisfied under ad-hoc ("Sign to Run Locally") signing, so giving Debug one would stop the test host from launching on CI. Do not add an iCloud entitlement to Debug. (A separate registered `*.debug` container was tried and rejected for exactly this CI-launch reason.)
- The live iCloud scan (resolving the ubiquity container + enumerating the directory) is expensive and must not run on the main thread at view construction — it would block launch and perturb hosted-view layout. It is deferred to `OutlineFileBrowserStore.refreshICloud()`, invoked when the Files tab actually appears. Init only loads the cached snapshot. Preserve this laziness.
- The store keeps the user's iCloud working set materialized via `ensureDownloaded(...)` (`FileManager.startDownloadingUbiquitousItem`), so evicted (dataless) files don't appear in search yet fail to open or drag. This is realized through the `UbiquitousItemDownloader` protocol so it is testable without real iCloud files.
- App-owned containers are still subject to iCloud purge when macOS believes the app was uninstalled. The durable additional protections are operational, not code: ship updates via Sparkle's atomic in-place swap (never instruct users to delete the old app and drag a new one), and do not run-then-delete locally built Release/Export copies of `com.lineform.app` while signed into the production iCloud account.

## Verification Commands

General deterministic test gate:

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

Use serial testing for the full suite. Some AppKit-hosted tests can contaminate each other when Xcode runs them in parallel. No signing/team flags are needed: Debug ships no iCloud entitlement, so the test host signs ad-hoc ("Sign to Run Locally") and launches on unprovisioned machines and CI. Do not add an iCloud entitlement to Debug — it cannot be satisfied under ad-hoc signing and the test host will fail to launch (CI red).

QUIT XCODE BEFORE RUNNING THE FULL SUITE. The hosted editor tests in `EditorDisplayModeTests` (e.g. `testEditorVisibleTextDoesNotJumpVerticallyWhenReadingInspectorOpens`) measure a sub-second animation and are load-sensitive: with Xcode left open during `xcodebuild test`, the extra resource contention intermittently makes them fail with a spurious vertical-jump delta (e.g. "13.0 > 1.0"). They pass reliably in isolation and on a quiet machine. This is harness fragility, not a product regression — do not weaken these tests to "fix" it; quit Xcode and re-run.

Known AppKit test-harness warning:

- `EditorDisplayModeTests/testEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens` may log `[WarnOnce] It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out`.
- This warning was investigated in an isolated worktree on May 28, 2026. It appears when the test constructs the full `NSHostingView`/`NSWindow` editor harness via `makeEditorDrawerHarness()`.
- Sandbox checks ruled out the drawer notification, the tuned text-canvas drawer motion code, Lineform's SwiftUI toolbar/search modifiers, and `makeKeyAndOrderFront` as direct causes.
- Do not weaken or replace the full hosted drawer-motion harness just to silence this warning. The harness protects real UI motion regressions. Revisit only if the warning appears during normal app use, becomes a CI failure, or has a proven user-visible layout symptom.

## Quality Bar

Before claiming a change is complete:

- Run the commands that prove the claim.
- Read the output and report exact pass/fail counts.
- Do not hide residual risk. If a manual UI state was not exercised, say so.

## Coding Guidelines

- Follow existing patterns before introducing new abstractions.
- Keep edits scoped to the feature or bug being handled.
- Prefer structured parsing/helpers over ad hoc string manipulation when reasonable.
- Keep Markdown handling structure-preserving.
- Keep UI native, restrained, and task-focused.
- Keep app identity surfaces consistent: Finder, Dock, Cmd-Tab, About, DMG, README download links, Sparkle appcast, and release docs should all point to the same versioned build.
- Treat every public app update as both a manual-download release and an in-app update release. Never ship only a GitHub DMG or only a Sparkle/appcast update: version bumps, release DMGs, GitHub Release assets, README download links, `docs/appcast.xml`, Sparkle signatures, and any referenced delta assets must all describe the same current version before the release is complete.
- Avoid unrelated refactors and metadata churn.
- Preserve user work in the git tree. Do not revert changes you did not make.
- Use focused tests for narrow changes and broader tests for shared behavior.

## Privacy And Safety

Lineform is local-first. Do not add behavior that uploads document contents, requires an account, collects analytics by default, or converts user documents into an app-owned database without an explicit product decision.

## Credits And Third-Party Materials

Keep attribution accurate when changing fonts, bundled resources, README copy, app metadata, or release docs:

- Atkinson Hyperlegible is bundled under the SIL Open Font License 1.1 and is credited to Braille Institute of America, Inc.
- OpenDyslexic is bundled under the SIL Open Font License 1.1 and is credited to Abbie Gonzalez, with Reserved Font Name OpenDyslexic.
- The bundled font license files must remain in `Lineform/Resources/Fonts`.
- `Lineform/Resources/FontLicenseReview.md` should stay in sync with the bundled font set.
- Sparkle is bundled for macOS update checking and must be credited in public docs/notices when release or dependency documentation changes.

## Documentation Expectations

Update docs when behavior, workflows, or quality gates change:

- Keep `README.md` user-facing: prominent download, website, privacy, about, credits, and only a compact source-build section.
- Use this `AGENTS.md` for AI coding agent context and repo operating rules.
- Use `docs/release/github-sparkle-release.md` for GitHub Releases, DMG packaging, and Sparkle appcast steps.
- Use `Lineform/Resources/*.md` for user-facing bundled app/help/release docs.

## PR / Marketing / Positioning Reference

For any PR, marketing, positioning, audience, or public-copy question ("how do I describe Lineform," "who is it for," "what's the one-liner," "is this claim safe to publish"), consult `POSITIONING_AND_MARKETING.md` at the repo root. It holds the verified positioning, target audience, plain-language feature list, differentiation vs. competitors, honesty constraints, launch-surface copy (Show HN / X / App Store / website), and a fact sheet (version, platform, license, privacy).

- It is a **local, untracked** working doc (in `.gitignore`) — it does not get committed or auto-updated by release tooling, so treat its facts as a dated snapshot. Its verification stamp names the app version it was checked against; if a question turns on a specific capability and the build has moved on, re-verify against the current code before making any public claim. Never publish a capability the shipped build can't demonstrate.
- Load-bearing rules from that doc: say "free" and "source-available" (never "open source" — PolyForm Shield 1.0.0); "No AI inside" is accurate and intentional; the CLI/stdin helper exists only in the released build after a one-time install; and only Atkinson Hyperlegible + OpenDyslexic are bundled fonts.

Keep this file current when major features, architecture, or verification gates change.
