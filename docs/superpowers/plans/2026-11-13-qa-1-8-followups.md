# Lineform 1.8 QA Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the History, AI review, Connect Your AI and theme issues found in 1.8.0 build 38 QA, as decided in the approved design.

**Architecture:** Changes stay inside existing modules: History engine/controller/sidebar (`Lineform/Documents`, `Lineform/Editor`, `Lineform/Outline`), AI review (`Lineform/AI`, `EditorContainerView`), reading settings (`Lineform/ReadingExperience`). The AI review collapses to one change per action, which deletes the pill cell and simplifies session/composition. History's "add" stores a single version and gains an in-sidebar "Add Replacement" editor.

**Tech Stack:** Swift, SwiftUI + AppKit/TextKit, XCTest, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-11-13-qa-1-8-followups-design.md` (read it with this plan). Code map from exploration: `docs/notes/2026-11-13-history-and-ai-qa-notes.md` lists the owner's observations.

## Global Constraints

- Every UI string through `String(localized:)` with the English text as key, translated in `Lineform/Localizable.xcstrings` for es, fr, de, ja, zh-Hans. Raw values / persisted identifiers never localized.
- Sidebar sub-views take `usesDarkChrome` threaded from the theme; never read `@Environment(\.colorScheme)`.
- Opening the sidebar goes through `NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)` and only when it is hidden — never a bare `isShowingOutline = true` write.
- Reader inks via `Theme.readableInk` / `HistoryPalette`; contrast pinned in `HistoryPaletteTests`.
- Any geometry hit-tested affordance gets an accessibility mirror (`accessibilityCustomActions` or `.accessibilityActions`).
- No `NSWindow` in default-plan tests (window tests belong in `LineformHosted`).
- Scoped test runs always include `LocalizationSourceSweepTests` and `LocalizationCatalogTests`.
- Build/test command (from the worktree root):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<Suite> -only-testing:LineformTests/LocalizationSourceSweepTests -only-testing:LineformTests/LocalizationCatalogTests`
- Floating card metrics come from `DefaultMarkdownAppCard` / `FloatingCardChrome` (`Lineform/Editor/AnnouncementCard.swift`): corner radius 12, edge inset 16, padding h14 v13, title 13 semibold, body 11.5, ✕ 18×18 with 9pt bold xmark at top-trailing offset −2.
- Model IDs: Claude `claude-haiku-5-5` / `claude-sonnet-5-5`; ChatGPT `gpt-6-luna` / `gpt-6.1-terra`; Google Flash-Lite / Gemini 3.8 Flash with IDs verified in Task 4.
- New files must be added to `Lineform.xcodeproj/project.pbxproj` by hand (objectVersion 56, no synced groups; four sections, sequential `1F0000xx` IDs); removed files removed from all four sections.

## Review Focus

1. A History passage that has AI versions (two versions from `recordAccepted`) must NOT be discarded on History exit — only single-version passages from Add to History are. (Task 8 test.)
2. An AI selection spanning several prose segments (a list or a line break in the middle) must review as one change and apply every segment's revision while leaving the Markdown between them untouched. (Task 5 test.)
3. Add Replacement with text equal to the current version, or empty/whitespace, must not create a version. (Task 8 test.)
4. Per-preset overrides must survive relaunch and an existing user's single stored profile must migrate into the matching preset's slot without losing their edits. (Task 3 test.)
5. A stored `Lineform.ai.otherEndpoint` of `http://x.local/...` saved by 1.8.0 must not be used to send a key in clear — reject on resolve, not only on connect. (Task 4 test.)

---

### Task 1: Monospaced joins the System font group

**Files:**
- Modify: `Lineform/ReadingExperience/FontOption.swift:19-43`
- Modify: `Lineform/Localizable.xcstrings` (remove the now-unused "Writing" entry)
- Test: `LineformTests/FontOptionTests.swift`

