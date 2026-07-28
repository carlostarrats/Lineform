# Audit Ledger

Tracks which areas of Lineform have been deliberately audited, when, and against which commit.

**Why this file exists.** On 2026-07-27 the same open-ended prompt ("review the codebase and QA in
detail… fix anything not right") was run four times back to back. Every run found real defects, which
looks like thoroughness and is actually the opposite: all four entered through the same door. Between
them they touched 21 source files, and 18 of those are the Markdown text-processing core
(`Editor/Markdown*`, `Outline/Markdown*`, `Preview/Markdown*`). Documents, tabs, the files sidebar,
search, export, settings, updates, and packaging were not read once in four passes. The prompt has no
completion criterion, so it converges on whatever is most legible, not on what is least covered.

This ledger replaces "review the codebase" with "audit the next unaudited area." The exit condition is
concrete: every row audited at a commit at or after that area's last source change.

## How to use it

1. Pick the row with the oldest `Audited at` (or `never`) whose `Last changed` is newer than it.
2. Read that area's architecture doc **first** — the invariants there are the audit targets.
3. Audit with **probes, not reading**. The four runs above found their real bugs by feeding hostile
   input (CRLF, BOM, emoji, escapes, `Int.max`, nested fences) to code the existing suite already
   agreed with, and by asserting that paired implementations of one concept actually agree. Static
   re-reading found close to nothing. See `docs/notes/2026-07-26-spell-check-probe-findings.md`.
4. Update the row: date, commit audited at, and a one-line finding summary (write `none` if clean —
   a clean audit is a result and stops the area being re-swept).
5. If the audit produces a rule that can never be broken, it goes in `Claude.md` under Load-Bearing
   Invariants and in the area's architecture doc — not here.

Findings themselves live in commit messages and architecture docs. This file only records coverage.

## Coverage

`Last changed` is the most recent commit touching that area's sources, as of 2026-07-27.

| Area | Doc | Key sources | Last changed | Audited at | Verified at | Findings |
|---|---|---|---|---|---|---|
| Markdown inline/block parsing | `rendering.md` | `Preview/MarkdownInlineSyntax`, `MarkdownBlockGrouping`, `MarkdownHTMLRenderer`, `MarkdownPreviewRenderer` | 07-27 (this change) | 7e3fdd1 (07-27) | 07-27 | escapes/BOM/emphasis flanking; nested emphasis in link text left divergent by decision |
| Editor keystroke commands | `editor-behavior.md` | `Editor/MarkdownListContinuation`, `MarkdownHeadingEditing`, `MarkdownFormattingCommand`, `MarkdownTableEditing` | 07-27 (this change) | 7e3fdd1 (07-27) | 07-27 | `Int.max` ordered-marker crash; tab-after-marker; CRLF caret column |
| Fenced-code state tracking | `editor-behavior.md` | `MarkdownWritingToolsProtection`, `MarkdownSyntaxHighlighter`, `Outline/MarkdownOutlineParser`, `SpeechTextExtractor` | 07-27 (this change) | ad0a83a (07-27) | 07-27 | four callers used a flag toggle instead of `MermaidFence` |
| Spell-check regions + perf gate | `editor-behavior.md` | `MarkdownSpellCheckRegions`, `MarkdownSpellCheckPerformanceTests` | 07-27 (this change) | 7e940ef (07-27) | 07-27 | absolute ms gate flaked on CI; now a ratio |
| Image paths and resolution | `rendering.md` | `Preview/ImageLinkRewrite`, `ImageResolver`, `Editor/ImageInsertionText` | 07-27 (this change) | 7e3fdd1 (07-27) | 07-27 | `photo (1).png` unparseable; bare `\n` insertion; `%20` fallback |
| Quick Look appex | `app-integration.md` | `LineformQuickLook/QuickLookMarkdownRenderer` | 07-27 (this change) | 7e3fdd1 (07-27) | 07-27 | `~~~` fences, empty alt/link text; agreement now asserted |
| Document model and autosave | `editor-behavior.md` | `Documents/LineformDocument`, `DocumentReloadController`, `DocumentReloadPolicy` | 07-27 (this change) | 07-27 | 07-27 | 4: live reload fired once per file (URL resource-value cache); Convert to Markdown on a `.txt` ran the stripper over the file; BOM dropped on read and never re-emitted; `data(for:)`/`recordsSourceSave` disagreed |
| Tabs, windows, chrome | `tabs-and-windows.md` | `Editor/EditorTabStore`, `DocumentTab`, `TabBarView`, `WindowCloseController`, `SaveAndCloseCoordinator` | 07-27 (this change) | 07-27 | 07-27 | 2: Save-All orphaned an untitled tab from the file it just saved; dirty dot read a narrower predicate than `hasUnsavedWork` |
| Files sidebar and iCloud | `files-sidebar.md` | `Outline/OutlineSidebarView`, `DirectoryEventMonitor`, `SidebarFileActions` | 07-27 (this change) | 07-27 | 07-27 | 3: hidden-folders OFF dropped real files past the 80-cap; workspace watcher not retargeted on a moved folder; global Sort row read the iCloud key while the workspace scanned with its own |
| Find, replace, cross-file search, ⌘K | `search.md` | `Editor/CrossFileSearchModel`, `CrossFileSearchResolver`, `EditorSearchResolver`, `QuickOpenPalette`, `Outline/QuickOpenIndex` | 07-27 (this change) | 07-27 | 07-27 | 4: Replace wrapped onto its own earlier output; the 0.2 s derived refresh re-armed the deliberately-cleared index; snippet window split surrogate pairs; VoiceOver status re-announced every typing pause |
| Export, print, Save As | `export-and-print.md` | `Preview/DocumentExportRenderer`, `ExportTypographyPreset`, `ImageExportPreflight`, `Editor/SaveAsExport` | 07-27 (this change) | 07-27 | 07-27 | 3: print panel's paper change sliced prose instead of rewrapping; inline `$…$` absent from HTML export; a math-bearing line stopped unescaping `\*` |
| Mermaid, math, code highlighting | `rendering.md` | `Preview/MermaidRendering`, `MermaidPieChart`, `MathRendering`, `CodeHighlighting`, `DiagramReportService` | 07-27 (this change) | 07-27 | 07-27 | 5: pie value crash; front-matter diagrams mis-routed to the bug-report path; copy pill truncated CRLF code; size guard bounded nothing; `inlineSpans` quadratic |
| Reading profiles, presets, themes, fonts | `app-integration.md` | `ReadingExperience/ReadingProfileStore`, `ReadingPreset`, `Theme`, `FontOption`, `BundledFontRegistrar` | 07-27 (this change) | 07-27 | 07-27 | 2 confirmed: link/image ink and the diagram fallback caption were the two reader inks never under the contrast gate. 2 REFUTED — persisted-number bounds and unknown-`fontID` profile discard are both real mechanisms but unreachable |
| Speech controller | `editor-behavior.md` | `ReadingExperience/SpeechController` | 07-27 (this change) | 07-27 | 07-27 | 4 confirmed: a stopped utterance reports `didFinish` (transport clobbered to `.idle` with audio playing); deferred pause overtakes a resume; speech range harvested from any focused `NSTextView`; speech outlived its document on tab/sidebar switch |
| Menus, settings, updates, App Intents, CLI | `app-integration.md` | `App/AppCommands`, `AppUpdater`, `LineformSettings`, `LineformAppIntents`, `MainMenuIconDecorator`, `CommandLineToolInstaller`, `CommandLineTool/` | 07-27 (this change) | 07-27 | 07-27 | 4 confirmed: decorator stamps context menus; Spelling submenu bare; `lineform -` accepts non-UTF-8 the app rejects; App Intents filenames drop non-ASCII. 1 REFUTED — Privacy.md/Sparkle disclosure |
| Packaging, signing, release gates | `app-integration.md`, `docs/release/` | `packaging/build-release.sh`, `verify-update.sh`, `docs/appcast.xml` | 07-27 (this change) | 07-27 | 07-27 | 4 confirmed, 2 release-blocking: the cert gate + re-sign list were behind a flag defaulting to NO; no clean of `$APP_PATH`; `generate-appcast.sh` clobbered the tracked appcast; runbook version drift. 3 REFUTED — CI publish path, `verify-update.sh`, smoke-test `rm -rf` |

## Notes

- **Every row is audited AND verified as of 2026-07-27.** Three rounds: 66 findings raised, 59
  confirmed and fixed. Re-audit a row only when its `Last changed` moves past its `Audited at`.
- **The verification round is the one that mattered most.** All six areas fixed by the day's
  sequential runs were sent to an adversary that had not written them, and NOT ONE held up — 24
  further gaps, twelve of them cases where the fix passed the test written beside it and failed the
  neighbouring case. Two were data loss, and one of those was INTRODUCED by the morning's own fix:
  an unescape added to Convert to Plain Text ran over fenced-code bodies, halving every doubled
  backslash in the user's code and autosaving it. A green suite is not evidence a fix is done; a fix
  and its same-pass test share the mental model that produced the bug.
- The 7 refutations are as much of the result as the confirmations. Two findings rated
  crash-or-data-loss (persisted-number bounds, unknown-`fontID` profile discard) described real
  mechanisms that no user path reaches, and three packaging alarms dissolved under a probe. A verify
  stage that never refutes anything is not verifying.
- `Verified at` means a later, independent pass tried to BREAK the fix and failed. An area is not done
  when it is audited — a fix and its test written in one pass can be wrong in the same way.
- `packaging/` has shipped broken twice (1.1.0 AMFI brick, 1.3.0 notarization rejection). Its gates are
  scripts, not tests, so no suite run covers them — audit it before the next release, not after.
- Re-audit an area whose `Last changed` moves past its `Audited at`; leave the rest alone.
