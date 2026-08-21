# Competitor Feature Scan — macOS Markdown Editors

> **HISTORICAL MARKET SNAPSHOT.** Competitor details and the Lineform inventory below reflect the
> date of this scan. They are not current product copy. Use `POSITIONING_AND_MARKETING.md` and the
> architecture documents for current Lineform capabilities.

**Date:** 2026-07-18
**Purpose:** Survey competing Markdown editors, note features worth adopting for Lineform (macOS), filtered against Lineform's positioning: calm, native, file-based, local-first, no AI, source-available (PolyForm Shield). Also captures the pricing landscape, since many of these charge and monetization is now on the table.
**Status:** Research working doc. Not a commitment. Verify each idea against the current build before acting — this is a dated snapshot.

> **Status pass 2026-07-25 — most of §3 has SHIPPED. Do not re-scope it.**
> Verified against the code, not memory:
> - **A. Local inline images** — SHIPPED (block-only, left-aligned, Reconnect pill; remote URLs still a placeholder, invariant intact).
> - **B. Callouts** — SHIPPED (5 GitHub types, monochrome title row, custom titles).
> - **C. Code highlighting + copy button** — SHIPPED (`Lineform/Preview/CodeHighlighting.swift`, native tokenizer: swift / js-ts / python / json / bash + script fallback). Line numbers still correctly skipped.
> - **D. DOCX + RTF export** — **RTF shipped; DOCX deliberately DROPPED**, not deferred: no native writer, and RTF opens cleanly in Word/Pages/Google Docs/TextEdit. See `docs/architecture/export-and-print.md`. Treat D as closed.
> - **E. Read-aloud** — SHIPPED (`SpeechController` + `SpeechTextExtractor`; skips code/math/diagrams, never reads `#`/`*`).
> - **F. Custom preview/export themes** — shipped in a much narrower form than proposed: **two** PDF presets, **Normal** and **Styled** (`ExportTypographyPreset.all`). The 4-preset *Standard / Manuscript / Compact / Article* set described in the 2026-07-18 plan and spec **never shipped** — those two files are historical design records and were intentionally left unedited. On-screen typographic themes (as opposed to reader color themes) remain unbuilt.
> - **G. ⌘E view-mode toggle** — SHIPPED exactly as decided (Write ↔ Read; Split stays on the toolbar).
> - **H. Session word-count goal** — **NOT built.** `DocumentStatistics` counts words/characters and the status bar shows them, but there is no target or progress affordance.
>
> Everything in §4 (wiki-links, tags, scratchpad, style check, EPUB) and §5 (reject list) is unchanged and still unbuilt, by decision. **Git history moved to rejected on 2026-07-26** — see §4.
>
> A follow-on gap review on the same date found items this scan never covered — chiefly **list continuation on Return**, **live spell check**, **footnotes**, **table authoring**, and **HTML export**. See `docs/research/2026-07-25-feature-backlog.md`.

---

## 1. Products surveyed (18 sites, 15 distinct apps)

| Product | Platforms | iOS? | Price model | Positioning |
|---|---|---|---|---|
| **iA Writer** | Mac, Win, iOS, Android | ✅ | One-time, per platform (~$50 Mac) | The benchmark. Focus mode, Style Check, restraint. |
| **Bear** | Mac, iOS, iPad | ✅ | Subscription $2.99/mo, $29.99/yr | Beautiful notes app. DB-backed (not plain files). |
| **Byword** | Mac, iOS, iPad | ✅ | One-time $10.99 | Minimal writer + blog publishing. **Now stale/abandoned.** |
| **MWeb Pro** | Mac, iOS, iPad | ✅ | One-time ~$21–35 | Feature-heavy: static blog gen, publishing, dual file+DB. |
| **Raven** | Mac, iOS, iPad + CLI | ✅ | $14 lifetime → $24.99/yr (Aug 2026) | **Closest positioned rival**: file-based, local-first, AI-native. |
| **iWriter Pro** | Mac, iOS, iPad | ✅ | One-time, "subscription-free" | Minimal MultiMarkdown, iCloud sync. |
| **uFocus** | Mac, iOS, iPad, Vision Pro | ✅ | Free / donation | Distraction-free; Fountain screenplay; typewriter sounds. |
| **Clearly** | Mac, iOS, iPad | ✅ | Free, open source | Native, no telemetry. Callouts, KaTeX, Mermaid, regex F&R. |
| **Read.md** | Mac, iOS, iPad, Android, Web | ✅ | $24.99 lifetime / $9.99/yr | **Reader**, not editor. GitHub repo browsing. |
| **Ink MD (LitSquare)** | Mac only | ❌ | Not stated | AI (Apple Intelligence/Ollama/OpenAI), Zotero, subtitles. |
| **Resomark** | Mac only | ❌ | Free (beta) | Local AI-collab; Git diff review; 100k+ file scale. |
| **Markdown Peek** | Mac only | ❌ | Free | Viewer only. Spacebar raw/rendered toggle; Quick Look. |
| **Mud** | Mac only | ❌ | Free, open source | Viewer only. Themes, TOC, CLI, AI-workflow oriented. |
| **Markdown Studio** (.app) | Mac, Win, Linux (Tauri) | ❌ | Free | Cross-desktop, distraction-free, 2 themes. |
| **MDStudio** (mdstudio.app) | Web only | ❌ | Free (BYO API key) | AI prompt-testing tool. Not really a writing app. |

