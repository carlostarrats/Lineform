# Feature Backlog — Selected 2026-07-25

**Date:** 2026-07-25
**Purpose:** The six items the user selected as future work after a gap review of the shipped 1.3.0-era build. **Nothing here is scheduled or started.** This is a written-down intent list, not a plan — each item needs its own design pass before code.
**Closed 2026-07-26:** items 1–5 shipped; item 6 (read-only Git history) was dropped rather than built — reasoning under "Explicitly not on this list."
**Companion:** `docs/research/2026-07-18-competitor-feature-scan.md` (whose §3 shortlist has now largely shipped; see the status pass at the top of that file).

**Verification basis:** static read of the source on 2026-07-25 — greps and file reads, **no build was run and no flow was driven in the app.** Two items below (1 and 2) were behavior claims needing confirmation in a real Debug build. **Both items 1 and 2 were confirmed in a real Debug build and have since shipped (2026-07-26).** The rest are structural absences visible in the code and are not in doubt.

**Status:** 5 of 6 shipped, 1 dropped. Nothing remaining.

---

## Ordered by everyday impact

### 1. List continuation on Return *(highest impact)* — **SHIPPED 2026-07-26**

**Shipped** as `MarkdownListContinuation` + a `LineformTextView.insertNewline` override. Bullets,
ordered items, task checkboxes, and blockquotes all continue; Return on an empty marker ends the
construct. Two deliberate reductions from the scope below: **Tab/Shift-Tab indent was dropped**
(it is the only piece that would remove existing behavior — Tab still inserts a literal tab) and
ordered lists **increment only** rather than renumbering. Design:
`docs/superpowers/specs/2026-07-26-list-continuation-design.md`; implementation notes and the
four load-bearing traps: `docs/architecture/editor-behavior.md`.

**Was true before the change:** there was no `doCommandBy(_:)`, `insertNewline`, or `shouldChangeTextIn` override anywhere in `Lineform/Editor/`. Pressing Return after `- groceries` yielded a bare empty line, not `- `. Confirmed on 2026-07-26 both by grep and by an AppKit probe showing `NSTextView` appends a bare newline for every marker type (its own continuation is `NSTextList`-attribute-driven and unreachable from a plain-text view).

**Scope when built:**
- Continue `-` / `*` / `+`, `1.` (renumbering), `- [ ]` (new item unchecked, never inheriting `[x]`), and `>` on Return.
- Return on an *empty* marker ends the list and removes the marker, rather than emitting another one.
- Tab / Shift-Tab indent and outdent the current list item.

**Why it's first:** a new user hits it within thirty seconds. iA Writer, Bear, Byword, Obsidian, and every GitHub textarea do this. Pure typing ergonomics — zero positioning risk, nothing to decide about product direction.

**Risk:** medium, and higher than it looks. This is the first key-level intercept in the text view, and it lands in the middle of the undo stack, autosave, and the visual-anchor machinery documented in `docs/architecture/editor-behavior.md`. Every inserted marker must be a single undoable edit. Read that file first.

**Confirm before starting:** type `- a` + Return in a Debug build.

---

### 2. Live spell check — **SHIPPED 2026-07-26**

**Shipped** as `MarkdownSpellCheckRegions` plus a `LineformTextView.checkText(in:types:options:)`
override that splits each checked range into prose-only sub-ranges. Autocorrect is now off,
grammar checking stays unused, and suppression covers fenced code, front matter, math, inline
code, and link/image destinations (link *text* is still checked). Design:
`docs/superpowers/specs/2026-07-26-live-spell-check-design.md`; implementation notes and the four
traps: `docs/architecture/editor-behavior.md`; measurements: `docs/notes/2026-07-26-spell-check-probe-findings.md`.

**Three things the plan did not anticipate**, all found in manual QA and all shipped as fixes:
the Edit menu had no Spelling and Grammar submenu (SwiftUI builds none and this app replaces the
Edit menu), so the feature had **no off switch**; `menu(for:)` replaces AppKit's context menu, so
right-click offered no guesses, Learn, or Ignore; and enabling continuous checking surfaced a
floating inline candidate pill, now disabled. Suggestions deliberately show **one** ranked
candidate rather than the checker's full phonetic list.

**Performance:** the first implementation failed its own gate at 14.97 ms/call and was rewritten;
shipped cost is ~0.6 ms mid-document in an optimized build, against Apple's own checker at
~0.09 ms. Guarded by `MarkdownSpellCheckPerformanceTests`.