- [ ] **Step 1: Write the failing test** `testMonospacedIsInTheSystemGroupAndThereIsNoWritingGroup`: `FontOption.groupedOptions.map(\.name) == [String(localized: "System"), String(localized: "Reading & Accessibility")]`; System group option ids `== [.sfPro, .newYork, .jetBrainsMono]`.
- [ ] **Step 2: Run** `-only-testing:LineformTests/FontOptionTests` → FAIL.
- [ ] **Step 3:** Move the Monospaced option into the System group (after New York); delete the "Writing" group and its catalog entry. Keep the `.jetBrainsMono` id (persisted).
- [ ] **Step 4: Run** → PASS (plus the two localization suites).
- [ ] **Step 5: Commit** "Move Monospaced into the System font group".

### Task 2: Visible unselected preset cards in dark chrome

**Files:**
- Modify: `Lineform/ReadingExperience/ReadingExperiencePopover.swift:339-410`
- Test: `LineformTests/ReadingPresetTests.swift`

**Interfaces:** Produces `static func ReadingPresetCard.unselectedStrokeColor(usesDarkChrome: Bool) -> NSColor`.

- [ ] **Step 1: Failing test** `testUnselectedPresetStrokeIsVisibleOnDarkChrome`: contrast between `unselectedStrokeColor(usesDarkChrome: true)` composited over `Theme.quiet.backgroundColor` and that background ≥ 1.3; light variant equals `NSColor.black.withAlphaComponent(0.08)`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement: dark → `NSColor.white.withAlphaComponent(0.18)`; light unchanged. Pass `usesDarkChrome` into `ReadingPresetCard` from the popover (threaded, not environment).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** "Give unselected theme cards a visible edge in dark chrome".

### Task 3: Each preset keeps its own edits

**Files:**
- Modify: `Lineform/ReadingExperience/ReadingProfileStore.swift`
- Modify: `Lineform/ReadingExperience/ReadingExperiencePopover.swift` (selection + Reset button)
- Test: `LineformTests/ReadingProfileStoreTests.swift`

**Interfaces — Produces:**
- `ReadingProfileStore.activePresetID: UUID?` (`@Published`, persisted under `"Lineform.activeReadingPresetID"`)
- overrides persisted as JSON `[String(uuid): ReadingProfile]` under `"Lineform.readingPresetOverrides"`
- `func applyPreset(_ preset: ReadingPreset)` — loads the override if present, else `preset.profile`; sets `activePresetID`
- `func update(_:)` — also writes the result into `overrides[activePresetID]` when non-nil
- `func resetCurrentPreset()` — drops the active preset's override and applies its pristine profile; with no active preset, behaves like today's `resetToDefault()`