**Read of the market:**
- **iOS is table stakes.** 8 of 15 have a real iOS/iPadOS app; every serious *writing* app (vs. viewer/AI-tool) ships iOS. This validates the iOS plan — see the companion doc.
- **Paid is normal and healthy.** One-time $11–50 is the dominant model; subscriptions ($30–40/yr) exist but draw complaints. Free/OSS is a crowded low end. Charging for Lineform is defensible.
- **AI is the current land-grab** (Ink MD, Resomark, MDStudio, Raven). Lineform's "No AI inside" is now a *differentiator*, not a gap — lean into it, don't chase it.
- **Byword is the cautionary tale:** beloved, minimal, then abandoned (iOS last updated 2020). Reviewers now send buyers to iA Writer. There's an opening for a *maintained*, calm, native writer.

---

## 2. What Lineform already has (do NOT re-scope)

Confirmed shipping per CLAUDE.md, so these came up in the scan but are **done**:

Mermaid diagrams · inline + block LaTeX math (SwiftMath) · GFM tables · multi-document tabs · Find & Replace (single file) · cross-file search · Jump-to-File (⌘K) · Quick Look Finder extension · rich PDF export + Print · reader themes (Apple Books-style) · reading profiles (size/leading/spacing/margins/column/focus/ruler) · focus mode · outline navigation · live external-file reload · iCloud container · Write/Read/Split modes · task checkboxes · strikethrough/HR/blockquote/lists · syntax highlighting · save-state status bar.

Lineform is already **ahead of most of this list** on rendering (Mermaid + math + native tables beats Byword, iWriter, Markdown Peek, Mud, Markdown Studio, uFocus). The gaps are narrow and specific.

---

## 3. Recommended — on-brand, worth doing

Ranked by fit + impact. All are file-based, local, network-free, and calm — consistent with positioning.

### A. Inline local image rendering ⭐ (biggest real gap)
- **Who has it:** Bear, MWeb, Raven, Clearly (paste-image), Inkdown, iA Writer.
- **Today:** Lineform deliberately renders `![alt](url)` as a `🖼` placeholder (Task 6 deferral).
- **Why now:** This is the one place Lineform visibly trails a reader like Read.md and every notes app. A *local, file-referenced, network-free* image render (Read/Preview only, from relative/absolute file paths, no remote fetch) is squarely on-brand — real files, portable, no cloud. Remote URLs can stay as the placeholder to preserve the "never hits the network" invariant.
- **Pair with:** paste/drag an image → write the file next to the doc + insert the relative link (Bear/Clearly pattern). Keeps documents portable.
- **Risk:** low–medium (rendering), but respects the deferral's original caution. Scope to local files first.

### B. Callouts / admonitions (`> [!NOTE]`, `> [!WARNING]`, …)
- **Who has it:** Clearly (15+ types, foldable), GitHub, Obsidian — now a de-facto GFM extension.
- **Why:** Pure text, degrades gracefully in other editors, teaches well in the Info tab. Fits the blockquote machinery already in the block-grouping layer.
- **Risk:** low. Natural extension of existing blockquote rendering.

