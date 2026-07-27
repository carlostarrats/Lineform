# Lineform Agent Guide

This file is for AI coding agents working in the Lineform repo. Read it before making changes. It explains what the app is, what quality means here, and how to verify work.

## Product Context

Lineform is a free native macOS Markdown editor for calm writing, real local files, and readable long-form text. V1.0 is the first public version of the app. The app should feel quiet, native, file-based, and trustworthy. It is not a web editor, not a note-taking database, and not a cloud writing service.

Public-facing links:

- Product website: `https://lineform-site.vercel.app`
- GitHub repo: `https://github.com/carlostarrats/Lineform`
- Public download target: `https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.3.0.dmg`

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
- Write mode for editing source Markdown.
- Read mode for rendered, calmer reading.
- Split/Preview mode for side-by-side writing and preview.
- Markdown outline navigation from document headings.
- Markdown formatting commands for common writing actions.
- Heading levels: ⌘1–⌘6 set the level of the lines a selection touches, ⌘0 returns them to body text, and pressing a line's current level clears it. Title (⌘1) and Section (⌘2) stay on the Format menu; Heading 3–6 and Body are in Format ▸ Heading. List items, blockquotes, code, and front matter are skipped, not converted.
- List continuation on Return for bullets, numbered items, task checkboxes, and blockquotes; Return on an empty marker ends the construct.
- Table authoring: Insert Table (⌃⌘T) drops a 3×2 skeleton, Reformat Table (⌃⌘R) aligns the pipes of the table under the caret, and Tab/Shift-Tab move between cells inside a table only. Reformat declines on escaped pipes and backticks, and is a silent no-op when the table is already aligned.
- Live spell checking as you type, suppressed inside fenced code, front matter, math, inline code, and link/image destinations; autocorrect is off, grammar checking is unused, and right-click offers one ranked suggestion plus Learn/Ignore.
- Multi-document tabs, Find & Replace, cross-file search, and ⌘K quick open.
- Read/Preview rendering of Mermaid diagrams, LaTeX math, GFM tables, task checkboxes, GitHub-style callouts, code-language syntax highlighting with a copy button, and local (never remote) inline images.
- Save As retargets the Markdown file; File ▸ Export As writes a copy as HTML, PDF, Styled PDF, or Rich Text (.rtf), plus Print (⌘P). Exported HTML is one-to-one with the source — image paths and link URLs are emitted exactly as written.
- Read-aloud of the rendered text (Edit ▸ Speech), skipping code, math, and diagrams.
- ⌘E toggles Write ↔ Read; Split stays on the toolbar and View menu.
- Reading profiles for type size, line height, block spacing, margins, column width, caret width, focus, ruler, and themes.
- Apple Books-style reader themes plus accessibility-oriented font and contrast options.
- Native Writing Tools protection around Markdown regions such as fenced code and front matter.
- Local release/help resources bundled in the app.
- SF Symbol icons on every main-menu row, matching Apple's iconed menus on macOS 26.

Deep reference lives in `docs/architecture/` — verbatim, not summarized. **Read the file for an area
before changing anything in it**; each one records decisions that were paid for in regressions.

| Area | File |
|---|---|
| Multi-document tabs, window/nav chrome, background-tab safety | `docs/architecture/tabs-and-windows.md` |
| Files sidebar: scanning, watching, virtualization, file ops, visuals | `docs/architecture/files-sidebar.md` |
| Read/Preview rendering: blocks, mermaid, math, code, callouts, images | `docs/architecture/rendering.md` |
| Save As, Export As, HTML/PDF/RTF export, print, typography presets | `docs/architecture/export-and-print.md` |
| Find & Replace, cross-file search, ⌘K quick open | `docs/architecture/search.md` |
| Live reload, scoped highlighting, save-state, view modes, speech | `docs/architecture/editor-behavior.md` |
| Settings, updates, CLI, App Intents, Quick Look, app identity | `docs/architecture/app-integration.md` |

## Load-Bearing Invariants

Break one of these and something regresses that tests may not catch. Each was a real defect; the
file named after it carries the full story and the reasoning.