**Was true before the change:** `Lineform/Editor/LineformTextView.swift:587-590` disabled quote, dash, and text substitution — correct for Markdown, kept — and set `isAutomaticSpellingCorrectionEnabled = true`. It never set `isContinuousSpellCheckingEnabled` or `isGrammarCheckingEnabled`, both of which default to `false` on `NSTextView`.

**The oddity:** autocorrect silently changes words while misspellings get no red underline. That's the least useful of the four possible combinations — the app edits your text without showing you what it thinks is wrong.

**Scope when built:** enable continuous spell checking; decide separately whether grammar checking is on (probably not — it's noisy and fights "calm"). Consider whether autocorrect should stay on once squiggles exist. Likely needs a Settings toggle, and must be suppressed inside fenced code and front matter — `MarkdownWritingToolsProtection` already computes exactly those regions and is the natural seam.

**Risk:** low mechanically, but the code-block suppression is the part that makes it feel native rather than annoying.

**Confirm before starting:** type `teh` in a Debug build and look for the underline.

---

### 3. Table authoring help — **SHIPPED 2026-07-26**

**Shipped** as `MarkdownTableEditing` plus `LineformTextView.insertTab` / `insertBacktab`
overrides and two Format menu rows. Insert Table (⌃⌘T) writes a 3×2 skeleton; Reformat Table
(⌃⌘R) aligns the pipes of the table under the caret; Tab / Shift-Tab move between cells inside a
table, and Tab off the last cell appends a row. Design:
`docs/superpowers/specs/2026-07-26-table-authoring-design.md`; implementation notes and the
load-bearing rules: `docs/architecture/editor-behavior.md`.

**Deliberate reductions from the scope below:** no size picker — the size is fixed at 3×2, because
every other Format command acts immediately and gaining a column is one pipe plus Reformat. No
alignment commands: setting a column to `:-:` stays a two-character hand edit, which Reformat then
preserves.

**Two things the plan did not anticipate**, both found before shipping: Reformat rebuilt its
delimiter row from the parsed alignments, which map `:--` and `---` both to `.left` — so it
silently erased every explicit-left delimiter in the file, invisibly, because the rendered output
was unchanged. And Tab from a caret ahead of the opening pipe (⌘←) skipped the first cell. The
first was caught by a test, the second by code review after the tests were green.

**Reformat declines rather than risks the file** on `\|` or any backtick in the region: the parser
splits on every pipe, which is harmless while rendering but permanent once written back.

**Verified:** 966 default-plan tests and 15 hosted-plan tests green, plus a driven pass in a real
Debug build covering align, second-align-is-a-no-op, alignment-colon preservation, both refusals,
Tab-in-table vs. Tab-in-prose, insert, append-row, and single-⌘Z undo of each.

**Was true before the change:** `MarkdownFormattingCommand` was title / section / bold / italic / inlineCode / strikethrough / blockquote / unorderedList / orderedList / link. No table command. Lineform *rendered* GFM tables natively and well (`NSTextTable`, per-column alignment — see `docs/architecture/rendering.md`) but authoring one meant hand-aligning pipes.

**Scope when built:** Insert Table (pick rows × columns), and Reformat/Align Table — pad the pipes of the table under the caret so columns line up in source. Possibly Tab to move between cells.

**Fit:** these are structure-preserving text transforms over a construct that already has a parser (`MarkdownTableParser`), which matches the repo rule about structured parsing over ad hoc string manipulation.

**Risk:** low–medium. Reformatting must be a single undoable edit and must not disturb the caret's logical position.

---

### 4. HTML export — **SHIPPED 2026-07-26**

**Shipped** as a file export: `ExportFormat` is now `html, pdf, styledPDF, rtf`, reached through
File ▸ Export As, while Save As stays on Markdown. Output is one-to-one with the source — image
paths and link URLs are emitted exactly as written, never resolved or inlined.

**The Copy as HTML clipboard command below was considered and declined.** The file export covers
the portability need; a second HTML surface is redundant. Do not reopen it.

**Was true before the change:** `SaveAsExport.Format` was `markdown, pdf, styledPDF, rtf`. Nothing HTML anywhere in the app.

**Why:** the real use case is paste-into-email and paste-into-CMS. This wasn't in the 2026-07-18 scan at all, and it's the cheapest remaining portability win — the RTF path already proves the seam (`DocumentExportRenderer.rtfData`, a pure `NSAttributedString` writer with no `NSPrintOperation`, hence default-test-plan friendly).

**Open question:** a *file* export (a fifth entry in the Format popup) or an **Edit ▸ Copy as HTML** clipboard command, or both. Copy-as-HTML is probably the more used of the two and the smaller change.

**Constraint:** self-contained output only. Local images would need to be inlined as `data:` URIs or the file breaks the moment it's pasted anywhere — and remote URLs must stay untouched, never fetched.

**Risk:** low.

---

### 5. Heading shortcuts beyond two — **SHIPPED 2026-07-26**

**Shipped** as `MarkdownHeadingEditing` plus a Format ▸ Heading submenu. ⌘1–⌘6 set a level, ⌘0
returns a line to body text, and pressing a line's current level clears it. `Title` (⌘1) and
`Section` (⌘2) keep their names, positions, and keys; Heading 3–6 and Body live in the submenu.
Design: `docs/superpowers/specs/2026-07-26-heading-levels-design.md`; implementation notes:
`docs/architecture/editor-behavior.md`.

**This was scoped as "add four shortcuts" and turned out to be a bug fix.** The shipped ⌘1/⌘2
routed through `prefixSelection`, which prepended to the raw selection: ⌘1 on `## Section` gave
`# ## Section`, which is not a heading and which the outline parser cannot see — the line silently
vanished from the sidebar. A caret mid-word split the word. Changing the level of an existing
heading is the *most common* heading motion, so the feature was broken on its main path. Setting
the level on a line fixes both and made the four missing levels nearly free.

**Two things the plan did not anticipate**, both caught before shipping: `isInsideCodeOrFrontMatter`
reports the OPENING ``` as outside the block it opens, so the opening fence took a heading marker
and broke the block; and calling that function per line makes Select All + a heading key quadratic
in document length — the block now takes one scoped `protectedRanges` pass instead. The first was
caught by a test, the second by reading the code after the tests were green.

**Rejected:** a raise/lower cycle pair (no direct jump, and nothing tells you your current level),
and a flat seven-row Format menu (retires the `Title`/`Section` names or reads inconsistently).

**Deliberately out of scope:** setext headings (`===` / `---`), which the outline parser does not
see either, and closing hashes (`## Section ##`), which are left alone.

---

## Explicitly not on this list

**Read-only Git history view** — selected on 2026-07-25, **dropped 2026-07-26.** The panel would have
shown that the open file changed *n* times, with a look at a previous version. Three reasons it went:

- `git` is not an inert reader. It executes code from the repo it is pointed at — `.git/config`
  aliases, `core.pager`, `core.fsmonitor`, hooks — so shelling out inside whatever folder the user
  opened is a code-execution path controlled by whoever authored that folder (the bug VS Code and
  Atom both shipped). The mitigation is a trust-this-repo prompt, which is exactly the noise this
  app exists to avoid. Commit metadata and `.git/config` also surface the user's name, email, and
  remote URLs — identity data the app currently never touches.
- The sandbox problem is worse than "not straightforward": `/usr/bin/git` is a shim that triggers an
  Xcode Command Line Tools install prompt on a machine without them, from inside a sandboxed child
  process, in front of a writer who does not know what Xcode is. The alternative is bundling
  libgit2 — a C dependency in the notarization and nested-bundle re-signing chain that has already
  broken a release once.
- Writers who keep drafts in Git already own a Git tool. It is the one item that made Lineform look
  like a developer tool.

**macOS Versions was considered as the replacement and also deferred (2026-07-26).** The machinery is
already running — `LineformDocument` is a SwiftUI `FileDocument` in a `DocumentGroup`, so
autosave-in-place has been writing snapshots to the volume's `.DocumentRevisions-V100` all along.
What is missing is the menu: `CommandGroup(replacing: .saveItem)` in `AppCommands.swift` customizes
Save and Save As and removes `Revert To ▸ Last Saved / Browse All Versions…` along with them.
Restoring it is a few lines.

Deferred anyway because Browse All Versions is Apple's full-screen Time Machine browser — the
loudest possible chrome in a calm app, unrestylable — and "pick an earlier version" is a job most
writers never do. Revisit only if users ask for it. If revisited, note the limits: snapshot cadence
is the system's and coarse under continuous autosave, versions are per-volume (external and network
drives may have none), and edits made in another editor leave no version behind. Building a custom
history panel on `NSFileVersion` is explicitly *not* the fallback — thin data plus a designed panel
is the Git item under another name.

Unchanged from the 2026-07-18 decisions: no wiki-links or backlinks, no tags, no AI, no blog publishing, no database library mode, no Fountain. Also considered and passed over in the 2026-07-25 review: footnotes (`[^1]`, unsupported by the renderer — a real gap for long-form and academic writing, but not selected), the session word-count goal (item H, still unbuilt), EPUB, and on-screen typographic themes.
