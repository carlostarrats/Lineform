# Intelligent Editing Benchmarks

This document defines the benchmark surface for Lineform's Apple Intelligence-backed selected-text instruction flow. The gate is designed to make known failures reproducible, catch likely unknown failures through scenario coverage, and block outputs that would reduce trust in selected-text editing.

## Request Modes

The app UI is freeform-instruction first: writers select text, type what they want, and review a replacement before accepting it. The fixed action enum still exists as an internal validation profile so custom instructions can be scored against the closest safe behavior:

- Rewrite
- Proofread
- Shorten
- Summarize
- Clean Markdown

Benchmarks must include explicit user-instruction tasks, not only internal action/profile tasks. A user-instruction task records the exact instruction in eval reports so live Apple Intelligence output can be audited against what the writer asked for.

## Selection Lengths

The corpus must keep coverage across the selection lengths users actually trigger:

- One word
- Short phrase
- Sentence
- Paragraph
- Multiple paragraphs
- Very long multi-paragraph selections
- Weird whitespace around Markdown markers

Short selections are scored more strictly. A one-word or short-phrase rewrite must stay word-like or phrase-like. A sentence rewrite must return a sentence-scale alternative, not a paragraph, list, prompt artifact, or copied selection.

## Required Scenario Matrix

Deterministic tests must cover these scenarios:

- All action and length pairs declared in `IntelligentEditingEvaluationSuite.requiredActionLengthPairs`.
- All scenario names declared in `IntelligentEditingEvaluationSuite.requiredScenarioNames`.
- User-visible list item rewrite: selected Markdown list items must preserve list shape and never surface protocol tags such as `<<<LINEFORM_OPTION_1>>>`.
- Generic sentence rewrite: arbitrary sentence input must produce useful sentence-scale alternatives even when the provider returns empty output.
- User-directed custom instruction: freeform tone, wording, grammar, shortening, and Markdown-formatting instructions must be represented by benchmark tasks and must preserve the selected-text boundary.
- Custom instruction intent: word swaps, less-corporate rewrites, simplification for non-technical readers, active-voice rewrites, heading renames, and Markdown-safe list-item edits must have explicit golden tasks and deterministic rubric checks where possible.
- Placeholder rejection: `Replacement option 1`, `Lorem ipsum`, `TODO`, and Lineform protocol tags must score as failures.
- Unchanged transform rejection: rewrite, shorten, summarize, and messy clean-Markdown tasks must not return the selected text unchanged.
- Nearby context leakage: output must not include unselected neighboring document text.
- Markdown preservation: list shape, heading levels, front matter delimiters, blank lines between list items, and fenced code blocks must remain structurally safe.
- Expanded Markdown preservation: links, tables, blockquotes, numbered lists, nested lists, and code-only selections must remain structurally safe.
- Writing-risk coverage: local/privacy/storage facts must not be invented or reversed, mixed-language text must remain meaningful, and already-correct proofreading selections must be allowed as no-op replacements.
- Provider failure modes: empty response, timeout, duplicate options, invalid options, and partial valid options must be tested.
- Full fallback matrix: every golden task must still produce a rubric-passing fallback when the provider returns unusable output.
- Multi-option fallback matrix: every rewrite task that requests multiple options must return the requested count of distinct, rubric-passing options when the provider returns unusable output.
- Stale selection behavior: generated suggestions must not apply if the underlying selected text changed before acceptance.
- App request flow: the editor selection path must use the same request coordinator exercised by tests, and suggestions must stay visible when validated suggestions are ready.

## Scoring

Each evaluated replacement receives:

- `passed`: true only when no rubric failures are present.
- `score`: 100 for clean output, with penalties for each failure.
- `qualityBand`: `pass`, `review`, or `fail`.
- `criticalFailureCount`: count of failures that should block release.

Critical failures are empty output, placeholder/protocol output, unchanged transform output, and leaked nearby context. Instruction-following failures are non-critical scoring failures, but they still make the record fail and should be treated as release-blocking for custom-instruction quality. A live report is acceptable only when:

- Pass rate is 100%.
- Average score is 100.
- Critical failure count is 0.
- The report includes full selected text, document context, replacement text, failures, score, and quality band for every record.
- The report includes the exact user instruction for custom-instruction records.
- Custom-instruction records visibly satisfy the requested operation, especially direct word swaps and tone/voice/simplification requests.
- Repeated live reports have no failed runs, empty outputs, duplicate options, critical failures, or average score loss.

## Live Eval Reports

Opt-in live Foundation Models evals write JSON reports to the app-hosted test process temporary directory and attach the same JSON to the `.xcresult` bundle:

- `lineform-intelligence-live-eval-single.json`
- `lineform-intelligence-live-eval-options.json`
- `lineform-intelligence-live-eval-repeated.json`

Run live evals with:

```sh
(
  touch /private/tmp/lineform-run-live-intelligence-evals
  trap 'rm -f /private/tmp/lineform-run-live-intelligence-evals' EXIT
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsEvalIsOptIn -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsOptionEvalIsOptIn
)
```

Run repeated live evals with:

```sh
LINEFORM_LIVE_INTELLIGENCE_REPEAT_COUNT=2 \
LINEFORM_RUN_REPEATED_LIVE_INTELLIGENCE_EVALS=1 \
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/IntelligentEditingEvaluationTests/testRepeatedLiveFoundationModelsEvalIsOptIn
```

Every prompt or validation change must compare the new reports against the previous run. A failed task should become a better prompt, deterministic fallback, stricter validator, or new benchmark case.

## Release Gate

Before calling intelligent editing quality acceptable, run:

- Prompt contract tests.
- Runner validation tests.
- Evaluation rubric tests.
- Golden-task fallback matrix tests.
- Multi-option rewrite and user-instruction fallback matrix tests.
- Full XCTest suite.
- Opt-in live single and option evals on a machine with Apple Intelligence available.
- Opt-in repeated live evals with at least two runs.
- Manual inspection of attached live reports for awkward-but-passing output.

Any user-reported bad output must be added as a deterministic regression case before fixing it.
