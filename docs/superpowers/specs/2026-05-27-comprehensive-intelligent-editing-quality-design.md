# Comprehensive Intelligent Editing Quality Design

## Goal

Make Lineform's Apple Intelligence editing actions reliable enough that selected-text workflows produce useful, trustworthy output across known failures, likely unknown failures, and realistic Markdown writing scenarios.

## Scope

This pass extends the current benchmark system in four areas:

- Expanded corpus coverage for more Markdown structures and writing risks.
- Adversarial quality checks for plausible bad output, not only obvious placeholders.
- Repeated live-eval reporting so a single lucky Apple Intelligence run is not treated as proof.
- A testable app-level request coordinator for the loading-to-result path that currently lives inside `EditorContainerView`.

## Architecture

`IntelligentEditingEvaluationSuite` remains the source of benchmark tasks and scenario coverage. The rubric grows stricter around fact invention, explanations/apologies, Markdown corruption, and weak generic language. Live eval tests keep producing JSON reports, and an additional repeated-run summary aggregates multiple live reports into stability metrics.

The UI-facing flow gets a small coordinator that wraps `IntelligentEditingRunner`: it resolves option count, runs the service, filters stale suggestions against the current document text, and returns ready/expired/failed states. `EditorContainerView` can keep its UI state, but tests can exercise the same request semantics without brittle SwiftUI private-state inspection.

## Required Coverage

The expanded corpus must cover:

- Markdown links.
- Tables.
- Blockquotes.
- Numbered lists.
- Nested lists.
- Fenced code and code-only selections.
- Front matter.
- Very long selections.
- Weird whitespace.
- Fact preservation.
- Non-English or mixed-language text.
- One-word and short-phrase rewrites.
- Sentence, paragraph, and multiple-paragraph transformations.

Adversarial tests must reject:

- Placeholder/protocol output.
- Apologies, explanations, and "I cannot" responses.
- Copied nearby context.
- Copied selected text for transform actions.
- Fact invention or polarity reversal.
- Overlong short-selection rewrites.
- Markdown structure damage.
- Duplicate or near-duplicate options.
- Awkward generic rewrites that technically change words but lower confidence.

## Live Quality Gate

The live gate is acceptable only when:

- Single-output live records have 100% pass rate and 100 average score.
- Multi-option live records have 100% pass rate and 100 average score.
- Repeated live summaries show 0 failed runs, 0 critical failures, 0 empty/no-result outputs, and no duplicate rewrite options.
- Reports are attached to `.xcresult` and can be inspected after the run.

## Non-Goals

This pass does not add silent production telemetry. User writing should not be collected without an explicit privacy/product decision. A local fixture capture workflow is acceptable for manual regression creation.