### C. Code block enhancements: language syntax highlighting + copy button (line numbers: skip)
- **Who has it:** Clearly (line numbers, diff), Mud, MWeb, Ink MD; Byword notably *lacks* code highlighting and gets dinged for it.
- **Today (verified 2026-07-18):** Fenced code is **flat monospace, one color — NOT syntax-highlighted**, in every mode. What Lineform has is *Markdown* highlighting (markup only: heading/list/blockquote markers, the ` ``` ` fence delimiters), NOT *code-language* highlighting. The fence's language tag (` ```swift `) is parsed but unused: in Write mode code content gets one uniform inline-code color (`MarkdownSyntaxHighlighter.swift:263`); in Read/Preview it's uniform `codeAttributes`, no tokens at all (`MarkdownPreviewRenderer.swift:431`). No line-number gutter anywhere.
- **Decision (2026-07-18):**
  - **DO — language syntax highlighting.** The flat one-color code block is the weakest part of Lineform's code rendering and technical writers notice it. The real feature of this group; worth the weight. Keep the tokenizer native/light.
  - **DO — hover "copy" button** on each code block. Small, universally loved, low risk. Ship alongside the highlighting.
  - **SKIP — line numbers.** A numbered gutter reads "code IDE," fights Lineform's calm feel, and needs fiddly layout so numbers don't break copy-paste or wrapping. Low payoff for a writing app. Parked; revisit only as an explicit opt-in if ever requested.
- **Why:** Long-form technical writing is a real audience; highlighting + copy is the on-brand slice.
- **Risk:** low–medium (a highlighter grammar set adds weight; keep it native/light). Copy button is low.

### D. More export formats: Word (.docx) and RTF and PDF (Saving as a pdf should be moved into save as, and these others should be there as well)
- **Who has it:** Byword, iA Writer, Ink MD (both), MWeb, Bear.
- **Why:** Portability is a *core* Lineform principle ("documents outlive the app"). PDF already ships; DOCX/RTF export is the natural next portability step and is frequently requested by writers who hand work to editors/collaborators on Word.
- **Risk:** low. Reuses the export renderer seam; DOCX is the fiddly one.

### E. Read-aloud / text-to-speech
- **Who has it:** Ink MD (dictation + TTS).
- **Why:** Directly serves the "readable long-form text" positioning and accessibility values already visible in the codebase (AA contrast tests, Atkinson/OpenDyslexic fonts, VoiceOver). System `AVSpeechSynthesizer` is native, offline, free.
- **Risk:** low.

### F. Custom preview/export themes (CSS or JSON)
- **Who has it:** Ink MD (JSON theme import/export), MWeb (32 themes + custom), Byword (custom stylesheet — a top user request it never fully delivered).
- **Why:** Calm, personal, one-time-configure. Could ship as a curated set first (like the reader themes) before user-editable.
- **Risk:** medium (scope creep risk — start curated, not a plugin system).

### G. Keyboard shortcut to switch view modes (`⌘E` toggles Write↔Read)
- **Who has it:** the spacebar raw↔rendered flip in Markdown Peek/Mud inspired this, but those are *read-only viewers* with no caret — spacebar is free there. In an editor, spacebar must type a space, so the viewer idiom does NOT transplant. The real, on-brand version is an ordinary modifier shortcut on the existing Mode picker.
- **Today:** Lineform has Write/Read/Split, but mode switching is **mouse-only** — the toolbar segmented control and a `Picker("Mode")` in the View menu (`AppCommands.swift:402`) with **no `.keyboardShortcut`**. This is the conspicuous gap: every adjacent View-menu item already has a key (Toggle Outline `⌥⌘0`, Reading Experience `⌥⌘R`).
- **Decision (2026-07-18):** add **`⌘E`** as a toggle between **Write ↔ Read** (matches Obsidian's edit/reading toggle — a recognized convention; `⌘E` is free in-app and doesn't collide with any editor navigation key). **Split stays on the toolbar/menu** — it's the rarely-used third state and folding it into a cycle would be a non-standard behavior that surprises Obsidian muscle memory. Considered and rejected: `⌃1/2/3` (slow pinky-stretch; `⌘1/⌘2` already taken by Format Title/Section), `fn`+arrows (= Home/End on macOS), `⌃`+arrows (= Mission Control Spaces), and a one-key 3-way cycle (not a common convention).
- **Risk:** low. Single key on the existing picker; no caret/typing collision.

### H. Writing session stats / word-count goal
- **Who has it:** implicit in iA Writer, Byword (live counts), writing-app norm.
- **Today:** Lineform shows word/char count in the status bar.
- **Why:** An optional per-session target + progress (quiet, dismissible) suits long drafting sessions without adding noise.
- **Risk:** low. Must stay opt-in and calm — no gamification.

---

## 4. Consider carefully — borderline vs. positioning

These are popular but risk drifting Lineform toward a notes-database or cloud service. Note, don't rush.

