# Lineform Agent Guide

This file is for AI coding agents working in the Lineform repo. Read it before making changes. It explains what the app is, what quality means here, and how to verify work.

## Product Context

Lineform is a free native macOS Markdown editor for calm writing, real local files, and readable long-form text. V1.0 is the first public version of the app. The app should feel quiet, native, file-based, and trustworthy. It is not a web editor, not a note-taking database, and not a cloud writing service.

Public-facing links:

- Product website: `https://lineform.app`
- GitHub repo: `https://github.com/carlostarrats/Lineform`
- Distribution: the **Mac App Store, and nothing else**. The app has no self-updater, alternate
  package, command-line helper, or helper installer. Do not add a second distribution path.
  Runbook: `docs/release/app-store-release.md`.

Core product principles:

- Real files: documents are plain UTF-8 Markdown or text files that remain portable across Finder, iCloud Drive, Git, and other editors.
- Native autosave: existing files use macOS document autosave and are written to their real `.md`, `.markdown`, or `.txt` file as the user writes. Untitled documents still need a user-chosen save location before they can become real files.
- Local-first privacy: there is no account system, no analytics by default, and no document upload.
- Native macOS behavior: prefer SwiftUI, AppKit, TextKit, document-based app patterns, system controls, and platform conventions.
- Calm writing: UI should reduce noise and support long drafting/review sessions.

## Main Features

- Document-based macOS app for Markdown and plain text files.
- Native macOS autosave for existing files, with Save/Save As still available and untitled files prompting for a destination when needed.
- Opening Lineform with no document creates a normal untitled editor window. File ▸ Open replaces only a pristine untitled tab; otherwise it adds the selected file as a tab in the current window.
- After a person has used a Markdown document, Lineform can make itself the default app for `.md` and `.markdown` files through a one-time invitation or the durable Settings action.
- Files selected from the left Files sidebar switch the CURRENT TAB in place, Apple Notes-style — browsing a workspace does not accumulate tabs. ⌘-click, or the row's context menu, opens in a new tab or a new window instead. A tab holding unsaved work prompts (Save / Cancel / Don't Save) before it is replaced; in practice that is mostly untitled documents, since existing files are already autosaved by the document system — so do not describe the prompt as a guaranteed step before every navigation.
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
- In-app announcements: a once-a-day read of a small static JSON file on the marketing site surfaces at most one dismissible card in the editor. No account, no identifier, no server. The Settings toggle (default on) gates the network request itself, not just the display.
- Local release/help resources bundled in the app.
- SF Symbol icons on every main-menu row, matching Apple's iconed menus on macOS 26.
- Localized interface: Spanish, French, German, Japanese, and Simplified Chinese — app chrome only, including the sidebar's Markdown Basics prose; text that renders document content stays in the document's language. Read-aloud picks its voice from the document's detected language rather than the interface's.

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
| Settings, App Intents, Quick Look, app identity, distribution | `docs/architecture/app-integration.md` |

## Load-Bearing Invariants

Break one of these and something regresses that tests may not catch. Each was a real defect; the
file named after it carries the full story and the reasoning.