- [ ] **Step 1: Failing tests:**
  - `testEditsSurviveSwitchingPresetsAndBack`: apply original, `update { $0.fontSize = 22 }`, apply quiet, apply original → `activeProfile.fontSize == 22`, `activePresetID == ReadingPreset.original.id`.
  - `testResetRestoresOnlyTheCurrentPreset`: edit original and quiet, `resetCurrentPreset()` on quiet → quiet pristine, switching to original still shows its edit.
  - `testOverridesPersistAcrossStores`: new store on the same `UserDefaults` suite restores override and `activePresetID`.
  - `testLegacyProfileMigratesIntoMatchingPresetSlot`: defaults hold only `"Lineform.activeReadingProfile"` = original with `fontSize 22` → new store has `activePresetID == original.id` and the edit preserved (match by `profile.id` == preset's profile id; fall back to `matchingPresetID`).
- [ ] **Step 2: Run** `-only-testing:LineformTests/ReadingProfileStoreTests` → FAIL.
- [ ] **Step 3:** Implement the store changes. In the popover, a preset card is selected when `preset.id == store.activePresetID` (fall back to `matchingPresetID` when nil); the Reset button calls `resetCurrentPreset()`. Keep the legacy key written for compatibility.
- [ ] **Step 4: Run** → PASS; also run `ReadingPresetTests`, `ReadingProfileTests`.
- [ ] **Step 5:** Update `docs/architecture/app-integration.md` (or the reading-settings section that documents the store) with the per-preset rule. **Commit** "Keep each reading preset's own edits; reset only the current preset".

### Task 4: Connect Your AI — model tiers, key guidance, http hardening

**Files:**
- Modify: `Lineform/AI/AIProvider.swift`, `Lineform/AI/AIConnectionStore.swift`, `Lineform/AI/ConnectAIView.swift`, `Lineform/AI/ConnectAIPresentation.swift`, `Lineform/AI/AIClient.swift` (unauthorized message)
- Test: `LineformTests/AIConnectionStoreTests.swift`, `LineformTests/ConnectAIPresentationTests.swift`

**Interfaces — Produces:**
- `enum AIModelTier: String, CaseIterable { case standard, higherQuality }` with localized `title` ("Standard", "Higher quality")
- `AIProvider.model(for tier: AIModelTier) -> String?` (replaces `defaultModel`; `.other` → nil)
- `AIConnectionStore.tier(for: AIProvider) -> AIModelTier` / `setTier(_:for:)`, persisted under `"Lineform.ai.tier.<provider.rawValue>"`, default `.standard`
- `ConnectAIPresentation.keyGuidance(for: AIProvider) -> String?`

- [ ] **Step 1: Verify model IDs.** Fetch Google's Gemini models page (ai.google.dev/gemini-api/docs/models) and OpenAI's model pages for `gpt-6-luna` and `gpt-6.1-terra`; record the exact Gemini Flash-Lite and 3.8 Flash IDs and confirm both OpenAI models list `v1/chat/completions` as a supported endpoint. If either OpenAI model is Responses-only, stop and report rather than switching endpoints.
- [ ] **Step 2: Failing tests:**
  - `testTierDefaultsToStandardAndPersistsPerProvider`
  - `testResolvedConnectionUsesTierModel`: claude standard → `claude-haiku-5-5`; higherQuality → `claude-sonnet-5-5`; chatGPT → `gpt-6-luna` / `gpt-6.1-terra`.
  - `testPlainHTTPAllowedOnlyForLoopback`: `localhost`, `127.0.0.1`, `[::1]` allowed; `printer.local` → `.insecureAddress` (replaces the existing `printer.local` expectation).
  - `testStoredPlainHTTPLocalEndpointIsNotResolved`: defaults pre-seeded with provider `other` + `http://box.local:1234/v1/chat/completions` → `resolvedConnection() == nil`.
  - `testKeyGuidanceCopy`: chatGPT → "Choose Restricted, set Model capabilities to Request, and leave everything else off."; claude and google → "Make a key just for Lineform, and set a monthly spend limit."; other → nil.
- [ ] **Step 3: Run** → FAIL.
- [ ] **Step 4:** Implement. View: guidance line (`.callout`, secondary) under the "Create an API key" link; segmented `Picker` of tiers with the model name in a caption below it, shown for the big three both before connecting and in the connected state (changing it calls `setTier`, no key re-entry). Unauthorized message becomes "The key wasn't accepted. It may have expired. Check it in Connect Your AI."
- [ ] **Step 5: Run** → PASS (+ localization suites).
- [ ] **Step 6:** Update `docs/architecture/app-integration.md` AI section (models, tiers, http rule) and `Lineform/Resources/Privacy.md` if it names models. **Commit** "Add model tiers and key guidance to Connect Your AI; require https off this Mac".

### Task 5: One AI change per action

**Files:**
- Modify: `Lineform/AI/AIChangeBuilder.swift`, `Lineform/AI/AIActionController.swift:~280-300`, `Lineform/AI/AIReviewSession.swift`
- Test: `LineformTests/AIChangeBuilderTests.swift`, `LineformTests/AIReviewSessionTests.swift`

**Interfaces — Produces:** `AIChangeBuilder.change(segments: [ProseSegment], revisions: [String?], in text: String) -> AIChange?` — one change whose `range` spans from the first changed segment's start to the last changed segment's end, `original` = that substring, `replacement` = the same substring with each changed segment's text replaced by its revision (unchanged text between segments kept byte-for-byte). nil when no revision differs. `AIReviewSession` keeps its API but always holds 0 or 1 change.

- [ ] **Step 1: Failing tests:**
  - `testOneSentenceRewriteIsOneChange`: text "Though wise men, at their end know dark is right,", one segment, revision "Though wise men, at their end, know that darkness is right," → one change, range = whole segment.
  - `testMultiSegmentSelectionIsOneChangeKeepingStructure`: text "- alpha one\n- beta two\n", segments for "alpha one" and "beta two", revisions "alpha 1" / "beta 2" → one change with replacement "alpha 1\n- beta 2".
  - `testUnchangedSegmentsAtEdgesAreExcluded`: three segments, only the middle revised → range covers only the middle segment.
  - `testProofreadIsAlsoOneChange` via `AIActionController` path or builder with two word fixes → one change.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement `change(...)`; `AIActionController.finish` builds the session from `[change].compactMap{$0}`. Remove the word-level LCS (`diff`, `tokens`, `maxDiffCells`) if nothing else uses them (grep first). Structure verification runs once on the whole change.
- [ ] **Step 4: Run** → PASS; also `AIReviewSessionTests`, `AIActionPromptTests`.
- [ ] **Step 5: Commit** "Review an AI action as one change".

### Task 6: Review presentation without pills

**Files:**
- Delete: `Lineform/AI/AIReviewPillCell.swift`, `LineformTests/AIReviewPillCellTests.swift` (and pbxproj entries)
- Modify: `Lineform/AI/AIReviewComposition.swift`, `Lineform/AI/AIReviewTextView.swift`, `Lineform/Editor/HistoryPalette.swift`
- Test: `LineformTests/AIReviewCompositionTests.swift`, `LineformTests/AIReviewTextViewTests.swift`, `LineformTests/HistoryPaletteTests.swift`

**Interfaces — Produces:** `AIReviewComposition` drops `pillIndices`/`pillCharacter`; gains `replacementRanges: [Int: NSRange]`. When the change's original range starts at a line start and ends at a line end, a line break (the document's `MarkdownLineEnding.inForce`) separates original and replacement in the overlay only. `HistoryPalette.reviewInsertTint(for: Theme) -> NSColor`.