**Windows, tabs, and chrome** (`tabs-and-windows.md`)
- The tab bar lives INSIDE `editorShell`, in the VStack the reading inspector attaches to. Moving it above breaks the drawer's geometry and the toolbar tint.
- Never lay out a full-width bar at the top of window content — the translucent toolbar samples whatever is beneath it, so any such bar visibly recolors the navigation. Float chrome as an overlay card instead.
- `WindowChromeReader.dismantleNSView` must NOT clear the window appearance, and `ChromeView` must re-assert the themed appearance on every `viewDidChangeEffectiveAppearance`.
- `activateSelectedTab` must reconcile a CLEAN incoming tab with disk. Without it, switching to a background tab whose file changed externally shows a stale snapshot and the next keystroke autosaves over the external rewrite (silent data loss).
- Closing a BACKGROUND tab must not re-run `activateSelectedTab` (guard on `wasSelected`) — it would wipe the still-active tab's search state and undo stack.
- `FileIdentity` is the single definition of "already open", shared by tab dedupe, `EditorTabStore.locate`, and the Save As guard. If they disagree, a file slips past dedupe and is then refused at save.
- The toolbar material is hidden with an explicit `Visibility.hidden` — the bare `.hidden` is ambiguous against `ShapeStyle` and TIMES OUT type-checking (build-blocking, not cosmetic).

**Editor motion** (`editor-behavior.md`)
- A NESTED layout-preservation pass must never schedule deferred restores or clear the outer anchor. Doing so reintroduces the live-drag text jump that only reproduces under a real HID drag — every automated test stayed green while users saw it.
- The cross-mode scroll restore must re-assert its target across several runloop ticks and bypass the clip view's transition lock. A single set is silently clobbered by the fresh view's own restore.

**Files sidebar and iCloud** (`files-sidebar.md`)
- Keep the file tree FLAT and LAZY (`visibleFileRows` + `LazyVStack`). Recursive `VStack`/`ForEach` froze large workspaces — the scan was never the bottleneck, view layout was.
- Every sidebar sub-view takes `usesDarkChrome` THREADED from the theme. Reading `@Environment(\.colorScheme)` in a nested control renders invisible text after a tab/inspector transition.
- `directoryRescanDebounceInterval` MUST exceed `DirectoryEventMonitor.coalescingLatency`, or autosave churn hitches typing.
- The expensive iCloud scan runs ONLY when the Files tab appears — never at launch or view construction. Preserve this laziness.
- Never add an iCloud entitlement to Debug: it cannot be satisfied under ad-hoc signing and the test host stops launching (CI red).
- `@Published` didSet observers DO fire for assignments in `OutlineFileBrowserStore.init`, so persisted prefs must load via `Published(initialValue:)` backing storage — a plain assignment runs the init-forbidden iCloud scan.
- Sidebar rename/trash are deliberately UNCOORDINATED. A main-thread `NSFileCoordinator` write against the open document's own presenters can deadlock, and a presenter-observed trash makes `NSDocument` follow the file into the Trash where autosave resurrects it.

**Privacy** (`rendering.md`, `app-integration.md`)
- Remote `http(s)`/`data:` image URLs are NEVER fetched — always a placeholder. The app's network-free invariant is a product promise, not an optimization.
- Spell checking routes through the system `NSSpellChecker` and nothing else — no bundled dictionary, no third-party service, no network-backed suggestions.

**Accessibility** (`app-integration.md`)
- Any window that BLOCKS the app must be operable without a mouse. The first-launch intro was not: a `.borderless` `NSWindow` cannot become key (so no key event reaches it) and its hand-drawn button had no AX identity — first launch was a dead end for VoiceOver, keyboard-only, and Switch Control users.
- Never put SwiftUI accessibility modifiers on `MarkdownTextViewRepresentable`. The `NSTextView` under it already carries label/role/help, and a text area's AX VALUE is its text — overriding it with a search summary replaces what the user is reading. Announce transient status instead.
- An affordance drawn as geometry and activated by hit-testing exists for assistive tech only via `accessibilityCustomActions` (Read-mode copy/Reconnect/checkbox) or `.accessibilityActions` (sidebar rows). Adding one means adding its mirror.

