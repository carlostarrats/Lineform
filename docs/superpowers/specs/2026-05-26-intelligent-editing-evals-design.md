# Intelligent Editing Evals Design

## Goal

Lineform needs repeatable quality tests for Apple Intelligence-backed editing prompts so selected text does not produce placeholders, copied input, dummy text, leaked context, or structurally unsafe Markdown.

## Context

The current implementation routes selected Markdown through `IntelligentEditingRunner`, `FoundationModelsIntelligentEditingService`, and `IntelligentEditingPromptBuilder`. Existing tests verify prompt text, option parsing, and basic placeholder rejection, but they do not score a corpus of editing tasks across selection lengths. Live Foundation Models behavior is therefore able to regress without a test failing.

## Approach

Use two complementary eval tracks:

1. Deterministic XCTest evals that always run in CI. These use a golden task corpus and known bad/good responses to verify the grader and runner protections.
2. Opt-in live Foundation Models evals. These use the same task corpus against `FoundationModelsIntelligentEditingService` when `LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1` is set, or when `/private/tmp/lineform-run-live-intelligence-evals` exists for app-hosted XCTest runs, and Apple Intelligence is available.

This follows established eval practice for generative features: a golden dataset, deterministic rubrics, clear pass thresholds, regression tests, and an expandable task set based on real failures.

## Corpus

The corpus covers all intended selection lengths:

- One word: title or terminology replacement.
- Sentence: proofread, rewrite, and shorten.
- Paragraph: rewrite, summarize, and shorten.
- Multiple paragraphs: summarize and clean Markdown.

Each task stores the action, selected text, optional nearby document context, length category, and rubric expectations.

## Rubric

Every replacement must:

- Be non-empty after trimming.
- Avoid placeholder and dummy output such as `replacement option`, `lorem ipsum`, `<write only replacement>`, or `TODO`.
- Avoid returning the selected text unchanged for transform actions.
- Avoid returning nearby document context that was not selected.
- Stay proportional to the selected text, especially for one-word and short selections.
- Preserve Markdown structure when the action requires it.
- Match action intent: proofread fixes surface errors only, rewrite changes wording while preserving meaning, summarize compresses, shorten compresses, and clean Markdown changes formatting without adding claims.

## Prompt Changes

The prompt should become more explicit and less placeholder-prone:

- Separate task, selected Markdown, nearby context, output contract, and quality bar.
- Include action-specific success criteria.
- Include explicit invalid-output rules for copied placeholders, unchanged text when action expects transformation, and context leakage.
- Keep short-selection rules strict.
- Keep tagged multi-option output but remove placeholder examples that the model can copy as valid answers.

## Validation Changes

Runner validation should reject broader placeholder/dummy text and obvious unchanged transform outputs before suggestions reach the UI. Rejection should surface as `emptyResponse`, preserving existing UI error handling.

## Testing

Add `IntelligentEditingEvaluationTests` with deterministic unit tests for:

- Corpus coverage across one-word, sentence, paragraph, and multi-paragraph selections.
- Rubric acceptance of useful replacements.
- Rubric rejection of placeholders, dummy text, unchanged transform outputs, oversized short-selection outputs, and leaked context.
- Live opt-in evals that skip unless `LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1` or `/private/tmp/lineform-run-live-intelligence-evals` is present.

Run the targeted intelligence tests after each prompt/rubric change, then run the full test suite once the targeted suite is green.