- [ ] **Step 1: Failing tests:**
  - `testWholeLineChangeStacksReplacementOnItsOwnLine`: overlay string for the sentence example == original + "\n" + replacement; `removedRanges[id]` covers the original, `replacementRanges[id]` the replacement.
  - `testMidLineChangeIsInline`: original "end know dark" mid-line → no inserted line break, separator per `AIReviewSession.separator`.
  - `testCompositionHasNoObjectReplacementCharacter`.
  - `testReviewInsertTintIsVisibleInEveryTheme` (contrast of tint-over-page vs page ≥ 1.15 for all built-in themes; text over tint keeps AA).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement: removed text dimmed (`recededInk`) with single strikethrough; replacement drawn with `reviewInsertTint` background (temporary attribute). Remove pill drawing, pill hit-testing, `toggleKeep` click path, and ←/→ / pill accessibility actions; keep custom actions "Accept Change", "Reject Change", "End Review". Return = accept, Esc = reject and end. Cursor stays arrow over the overlay (it is not editable).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5:** Update `docs/architecture/editor-behavior.md` AI review section. **Commit** "Show an AI change as struck original plus highlighted replacement".

### Task 7: AI cards in the bottom-right corner

**Files:**
- Modify: `Lineform/AI/AIReviewCards.swift`, `Lineform/Editor/EditorContainerView.swift:1009-1049, 2514-2573`
- Test: `LineformTests/AIReviewCardPresentationTests.swift`

**Interfaces — Produces:** `AIReviewCard` (label, Reject, Accept, ✕) and `AIStatusCard` sharing `DefaultMarkdownAppCard` metrics; both placed by the existing `.overlay(alignment: .bottomTrailing)` stack.

- [ ] **Step 1: Failing tests:** presentation: `AIReviewCardPresentation.title(for: .rewrite) == "Rewrite ready"` (one per action: "Trim ready", "Cut ready", "Proofread ready"); `buttonTitles == ("Reject", "Accept")`; no `positionText`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement. Review card layout: VStack — title 13 semibold + subtitle 11.5 secondary ("Return to accept · Esc to reject"), then HStack Reject (bordered small) + Accept (borderedProminent small); ✕ top-trailing like the announcement card. Width hugs content (cap `AnnouncementCard.maximumWidth`). Status card: spinner in the icon slot, title "Rewriting with ChatGPT…" 13 semibold, "Esc to cancel" 11.5, ✕ top-trailing. Move the AI overlay from `.bottom` to the `.bottomTrailing` stack, keeping the announcement/default-app suppression while an AI card shows.
- [ ] **Step 4: Run** → PASS. Build and look at both cards in Light and Quiet-dark next to the default-app card (seed its defaults) — pixel check corner, inset, ✕ position.
- [ ] **Step 5: Commit** "Move AI cards to the corner and match the default-app card".