**Editor** (`editor-behavior.md`)
- `MarkdownRangeAnalyzer` must stay strictly LINE-LOCAL. Visible-window-scoped highlighting is only correct because of it; a cross-line construct silently breaks scoping.
- Only real writes flash "Saved"/"Autosaved". Load and external reload call `markSaved`, never `recordWrite`.
- The spell-check path must never call `MarkdownWritingToolsProtection.ignoredRanges` or `MarkdownRangeAnalyzer.ranges(in:)` — both are whole-document (18 ms at 730 KB) and it runs as the user types. Use `MarkdownSpellCheckRegions`, guarded by `MarkdownSpellCheckPerformanceTests`; that test runs in Debug, which measures ~3.6× slower than the build that ships.
- SwiftUI builds NO Spelling and Grammar menu and this app replaces the Edit menu, so the submenu in `AppCommands` is the only off switch; `menu(for:)` likewise replaces AppKit's context menu, so spelling guesses/Learn/Ignore only exist because they are added there by hand. Deleting either strands the feature with no way to control it.
- Keyboard intercepts in the text view hook `insertNewline`/`insertTab`/`insertBacktab`/`doCommandBy`, NEVER `keyDown` — `keyDown` fires before input-method handling and swallows Return during IME composition. Per-keystroke edits must use the localized `replaceCharacters` path, never `applyWholeTextReplacement` (it rewrites the whole document), and must not force a synchronous re-highlight (`didChangeText` already schedules the debounced one).
- `MarkdownHeadingEditing` must NOT detect headings with `MarkdownHeadingParser.heading(in:)`. That parser requires a non-empty title, so it reports `nil` for `"## "` and the line is then treated as prose and given a second marker — the `# ## Section` stacking bug, which produces a line the outline sidebar cannot see. It must also never call `isInsideCodeOrFrontMatter` per line: that rescans from the document start, making Select All + a heading key quadratic.
- `MarkdownFormattingCommand.apply` must align its incoming selection to composed-character boundaries first. Its edits convert through `Range(_:in:)`, which returns `nil` when a selection splits an emoji or a combining mark — the edit was then skipped while the command still returned the selection it *would* have produced, and `setSelectedRange` raises on that. Align at the entry point, not per edit site.
- Table Reformat pads by APPENDING spaces, never `String.padding(toLength:)` — that measures in UTF-16 while the widths measure in Characters, so it silently truncated emoji and decomposed-accent cells and wrote the loss to disk.
- `MarkdownHeadingEditing.classify` and `MarkdownHeadingParser` must accept the SAME heading shape (≤3 columns of indent; space, tab, or end of line after the hashes). A disagreement is the stacking bug from the other side.
- Table Reformat must REFUSE on `\|` and on backticks. It rewrites the file through `MarkdownTableParser.cells(in:)`, which splits on every pipe — harmless while rendering, permanent data loss when written back. It must also re-emit delimiter colons read from the ORIGINAL row, not from `table.alignments`, which collapses `:--` into `---`.