- **Wiki-links / backlinks** (Raven, Resomark) — powerful, but the slippery slope toward "note-taking database" that positioning explicitly rejects. If ever done, keep it *file-link* only (`[[file.md]]` resolves to opening the real file), no graph/DB, no auto-index UI. Lean skip for now.
- **Tags** (Bear, MWeb, Raven) — same concern, stronger. This is the notes-database line. **Skip.**
- **Menu-bar scratchpad + global hotkey** (Clearly) — great quick-capture, but "capture" is notes-app framing and needs a scratch storage model. Borderline; revisit only if a clean file-based design exists.
- **Style Check / grammar** (iA Writer's cliché/filler flagging) — on-theme for "calm, readable writing," but it's a big feature and adjacent to the AI-assist space Lineform deliberately avoids. Note as a possible *rules-based* (non-AI, non-network) future item; iA does it without AI.
- **EPUB export** (MWeb, Inkdown) — nice for book-length work, but niche. After DOCX/RTF.
- ~~**Git version history UI**~~ (MWeb, Resomark diff view) — **rejected 2026-07-26.** Shelling out to `git` executes repo-controlled config and hooks, `/usr/bin/git` is an Xcode-CLT install prompt on a clean machine, and the audience already owns a Git tool. macOS Versions (`browseVersions:`) serves the same want with none of it. Full reasoning in `2026-07-25-feature-backlog.md`.

---

## 5. Explicitly reject — off-brand

- **AI features** (Ink MD, Resomark, MDStudio, Raven) — "No AI inside" is a deliberate, marketable stance. The market is saturating; do not chase.
- **Blog publishing to WordPress/Medium/Ghost/Tumblr** (Byword, MWeb, Inkdown) — this is a cloud-service behavior; conflicts with "not a cloud writing service." Byword's differentiator, but off Lineform's axis.
- **Database/library storage mode** (Bear, MWeb Library mode) — violates "real files." Lineform's file-based model is the whole point.
- **Fountain screenplay format** (uFocus) — different product.
- **Zotero / academic citations** (Ink MD) — narrow academic wedge; off-brand.
- **Typewriter sounds** (uFocus, Byword) — cute, but noise, not calm.

---

## 6. Monetization notes (raised by the user)

The scan confirms **charging is viable** — most maintained competitors are paid. Key observations, kept separate from feature work:

- **Bottom line:** *don't* try to charge for the Mac app you've already shipped free — monetize the future iOS app instead. Charging in general is smart; charging *for the thing that's already free* is not.
- **The Mac app is already free + source-available — you can't cleanly un-free it.** Retroactively paywalling a shipped free app reads as a bait-and-switch even when it isn't, alienates the early users who validate a calm indie app, and the source is public anyway (PolyForm Shield lets anyone build it). Keep the Mac app free; it's your credibility and your funnel.
- **Price band:** one-time $11 (Byword) → $50 (iA Writer); MWeb/iWriter/Raven cluster $14–35. Subscriptions ($30–40/yr: Bear, Inkdown, Read.md, Raven's 2026 shift) exist but attract the loudest complaints. A one-time or lifetime price reads as the "calm, trustworthy, no-lock-in" choice and matches Lineform's ethos.
- **License friction:** Lineform is **PolyForm Shield 1.0.0 source-available** and currently free. Charging for a source-available binary is legitimate (many do), but it's a real decision — think through how a paid App Store build coexists with the public source and the source-available promise before pricing anything. Worth a dedicated positioning pass.
- **Where money actually changes hands:** iOS/App Store is where casual writers pay. The most natural monetization is **the iOS app** (paid or universal purchase), keeping the Mac app free/source-available — this preserves the open ethos on desktop while capturing value on mobile. See the iOS doc for models (universal purchase, iOS-paid-Mac-free, optional sync tier).
- **"No AI" as a paid selling point:** in an AI-flooded market, "a calm, private, local, no-AI, no-account writer that respects your files" is a *positioning* people pay for. That's the pitch, not a feature checklist.

---

## 7. Suggested near-term shortlist

If picking a small, high-fit batch that keeps Lineform *Lineform*:

1. **Local inline image rendering** (+ paste-to-file) — closes the one visible gap.
2. **Callouts** — cheap, expected, on-brand.
3. **DOCX/RTF export** — extends the portability principle.
4. **Read-aloud (TTS)** — serves the readability + accessibility mission.
5. **`⌘E` view-mode shortcut** (toggle Write↔Read; Split stays on toolbar) — closes the mouse-only mode-switch gap; tiny.

Everything else: note and defer. Resist the notes-database and AI gravity that pulls this whole category away from what Lineform is.
