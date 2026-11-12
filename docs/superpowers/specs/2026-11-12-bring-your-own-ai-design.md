# Bring Your Own AI + History — Design

Status: design, approved in conversation 2026-11-12, not yet planned or built.
Interactive mockup of History mode (final agreed state):
`docs/superpowers/specs/2026-11-12-history-mode-mockup.html` — open it in a browser, click
**History**.

Marking: everything not tagged is the owner's decision. **[Claude's call]** marks a choice made
during design that the owner has not explicitly confirmed; the builder may revisit those.

---

## 1. Intent

Lineform is a calm, local-first Markdown editor. The owner wants AI help that **assists the writer
without taking over**: the AI proposes, the writer decides, and nothing changes the file until the
writer accepts it. Alongside it, a lightweight **History** lets anyone keep alternative versions of
a word, sentence, or paragraph and step between them — useful with or without AI.

Inspirations, taken selectively: Jason Fried's Write_on (dim what would be cut instead of cutting
it; version dots; a Word/Sentence/Paragraph version panel) and iA Writer's right-click
Proofread/Rewrite.

The product must stay light: **nothing is bundled**. AI exists only if the user connects their own.

## 2. Goals, non-goals, anti-goals

**Goals**
- Connect the user's own AI (Claude, ChatGPT, Google, or anything else) from one window.
- Right-click AI actions on a selection: Trim, Cut in half, Rewrite, Proofread, Mark.
- Suggestions are shown, not applied: removals dim, the writer accepts or rejects per change or
  in bulk.
- History of a passage's versions, for everyone, with a dedicated History mode for reviewing it.
- History never touches the `.md` file and cleans itself up.

**Non-goals**
- No bundled or on-device model (including Apple Foundation Models).
- No Lineform MCP server / "work from inside Claude" integration (the Luz pattern is explicitly
  rejected for Lineform).
- No Siri.
- No finish-your-sentence autocomplete or inline ghost writing.
- No "Take a stance"/"More direct"/"Sharper" style option — dropped because no clear name exists.
- No OpenRouter as a headline option.

**Anti-goals (would be a failure even if it works)**
- Any AI UI visible when no AI is connected. With no AI connected, Lineform is today's app plus
  History.
- AI changing the document without an explicit accept.
- Markers that make a heavily-edited page noisy (e.g. every paragraph underlined).
- Any extra data inside the user's Markdown file.
- History build-up that outlives the files it belongs to.
- A full-width bar at the top of window content (repo invariant: the toolbar samples it).

## 3. Connect Your AI

**Entry:** a new item in the **Lineform** app menu, "Connect Your AI…", opening a window laid out
like Luz's Connect Your AI (`/Users/carlostarrats/Documents/Projects/Luz/Luz Photo/Luz/Luz/Views/ConnectAI/ConnectAIView.swift`
is the visual reference): a left list — **Claude, ChatGPT, Google, Other** — and a right pane for
the selected provider, with Done at the bottom. Presentation like Lineform's Settings window
(a normal window, not a sheet over the document).

