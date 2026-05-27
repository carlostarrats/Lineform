# Intelligent Editing Benchmarks

This document defines the benchmark surface for Lineform's Apple Intelligence-backed editing actions. The goal is not to prove that every generative response will be good; the goal is to make bad output measurable, reproducible, and difficult to miss before it reaches the app.

## Actions

The benchmark suite covers every app action exposed through selected text:

- Rewrite
- Proofread
- Shorten
- Summarize
- Clean Markdown

## Selection Lengths

The corpus must keep coverage across the selection lengths users actually trigger:

- One word
- Short phrase
- Sentence
- Paragraph
- Multiple paragraphs

Short selections are scored more strictly. A one-word or short-phrase rewrite must stay word-like or phrase-like. A sentence rewrite must return a sentence-scale alternative, not a paragraph, list, prompt artifact, or copied selection.

## Required Scenario Matrix

Deterministic tests must cover these scenarios:

- All action and length pairs declared in `IntelligentEditingEvaluationSuite.requiredActionLengthPairs`.
- All scenario names declared in `IntelligentEditingEvaluationSuite.requiredScenarioNames`.
- User-visible list item rewrite: selected Markdown list items must preserve list shape and never surface protocol tags such as `<<<LINEFORM_OPTION_1>>>`.
- Generic sentence rewrite: arbitrary sentence input must produce useful sentence-scale alternatives even when the provider returns empty output.
- Placeholder rejection: `Replacement option 1`, `Lorem ipsum`, `TODO`, and Lineform protocol tags must score as failures.
- Unchanged transform rejection: rewrite, shorten, summarize, and messy clean-Markdown tasks must not return the selected text unchanged.
- Nearby context leakage: output must not include unselected neighboring document text.
- Markdown preservation: list shape, heading levels, front matter delimiters, blank lines between list items, and fenced code blocks must remain structurally safe.
- Provider failure modes: empty response, timeout, duplicate options, invalid options, and partial valid options must be tested.
- Full fallback matrix: every golden task must still produce a rubric-passing fallback when the provider returns unusable output.
- Multi-option fallback matrix: every rewrite task that requests multiple options must return the requested count of distinct, rubric-passing options when the provider returns unusable output.
- Stale selection behavior: generated suggestions must not apply if the underlying selected text changed before acceptance.

## Scoring

Each evaluated replacement receives:

- `passed`: true only when no rubric failures are present.
- `score`: 100 for clean output, with penalties for each failure.
- `qualityBand`: `pass`, `review`, or `fail`.
- `criticalFailureCount`: count of failures that should block release.

Critical failures are empty output, placeholder/protocol output, unchanged transform output, and leaked nearby context. A live report is acceptable only when:

- Pass rate is 100%.
- Average score is 100.
- Critical failure count is 0.
- The report includes full selected text, document context, replacement text, failures, score, and quality band for every record.

## Live Eval Reports

Opt-in live Foundation Models evals write JSON reports to the app-hosted test process temporary directory and attach the same JSON to the `.xcresult` bundle:

- `lineform-intelligence-live-eval-single.json`
- `lineform-intelligence-live-eval-options.json`

Run live evals with:

```sh
touch /private/tmp/lineform-run-live-intelligence-evals
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsEvalIsOptIn -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsOptionEvalIsOptIn
rm /private/tmp/lineform-run-live-intelligence-evals
```

Every prompt or validation change must compare the new reports against the previous run. A failed task should become either a better prompt, a deterministic fallback, a stricter validator, or a new benchmark case.

## Release Gate

Before calling intelligent editing quality acceptable, run:

- Prompt contract tests.
- Runner validation tests.
- Evaluation rubric tests.
- Golden-task fallback matrix tests.
- Multi-option rewrite fallback matrix tests.
- Full XCTest suite.
- Opt-in live single and option evals on a machine with Apple Intelligence available.
- Manual inspection of attached live reports for awkward-but-passing output.

Any user-reported bad output must be added as a deterministic regression case before fixing it.
