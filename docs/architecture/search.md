# Search & navigation

Find & Replace, cross-file search, and the ⌘K quick-open palette.

Extracted from `CLAUDE.md` so the always-loaded file stays scannable. Content is verbatim —
these are the same load-bearing notes, not a summary. Read this file before changing anything
in this area.

- Find & Replace (single file, Write-mode): **Edit ▸ Find & Replace… (⌥⌘F)** reveals a compact **floating card** over the top-trailing corner of the page (Safari-⌘F style; Write/Split — ⌥⌘F from Read auto-switches to Write, mirroring how search forces Write to reach a match). The card is deliberately an **overlay in the editor shell's ZStack, never a laid-out top strip**: the translucent unified toolbar takes its color from the content directly beneath it, so ANY full-width bar at the top edge (material, theme color, or transparent) visibly recolors the navigation when it opens — the overlay leaves the top-edge hierarchy identical, so the header cannot change (QA-diagnosed the hard way; do not convert it back to a layout row). Two **fixed card variants** keyed on `Theme.usesDarkChrome` (not per-theme tinting): the Muse-modal light card on light themes, a dark card (white 0.15 fill, faint light border) on Quiet/Night, with `.environment(\.colorScheme,…)` pinned to match so the field border/labels always read. It is deliberately **additive** to the settled search UX — the FIND term stays in the existing native `.searchable` toolbar field (`searchQuery`); the card adds only a replacement `TextField` + **Replace** / **Replace All** + a quiet match-count hint + close (Esc in the replace field also dismisses). No second find field, no case-sensitivity toggle, no regex, no cross-file replace (single open file only — cross-file would drift toward a notes database). Matching **reuses `EditorSearchResolver.matches`**, so replace matches exactly what search finds (case- **and** diacritic-insensitive). Pure logic lives in `EditorSearchResolver` (`replaceAll` rewrites back-to-front so ranges stay valid and never re-scans its own output; `replaceMatch`; `nextActiveIndexAfterReplacement` picks "Replace & find next", anchored past the inserted text and skipping any match **inside** the insertion on both the forward and wrap paths so a self-containing replacement like `cat`→`cats` can't cascade). The edit is applied through a new one-shot `requestedReplacement` binding on `MarkdownTextViewRepresentable` (mirrors `requestedSelection`), routed to `LineformTextView.applyExternalReplacement` → the same `applyWholeTextReplacement` (shouldChangeText → setAttributedString → didChangeText) path the formatting commands use — so **Replace All is a single ⌘Z step** and `document.text` syncs via the delegate. `applyExternalReplacement` is **idempotent on text** (`guard string != edit.text`) because the didChangeText re-render can re-enter before the async binding-clear lands; without it Replace All could register a second undo step. `replaceCurrentMatch` re-resolves against **live** `document.text` (not the debounced `searchMatches`) and only replaces a range that is still a real match, so a body edit within the search debounce can't overwrite non-matching characters. Menu command is a `CommandGroup(after: .pasteboard)` sibling of Find, posting the window-scoped `showFindReplace` notification (the focusSearch pattern). See `docs/superpowers/specs/2026-07-04-find-and-replace-design.md`.

- Cross-file search (All Files scope): the native toolbar search field gains SwiftUI `.searchScopes` — **This File** (default, the settled in-document search) and **All Files**, which renders a transient READ-ONLY results page over the current tab's content area (`CrossFileSearchResultsView`; never a floating card and never a laid-out top strip — the toolbar-sampling rule) listing every scanned Workspace/iCloud file whose *filename or contents* contain the query (one row per file: name, relative path, content-match snippets with hits emphasized, total match count; filename hits are emphasized in the name itself; ranked by total match count via `CrossFileSearchResolver.ranked`). Matching reuses `EditorSearchResolver.matches` (literal, case- and diacritic-insensitive) so cross-file agrees with in-file search by construction; ranking/snippets are pure tested logic in `Lineform/Editor/CrossFileSearchResolver.swift`; `CrossFileSearchModel` reads candidate files off-main (0.3s debounce, latest-wins generation guard, skips iCloud-evicted and >1 MB *contents*, but still returns a matching filename) with no persisted index and no FSEvents watcher (candidates = the store's last scan, the ⌘K universe incl. the 80-per-folder cap; first All Files activation triggers the deferred iCloud scan exactly like ⌘K, so the laziness invariant holds). Clicking a result opens via `openSidebarFile` (new tab / switch to existing) and then `clearAllSearchState()` wipes ALL search residue (query, highlights, scope back to This File — which also dismisses the system scope bar); Esc and document swaps do the same. The scope bar is system-drawn and deliberately unstyled; the search field itself is never wrapped or rebuilt. No cross-file replace, no saved searches, no new shortcuts (deliberate). See `docs/superpowers/specs/2026-07-17-cross-file-search-design.md`.