**Windows, tabs, and chrome** (`tabs-and-windows.md`)
- The tab bar lives INSIDE `editorShell`, in the VStack the reading inspector attaches to. Moving it above breaks the drawer's geometry and the toolbar tint.
- Never lay out a full-width bar at the top of window content — the translucent toolbar samples whatever is beneath it, so any such bar visibly recolors the navigation. Float chrome as an overlay card instead.
- `WindowChromeReader.dismantleNSView` must NOT clear the window appearance, and `ChromeView` must re-assert the themed appearance on every `viewDidChangeEffectiveAppearance`.
- The sidebar toggle is OWNED (`SidebarToggleReplacement`), never `NavigationSplitView`'s automatic one: that item resolves its ink at WINDOW CREATION and never re-resolves, so a window born dark keeps a white glyph on light themes (and the mirror). It is NOT `window.appearance` drift — every appearance layer reads correct while the glyph is wrong. Its flexible space (trailing edge), the tracking separator (stays pinned while the sidebar resizes), and sending AppKit's `toggleSidebar:` (the sidebar ANIMATES) are all load-bearing.
- `activateSelectedTab` must reconcile a CLEAN incoming tab with disk. Without it, switching to a background tab whose file changed externally shows a stale snapshot and the next keystroke autosaves over the external rewrite (silent data loss).
- Closing a BACKGROUND tab must not re-run `activateSelectedTab` (guard on `wasSelected`) — it would wipe the still-active tab's search state and undo stack.
- `FileIdentity` is the single definition of "already open", shared by tab dedupe, `EditorTabStore.locate`, and the Save As guard. If they disagree, a file slips past dedupe and is then refused at save.
- "Does this tab hold unsaved work" is `DocumentTab.hasUnsavedWork` and nothing else — the tab-bar dot included. `DocumentSaveStatus.isDirty` alone omits the `fileURL == nil && !text.isEmpty` branch, so an untitled tab with typed content and a tab whose file was trashed from the sidebar (which nils its `fileURL`) drew NO dot while holding the only copy of their content.
- The Save-All-before-close chain must write each saved tab's new `fileURL` back to the store BEFORE activating the next tab, which clobbers `backingDocument.fileURL`. Without it a tab that was untitled at save time stays `fileURL == nil`: the close alert re-prompts, a second save panel writes a duplicate copy, and the tab is detached from its file for the rest of the session.
- Save All must start after `windowShouldClose` returns, and save callbacks must unwind before the next tab is activated/saved or the window closes; re-entering AppKit's document serialization from either callback deadlocks. Save-and-close must use the existing `performCloseTab` scene-dismissal path.
- File ▸ Open must keep the system menu item and native `NSDocumentController.beginOpenPanel`, then route authorized URLs through `openSidebarFile`; sending ⌘O through `DocumentGroup` creates a transient second window instead of a tab-native open.
- Closing the final tab must leave it in `EditorTabStore`, call `WindowCloseController.prepareForTabApprovedClose`, and dismiss the `DocumentGroup` scene. Removing the tab first destroys state needed by the native close and can leave an empty window that ignores ⌘W.
- The toolbar material is hidden with an explicit `Visibility.hidden` — the bare `.hidden` is ambiguous against `ShapeStyle` and TIMES OUT type-checking (build-blocking, not cosmetic).

**Editor motion** (`editor-behavior.md`)
- A NESTED layout-preservation pass must never schedule deferred restores or clear the outer anchor. Doing so reintroduces the live-drag text jump that only reproduces under a real HID drag — every automated test stayed green while users saw it.
- The cross-mode scroll restore must re-assert its target across several runloop ticks and bypass the clip view's transition lock. A single set is silently clobbered by the fresh view's own restore.

**Files sidebar and iCloud** (`files-sidebar.md`)
- Keep the file tree FLAT and LAZY (`visibleFileRows` + `LazyVStack`). Recursive `VStack`/`ForEach` froze large workspaces — the scan was never the bottleneck, view layout was.
- Every sidebar sub-view takes `usesDarkChrome` THREADED from the theme. Reading `@Environment(\.colorScheme)` in a nested control renders invisible text after a tab/inspector transition. A dynamic `NSColor` (the selection grey and its blue label) is the same rule for AppKit: resolve it inside `performAsCurrentDrawingAppearance` for that appearance, or it silently follows the SYSTEM light/dark instead of the theme.
- `directoryRescanDebounceInterval` MUST exceed `DirectoryEventMonitor.coalescingLatency`, or autosave churn hitches typing.
- EVERY write to `workspaceURL` must call `retargetWorkspaceWatcher()`. `DirectoryEventMonitor` binds FSEvents to a path string with no `kFSEventStreamCreateFlagWatchRoot`, so a stream on a moved or renamed folder is silently dead — `setWorkspaceURL` retargeted and the bookmark-re-resolution branch did not, so renaming the workspace in Finder killed live refresh for the session while the tree still looked correct.
- Toggling Show Hidden Folders OFF must RE-SCAN a live root, for the same reason a sort change does: the 80-per-folder cap is applied in display order, BEFORE hidden filtering, so a hidden-inclusive scan is not a superset. Filtering it in memory deleted ordinary Markdown files from the tree. In-memory filtering is only for the cached/disconnected fallbacks, where no scan is possible.
- The expensive iCloud scan runs ONLY when the Files tab appears — never at launch or view construction. Preserve this laziness.
- Never add an iCloud entitlement to Debug: it cannot be satisfied under ad-hoc signing and the test host stops launching (CI red).
- `@Published` didSet observers DO fire for assignments in `OutlineFileBrowserStore.init`, so persisted prefs must load via `Published(initialValue:)` backing storage — a plain assignment runs the init-forbidden iCloud scan.
- Sidebar rename/trash are deliberately UNCOORDINATED. A main-thread `NSFileCoordinator` write against the open document's own presenters can deadlock, and a presenter-observed trash makes `NSDocument` follow the file into the Trash where autosave resurrects it.
- The workspace chooser stays a native, asynchronous `NSOpenPanel` sheet attached to the key Lineform document window, with Lineform-specific title/message copy. Do not return to detached `runModal()` presentation or perform a scan before the user accepts a folder.

