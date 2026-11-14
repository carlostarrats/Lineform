# Lineform 1.8 follow-ups — History, AI review, Connect Your AI, themes

Date: 2026-11-13. Source: the owner's hands-on QA of 1.8.0 build 38, recorded in
`docs/notes/2026-11-13-history-and-ai-qa-notes.md`, and the decisions made in conversation after it.
Branch: `feature/qa-1-8-followups` (from `origin/main` cf6febf).

## Intent

History and the AI actions shipped in 1.8.0 work, but first real use showed they are hard to
read and hard to steer: you can't see how to leave History, adding a passage shows it twice, you
can't write an alternative without leaving History, AI rewrites arrive as many tiny decisions on
fiddly inline pills, and the cards cover the text. The goal is a calmer, clearer version of the
same features. Nothing new in scope beyond what the owner asked for.

**Success:** the owner can add a passage, write alternatives, flip between them and leave History
without hunting; an AI rewrite of a sentence is one clear decision; every floating card looks like
the "Make Lineform your default" card.

**Anti-goals:** no new AI capabilities; no change to what is sent to providers; no new
dependencies; no weakening of any invariant in `CLAUDE.md`.

## Decisions (owner's)

### AI review: option A, one decision per action
- Mockup: https://claude.ai/artifact/9mYVqzK6XyDf8B5rYrA2NJ (option A).
- **Granularity: whatever you selected is ONE change.** A word, a sentence or a paragraph — Trim,
  Cut in half, Rewrite and Proofread alike — comes back as a single Accept / Reject decision.
  (Build 38 split a one-sentence rewrite into three word-level hunks; that is the bug.) When the
  selection spans several prose segments (lines or Markdown structure in between), all segment
  revisions still form that one change and are applied together; structure verification runs on
  the whole change.
- **Presentation.** The inline ✓|✕ pills are removed. The changed text shows the original struck
  through and dimmed, followed by the replacement with a highlight. When a segment replaces a
  whole line, its replacement starts on its own line (as in the mockup); otherwise it follows
  inline. Word-level diffing is no longer used to split decisions (it may still be used to keep
  unchanged words un-struck, at the builder's discretion, as long as it stays one decision).
- **Controls.** A compact card in the bottom-right corner, sized to its content (no dead space):
  short label, Reject, Accept, ✕. Return accepts; Esc rejects and ends the review. No position
  counter, no arrows, no Accept All / Reject All — there is only one decision.

### Floating cards
- The AI progress card ("Rewriting with ChatGPT… / Esc to cancel", ✕) and the review card move to
  the **bottom-right** and match the default-app card exactly: same corner inset, corner radius,
  padding, type sizes, and ✕ position. Width fits content up to the existing cap.

### History
- **Exit button** to the right of the History title, styled like the Files tab's "Change" capsule.
  It returns to the tab that was showing before History.
- **Add to History** stores **only the original** (one version, not a copy plus an identical live
  version), opens the sidebar, and enters History focused on that passage. If you leave History
  without adding a replacement, that passage is discarded (nothing was added). Existing stored
  history with adjacent identical versions is collapsed on load.
- **Add a replacement:** below the version list, a centered capsule button (same size and style as
  the Files "Change" button) labelled "Add Replacement". Clicking it shows an editable field; you
  type a word, phrase or sentence; Return adds it as a new version, makes it current (so it shows
  in the document), and the button appears again below for another. Esc cancels the field.
- **Other passages stay visible** when one is selected: they keep a dimmed but clearly visible
  highlight (checked in light and dark themes, pinned by a test); hovering one brings it to full
  strength; clicking selects it.
- **Pointing-hand cursor** over highlighted passages in History; I-beam elsewhere.
- **Footer hint** left-aligned, matching the empty-state text's 14pt inset.
- **First AI accept** opens the sidebar on History once ever, to show it exists; later accepts don't.
- The History right-click menu already hides formatting in build 38 — no change.

### Themes and fonts
- **Per-theme edits persist.** Each preset keeps the writer's own edits when you switch away and
  back. The edited preset stays selected. **Reset to Default resets only the current preset.**
  The existing single stored profile migrates into its preset's slot.
- **Quiet card in Dark Mode** gets a visible edge when unselected (the stroke follows the dark
  chrome instead of a fixed black 8%).
- **Font group "Writing" is removed.** Owner chose "Non-system", but "Monospaced" is Apple's own
  system monospaced font (not JetBrains Mono; nothing is bundled for it), so it moves into the
  **System** group. When non-system fonts are added later, they get a group then. *(Claude's
  call, flagged to the owner.)*

### Connect Your AI
- **Model tiers.** Per provider, a two-option picker: **Standard** (default) and **Higher quality**,
  each showing its model name. No cost text. Changeable while connected without re-entering the
  key. Stored per provider in UserDefaults as raw identifiers.
  - Claude: `claude-haiku-5-5` / `claude-sonnet-5-5`.
  - ChatGPT: `gpt-6-luna` / `gpt-6.1-terra`.
  - Google: current Flash-Lite / Gemini 3.8 Flash — exact IDs verified against Google's model list
    at build time.
  - Verify the OpenAI models accept the chat-completions endpoint Lineform uses.
- **Key-permission guidance**, one line per provider page:
  - ChatGPT: choose Restricted, set Model capabilities to Request, leave everything else off.
  - Claude and Google: make a key just for Lineform and set a monthly spend limit.
- **Security:** plain `http://` for "Other" is allowed only for this Mac (`localhost`,
  `127.0.0.1`, `::1`); `.local` addresses require https.
- An expired key's error message mentions expiry as a possible cause.

## Approaches considered (review controls)

- **A — corner card, struck-through original + highlighted replacement** (chosen): nothing inside
  the text line, full-size buttons in one fixed place, works in narrow windows.
- B — floating buttons under the current change: close to the eye, but covers the next line and
  moves as you step.
- C — buttons in the right margin: clear, but needs a wide window; no room in Split or narrow
  windows.

## Constraints

All `CLAUDE.md` invariants hold, notably: hit-tested affordances need accessibility mirrors;
every UI string through `String(localized:)` (EN key) with the five localizations; raw values
never localized; sidebar sub-views take `usesDarkChrome` threaded from the theme; opening the
sidebar must go through AppKit `toggleSidebar:` (never a bare binding write); reader inks through
`Theme.readableInk`; no `NSWindow` in the default test plan; perf rules for per-keystroke paths.

## Left to the builder

Exact sentence-boundary algorithm (reuse `AISentenceSplitter` / `.bySentences`); the strikethrough
and highlight colours (from `HistoryPalette`, AA-checked); persistence key names; test structure.
