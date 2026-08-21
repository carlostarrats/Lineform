# Remove AI Features Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** The removal shipped. Lineform has no in-app AI feature; use
> `AGENTS.md` for the current product boundary.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Lineform's selected-text AI editing features entirely — code, tests, build references, and every user-facing surface — after first archiving the working implementation to a recoverable git tag + note.

**Architecture:** This is a *removal*, not a rewrite. Standalone AI files are deleted; five mixed editor/app files have their AI wiring surgically excised while every non-AI behavior stays byte-identical. The regression safety net is the **existing non-AI test suite staying green** plus a **grep sweep** proving no live AI references remain — not new tests (there is no new behavior to test). The Xcode project uses classic explicit file references (no synchronized groups), so every deleted file must also be removed from `Lineform.xcodeproj/project.pbxproj` or the build breaks.

**Tech Stack:** Swift, SwiftUI, AppKit, TextKit, Xcode (`xcodebuild`), macOS 14+.

## Global Constraints

- Verification gate (serial, per CLAUDE.md; quit Xcode first):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
- Keep `Lineform/Editor/MarkdownWritingToolsProtection.swift` — native OS Writing Tools protection, confirmed no dependency on removed code. Do NOT delete it.
- Do NOT touch entitlements or the Debug/Release iCloud isolation. No AI-specific entitlement exists.
- Do NOT refactor surviving code beyond what deleting AI wiring requires. No unrelated metadata churn.
- The app must **build green** at every commit. Because the AI code is tightly coupled, the entire code removal (Task 3) is one atomic build-green commit — do not commit a partially-removed, non-compiling state.
- Historical AI docs under `docs/` (benchmark, dogfood, old specs/plans) stay in place. Only their status as active gates is removed (Task 5, via CLAUDE.md).
- Spec: `docs/superpowers/specs/2026-07-01-remove-ai-features-design.md`. Index: `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`.

---

## AI code inventory (reference for Task 3)

**Delete outright (standalone):**
- All 13 files in `Lineform/Intelligence/`:
  `IntelligenceAvailability.swift`, `IntelligentEditingAction.swift`, `IntelligentEditingEvaluation.swift`, `IntelligentEditingPromptBuilder.swift`, `IntelligentEditingProofreadChangeReview.swift`, `IntelligentEditingQualityPipeline.swift`, `IntelligentEditingRequestCoordinator.swift`, `IntelligentEditingRunner.swift`, `IntelligentEditingService.swift`, `IntelligentEditingSuggestion.swift`, `IntelligentEditingSuggestionBar.swift`, `LineformProofreadingSupport.swift`, `MarkdownDiff.swift`.
- `Lineform/Editor/IntelligenceActionRail.swift`
- `Lineform/Editor/IntelligenceInstructionComposer.swift`

**Delete AI test files (`LineformTests/`):**
`IntelligentEditingActionTests.swift`, `IntelligentEditingCursorTests.swift`, `IntelligentEditingDogfoodTests.swift`, `IntelligentEditingEvaluationTests.swift`, `IntelligentEditingMessyWritingCorpusTests.swift`, `IntelligentEditingPromptBuilderTests.swift`, `IntelligentEditingQualityPipelineTests.swift`, `IntelligentEditingRunnerTests.swift`, `MarkdownDiffTests.swift`.

**Surgically strip AI members (keep everything else in these files):**

`Lineform/App/LineformAppNotification.swift` — remove `case runIntelligentEditingAction` (line ~7) and its `switch` arm (~18-19).

`Lineform/App/AppCommands.swift` — remove `keepsTopLevelIntelligenceMenu`, `intelligencePrimaryCommandTitle`, `lineformIntelligenceCommandTitles` (lines ~21-24); the `if AppMenuConfiguration.keepsTopLevelIntelligenceMenu { CommandMenu("Intelligence") {...} }` block (~240-269); the `intelligenceAvailable` computed property (~271-273).

