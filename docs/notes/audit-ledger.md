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
| Markdown inline/block parsing | `rendering.md` | `Preview/MarkdownInlineSyntax`, `MarkdownBlockGrouping`, `MarkdownHTMLRenderer`, `MarkdownPreviewRenderer` | 7e3fdd1 (07-27) | 7e3fdd1 (07-27) | — | escapes/BOM/emphasis flanking; nested emphasis in link text left divergent by decision |
| Editor keystroke commands | `editor-behavior.md` | `Editor/MarkdownListContinuation`, `MarkdownHeadingEditing`, `MarkdownFormattingCommand`, `MarkdownTableEditing` | 7e3fdd1 (07-27) | 7e3fdd1 (07-27) | — | `Int.max` ordered-marker crash; tab-after-marker; CRLF caret column |
| Fenced-code state tracking | `editor-behavior.md` | `MarkdownWritingToolsProtection`, `MarkdownSyntaxHighlighter`, `Outline/MarkdownOutlineParser`, `SpeechTextExtractor` | ad0a83a (07-27) | ad0a83a (07-27) | — | four callers used a flag toggle instead of `MermaidFence` |
| Spell-check regions + perf gate | `editor-behavior.md` | `MarkdownSpellCheckRegions`, `MarkdownSpellCheckPerformanceTests` | 7e940ef (07-27) | 7e940ef (07-27) | — | absolute ms gate flaked on CI; now a ratio |
| Image paths and resolution | `rendering.md` | `Preview/ImageLinkRewrite`, `ImageResolver`, `Editor/ImageInsertionText` | 7e3fdd1 (07-27) | 7e3fdd1 (07-27) | — | `photo (1).png` unparseable; bare `\n` insertion; `%20` fallback |
| Quick Look appex | `app-integration.md` | `LineformQuickLook/QuickLookMarkdownRenderer` | 7e3fdd1 (07-27) | 7e3fdd1 (07-27) | — | `~~~` fences, empty alt/link text; agreement now asserted |
| Document model and autosave | `editor-behavior.md` | `Documents/LineformDocument`, `DocumentReloadController`, `DocumentReloadPolicy` | 07-27 (this change) | 07-27 | 07-27 | 4: live reload fired once per file (URL resource-value cache); Convert to Markdown on a `.txt` ran the stripper over the file; BOM dropped on read and never re-emitted; `data(for:)`/`recordsSourceSave` disagreed |
| Tabs, windows, chrome | `tabs-and-windows.md` | `Editor/EditorTabStore`, `DocumentTab`, `TabBarView`, `WindowCloseController`, `SaveAndCloseCoordinator` | 07-27 (this change) | 07-27 | 07-27 | 2: Save-All orphaned an untitled tab from the file it just saved; dirty dot read a narrower predicate than `hasUnsavedWork` |
| Files sidebar and iCloud | `files-sidebar.md` | `Outline/OutlineSidebarView`, `DirectoryEventMonitor`, `SidebarFileActions` | 07-27 (this change) | 07-27 | 07-27 | 3: hidden-folders OFF dropped real files past the 80-cap; workspace watcher not retargeted on a moved folder; global Sort row read the iCloud key while the workspace scanned with its own |
| Find, replace, cross-file search, ⌘K | `search.md` | `Editor/CrossFileSearchModel`, `CrossFileSearchResolver`, `EditorSearchResolver`, `QuickOpenPalette`, `Outline/QuickOpenIndex` | 07-27 (this change) | 07-27 | 07-27 | 4: Replace wrapped onto its own earlier output; the 0.2 s derived refresh re-armed the deliberately-cleared index; snippet window split surrogate pairs; VoiceOver status re-announced every typing pause |
| Export, print, Save As | `export-and-print.md` | `Preview/DocumentExportRenderer`, `ExportTypographyPreset`, `ImageExportPreflight`, `Editor/SaveAsExport` | 07-27 (this change) | 07-27 | 07-27 | 3: print panel's paper change sliced prose instead of rewrapping; inline `$…$` absent from HTML export; a math-bearing line stopped unescaping `\*` |
| Mermaid, math, code highlighting | `rendering.md` | `Preview/MermaidRendering`, `MermaidPieChart`, `MathRendering`, `CodeHighlighting`, `DiagramReportService` | 07-27 (this change) | 07-27 | 07-27 | 5: pie value crash; front-matter diagrams mis-routed to the bug-report path; copy pill truncated CRLF code; size guard bounded nothing; `inlineSpans` quadratic |
| **Reading profiles and themes** | `app-integration.md` | `ReadingExperience/ReadingProfileStore`, `ReadingPreset`, `Theme`, `FontOption`, `BundledFontRegistrar` | 7e3fdd1 (07-27, contrast ratios only) | **never** | — | dropped by a script bug on the first run, then blocked by the session limit |
| **Speech** | `editor-behavior.md` | `ReadingExperience/SpeechController` | ad0a83a (07-27, extractor only) | 07-27 (**unverified**) | — | 4 raw findings, verify agents died on the session limit — DO NOT act on them until re-verified |
| **Menus, settings, updates, intents, CLI** | `app-integration.md` | `App/AppCommands`, `AppUpdater`, `LineformSettings`, `LineformAppIntents`, `MainMenuIconDecorator`, `CommandLineToolInstaller`, `CommandLineTool/` | e99d98b (07-27, intro overlay only) | **never** | — | dropped by a script bug on the first run, then blocked by the session limit |
| **Packaging, signing, release gates** | `app-integration.md`, `docs/release/` | `packaging/build-release.sh`, `verify-update.sh`, `docs/appcast.xml` | 98a7225 (07-19) | **never** | — | dropped by a script bug on the first run, then blocked by the session limit |

## Notes

- Bold rows are the backlog. The four remaining are there because of how the first parallel run went,
  not because they were judged low value: a workflow-script bug dropped them before their audit stage
  ran, and the re-run hit the session usage limit. Speech got an audit but its verification died with
  it, so its four findings are unverified and must be re-verified before anyone acts on them.
- `Verified at` means a later, independent pass tried to BREAK the fix and failed. An area is not done
  when it is audited — a fix and its test written in one pass can be wrong in the same way.
- `packaging/` has shipped broken twice (1.1.0 AMFI brick, 1.3.0 notarization rejection). Its gates are
  scripts, not tests, so no suite run covers them — audit it before the next release, not after.
- Re-audit an area whose `Last changed` moves past its `Audited at`; leave the rest alone.