- Jump to File (⌘K): a centered quick-open palette that fuzzy-searches filenames across the Workspace + iCloud roots (the Files sidebar's scanned tree) and opens the selection exactly like a sidebar click (new tab, or switch to the existing tab). Pure flatten/rank logic in `QuickOpenIndex` (`Lineform/Outline/QuickOpenIndex.swift`); the card is `QuickOpenPalette` (`Lineform/Editor/QuickOpenPalette.swift`), presented through the shared `museModalLayer` scrim in `EditorContainerView`. The first ⌘K of a session triggers the deferred iCloud scan (`OutlineFileBrowserStore.hasPerformedICloudScan` guard) — the laziness invariant holds; the palette starts no FSEvents watcher and inherits the sidebar's 80-per-folder cap. Freeing ⌘K moved **Format ▸ Link to ⌘L** (`AppMenuConfiguration.linkCommandKeyEquivalent`, shared with the editor's right-click menu hint). The store is owned by `EditorContainerView` (hoisted 2026-07-17) and injected into the sidebar. See `docs/superpowers/specs/2026-07-17-quick-open-jump-to-file-design.md`.

## Replace could rewrite its own output (audited 2026-07-27)

Two independent defects produced the same visible failure — clicking Replace repeatedly grew the
text (`log` → `logs` → `logss`) while the counter kept saying the same thing — and either one alone
reproduces it, so both had to be fixed.

**The wrap only knew about the LAST insertion.** `nextActiveIndexAfterReplacement`'s wrap path was
`matches.firstIndex { $0.location < replacedLocation }`, and `replacedLocation` describes only the
replacement just made. After the final occurrence was replaced, the wrap landed on a match sitting
inside an EARLIER replacement — indistinguishable from untouched document text. `the log and the log`
with Replace ×4 gave `the logss and the logss`, autosaved at every step. The resolver now takes
`priorInsertions` and skips matches overlapping ANY of them, on both the forward and wrap paths.
`insertionsAfterReplacement` rolls those spans forward across each replacement's length delta, and
the container clears them whenever the search is re-aimed (query change, scope change, tab switch,
cross-file open).

**The debounced refresh un-did the anti-cascade nil.** When the only remaining match lies inside the
text it just inserted, the resolver deliberately returns nil, which greys out Replace. 200 ms later
`recomputeDerived` called `refreshSearchMatches(selectFirstWhenNeeded: activeSearchIndex == nil)` —
and because the index WAS nil, it selected match 0: the match inside the replacement. Replace lit up
again and the cascade resumed. Since a human clicking a button always pauses more than 200 ms, this
was the normal path, not a race. A nil produced by a replacement is a DECISION, not an absence, and
the `replacementInsertions` state is what distinguishes the two.

**Snippet elision split surrogate pairs.** `CrossFileSearchResolver` sliced the line with window
bounds documented in characters but measured in UTF-16 units, so a boundary landing inside an emoji
put a lone surrogate on the pill, which bridges to U+FFFD — a replacement character that is not in
the user's file. Both edges now snap via `rangeOfComposedCharacterSequence`. Same class as the Table
Reformat padding rule.

**VoiceOver heard the search status on every typing pause.** `refreshSearchMatches` ended with an
unconditional `announceSearchStatus()`, and it runs from the debounced derived refresh — so leaving
a query in the toolbar field and going back to writing re-posted the identical announcement after
every lull in typing, for the whole session. It is now posted only when the summary changes.