**Rendering** (`rendering.md`)
- Every INSERTION path (Return, list continuation, Insert Table, Tab's appended row, Reformat, image drop/paste) writes `MarkdownLineEnding.inForce(at:in:)`, never a bare `\n` — the document's endings are preserved, never normalised. It reads the caret's own line, never the whole document (per-keystroke). `ImageInsertionText` was outside this sweep and left a lone LF in Windows-authored files.
- Anything tracking fenced-code state across lines uses `MermaidFence.openingMarker`/`isClosingFence` (same delimiter character, closing run at least as long) — never a flag toggled on "starts with ``` or ~~~". A toggle disagrees with the renderer on any note *about* Markdown: it closed on an inner fence, so `MarkdownOutlineParser` listed headings that only exist inside code AND dropped every real heading after them.
- Code reading RAW document text (where offsets matter and `markdownSourceLines` can't be used) trims with `markdownLineTrimCharacters` = whitespace + `\r`. `MarkdownWritingToolsProtection` must apply it in BOTH the whole-document passes and the scoped `isWhitespace` walk, which have to stay in agreement. Never split Markdown on `CharacterSet.newlines` — it splits `\r` and `\n` separately, so every CRLF yields an empty line (this doubled the document in Convert to Plain Text).
- `markdownSourceLines(in:)` is the ONE splitter every renderer uses. It strips a CRLF file's `\r` (without it no code fence ever closes and the document collapses into one code block) while reporting each line's range in the ORIGINAL text (the stripped `\r` still occupies a UTF-16 unit, so recomputed offsets drift and misaim checkbox toggle, Reconnect, copy, and scroll restore). Never fix CRLF by normalising the document text — that rewrites the user's file.
- The mermaid orientation flip and the supported-type routing are coupled to the pinned BeautifulMermaid version. Re-check both if the pin moves, or diagrams render upside down or as garbage flowcharts.
- Math images must stay CGImage-backed, or block math exports upside down in PDFs.
- `MarkdownInlineSyntax` is the ONE emphasis definition — screen, HTML export, read-aloud, and Convert to Plain Text all read it. Underscore emphasis must NEVER fire inside a word (`make_test_file` rendered as "maketestfile", everywhere, including the file that conversion rewrites) and asterisk emphasis must never fire when flanked by spaces (`2 * 3`). `__bold__` stays unsupported on purpose: in prose it is nearly always a dunder. The Quick Look appex mirrors these by hand — it cannot import the file — including an `.image` pattern ordered BEFORE `.link`, or the link rule claims an image's `[alt](path)` and strands the `!` in the Finder preview.

**Export** (`export-and-print.md`)
- `com.apple.security.print` must stay in BOTH entitlements files or printing fails outright.
- Save As → Markdown must drive `NSDocument.save(to:ofType:for:.saveAsOperation)`. A raw `Data.write` leaves the in-app document detached from the file.
- HTML export drops `javascript:`/`vbscript:`/`data:text/html` LINK destinations (text still renders). That is a closed set of executable schemes, not a URL policy — never grow it into a sanitizer, and leave image `src` alone (`data:image` is legitimate).
- HTML export is ONE-TO-ONE with the source: image paths, link URLs, and remote URLs are emitted exactly as written — never resolved, rewritten, or inlined. Only generated math/mermaid images embed. Special cases accumulating here mean a non-one-to-one default crept back in.
- PDF export must go through `writePDFAtomically`. `NSPrintOperation` writes straight into its target, so a direct write truncates the file being overwritten.

**Build config and app shell** (`app-integration.md`)
- `AppIntents.framework` must stay LINKED in the app target's Frameworks phase. `import AppIntents` alone is not enough: without the link no `Metadata.appintents` is emitted and the Shortcuts/Spotlight/Siri actions silently never register. **This already shipped broken once.** Verify `Contents/Resources/Metadata.appintents` exists after any build-config change.
- EVERY nested bundle must be re-signed with Developer ID in `packaging/build-release.sh` — Xcode signs them with the Apple Development cert and the notary rejects the whole archive ("binary is not signed with a valid Developer ID certificate"). Adding an app extension or embedded binary means adding it to that re-sign list; the Quick Look appex needs `--entitlements LineformQuickLook/LineformQuickLook.entitlements` because it keeps its own sandbox. This failed notarization once for 1.3.0.
- Main-menu icons must be applied to the menu that POSTS the notification, never by walking `NSApp.mainMenu` on a tracking hook. SwiftUI builds `CommandMenu` replacements DETACHED and swaps them in, so the walk decorates the outgoing menu while the bare one is drawn. `didAddItem` is not enough on its own: SwiftUI updates a `CommandMenu`'s EXISTING items in place when it opens, clearing `image` with no insertion to observe, which is why `didChangeItem` is observed too — the `isDecorating` guard is what keeps our own `image` writes from feeding back.
- Releases must build from a CLEAN `Release/Lineform.app`. `Contents/Helpers/lineform` is written after `xcodebuild`, so a leftover copy from a previous run makes the next build's CodeSign step fail with "code object is not signed at all".

**Verification**
- The two test plans' quarantine lists must stay in lockstep (`TestPlanGuardTests`).
- Never construct an `NSWindow` in the DEFAULT test plan — it crashes the test host. Window-hosting tests belong in `LineformHosted`.
- When QA'ing a build by hand, open files with `open -a "$BUILT_PRODUCTS_DIR/Lineform.app" file.md`. A bare `open file.md` hands the file to whatever Lineform Launch Services prefers — usually an installed release — and reads exactly like your fix failing.
- Do not set `applicationIconImage` at runtime.

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

`docs/architecture/` mirrors these areas in prose. It is the long-form half of this file: the same
load-bearing detail, moved out so this one stays scannable and cheap to load every session. When you
touch an area, read its file first and update it in the same change — that is where new decisions,
rejected alternatives, and "do not retry this" notes belong. Keep only rules that apply *always* in
this file.

## iCloud Storage

The Files sidebar's iCloud root is an app-owned iCloud Drive container (`NSUbiquitousContainers`,
public document scope), owned by `OutlineFileBrowserStore`. Two rules are load-bearing and listed
above; the rest — Debug/Release entitlement split, dimmed-vs-hidden root states, `ensureDownloaded`
materialization, purge protection — is in `docs/architecture/files-sidebar.md`.

App-owned containers are still subject to iCloud purge when macOS believes the app was uninstalled.
The durable protections are operational, not code: ship updates via Sparkle's atomic in-place swap
(never instruct users to delete the old app and drag a new one), and do not run-then-delete locally
built Release/Export copies of `com.lineform.app` while signed into the production iCloud account.

## Release Verification Gates (do not weaken)

Two production incidents on 2026-07-02 shipped despite green tests, valid codesign,
notarization, and Gatekeeper — see `docs/postmortems/2026-07-02-launch-brick-and-file-access.md`
before touching signing, certificates, provisioning profiles, or sandbox/bookmark code.
The short rules:

- The signing cert MUST be embedded in the app's provisioning profile. A mismatch passes
  every static check but AMFI SIGKILLs the app at launch on every machine (this shipped
  as 1.1.0 build 14). `packaging/build-release.sh` hard-fails on this (exit 68) and also
  launch-tests the packaged app (exit 69) — never remove these gates. After any cert
  change, regenerate the Direct profile (headless: `xcodebuild archive` + `-exportArchive`,
  method `developer-id`, `-allowProvisioningUpdates`) before releasing.
- Run `packaging/verify-update.sh` after generating the appcast and before publishing:
  it verifies the Sparkle EdDSA key pair, the appcast signature against the exact stapled
  DMG bytes, and that every delta reconstructs a launchable new build. Regenerate the
  appcast AFTER `stapler staple` (stapling changes the DMG bytes).
- `generate_appcast` rewrites every entry's URL with one prefix; hand-merge only the new
  top item into `docs/appcast.xml` so old versions keep their per-tag URLs.
- "It launches" is not "it works": before calling a release done, open a real document
  from a workspace folder after a relaunch (the sandbox-bookmark path; a same-session
  NSOpenPanel grant hides bookmark bugs). The workspace security scope is HELD by
  `OutlineFileBrowserStore` for its lifetime — never revert to transient
  start/stopAccessingSecurityScopedResource around the directory scan (that was the
  1.1.1 file-access bug).

## Verification Commands

Two test plans (`Lineform.xctestplan`, `LineformHosted.xctestplan`). The split exists because a few
tests host a real `NSWindow` + `NSHostingView`: load-sensitive and prone to test-host crashes.
Background, failure modes, and the "is this a real regression or machine state?" recipe:
`docs/notes/hosted-test-plan.md`.

**Default gate — the everyday command** (~1100 tests, seconds, crash-free; what CI and ⌘U run):

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

**Hosted plan — opt-in**, before releases touching editor motion, drawer/inspector presentation,
reload scroll behavior, or PDF export/print. Add `-testPlan LineformHosted`. **Quit Xcode first**:
these measure sub-second animations and fail spuriously under load.

- Keep `-parallel-testing-enabled NO`: AppKit state contaminates across parallel runners.
- No signing flags needed — Debug ships no iCloud entitlement, so the host signs ad-hoc.
- Do not weaken, delete, or fold the hosted tests back into the default plan. Their placement was the
  problem, not their existence.
- A hosted failure on a busy or long-uptime machine is usually machine state. Re-run the same test at
  a known-good commit before calling it a regression.
- TCC caveat for ANY CLI test run: the re-signed host can prompt for Documents access and block the
  run. Warn the user first; never run the suite unattended and assume it finished.

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
- Use this file for AI coding agent context and repo operating rules — product context, invariants, verification, and policy. It is loaded in full every session, so keep it lean.
- Use `docs/architecture/*.md` for per-area implementation detail. New feature narrative goes there, not here; add at most a one-line feature entry and, if the change creates a rule that can never be broken, one line under Load-Bearing Invariants.
- Use `docs/release/github-sparkle-release.md` for GitHub Releases, DMG packaging, and Sparkle appcast steps.
- Use `Lineform/Resources/*.md` for user-facing bundled app/help/release docs.

## PR / Marketing / Positioning Reference

For any PR, marketing, positioning, audience, or public-copy question ("how do I describe Lineform," "who is it for," "what's the one-liner," "is this claim safe to publish"), consult `POSITIONING_AND_MARKETING.md` at the repo root. It holds the verified positioning, target audience, plain-language feature list, differentiation vs. competitors, honesty constraints, launch-surface copy (Show HN / X / App Store / website), and a fact sheet (version, platform, license, privacy).

- It is a **local, untracked** working doc (in `.gitignore`) — it does not get committed or auto-updated by release tooling, so treat its facts as a dated snapshot. Its verification stamp names the app version it was checked against; if a question turns on a specific capability and the build has moved on, re-verify against the current code before making any public claim. Never publish a capability the shipped build can't demonstrate.
- Load-bearing rules from that doc: say "free" and "source-available" (never "open source" — PolyForm Shield 1.0.0); "No AI inside" is accurate and intentional; the CLI/stdin helper exists only in the released build after a one-time install; and only Atkinson Hyperlegible + OpenDyslexic are bundled fonts.

Keep this file current when major features, architecture, or verification gates change.