**Privacy** (`rendering.md`, `app-integration.md`)
- Remote `http(s)`/`data:` image URLs are NEVER fetched — always a placeholder. The app's network-free invariant is a product promise, not an optimization.
- Spell checking routes through the system `NSSpellChecker` and nothing else — no bundled dictionary, no third-party service, no network-backed suggestions.
- The announcements setting gates the REQUEST, not the display: `AnnouncementStore.checkIfNeeded(isEnabled:)` must return before the fetcher is touched, so "off" means no outbound call at all. The feed is remote input and is treated as hostile — single-scheme (`https`) allowlist for links, control characters and over-length strings REJECTED rather than stripped, byte ceiling enforced as bytes arrive (never from `expectedContentLength`), and title/body rendered as plain `Text`, never Markdown or HTML. Dismissed ids are never pruned against the live feed, or an announcement the user dismissed eventually comes back. `AnnouncementFetching.fetch` must keep nil (the check LEARNED NOTHING) distinct from [] (read fine, publisher shows nothing): nil leaves the cache and the screen alone, [] retracts. Collapsing them lets one offline launch or one malformed deploy pull a live announcement off every screen. The throttle gates the NETWORK CALL only — `visible` is restored from the cached feed in `init`, or an undismissed card vanishes for a day after relaunch — and `AnnouncementFeed.encode`/`decode` are one wire format written twice, so they must round-trip (asserted at maximum feed size).

**Accessibility** (`app-integration.md`)
- Every reader ink goes through `Theme.readableInk` (AA against the page). The two that did not were the two that were never theme-derived: link/image text used the system `NSColor.linkColor` (3.70:1 on Quiet) and the diagram/math fallback caption used a flat 0.6 alpha (below AA on four of five themes, at a size SMALLER than body text). `Theme.contrastRatio` is the one definition, in production, so a test cannot assert a rule the app does not use.
- Any window that BLOCKS the app must be operable without a mouse. The first-launch intro was not: a `.borderless` `NSWindow` cannot become key (so no key event reaches it) and its hand-drawn button had no AX identity — first launch was a dead end for VoiceOver, keyboard-only, and Switch Control users.
- Never put SwiftUI accessibility modifiers on `MarkdownTextViewRepresentable`. The `NSTextView` under it already carries label/role/help, and a text area's AX VALUE is its text — overriding it with a search summary replaces what the user is reading. Announce transient status instead.
- An affordance drawn as geometry and activated by hit-testing exists for assistive tech only via `accessibilityCustomActions` (Read-mode copy/Reconnect/checkbox) or `.accessibilityActions` (sidebar rows). Adding one means adding its mirror.