`Lineform/Editor/MarkdownTextViewRepresentable.swift` — remove `var intelligentSuggestionRange: NSRange?` (~13) and the `textView.setIntelligentSuggestionRange(...)` call (~67).

`Lineform/Editor/LineformTextView.swift` — remove `activeIntelligentSuggestionRange` (~14), `cancelPendingAutomaticIntelligenceMenu()` + its call site (~223, ~462), `shouldOpenAutomaticIntelligenceMenuAfterMouseUp()` (~271), `hasPendingAutomaticIntelligenceMenu` (~275), `drawIntelligentSuggestionHighlightIfNeeded()` + its call (~305, ~465-472), `setIntelligentSuggestionRange(_:)` (~309-310), `@objc runIntelligentEditingAction(_:)` (~445-457), `scheduleAutomaticIntelligenceMenuIfNeeded()` (~459). Keep all mouse/menu/drawing logic that is not AI-gated.

`Lineform/Editor/EditorStatusPresentation.swift` — `EditorStatusFormatter.statusMessage`/`statusIndicator` currently take `intelligentEditingStatus:` and `intelligenceAvailability:`. Remove those parameters and the private `userFacingMessage(from:)` + the two Apple-Intelligence message/prefix arrays (~92-129). Keep `LastSavedDisplay`, `statisticsText`, `statusText`, `metadataText`, `lastSavedText/Display`, `EditorStatusIndicator`, `EditorStatusBar`.

`Lineform/Editor/EditorPresentation.swift` — delete AI-only types: `IntelligentEditingOverlayPlacement`, `IntelligenceActionRailPresentation`, `IntelligenceInstructionComposerPresentation`, `IntelligenceInstructionComposerState`, `IntelligentEditingSelectionDismissal`, `IntelligentEditingRequestLifecycle`, `IntelligenceActionRailPlacement`, `IntelligenceActionRailHoverCursor`, `IntelligenceToolbarTogglePresentation`, `IntelligenceToolbarIcon`. Remove `EditorToolbarVisibility.showsIntelligence(...)`, the `.intelligence` case from `EditorToolbarAction` (~517) and its arms (~525-526, ~535-536), and drop `.intelligence` from the toolbar-actions array (~546-547). Keep display-mode, markdown-basics, and reading-experience toolbar logic.

`Lineform/Editor/EditorContainerView.swift` (heaviest) — remove the 12 AI `@State` vars + `intelligentEditingService` (~20-34); the `initialIntelligenceRailEnabled` init param + its assignment (~38, ~42); the `.onReceive(runIntelligentEditingAction)` modifier (~91-99); the suggestion-expiry `onChange` branch + `refreshRetainedIntelligenceSelection` call (~151-167); the composer view block (~249-280); the options-panel block (~287-315); the three AI `.animation(...)` modifiers (~323-340); the `intelligentSuggestionRange:` argument to the representable (~381); all AI computed vars (`activeIntelligentSuggestion`, `shouldShowIntelligentOptionsPanel`, `isPreparingIntelligentSuggestion`, `hasActionableIntelligentSelection`, `activeIntelligenceSelection`, `hasActiveIntelligentSelection`, `hasVisibleIntelligenceComposerSelection`, `intelligenceComposerIsEnabled`, ~389-436); all AI methods (`runIntelligentEditingAction`, `runIntelligentEditingRequest`, `navigateToSuggestedChange`, `acceptIntelligentSuggestion`, `acceptAllIntelligentSuggestion`, `acceptCurrentProofreadChange`, `retryIntelligentSuggestion`, `rejectIntelligentSuggestion`, `clearIntelligentSuggestions`, `refreshRetainedIntelligenceSelection`, `clearRetainedIntelligenceSelectionIfIdle`, ~565-778); the `notificationPayloadSelectedRange` helper if only AI uses it; and the `intelligentEditingStatus` argument passed to `EditorStatusFormatter` (~545). Update any `EditorContainerView(...)` call sites that passed `initialIntelligenceRailEnabled:`. Keep everything else: sidebar/file switching, search, outline, formatting, toolbar (minus intelligence), reading inspector, status bar, display modes.