### Task 8: History engine — single-version add, replacements, discard on exit

**Files:**
- Modify: `Lineform/Documents/DocumentHistoryEngine.swift:313-421`, `Lineform/Documents/PassageHistoryStore.swift` (load-time collapse), `Lineform/Editor/DocumentHistoryController.swift`
- Test: `LineformTests/DocumentHistoryEngineTests.swift`, `LineformTests/DocumentHistoryControllerTests.swift`, `LineformTests/PassageHistoryStoreTests.swift`

**Interfaces — Produces:**
- `DocumentHistoryEngine.add` creates `versions: [live(you)]`, `currentIndex 0`; on `.existing` it adds nothing and returns that passage's id.
- `mutating func addReplacement(_ text: String, to id: UUID) -> HistoryEdit?` — appends `HistoryVersion(text, .you)`, selects it, returns the document edit; nil when `text` trimmed is empty or equals the current version's text.
- `mutating func discardUnrevisedPassages() -> [UUID]` — removes passages with exactly one version.
- `static func collapsingAdjacentDuplicates(_ history: DocumentHistory) -> DocumentHistory` applied on load.
- Controller: `func add(_ range: NSRange)` now returns the passage id; `exitHistoryMode()` calls `discardUnrevisedPassages()` then saves; `func addReplacement(_ text: String)` acts on the selected passage; `var onRequestShowHistory: ((UUID) -> Void)?` fired after add.

- [ ] **Step 1: Failing tests** (replace `testAddCreatesPassageWithFrozenCopyAndLiveVersion`):
  - `testAddStoresOnlyTheOriginal`: versions.count == 1, text "gentle".
  - `testAddReplacementAppendsAndSelects`: edit replaces "gentle" with "dangerous" in the document; versions == ["gentle","dangerous"], currentIndex 1.
  - `testAddReplacementIgnoresEmptyAndUnchanged`.
  - `testExitDiscardsPassagesWithNoReplacement` and `testExitKeepsAIRecordedPassages` (Review Focus 1).
  - `testLoadCollapsesAdjacentDuplicateVersions`: stored ["gentle","gentle"] → ["gentle"] (and then discarded on next exit).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement; keep `appendLive` behaviour for AI `recordAccepted`. Update `docs/superpowers/plans/2026-11-12-history.md`? No — update `docs/architecture/editor-behavior.md` History section instead.
- [ ] **Step 4: Run** → PASS; also `LineformTextViewHistoryTests`, `SettingsClearHistoryTests`.
- [ ] **Step 5: Commit** "Store only the original on Add to History; add replacements; discard unrevised passages".

### Task 9: History sidebar — Exit, Add Replacement, auto-open, hint

**Files:**
- Modify: `Lineform/Outline/HistorySidebarView.swift`, `Lineform/Outline/OutlineSidebarView.swift` (shared capsule style, exit/replacement closures), `Lineform/Editor/EditorContainerView.swift` (`selectSidebarTab`, sidebar opening, wiring), `Lineform/AI/AIActionController.swift` (first-accept open)
- Test: `LineformTests/HistorySidebarPresentationTests.swift`, `LineformTests/DocumentHistoryControllerTests.swift`

**Interfaces — Produces:**
- `SidebarCapsuleButtonStyle(usesDarkChrome:emphasis:)` factored from `OutlineFileRootRow`'s Change capsule (11 medium, h-padding 10, height 22, colours as today); the Files row uses it unchanged.
- `HistorySidebarView` gains `onExit: () -> Void`, `onAddReplacement: (String) -> Void`.
- `HistorySidebarPresentation.exitTitle == "Exit"`, `addReplacementTitle == "Add Replacement"`, `replacementPlaceholder == "Type a replacement"`.
- `EditorContainerView.showHistory(focusing: UUID)` — opens the sidebar via `toggleSidebar:` when hidden, then `selectSidebarTab(.history)` and focuses the passage.
- UserDefaults `"Lineform.history.didIntroduceAfterAI"` (Bool).

