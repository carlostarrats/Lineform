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