---

### Task 1: Archive the AI implementation

**Files:**
- Create: `docs/notes/ai-flow-archive.md`
- Git: annotated tag `ai-features-archive`

**Interfaces:**
- Produces: git tag `ai-features-archive` (revive point); note documenting the flow.

- [ ] **Step 1: Create the annotated archive tag on the current commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
git tag -a ai-features-archive -m "Frozen: complete working selected-text AI editing implementation before removal. Revive baseline for a future OS."
```

- [ ] **Step 2: Verify the tag points at a commit that still contains the AI code**

```bash
git tag -l ai-features-archive
git ls-tree -r --name-only ai-features-archive -- Lineform/Intelligence | head
```
Expected: tag listed; `Lineform/Intelligence/…` files enumerated.

- [ ] **Step 3: Write the archive note**

Create `docs/notes/ai-flow-archive.md`:

```markdown
# AI Flow Archive (removed 2026-07-01)

Lineform once shipped selected-text AI editing. It was removed because output quality
was below bar and the feature was unnecessary for the product's positioning
(a reader/editor for agent-written markdown). This note is the "maybe note": a map for
reviving the approach if a future OS makes it worthwhile.

## What it did
Five selected-text actions: Proofread, Rewrite, Summarize, Make Shorter, Clean Markdown.

## Architecture (flow order)
`IntelligentEditingPromptBuilder` (action-specific prompts)
→ `FoundationModelsIntelligentEditingService` / `IntelligentEditingService` (Apple Foundation Models + response validation)
→ `IntelligentEditingRunner` (scopes to selection, validates replacement, builds suggestion)
→ `IntelligentEditingRequestCoordinator` (async, blocks stale suggestions after edits)
→ `IntelligentEditingEvaluationRubric` (scores output, blocks bad classes)
→ `IntelligentEditingSuggestion` / `IntelligentEditingSuggestionBar` (UI)
Editor surface: `IntelligenceActionRail`, `IntelligenceInstructionComposer`; change review via `MarkdownDiff` + `IntelligentEditingProofreadChangeReview`. Availability gate: `IntelligenceAvailability`.

## Revive baseline
    git checkout ai-features-archive -- Lineform/Intelligence
    git checkout ai-features-archive -- Lineform/Editor/IntelligenceActionRail.swift Lineform/Editor/IntelligenceInstructionComposer.swift