**Editor** (`editor-behavior.md`)
- `MarkdownRangeAnalyzer` must stay strictly LINE-LOCAL. Visible-window-scoped highlighting is only correct because of it; a cross-line construct silently breaks scoping.
- Only real writes flash "Saved"/"Autosaved". Load and external reload call `markSaved`, never `recordWrite`.
- App-review ENGAGEMENT is stricter than the save-status flash: `fileWrapper(configuration:)` only serialized a candidate. Count engagement from a successful `NSDocument` completion or an exact file-presenter readback, never directly from `DocumentSaveStatus.recordWrite`, because the later safe write can still fail.
- `LineformDocument.data(for:)` and `recordsSourceSave(for:)` MUST both derive from `writesSourceVerbatim(for:)`. Written separately they disagreed for a `.md` document left in `.plainText` by Convert to Plain Text: that write emitted the source verbatim yet recorded nothing, so the status bar stuck on amber, the dirty hash froze, and `lastSyncedText` stopped updating — which disables live reload AND the background-tab disk reconcile.
- Decode document bytes by VALIDATING with `String(data:encoding:.utf8)` and then decoding with `String(decoding:as:)`. The validating initializer also strips a leading U+FEFF on Darwin, so the BOM never reached `text`, could not be re-emitted, and the first write silently rewrote the head of every Notepad-authored file. The loader and `FileSystemDiskReader` must use the same pair.
- Stat for live reload through `FileManager.attributesOfItem`, NEVER `url.resourceValues(forKeys:)`. `URL` caches resource values per instance and the reload controller re-uses one `URL`, so the modification date froze and live reload fired at most once per file — every later external rewrite produced no reload while the editor kept showing, and autosaving, the stale snapshot.
- The spell-check path must never call `MarkdownWritingToolsProtection.ignoredRanges` or `MarkdownRangeAnalyzer.ranges(in:)` — both are whole-document (18 ms at 730 KB) and it runs as the user types. Use `MarkdownSpellCheckRegions`, guarded by `MarkdownSpellCheckPerformanceTests`; that test runs in Debug, which measures ~3.6× slower than the build that ships.
- `LineformAppNotification.activeWindowPayload` casts to `LineformTextView`, NEVER the general `NSTextView`. Its `selectedRange` is used to substring `document.text` (read aloud, Convert to Plain Text), and the wide cast also matched a search field's FIELD EDITOR and the Split preview pane — whose ranges are in rendered coordinates, the thing the `.read` guard exists to prevent but could not catch for `.split`.
- `speechController.stop()` belongs in `resetTransientDocumentState()`, the choke point every document swap goes through. Wired only to `willCloseNotification`, read-aloud kept reading the PREVIOUS document after a tab switch or sidebar selection, with Pause/Stop acting on a document no longer on screen.
- Never infer cancel-vs-finish from which `AVSpeechSynthesizer` delegate method fires. A stopped utterance reports `didFinish`, not `didCancel` — `SystemSpeechSynthesizer` filters by utterance identity. `FakeSynthesizer` must model the SHIPPING behaviour (stop delivers finish; pause is deferred to a word boundary) or it certifies the bug instead of catching it.
- Read-aloud must NEVER set `utterance.voice` when the detected document language agrees with `AVSpeechSynthesisVoice.currentLanguageCode()` — nil voice IS the user's Spoken Content selection, and `AVSpeechSynthesisVoice(language:)` picks an arbitrary region (`fr` → fr-CA with fr-FR installed, `en` → en-US), so overriding on agreement forced every en-GB/en-AU user onto Samantha. `SpeechVoiceResolver` owns that decision and prefers an installed region-matched voice by identifier; its zh script inference (region → Hans/Hant) is what keeps a Traditional document off a Simplified voice.
- SwiftUI builds NO Spelling and Grammar menu and this app replaces the Edit menu, so the submenu in `AppCommands` is the only off switch; `menu(for:)` likewise replaces AppKit's context menu, so spelling guesses/Learn/Ignore only exist because they are added there by hand. Deleting either strands the feature with no way to control it.
- Keyboard intercepts in the text view hook `insertNewline`/`insertTab`/`insertBacktab`/`doCommandBy`, NEVER `keyDown` — `keyDown` fires before input-method handling and swallows Return during IME composition. Per-keystroke edits must use the localized `replaceCharacters` path, never `applyWholeTextReplacement` (it rewrites the whole document), and must not force a synchronous re-highlight (`didChangeText` already schedules the debounced one).
- `MarkdownHeadingEditing` must NOT detect headings with `MarkdownHeadingParser.heading(in:)`. That parser requires a non-empty title, so it reports `nil` for `"## "` and the line is then treated as prose and given a second marker — the `# ## Section` stacking bug, which produces a line the outline sidebar cannot see. It must also never call `isInsideCodeOrFrontMatter` per line: that rescans from the document start, making Select All + a heading key quadratic.
- `MarkdownFormattingCommand.apply` must align its incoming selection to composed-character boundaries first. Its edits convert through `Range(_:in:)`, which returns `nil` when a selection splits an emoji or a combining mark — the edit was then skipped while the command still returned the selection it *would* have produced, and `setSelectedRange` raises on that. Align at the entry point, not per edit site.
- Table Reformat pads by APPENDING spaces, never `String.padding(toLength:)` — that measures in UTF-16 while the widths measure in Characters, so it silently truncated emoji and decomposed-accent cells and wrote the loss to disk.
- `MarkdownHeadingEditing.classify` and `MarkdownHeadingParser` must accept the SAME heading shape (≤3 columns of indent; space, tab, or end of line after the hashes). A disagreement is the stacking bug from the other side.
- Ordered-list continuation must cap the marker at NINE ASCII digits, matching `MarkdownBlockGrouping`'s `[0-9]{1,9}`. Unbounded, `Int.max` overflowed `number + 1` and Return on that line CRASHED the app, and a 10-digit marker drew as a paragraph while Return continued it as a list.
- Table Reformat must REFUSE on `\|` and on backticks. It rewrites the file through `MarkdownTableParser.cells(in:)`, which splits on every pipe — harmless while rendering, permanent data loss when written back. It must also re-emit delimiter colons read from the ORIGINAL row, not from `table.alignments`, which collapses `:--` into `---`.