- [ ] **Step 1: Failing tests:** presentation strings; `testExitReturnsToPreviousTab` (presentation/model level); controller `testAddRequestsShowingHistoryForThePassage` (`onRequestShowHistory` receives the id); `testFirstAIAcceptRequestsHistoryOnlyOnce`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement:
  - Exit capsule trailing in a header row "History" + Spacer + Exit, padding matching the Files root row; calls `exitHistoryMode()`.
  - Below the version rows, a centered `Add Replacement` capsule; tapping swaps it for a rounded text field (Return commits via `onAddReplacement`, Esc cancels); after commit the capsule returns below the new row. While the field has focus, arrow/Esc keys go to the field, not History navigation.
  - Footer hint: `.multilineTextAlignment(.leading)`, `.frame(maxWidth: .infinity, alignment: .leading)`, horizontal padding 14.
  - Add to History → `onRequestShowHistory` → `showHistory(focusing:)`.
  - First accepted AI review (flag unset) → `showHistory(focusing:)` for the first recorded passage, set flag.
- [ ] **Step 4: Run** → PASS (+ localization suites, translations for the three new strings).
- [ ] **Step 5: Commit** "Add Exit and Add Replacement to History; open History after adding".

### Task 10: History visuals — visible other passages, hover, pointing hand

**Files:**
- Modify: `Lineform/Editor/LineformTextView+History.swift:175-326, 590-606`, `Lineform/Editor/LineformTextView.swift:325-331`, `Lineform/Editor/HistoryPalette.swift`
- Test: `LineformTests/HistoryPaletteTests.swift`, `LineformTests/LineformTextViewHistoryTests.swift`

**Interfaces — Produces:** `HistoryPalette.focusOtherTint(for: Theme) -> NSColor`; `LineformTextView.historyCursor(at: NSPoint) -> NSCursor`.

- [ ] **Step 1: Failing tests:**
  - `testFocusOtherTintIsVisibleInEveryTheme`: composited tint vs page contrast ≥ 1.15 in all built-in themes and Quiet-dark; text in `focusOtherInk` over it keeps ≥ 3:1.
  - `testHistoryCursorIsPointingHandOverPassagesOnly` (point over a located passage → `.pointingHand`; elsewhere → `.iBeam`; outside History mode → `.iBeam`).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3:** Implement: in the focused branch of `drawHistoryIfNeeded`, fill other passages with `focusOtherTint`, the hovered one with `hoverTint`; in `refreshHistoryRecededInk` give the hovered passage full ink. Cursor: add `.cursorUpdate` to the tracking area, set the cursor from `historyCursor(at:)` in `mouseMoved`/`cursorUpdate` while in History mode, invalidate cursor rects on enter/exit. Raise `tintAlpha` if needed so the unfocused wash meets the same floor.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5:** Update the History "Focus" paragraph in `docs/architecture/editor-behavior.md` (replaces "no fills"). **Commit** "Keep other History passages visible; pointing hand over passages".

### Task 11: Docs sweep, full verification, hand QA

- [ ] **Step 1:** Update `CLAUDE.md` (tracked as `Claude.md`) feature lines that change (font groups unchanged list; AI review is one decision; model tiers), `Lineform/Resources/*.md` user help that describes AI review, History or fonts, and the QA notes file (mark items done).
- [ ] **Step 2:** Full default suite: the default-gate command in CLAUDE.md. Expected: all pass; report counts.
- [ ] **Step 3:** Build Debug, launch `$BUILT_PRODUCTS_DIR/Lineform.app` with `open -a`, verify the running process path, and exercise with the owner's poem file: Add to History → sidebar opens, single "gentle" row, Add Replacement works, Exit returns to the previous tab, other passages visible, pointing hand; Rewrite with the local stub server (`scripts/ai-stub-server.py`) → one change, corner cards; reading presets keep edits; Quiet card visible in dark. Screenshot each.
- [ ] **Step 4: Commit** docs; leave the branch unpushed for the owner's review.