**Mechanism — one connection path [Claude's call on the technical shape]:**
- Claude / ChatGPT / Google: the page links to that provider's "create an API key" page and has
  one field to paste the key. The endpoint is pre-filled; the user never types an address.
- Other: the user enters an address (e.g. a model they run on this Mac via Ollama / LM Studio /
  llama.cpp, or any OpenAI-compatible server) and, optionally, a key and model name.
- Under the hood: one OpenAI-compatible chat-completions client. Google and local runners expose
  that format. For Claude, verify the current state of Anthropic's OpenAI-compatibility endpoint;
  Anthropic documents it as not intended for production, so the builder should use the native
  Messages API for Claude if needed — still a single small client per protocol, not per feature.
- Say plainly on each page that a Claude Pro / ChatGPT Plus / Gemini subscription does **not**
  cover this; API keys are billed per use by the provider.
- One connection active at a time **[Claude's call]**. Provide Disconnect.
- Default model per provider chosen by the builder (current mid-tier, cost-sensible); a model
  override field is acceptable but must not clutter the main path **[Claude's call]**.

**Storage:** keys in the Keychain, never UserDefaults, never in files.

**Privacy copy on the page:** Lineform sends only the text you act on, only when you choose an AI
action, directly to the provider you connected, under your account and that provider's terms.
Lineform's developer receives nothing.

**Consent and App Review [Claude's call]:** connecting is the explicit permission step. The
key field's confirm button states what will be sent and to whom (e.g. "Connect — Lineform will
send the text you choose to Anthropic"). No separate per-action prompt. The builder must check
the current App Review Guidelines (5.1.2 on sharing data with third-party AI) and update the App
Privacy details and the bundled privacy doc accordingly; if Apple requires more than this, it
comes back to the owner.

**Connected state drives everything:** a single "AI is connected" flag gates every AI surface.

## 4. AI actions (only when connected)

Right-click on a selection adds one group to the existing context menu (`menu(for:)` in
`LineformTextView`):

- **Rewrite ▸** Trim · Cut in half · Rewrite
- **Proofread** (punctuation and typos)
- **Mark ▸** Weakest sentences · Long sentences

Requires a selection; to act on the whole document, Select All **[Claude's call]**.
Disconnected → the group is absent, not disabled.

Choosing an action **runs immediately** — no intermediate bar or strength picker. While it runs,
show quiet progress and allow Esc to cancel **[Claude's call on the exact indicator]**.

### 4.1 Reviewing a suggestion (Trim, Cut in half, Rewrite, Proofread)

- Text the AI would remove is **dimmed**, not deleted. New text appears inline in normal ink
  **[Claude's call: how insertions are distinguished — keep it calm, no colour coding]**.
- At the end of each change: a small **pill** — outline only, ✓ on the left, a thin vertical
  divider that stops ~1px short of the pill's top and bottom edges, ✕ on the right, all
  monotone. ✓ accepts that change; ✕ rejects it.
- Clicking a dimmed piece keeps it (un-dims it) before accepting.
- Multiple changes: a **floating** card (not a top bar) shows position ("3 of 7") and
  **Accept All / Reject All**. After the writer decides any single change, the buttons become
  **Accept Remaining / Reject Remaining**.
- **The document is read-only during review [Claude's call]**, like History mode. Suggestions
  are an overlay and never enter the text buffer until accepted, so autosave, live reload, and
  undo can never write an unaccepted suggestion to the `.md`. Accepting applies the change as
  one undoable edit.
- During review the writer is in a review state, like search: **← / →** jump between changes
  (they do not move the caret), Return accepts the current change, Esc ends review
  **[Claude's call: Esc leaves undecided changes rejected, i.e. the text unchanged]**.
- Accepting a change creates History for that passage: the original plus the accepted version.

### 4.2 Markdown structure is never the AI's to change (hard rule)

The writer works on Markdown **source** (Write mode), not rendered text — the mockups show
rendered prose only for readability. AI actions must never erase or alter the document's
Markdown structure.

- **Only prose is editable.** Heading markers (`#`), list and task markers (`-`, `1.`, `- [ ]`),
  blockquote `>`, emphasis delimiters (`*`, `_`, `**`, `~~`), link and image syntax (brackets,
  destinations, titles), inline code, fenced code blocks, front matter, math, tables' pipes and
  delimiter rows, HTML, footnote markers, and line endings / BOM are **structure** and are never
  changed by an AI action.
- **Full inventory of what Lineform supports, and how each is protected** (from
  `MarkdownBlockGrouping`, `MarkdownInlineSyntax`, `MarkdownReference` (Markdown Basics),
  `docs/architecture/rendering.md`, and lineform.app; the builder must re-derive this from the
  code at build time and fail a test if a new construct appears without a protection rule):

  | Construct | Never sent / never changed | Prose the AI may edit |
  |---|---|---|
  | Front matter (`---` block at top of file) | whole block | — |
  | Fenced code (``` and ~~~, any language) | whole block incl. fences and language tag | — |
  | Mermaid (```mermaid, incl. its own front matter) | whole block | — |
  | Display math (`$$…$$` one line, `$$` fenced) | whole block | — |
  | Inline math `$…$` (plain dollar amounts stay text) | the math | surrounding prose |
  | Inline code `` `…` `` | whole span | — |
  | Headings `#`–`######`, setext underline `===`/`---` | markers, underline line | heading text |
  | Lists `-` `*` `+` `1.` (≤9 digits), nesting indentation | markers, indentation | item text |
  | Tasks `- [ ]` / `- [x]` | marker and checkbox state | item text |
  | Blockquotes `>` (any depth) | markers | quoted text |
  | Callouts `> [!NOTE]` / TIP / IMPORTANT / WARNING / CAUTION + optional title | marker line's `[!KIND]` | title and body text |
  | Tables: pipes, delimiter row, alignment colons, `\|` | all structure; row/column count | cell text |
  | Emphasis `**` `*` `_` `~~` | delimiters | emphasised words |
  | Links `[text](url "title")` | brackets, URL, title | link text |
  | Images `![alt](path)` incl. local paths with spaces/parens | whole construct | — **[Claude's call: alt text is left alone]** |
  | Horizontal rules `---` `***` `___` | whole line | — |
  | Backslash escapes `\*` `\_` `` \` `` `\[` etc. | the escapes | — |
  | Hard line breaks (two trailing spaces, trailing `\`) | the break | — |
  | Raw HTML tags | the tags | — |
  | Blank lines between blocks, line endings (LF/CRLF), leading BOM | all of it | — |

  Math today is `$…$` and `$$…$$` only (`MathRendering.swift`). If `\(…\)` / `\[…\]` support is
  ever added, it joins this table.
- **Protected regions are not sent at all** where possible: fenced code, front matter, math, and
  link/image destinations are excluded the same way `MarkdownWritingToolsProtection` and
  `MarkdownSpellCheckRegions` already exclude them. Reuse those definitions; do not write a new
  one (repo rule: paired definitions disagree).
- **The structure is verified, not trusted.** After the AI responds, Lineform checks that every
  structural token in the selection is still present and unchanged. Any proposed change that
  touches structure is dropped (or the whole suggestion is refused if it can't be separated) —
  the AI is never relied on to "be careful".
- Link **text** and emphasised words are prose and may be edited; their delimiters stay in place.
- Proofread follows the same rule: it fixes prose punctuation and typos, never Markdown
  punctuation (`*`, `#`, `|`, `` ` ``, `[]()`, etc.).
- This rule is a load-bearing invariant: add a one-line entry to `CLAUDE.md` and tests that
  feed structured Markdown (headings, nested lists, tasks, tables, links, code, front matter,
  CRLF, BOM) through the apply path with a fake AI that tries to alter structure, asserting the
  structure survives byte-for-byte.

**Where it runs [Claude's call]:** AI actions, review, and History mode operate in **Write mode**
(source). Read and Split modes show the resulting document but do not host review or History
mode. History mode in Write mode shows the source, with its syntax, in the receded/tinted style
of the mockup.

### 4.3 Mark

Highlights the weakest or longest sentences. Changes nothing. Dismiss with Esc or by editing
**[Claude's call]**.

## 5. History (for everyone)

- **Add to History** — right-click a selection; saves the selected passage's current text as a
  version. (Not "Save Version", which reads as a whole-document version.) Available with or
  without AI.
- Accepting an AI change also adds to History (§4.1).
- Each version records who made it: **✎ pencil = you**, **✦ sparkles = AI** (SF Symbols).
  **[Claude's call: ✦ stays on AI-made versions even after the AI is disconnected — it records
  authorship, not a live AI feature.]**
- **Delete from History** — right-click a version row in the History sidebar. A passage reduced
  to one version loses its history record entirely.
- **Levels:** three, named **Paragraph · Sentence · Word**. Hard cap of three nesting levels;
  inside a word-level passage, Add to History and AI actions are unavailable. How a selection is
  classified (e.g. word = a short run within one sentence; sentence = within one paragraph;
  paragraph = a whole paragraph or more) is left to the builder.
- **History belongs to a version.** Nested history lives inside the specific version of its parent
  in which it was made. Switching the parent to a version without it hides it; switching back
  restores it. Nothing is lost.

### 5.0 What edits and actions mean for History [Claude's calls]

- **The current version is always the live text in the document.** Typing in a passage that
  has history edits the version you're on, in place — it does not create a new version. Other
  versions are untouched. Switching away and back keeps your typed edits (the current version is
  re-read from the document before switching). If the passage is edited past recognition, its
  entry is dropped (§5.1 rule 2) — never resurrected over your text.
- **One AI action = one history passage.** A Rewrite/Proofread of a selection, however many
  changes it proposes, adds one passage for that selection: the original, plus the result of
  whatever was accepted (e.g. 3 of 7 accepted → one version containing those 3). If nothing is
  accepted, nothing is stored.
- **History follows the file.** A rename or move (in Finder, the sidebar, iCloud) or a Save As
  keeps the document's history attached to the file it now lives in. This needs an identity that
  survives a move (e.g. a bookmark), retargeted through the existing hooks such as
  `onExternalMove`; `FileIdentity` stays the definition of "already open" and is not changed.
  Only a genuinely deleted file loses its history.

### 5.1 Storage and cleanup

- Never inside the `.md`. A small text-only store in Lineform's own container, keyed by
  `FileIdentity` (the repo's one definition of "same file"). Nothing is written until a version is
  actually kept; discarded suggestions write nothing.
- Persists across quit and relaunch.
- Automatic cleanup:
  1. File deleted → its history removed (checked lazily, e.g. on launch / next access).
  2. Passage no longer found in the file (heavily edited here or in another app) → that entry
     dropped.
  3. Untouched for ~30 days → dropped.
- Manual: **Settings ▸ Clear History** removes everything.
- Anchoring a passage robustly across edits (including external edits and live reload) is the
  builder's design problem; failure mode is "history quietly disappears", never "wrong text
  replaced".

## 6. History mode (the only place history is visible)

Normal writing shows **no history markers at all** — no dots, underlines, or AI indicators.

**Entering:** the left sidebar gets a **History** row, stacked under Outline / Files /
Markdown Basics, with its own icon. It appears only when the current document has history (that
row is the one quiet sign history exists) and is hidden otherwise. Clicking it enters History
mode. Also reachable from the View menu with a shortcut **[Claude's call]**.

**In History mode** (see the mockup):
- The document is **read-only**.
- Unchanged text recedes (dimmed); passages with history are in full ink on a light tint.
- **Hover previews** (slightly stronger tint) and does not change the sidebar.
- **Click selects**, and the selection **stays** until another passage with history is clicked.
  Clicking unchanged text does not clear it.
- The selected passage is **blue** (tint), with version **dots** under its first word: filled =
  current, outline = others, ~5px, hairline (~0.75px) outline, set well below the baseline so they
  never crowd the text.
- **← / →** step the selected passage's versions; clicking a version row does the same.
- The text showing when you leave **is** the document text and autosaves as usual. Each step
  updates the document immediately (what you see is the file) **[Claude's call]**; the whole
  History-mode session is one undo step, so a single ⌘Z after leaving restores how the document
  was when you entered. If the file changes on disk during History mode, live reload wins and
  History mode closes.
- **Never an empty History mode.** Because the row only exists when the document has history,
  you can't enter History mode on a document with nothing in it. If you delete the last version
  while in History mode, the row disappears and the sidebar returns to the tab you came from,
  back in normal writing. Switching to a document with no history also leaves History mode.
- **Read-only is visible:** the bottom hint names the mode, and typing while in History mode
  does not silently fail — the first keystroke leaves History mode and types normally
  **[Claude's call; alternative is a brief "History mode — Esc to write" notice]**.
- **Leaving:** Esc, or clicking Outline / Files / Markdown Basics. Returns to normal writing with
  no markers.

**History sidebar contents:**
- **Level switcher** — **Paragraph · Sentence · Word**, in that order, **centred**, shown only when
  the selected passage belongs to a nested group. It lists every level present in the **whole
  nested group** (the outermost passage and everything inside it), whichever member was clicked:
  - paragraph with a sentence with a word inside → all three, from any of them;
  - sentence with a word inside (paragraph unchanged) → Sentence · Word;
  - a lone passage with nothing nested → no switcher at all.
  Clicking a level moves the selection up to the enclosing passage or down into the nested one.
  Current level shown in the primary colour/weight.
- **Version rows** — the Files-row pattern exactly: same margins and alignment, one line, "…"
  truncation, ✎/✦ icon, selected row = blue label on the system selection grey. Only the selected
  passage's versions, never the whole document's.
- Hint at the bottom: "Click to select · ← → switch version · Esc closes" (localized).

**Typography and colour — consistent with the existing sidebar:** the level switcher uses the
same style as the Files tab's "Sort folders by" control (12pt, medium) with the sidebar's
existing `secondaryTextColor` / `primaryTextColor`; rows use the existing Files-row styles. No new
greys or blues — reuse the sidebar's.

## 7. Themes, contrast, accessibility

- Every tint and the blue selection must read on all five themes (Original, Paper, Calm, Quiet,
  Night), with Automatic Dark Mode, and on the sidebar's grey chrome. Text inside a tint or
  selection must keep ≥ 4.5:1 (`Theme.contrastRatio` / `Theme.readableInk` are the repo's
  definitions). Grey-on-grey (tint over the grey sidebar/selection grey) must be checked
  explicitly. Add tests that assert contrast per theme, as the repo already does for inks.
- Pills, dimmed pieces, review navigation and version stepping need keyboard and VoiceOver paths
  (`accessibilityCustomActions`, per the repo invariant for hit-tested affordances). Announce
  review progress ("3 of 7") rather than overriding the text view's AX value.
- All new chrome strings localized (EN, ES, FR, DE, JA, zh-Hans) via `String(localized:)`;
  document content never localized. The sidebar width does not grow — shorten English if a
  translation is too long.

## 8. Constraints and repo rules that apply

- Mac App Store only, sandboxed. `com.apple.security.network.client` is already present in both
  entitlements files. Plain-http local endpoints ("Other") may need an ATS exception for local
  networking — builder to verify; do not add any `temporary-exception` entitlement.
- **Network rule changes:** today Lineform's only outbound call is the announcements feed. AI
  calls happen **only** on an explicit user action with a connected provider; with no AI
  connected there must be no new network traffic. The test host is the app — nothing AI-related
  may fire at launch (guard per `AnnouncementStore.isRunningUnderTests` pattern if anything is
  wired at launch).
- Remote image never-fetch, spell-check-local, and every other existing privacy invariant stand.
- Treat AI responses as untrusted input (size limits, no rendering as HTML).
- Coexists with Apple's Writing Tools and the existing `MarkdownWritingToolsProtection`; do not
  remove either.
- Edits applied from review/history go through the localized replace path, preserve the
  document's line endings and BOM (see the Rendering invariants in `CLAUDE.md`), and register
  with undo.
- Docs to update when built: `CLAUDE.md` (feature line + any new invariants),
  `docs/architecture/editor-behavior.md` and `app-integration.md`, `Lineform/Resources/*.md`
  (privacy, help), and the local `POSITIONING_AND_MARKETING.md`.
- **Public positioning:** the owner does not consider bring-your-own AI to conflict with "No AI
  inside" (nothing is inside). Public copy still needs a wording pass so no claim becomes
  inaccurate — e.g. "No AI built in. Connect your own if you want it."

## 9. Left to the builder

- Prompt wording for each action and how responses are parsed into discrete changes (a
  structured diff, not a whole-text swap, is required for per-change accept/reject).
- Passage anchoring and classification (word/sentence/paragraph) algorithms.
- History store format and the cleanup schedule mechanics.
- Exact progress indicator, icons for the History sidebar row, and the View-menu shortcut
  (must not collide with existing shortcuts).
- How insertions read during review, within "calm, monotone".
- Default models per provider.