**Rendering** (`rendering.md`)
- Every INSERTION path (Return, list continuation, Insert Table, Tab's appended row, Reformat, image drop/paste) writes `MarkdownLineEnding.inForce(at:in:)`, never a bare `\n` — the document's endings are preserved, never normalised. It reads the caret's own line, never the whole document (per-keystroke). `ImageInsertionText` was outside this sweep and left a lone LF in Windows-authored files.
- Anything tracking fenced-code state across lines uses `MermaidFence.openingMarker`/`isClosingFence` (same delimiter character, closing run at least as long) — never a flag toggled on "starts with ``` or ~~~". A toggle disagrees with the renderer on any note *about* Markdown: it closed on an inner fence, so `MarkdownOutlineParser` listed headings that only exist inside code AND dropped every real heading after them.
- Code reading RAW document text (where offsets matter and `markdownSourceLines` can't be used) trims with `markdownLineTrimCharacters` = whitespace + `\r` + U+FEFF. `MarkdownWritingToolsProtection` must apply it in BOTH the whole-document passes and the scoped `isWhitespace` walk, which have to stay in agreement. Never split Markdown on `CharacterSet.newlines` — it splits `\r` and `\n` separately, so every CRLF yields an empty line (this doubled the document in Convert to Plain Text).
- `markdownSourceLines(in:)` is the ONE splitter every renderer uses. It strips a CRLF file's `\r` (without it no code fence ever closes and the document collapses into one code block) while reporting each line's range in the ORIGINAL text (the stripped `\r` still occupies a UTF-16 unit, so recomputed offsets drift and misaim checkbox toggle, Reconnect, copy, and scroll restore). Never fix CRLF by normalising the document text — that rewrites the user's file.
- A leading UTF-8 BOM is stripped like the `\r` — but it PRECEDES the line's text, so `markdownSourceLines` moves the range's `location` past it rather than only growing its length. `MarkdownHeadingParser`, `MarkdownHeadingEditing.classify`, `LinePrefix`, and `frontMatterRange` skip it too: had only the reader learned about it, ⌘1 on a BOM'd heading would stack a second marker. Never strip it from the document text.
- `MarkdownRangeAnalyzer` is the FOURTH implementation of code spans and links (with the renderer, the HTML emitter, and the appex) and must carry the same `(?<!\\)` and BOM handling. Without them the editor coloured escaped text as code — which also switched live spell checking OFF over prose, since `MarkdownSpellCheckRegions` suppresses those kinds.
- Anything comparing against a line-anchored construct in RAW document text splits on `"\n"` only. `NSString.getLineStart` also breaks on a lone `\r`, U+2028 and U+0085, so `isInsideCodeOrFrontMatter` saw line boundaries the renderer does not and reported "inside code" for prose.
- The mermaid orientation flip and the supported-type routing are coupled to the pinned BeautifulMermaid version. Re-check both if the pin moves, or diagrams render upside down or as garbage flowcharts. `uprightForMacOS` returns nil rather than the un-flipped image when its context allocation fails — handing back the input would put a MIRRORED diagram on screen.
- `MermaidSource` is the ONE definition of "what part of a mermaid block is the diagram". Front matter must be stripped AT THE SEAM before BeautifulMermaid, which reads `---` as the first line and throws. The classifier looked past front matter while the library did not, so a valid `title:`-prefixed diagram took the `.failed` path: no diagram, and 2,000 characters of the user's document written to the on-disk log — the path reserved for genuine library bugs.
- A number parsed out of document text must be BOUNDED before any `Int` conversion. This is the ordered-list `Int.max` rule generalized: `MermaidPieChart` accepted any positive `Double`, and the legend's `String(Int(v))` trapped on `inf` and on any value above `Double(Int.max)` — a hard crash in Read, Split, Export, and Print.
- A source range recorded for a rendered block takes BOTH endpoints from `lineRanges`, never a length recomputed from the rendered body. The body is joined from CR-stripped lines while `lineRanges` measures the original text, so on a CRLF file the code-block copy pill put truncated code on the pasteboard, losing one character per body line.
- Math images must stay CGImage-backed, or block math exports upside down in PDFs.
- Convert to Plain Text must leave CODE verbatim: fenced bodies tracked with `MermaidFence`, and the inline strips + `unescape` applied only to the runs BETWEEN code spans. It rewrites and autosaves the user's file, and a whole-document unescape halved every doubled backslash in their code (`r"\\d+"` → `r"\d+"`). Its link/image patterns exclude `\n` for the same reason `MarkdownInlineSyntax` does — without it an unclosed `](` paired with a `)` on a later line and DELETED the line between.
- `LinePrefix` skips a BOM for matching but must NEVER copy it into the continuation; and a list marker requires a following space or tab, matching `MarkdownBlockGrouping`'s `[ \t]+` — accepting a bare `-` made Return ERASE the character the writer just typed.
- `MarkdownInlineSyntax` is the ONE emphasis definition — screen, HTML export, read-aloud, and Convert to Plain Text all read it. Underscore emphasis must NEVER fire inside a word (`make_test_file` rendered as "maketestfile", everywhere, including the file that conversion rewrites) and asterisk emphasis must never fire when flanked by spaces (`2 * 3`). `__bold__` stays unsupported on purpose: in prose it is nearly always a dunder. The Quick Look appex mirrors these by hand — it cannot import the file — including an `.image` pattern ordered BEFORE `.link`, or the link rule claims an image's `[alt](path)` and strands the `!` in the Finder preview.
- Every inline walk that appends plain runs between tokens must `unescape` them — `inlineMarkdown`, `inlineWithMath`, and `MarkdownHTMLRenderer.inlineHTML` are three implementations of one loop, and `inlineWithMath` had the lookbehind without the unescape, so adding one `$x$` to a line turned off escape processing for the whole line.
- Every `MarkdownInlineSyntax` opener carries `(?<!\\)` AND `unescape(_:)` runs on the plain runs between tokens. They are one feature: without the lookbehind `` \`x\` `` opened a code span and ate the backticks; without the unescape, declining to open left a bare `\*` on screen. Never unescape a code span's contents or a link/image DESTINATION.
- A path written into `![](…)` goes through `ImageLinkRewrite.markdownDestination(for:)` — a bare `)` ends the destination, so `photo (1).png` produced a link the app could not parse back. `ImageResolver` resolves the literal path FIRST, then its percent-decoded form (never the other way round).
- NEVER declare a static CJK `.cascadeList`. CoreText's implicit substitution is locale-informed AND metric-compatible with the primary face (it picks optically-sized UI variants, and a bold conversion resolves CJK to a BOLD face on its own); a hardcoded list can only name the taller public families, which made line heights uneven inside one document and re-paginated exports. This was built, measured and removed — `CJKFontFallbackTests` pins the platform behaviour, including uniform mixed-script line heights for the system-derived faces (SF Pro, Monospaced). Non-system families (New York, Helvetica) have their own CJK metrics and were never uniform — that predates this branch and is not a defect to fix.

**Export** (`export-and-print.md`)
- `com.apple.security.print` must stay in BOTH entitlements files or printing fails outright.
- Save As → Markdown must drive `NSDocument.save(to:ofType:for:.saveAsOperation)`. A raw `Data.write` leaves the in-app document detached from the file.
- HTML export drops `javascript:`/`vbscript:`/`data:text/html` LINK destinations (text still renders). That is a closed set of executable schemes, not a URL policy — never grow it into a sanitizer, and leave image `src` alone (`data:image` is legitimate).
- HTML export is ONE-TO-ONE with the source: image paths, link URLs, and remote URLs are emitted exactly as written — never resolved, rewritten, or inlined. Only generated math/mermaid images embed. Special cases accumulating here mean a non-one-to-one default crept back in.
- PDF export must go through `writePDFAtomically`. `NSPrintOperation` writes straight into its target, so a direct write truncates the file being overwritten.

**Build config and app shell** (`app-integration.md`)
- `AppIntents.framework` must stay LINKED in the app target's Frameworks phase. `import AppIntents` alone is not enough: without the link no `Metadata.appintents` is emitted and the Shortcuts/Spotlight/Siri actions silently never register. **This already shipped broken once.** Verify `Contents/Resources/Metadata.appintents` exists after any build-config change.
- No updater, external helper, or unsandboxed nested executable may be added. A `com.apple.security.temporary-exception.*` entitlement is a review flag by itself. `ReleaseResourceTests` asserts the absence of updater metadata and the mach-lookup exception, and asserts `LSApplicationCategoryType` + `ITSAppUsesNonExemptEncryption` are present — submission is rejected without the first.
- Every nested bundle must be signed correctly, and the Quick Look appex keeps its OWN sandbox entitlements. Xcode signs nested bundles from the App Store archive, and **Organizer's Validate App is the gate that catches a wrong or unsandboxed one**. Adding an app extension or embedded binary means re-validating before upload.
- `MainMenuIconDecorator` observes every `NSMenu` in the process (a detached SwiftUI `CommandMenu` has no supermenu to test), so any menu it must not touch carries `MainMenuIconDecorator.excludedMenuIdentifier`. Without it the editor's right-click menu came up wearing main-menu SF Symbols.
- Main-menu icons must be applied to the menu that POSTS the notification, never by walking `NSApp.mainMenu` on a tracking hook. SwiftUI builds `CommandMenu` replacements DETACHED and swaps them in, so the walk decorates the outgoing menu while the bare one is drawn. `didAddItem` is not enough on its own: SwiftUI updates a `CommandMenu`'s EXISTING items in place when it opens, clearing `image` with no insertion to observe, which is why `didChangeItem` is observed too — the `isDecorating` guard is what keeps our own `image` writes from feeding back.
- Cold launch and Dock reopen create an untitled document only when there are no visible windows, no open documents, and no first-launch intro to present. Removing any guard can duplicate a file-open document or cover the intro.
- Changing the default Markdown handler is always an explicit user action through `NSWorkspace.setDefaultApplication`; keep `LSHandlerRank` at `Alternate`, exclude `.txt`, and never add a helper, installer, entitlement, or Finder automation for it. The one-time invitation becomes eligible only on a launch after the first Markdown use; Settings remains the durable action.

**Localization** (`app-integration.md`)
- Text that renders DOCUMENT CONTENT (callout labels, Markdown syntax) is never localized — HTML export is one-to-one with the source and the Quick Look appex mirrors the renderers by hand. Only app chrome localizes.
- UI strings route through `String(localized:)` with the English text as the catalog key. A bare literal at an AppKit call site silently ships English in every other language — nothing fails, it just doesn't translate.
- Never localize an enum `rawValue` — it is persisted identity (UserDefaults, file contents, test fixtures). Add a `title` property instead.
- `MainMenuIconDecorator` resolves its title-keyed icons (all but the four rows exempted in `MainMenuIconDecoratorTests`) by localized menu title, so its runtime language must come from `Bundle.main.preferredLocalizations`, never `Locale.language.languageCode` — the latter collapses `zh-Hans` to `zh`, matching nothing and silently losing every title-keyed icon in Chinese.
- Catalog membership is NOT localization. `Button(someString)` / `.alert(someString,…)` pick SwiftUI's VERBATIM overload, so a `String` constant ships English however complete the catalog is — localize at the DEFINITION site. `LocalizationSourceSweepTests` scans the source for this; its allowlist needs a reason per entry.
- `String(localized:…locale:)` selects a value FORMAT, never an `.lproj`. Per-language assertions resolve through `Bundle(path: "<lang>.lproj")` — which is why `MarkdownReference.sections(in:)` and `Row.accessibilityLabel(in:)` take a bundle at all. The reference's 90-character sidebar ceiling then holds in EVERY language: the column does not get wider in German, so shorten the ENGLISH rather than raise the cap.

- A perf gate's fixture must sit at the WORST case, not a convenient one. `MarkdownSpellCheckPerformanceTests` pinned the caret to the document midpoint while the prefix walk runs from offset 0 to the scope's end — so it measured exactly half the real per-keystroke cost, and the headroom above its floor was half what the numbers claimed.

**Verification**
- The two test plans' quarantine lists must stay in lockstep (`TestPlanGuardTests`).
- Three invariants above are now asserted rather than remembered: the print entitlement in both
  configurations and the emitted `Metadata.appintents` (`ReleaseResourceTests`), and the rescan
  debounce exceeding the FSEvents coalescing latency (`OutlineSidebarViewTests`). Each had already
  shipped broken or could only be caught by hand.
- The repo-wide gates (`LocalizationSourceSweepTests`, `LocalizationCatalogTests`) belong in EVERY scoped `-only-testing` run, not only runs whose feature is localization. Any change that merely ADDS a hard-coded string trips the sweep, so scoping a run to the feature's own suites left that gate red across three tasks undetected.
- Never construct an `NSWindow` in the DEFAULT test plan — it crashes the test host. Window-hosting tests belong in `LineformHosted`.
- The test host IS the app, so `applicationDidFinishLaunching` runs on EVERY `xcodebuild test`. Anything wired there that calls out — network, XPC, a daemon — fires once per test run unless it is guarded by `AnnouncementStore.isRunningUnderTests` (`XCTestConfigurationFilePath`). The announcement check shipped without that guard and made the suite issue a live request to the production feed. Guard at the LAUNCH CALL SITE, never inside the method under test, or the tests for it become silent no-ops that still pass.
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
The durable protections are operational, not code: ship updates through the App Store, which
replaces the app in place (never instruct users to delete the old app and drag a new one), and do
not run-then-delete locally built Release/Export copies of `com.lineform.app` while signed into the
production iCloud account. TestFlight builds count as locally installed copies for this purpose.

## Release Verification Gates (do not weaken)

A historical signing incident and a workspace-bookmark defect both shipped despite green tests.
Read `docs/postmortems/2026-07-02-launch-brick-and-file-access.md` before touching signing,
certificates, provisioning profiles, or sandbox/bookmark code. Current release steps live in
`docs/release/app-store-release.md`.

- The signing cert MUST be embedded in the app's provisioning profile. A mismatch passes
  every static check but AMFI SIGKILLs the app at launch on every machine (this shipped
  as 1.1.0 build 14). The same mismatch happened again on 2026-07-29 when Xcode reused a cached
  profile after a capability change. After any cert or
  capability change, dump the profile's whole `Entitlements` dict and read it; do not trust a
  `plutil -extract` of a single dotted key, which silently returns nothing.
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
- Keep app identity surfaces consistent: Finder, Dock, Cmd-Tab, About, the App Store Connect record, and release docs should all point to the same versioned build. (The README is NOT one of these surfaces — see the no-download-links rule below.)
- Public updates ship through the App Store and nowhere else. The app has no self-update mechanism and must not grow one.
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

## Documentation Expectations

Update docs when behavior, workflows, or quality gates change:

- Keep `README.md` user-facing: website, privacy, about, credits, and only a compact source-build section.
- **The GitHub README carries NO download links — this is the owner's standing decision, not an omission.** Do not add a package URL, download badge, or release badge to `README.md`; the product website and the Mac App Store are where downloads live. A release version bump therefore does NOT touch the README.
- Use this file for AI coding agent context and repo operating rules — product context, invariants, verification, and policy. It is loaded in full every session, so keep it lean.
- Use `docs/architecture/*.md` for per-area implementation detail. New feature narrative goes there, not here; add at most a one-line feature entry and, if the change creates a rule that can never be broken, one line under Load-Bearing Invariants.
- Use `docs/release/app-store-release.md` for App Store submission, signing, and TestFlight. It is the only release runbook.
- Use `Lineform/Resources/*.md` for user-facing bundled app/help/release docs.

## PR / Marketing / Positioning Reference

For any PR, marketing, positioning, audience, or public-copy question ("how do I describe Lineform," "who is it for," "what's the one-liner," "is this claim safe to publish"), consult `POSITIONING_AND_MARKETING.md` at the repo root. It holds the verified positioning, target audience, plain-language feature list, differentiation vs. competitors, honesty constraints, launch-surface copy (Show HN / X / App Store / website), and a fact sheet (version, platform, license, privacy).

- It is a **local, untracked** working doc (in `.gitignore`) — it does not get committed or auto-updated by release tooling, so treat its facts as a dated snapshot. Its verification stamp names the app version it was checked against; if a question turns on a specific capability and the build has moved on, re-verify against the current code before making any public claim. Never publish a capability the shipped build can't demonstrate.
- Load-bearing rules from that doc: say "free" and "source-available" (never "open source" — PolyForm Shield 1.0.0); "No AI inside" is accurate and intentional; only Atkinson Hyperlegible + OpenDyslexic are bundled fonts; and distribution is Mac App Store-only.

Keep this file current when major features, architecture, or verification gates change.
