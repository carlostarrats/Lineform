# Spec 0 — Remove AI Features (with archival)

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 0)

## Goal

Remove Lineform's selected-text AI editing features entirely — from code, tests, build,
and every user-facing surface — because they do not work well enough and are unnecessary
for the product's positioning (**a reader/editor for agent-written markdown**). Preserve
the full working implementation as a recoverable archive so it can serve as a baseline if a
future OS makes the approach worthwhile.

This is a **removal**, not a rewrite. Non-AI editor behavior must be untouched.

## Non-goals

- No refactor of surviving editor code beyond what deleting AI wiring requires.
- No change to native macOS **Writing Tools protection** (`MarkdownWritingToolsProtection.swift`)
  — that is a defensive system feature (guards code fences / front matter from OS Writing
  Tools), verified to have no dependency on the removed AI code. It stays.
- No metadata churn unrelated to AI removal.

## Archival (do first, before any deletion)

The point is a "maybe note" for the future, not live dead code in the tree.

1. **Git tag.** Create annotated tag `ai-features-archive` on the current commit (the last
   commit that contains the complete, working AI implementation). This makes the entire
   implementation recoverable forever without any files remaining in the working tree.
2. **Archive note.** Write `docs/notes/ai-flow-archive.md` containing:
   - What the AI feature did: the five selected-text actions (Proofread, Rewrite,
     Summarize, Make Shorter, Clean Markdown).
   - The architecture, in flow order: `IntelligentEditingPromptBuilder` →
     `FoundationModelsIntelligentEditingService` / `IntelligentEditingService` →
     `IntelligentEditingRunner` → `IntelligentEditingRequestCoordinator` →
     `IntelligentEditingEvaluationRubric` → `IntelligentEditingSuggestion` /
     `IntelligentEditingSuggestionBar`, plus `IntelligenceActionRail` /
     `IntelligenceInstructionComposer` in the editor and `MarkdownDiff` for change review.
   - Why it was pulled (quality below bar, unnecessary for positioning).
   - The revive recipe: `git checkout ai-features-archive -- Lineform/Intelligence` (and the
     editor/test files listed below) as a baseline to build off.
   - A pointer to the historical design/plan/benchmark docs under `docs/` (left in place).

## Code removal

### Delete outright
- `Lineform/Intelligence/` — all 13 files.
- `Lineform/Editor/IntelligenceActionRail.swift` (AI-only).
- `Lineform/Editor/IntelligenceInstructionComposer.swift` (AI-only).

### Delete AI test files
`LineformTests/`: `IntelligentEditingActionTests`, `IntelligentEditingCursorTests`,
`IntelligentEditingDogfoodTests`, `IntelligentEditingEvaluationTests`,
`IntelligentEditingMessyWritingCorpusTests`, `IntelligentEditingPromptBuilderTests`,
`IntelligentEditingQualityPipelineTests`, `IntelligentEditingRunnerTests`,
`MarkdownDiffTests` (tests deleted code).

### Surgically strip AI wiring from mixed files (keep all non-AI behavior)
- `Lineform/Editor/EditorContainerView.swift` (~200 refs — the heaviest surgery).
- `Lineform/Editor/EditorPresentation.swift`
- `Lineform/Editor/EditorStatusPresentation.swift`
- `Lineform/Editor/LineformTextView.swift`
- `Lineform/Editor/MarkdownTextViewRepresentable.swift`
- `Lineform/App/AppCommands.swift` — remove the Intelligence `CommandMenu`, the
  `AppMenuConfiguration` intelligence flags/titles, and `intelligenceAvailable`.
- `Lineform/App/LineformAppNotification.swift` — remove the `runIntelligentEditingAction`
  notification and related plumbing.

### Xcode project
- Remove all deleted files from the `Lineform` and `LineformTests` targets so the project
  builds with no dangling references.

## User-facing surface cleanup

Remove AI feature copy/claims from every surface a user or reviewer sees:

- `README.md`
- `Lineform/Resources/Help.md`
- `Lineform/Resources/Privacy.md`
- `Lineform/Resources/AppStoreMetadata.md`
- `Lineform/Resources/AccessibilityNutritionLabel.md`
- `Lineform/Resources/ReleaseReadiness.md`
- `Lineform/Resources/FirstLaunchIntro/intro.js` (first-launch intro copy)
- About window / menu bar — no AI entries remain (menu removal handled in code section).

## Agent-doc cleanup

- `CLAUDE.md` — remove the **Intelligent Editing** section, the **AI Benchmark Docs**
  section, and the live/repeated Apple-Intelligence eval commands and quality-bar gates, so
  agent guidance matches the shipped app. Leave the rest (iCloud, verification, icon, etc.)
  intact.

## Historical docs — decision

The historical AI **design/plan/benchmark/dogfood** docs under `docs/` are left **in place**.
They are archive-by-nature, cost nothing, and are part of the "notes" the archive tag points
back to. Only their status as *active gates* is removed (via the CLAUDE.md edit above). The
archive note links to them.

## Entitlements

No change. Confirmed there is no AI-specific entitlement key in `Lineform.entitlements`,
`LineformDebug.entitlements`, or `Info.plist`. (Apple Foundation Models needs no
entitlement.) The Debug/Release iCloud isolation is untouched.

## Verification

1. **Build** both configs clean (no dangling target references).
2. **Full deterministic suite**, serial, per CLAUDE.md:
   ```sh
   xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
     -destination 'platform=macOS' -parallel-testing-enabled NO
   ```
   Report exact pass/fail counts. (Quit Xcode first per the harness-fragility note.)
3. **Grep sweep** confirms zero *live* `Intelligen` / AI references outside
   `docs/notes/ai-flow-archive.md` and the historical `docs/` files:
   ```sh
   grep -rniE "intelligen|intelligentediting" Lineform/ README.md \
     | grep -viE "writingtools|writing tools"
   ```
   Expected: empty (Writing Tools protection is the only allowed "intelligen"-adjacent hit,
   and it does not contain the string).
4. **Manual smoke:** launch app; confirm Write/Read/Preview modes, selection, formatting,
   outline, and reading profiles all still work; confirm no AI menu, no AI action rail, no
   AI status text; confirm first-launch intro no longer mentions AI.

## Risk / notes

- `EditorContainerView.swift` is the main risk (200 refs). Its AI wiring must come out
  without disturbing display-mode, selection, or the load-sensitive drawer-motion behavior
  the hosted tests guard. Run `EditorDisplayModeTests` specifically after surgery.
- Implementation can fan out across the independent file clusters (Resources docs, App
  menus, test deletions) with subagents; the `EditorContainerView` surgery should be done
  carefully in the main pass and verified against its hosted tests.
