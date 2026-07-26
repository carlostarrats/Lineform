# Feature Backlog — Selected 2026-07-25

**Date:** 2026-07-25
**Purpose:** The six items the user selected as future work after a gap review of the shipped 1.3.0-era build. **Nothing here is scheduled or started.** This is a written-down intent list, not a plan — each item needs its own design pass before code.
**Companion:** `docs/research/2026-07-18-competitor-feature-scan.md` (whose §3 shortlist has now largely shipped; see the status pass at the top of that file).

**Verification basis:** static read of the source on 2026-07-25 — greps and file reads, **no build was run and no flow was driven in the app.** Two items below (1 and 2) are behavior claims that should be confirmed by typing in a real Debug build before any work starts. The rest are structural absences visible in the code and are not in doubt.

---

## Ordered by everyday impact

### 1. List continuation on Return *(highest impact)*

**Today:** there is no `doCommandBy(_:)`, `insertNewline`, or `shouldChangeTextIn` override anywhere in `Lineform/Editor/`. Pressing Return after `- groceries` yields a bare empty line, not `- `.

**Scope when built:**
- Continue `-` / `*` / `+`, `1.` (renumbering), `- [ ]` (new item unchecked, never inheriting `[x]`), and `>` on Return.
- Return on an *empty* marker ends the list and removes the marker, rather than emitting another one.
- Tab / Shift-Tab indent and outdent the current list item.

**Why it's first:** a new user hits it within thirty seconds. iA Writer, Bear, Byword, Obsidian, and every GitHub textarea do this. Pure typing ergonomics — zero positioning risk, nothing to decide about product direction.

**Risk:** medium, and higher than it looks. This is the first key-level intercept in the text view, and it lands in the middle of the undo stack, autosave, and the visual-anchor machinery documented in `docs/architecture/editor-behavior.md`. Every inserted marker must be a single undoable edit. Read that file first.

**Confirm before starting:** type `- a` + Return in a Debug build.

---

### 2. Live spell check

**Today:** `Lineform/Editor/LineformTextView.swift:587-590` disables quote, dash, and text substitution — correct for Markdown, keep it — and sets `isAutomaticSpellingCorrectionEnabled = true`. It never sets `isContinuousSpellCheckingEnabled` or `isGrammarCheckingEnabled`, both of which default to `false` on `NSTextView`.

**The oddity:** autocorrect silently changes words while misspellings get no red underline. That's the least useful of the four possible combinations — the app edits your text without showing you what it thinks is wrong.

**Scope when built:** enable continuous spell checking; decide separately whether grammar checking is on (probably not — it's noisy and fights "calm"). Consider whether autocorrect should stay on once squiggles exist. Likely needs a Settings toggle, and must be suppressed inside fenced code and front matter — `MarkdownWritingToolsProtection` already computes exactly those regions and is the natural seam.

**Risk:** low mechanically, but the code-block suppression is the part that makes it feel native rather than annoying.

**Confirm before starting:** type `teh` in a Debug build and look for the underline.

---

### 3. Table authoring help

**Today:** `MarkdownFormattingCommand` is title / section / bold / italic / inlineCode / strikethrough / blockquote / unorderedList / orderedList / link. No table command. Lineform *renders* GFM tables natively and well (`NSTextTable`, per-column alignment — see `docs/architecture/rendering.md`) but authoring one means hand-aligning pipes.

**Scope when built:** Insert Table (pick rows × columns), and Reformat/Align Table — pad the pipes of the table under the caret so columns line up in source. Possibly Tab to move between cells.

**Fit:** these are structure-preserving text transforms over a construct that already has a parser (`MarkdownTableParser`), which matches the repo rule about structured parsing over ad hoc string manipulation.

**Risk:** low–medium. Reformatting must be a single undoable edit and must not disturb the caret's logical position.

---

### 4. HTML export / Copy as HTML

**Today:** `SaveAsExport.Format` is `markdown, pdf, styledPDF, rtf`. Nothing HTML anywhere in the app.

**Why:** the real use case is paste-into-email and paste-into-CMS. This wasn't in the 2026-07-18 scan at all, and it's the cheapest remaining portability win — the RTF path already proves the seam (`DocumentExportRenderer.rtfData`, a pure `NSAttributedString` writer with no `NSPrintOperation`, hence default-test-plan friendly).

**Open question:** a *file* export (a fifth entry in the Format popup) or an **Edit ▸ Copy as HTML** clipboard command, or both. Copy-as-HTML is probably the more used of the two and the smaller change.

**Constraint:** self-contained output only. Local images would need to be inlined as `data:` URIs or the file breaks the moment it's pasted anywhere — and remote URLs must stay untouched, never fetched.

**Risk:** low.

---

### 5. Heading shortcuts beyond two

**Today:** ⌘1 = Title, ⌘2 = Section (`AppCommands.swift:353-361`). Nothing for H3–H6, and no way to raise or lower the heading level of the current line.

**Scope when built:** either ⌘3–⌘6 for the remaining levels, or a "cycle heading level" pair — the latter is fewer keys and reads calmer, but is less discoverable. Check for collisions first: ⌘7/⌘8 are already Numbered/Bulleted List with ⇧.

**Risk:** low. Smallest item on this list.

---

### 6. Read-only Git history view

**Today:** nothing. Lineform's files are plain `.md` in real folders, so if the user keeps writing in a Git repo the history already exists on disk — the app just can't see it.

**Scope when built:** a panel showing that the open file changed *n* times, with the ability to look at a previous version and what changed. **Read-only by definition:** no commit, no push, no branch, no staging. It lets a writer look backward at their own drafts; it does not make Lineform a Git client.

**Fit:** "trustworthy" is a stated product value, and this is the one item on the list that expresses it directly. MWeb and Resomark both ship a version.

**Risk:** high relative to everything else here, and the most design-dependent. Real questions to settle before any code:
- Shelling out to `git` from a sandboxed app is not straightforward. Investigate what's actually reachable before promising the feature.
- Repo detection has to be quiet and never block the editor.
- A file not in a repo must degrade to *nothing visible*, not an error or an empty panel.
- Worth weighing against macOS's built-in **Versions** (`NSDocument`'s `browseVersions:`), which is free, sandbox-native, needs no repo, and covers a meaningful share of "let me see an earlier draft." Not currently wired up. It may be the better first move, or the only move.

---

## Explicitly not on this list

Unchanged from the 2026-07-18 decisions: no wiki-links or backlinks, no tags, no AI, no blog publishing, no database library mode, no Fountain. Also considered and passed over in the 2026-07-25 review: footnotes (`[^1]`, unsupported by the renderer — a real gap for long-form and academic writing, but not selected), the session word-count goal (item H, still unbuilt), EPUB, and on-screen typographic themes.