Then re-wire into `EditorContainerView` / `AppCommands` / `LineformAppNotification` (see that tag's versions as reference) and re-add the deleted `LineformTests/IntelligentEditing*` tests.

## Historical design/benchmark docs (left in the repo)
`docs/intelligent-editing-benchmarks.md`, `docs/intelligent-editing-dogfood*.md`,
`docs/harper-proofread-comparison.md`, and `docs/superpowers/{specs,plans}/*intelligent-editing*` / `*ai-action-rail*` / `*intel-universal*`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/notes/ai-flow-archive.md
git commit -m "Archive AI flow: tag + revive note before removal"
```

---

### Task 2: Baseline the current test suite (know what green looks like)

**Files:** none (measurement only).

- [ ] **Step 1: Run the full serial suite once, BEFORE removal**

Quit Xcode, then:
```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -40
```
Expected: suite passes. **Record the exact "Executed N tests … N passed" line** and the pass count of the AI test files, so Task 3's post-removal count is explainable (total drops by exactly the deleted AI tests). Do not commit; this is a reference measurement.

---

### Task 3: Remove all AI code (atomic build-green commit)

**Files:** delete + modify per the **AI code inventory** above; modify `Lineform.xcodeproj/project.pbxproj`.

**Interfaces:**
- Consumes: `ai-features-archive` tag (Task 1) as the recoverable copy.
- Produces: an app with zero AI code that builds and passes the non-AI suite.

- [ ] **Step 1: Delete the standalone AI files and AI tests**

```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
git rm -r Lineform/Intelligence
git rm Lineform/Editor/IntelligenceActionRail.swift Lineform/Editor/IntelligenceInstructionComposer.swift
git rm LineformTests/IntelligentEditingActionTests.swift LineformTests/IntelligentEditingCursorTests.swift \
       LineformTests/IntelligentEditingDogfoodTests.swift LineformTests/IntelligentEditingEvaluationTests.swift \
       LineformTests/IntelligentEditingMessyWritingCorpusTests.swift LineformTests/IntelligentEditingPromptBuilderTests.swift \
       LineformTests/IntelligentEditingQualityPipelineTests.swift LineformTests/IntelligentEditingRunnerTests.swift \
       LineformTests/MarkdownDiffTests.swift
```

- [ ] **Step 2: Remove every deleted file's references from `project.pbxproj`**

The project has no synchronized groups, so each deleted `.swift` still has `PBXBuildFile`, `PBXFileReference`, and group-`children` entries that must go. Prefer the `xcodeproj` Ruby gem if available; otherwise remove the lines by hand.

```bash
# If the xcodeproj gem is available this is safest:
ruby -e 'require "xcodeproj"' 2>/dev/null && echo "xcodeproj gem present" || echo "no gem — remove pbxproj lines by hand"
```
For each deleted file, delete the three line types that mention its name. After editing, sanity-check no dangling references remain:
```bash
grep -nE "IntelligentEditing|IntelligenceActionRail|IntelligenceInstructionComposer|IntelligenceAvailability|LineformProofreadingSupport|MarkdownDiff" Lineform.xcodeproj/project.pbxproj || echo "clean"
```
Expected: `clean`.

- [ ] **Step 3: Strip AI members from the five mixed files**

Apply the surgery listed under **AI code inventory** to, in this order (least-coupled first so the compiler guides you): `LineformAppNotification.swift`, `AppCommands.swift`, `MarkdownTextViewRepresentable.swift`, `LineformTextView.swift`, `EditorStatusPresentation.swift`, `EditorPresentation.swift`, `EditorContainerView.swift`. Work compiler-guided: remove declarations, then delete each resulting error's AI-only usage. Do not alter non-AI logic.

- [ ] **Step 4: Build until clean**

```bash
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -30
```
Expected: `BUILD SUCCEEDED`. Fix any remaining reference the compiler flags (all should be AI-only).

- [ ] **Step 5: Grep sweep for live AI references in source**

```bash
grep -rniE "intelligen|intelligentediting|foundationmodels" Lineform/ | grep -viE "writingtools|writing tools"
```
Expected: empty. (`MarkdownWritingToolsProtection` is the only Writing-Tools file and contains no "intelligen" string.)

- [ ] **Step 6: Run the full serial suite**

Quit Xcode, then run the Global-Constraints gate command.
Expected: PASS. Compare against Task 2's baseline: total = baseline minus the deleted AI tests, 0 failures. Run `EditorDisplayModeTests` specifically to confirm the drawer-motion/display-mode behavior is intact:
```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/EditorDisplayModeTests 2>&1 | tail -15
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Remove selected-text AI editing (code, tests, project refs)"
```

---

### Task 4: Remove AI from user-facing surfaces

**Files:** Modify `README.md`, `Lineform/Resources/Help.md`, `Lineform/Resources/Privacy.md`, `Lineform/Resources/AppStoreMetadata.md`, `Lineform/Resources/AccessibilityNutritionLabel.md`, `Lineform/Resources/ReleaseReadiness.md`, `Lineform/Resources/FirstLaunchIntro/intro.js`.

- [ ] **Step 1: Find every AI mention in user-facing surfaces**

```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
grep -rniE "apple intelligence|intelligen|proofread|rewrite|make shorter|clean markdown|ai-|\bai\b|foundation model" \
  README.md Lineform/Resources/Help.md Lineform/Resources/Privacy.md Lineform/Resources/AppStoreMetadata.md \
  Lineform/Resources/AccessibilityNutritionLabel.md Lineform/Resources/ReleaseReadiness.md Lineform/Resources/FirstLaunchIntro/intro.js
```

- [ ] **Step 2: Edit each surface to remove AI feature copy/claims**

Remove AI feature bullets, the Apple-Intelligence availability lines, the "selected-text editing" claims, and any AI mention in the first-launch intro (`intro.js`). Keep the surrounding non-AI copy grammatical and the feature lists coherent (no dangling "and", no orphaned headings). Do NOT invent replacement features — the positioning is "a reader/editor for agent-written markdown"; AI simply goes away.

- [ ] **Step 3: Re-grep to confirm surfaces are clean**

Re-run Step 1's command. Expected: empty (or only false positives like the word "email"/"maintain" — inspect any hit and confirm it is not an AI reference).

- [ ] **Step 4: Commit**

```bash
git add README.md Lineform/Resources/
git commit -m "Remove AI feature copy from user-facing surfaces"
```

---

### Task 5: Update agent guidance (CLAUDE.md)

**Files:** Modify `CLAUDE.md`.

- [ ] **Step 1: Remove AI sections from CLAUDE.md**

Delete the **Intelligent Editing** section, the **AI Benchmark Docs** section, and the "Live Apple Intelligence single/options eval" + "Repeated live Apple Intelligence stability eval" command blocks and the intelligent-editing bullets in **Verification Commands**, plus the "For intelligent editing, acceptable means…" block under **Quality Bar**. Leave the general deterministic test gate, iCloud, icon, DMG, and release sections intact. Remove `Lineform/Intelligence` and `Lineform/Intelligence`-related entries from the Architecture Map / Main Features lists.

- [ ] **Step 2: Verify no active AI gate remains in CLAUDE.md**

```bash
grep -niE "intelligen|proofread|apple intelligence|foundation model|IntelligentEditing" CLAUDE.md
```
Expected: empty.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Drop AI sections and eval gates from agent guide"
```

---

### Task 6: Final verification and manual smoke

**Files:** none.

- [ ] **Step 1: Whole-repo live-reference sweep**

```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
grep -rniE "intelligen|intelligentediting" Lineform/ README.md CLAUDE.md \
  | grep -viE "writingtools|writing tools"
```
Expected: empty. Historical `docs/` files are intentionally excluded and may still match — that is correct.

- [ ] **Step 2: Full serial suite, final run**

Quit Xcode; run the Global-Constraints gate command. Record exact pass/fail counts.
Expected: PASS, 0 failures.

- [ ] **Step 3: Manual smoke checklist**

Launch the built app and confirm:
- Write / Read / Preview modes switch and render.
- Text selection, markdown formatting commands, and the outline all work.
- Reading profiles (size, theme, spacing) apply.
- **No** Intelligence menu, **no** AI action rail/composer, **no** AI status text.
- First-launch intro no longer mentions AI (reset via a fresh user-defaults domain if needed).

- [ ] **Step 4: Update the decomposition index status**

In `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`, check off `- [x] 0 — Remove AI features`. Commit:
```bash
git add docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md
git commit -m "Mark AI removal complete in agent-reader index"
```

---

## Notes for the implementer

- **Why no failing-test-first TDD here:** this task deletes behavior, so the correctness proof is the *existing* non-AI suite staying green plus the grep sweeps — not new tests. Do not fabricate placeholder tests.
- **Biggest risk:** `EditorContainerView.swift` (200 AI refs) and `EditorPresentation.swift`. Go compiler-guided and re-run `EditorDisplayModeTests` after (Task 3, Step 6) — those hosted tests guard load-sensitive drawer motion the CLAUDE.md warns about.
- **pbxproj is the sneaky failure mode:** if the build errors with "Build input file cannot be found" or a linker/duplicate error, a `project.pbxproj` reference to a deleted file was missed — re-run Task 3 Step 2's grep.
- **Parallelizable:** Tasks 4 and 5 are independent of each other and of Task 3's outcome (they touch only docs), so a subagent-driven run can dispatch them in parallel once Task 3 is committed.
```
