# Proofread Quality Comparison

This document tracks the before/after comparison for the proofread quality work that investigated Harper and then kept the shipping fix provider-agnostic.

## Goal

Improve basic spelling and grammar reliability without changing Lineform's UI, review flow, Apple Intelligence usage, local-first privacy posture, or Markdown safety rules.

Harper must not become a visible feature, a background grammar product, or a replacement for Apple Intelligence rewrite/summarize/shorten actions. The final implementation does not ship a Harper runtime path.

## Before Baseline

Recorded before implementation on June 1, 2026.

- Existing `Proofread` path is Apple Intelligence first, with deterministic fallbacks and validation.
- Existing UI remains a selected-text suggestion card; there is no live lint UI.
- Current deterministic gate before this system spell-check validation pass:
  - Full deterministic suite: 421 executed, 3 skipped, 0 failures.
  - Live single/options eval: single 38/38, options 52/52, average score 100, critical failures 0, empty outputs 0, duplicate failures 0.
  - Repeated live eval: 4 runs, 180 records, average score 100, failed runs 0, failed records 0, critical failures 0, empty outputs 0, duplicate options 0.

### User-Reported Cases

| Input | Before behavior after current hardening | Required after behavior |
| --- | --- | --- |
| `Can I ds it tommorow?` | Deterministic fallback can produce `Can I do it tomorrow?`; ambiguous options produce 3 alternatives. | Must keep this behavior or improve it without reducing option count for ambiguous proofread. |
| Keyboard mash such as `slkj sl;jf...` | Rejected as not recognizable English. | Must keep rejecting instead of applying Harper's low-confidence spelling guesses. |
| Lorem ipsum / placeholder text | Rejected as placeholder/dummy text. | Must keep rejecting instead of applying Harper's Latin-looking spelling guesses. |
| Markdown with fenced code | Lineform protects fenced code/front matter in system Writing Tools and rubric validation. | Harper integration must not edit fenced code or front matter. |

## Raw Harper Spike

Harper was installed locally with Homebrew only for measurement.

- Homebrew package size: 108MB.
- `harper-cli`: 53MB Mach-O arm64, about 12MB gzipped.
- `harper-ls`: 55MB Mach-O arm64, about 13MB gzipped.
- CLI cold selected-text calls: about 0.20-0.24 seconds for short selections.
- Raw stdin linting catches:
  - `tommorow` -> `tomorrow`
  - `dont` -> `don't`
  - `I has a apple.` -> `I have an apple.`
- Raw stdin linting risks:
  - Flags keyboard mash with many low-confidence replacements.
  - Flags lorem ipsum with bad replacement ideas.
  - Does not ignore fenced code by itself when run against stdin.

## Integration Criteria

An acceptable Lineform change must:

- Keep Apple Intelligence as the primary provider for proofread, rewrite, summarize, shorten, clean Markdown, and ambiguous alternatives.
- Reject unchanged proofread output when the selected text still contains detected spelling, grammar, punctuation, or obvious typo issues.
- Reject or repair low-confidence provider output instead of surfacing it.
- Reuse Lineform Markdown protection before accepting a replacement.
- Pass the same `IntelligentEditingEvaluationRubric` before showing a suggestion.
- Add no visible UI, menu item, panel, setting, or background underline behavior.

## After Results

- Runtime implementation: provider-agnostic issue detection in the existing evaluation rubric, with local macOS spell-check as a validation/fallback signal. No Harper runtime integration is shipped.
- The shared proofread issue detector and deterministic fallback live in `LineformProofreadingSupport`, so service fallback and rubric validation use the same correction signal.
- Rewrite option generation now asks the provider for a numbered alternatives set first, validates each parsed candidate through the same rubric, and falls back to one-at-a-time option repair only when the set is incomplete. This keeps the existing review panel while reducing single-option collapse.
- Focused deterministic intelligence tests: 126 executed, 3 skipped, 0 failures.
- Full deterministic suite: 438 executed, 3 skipped, 0 failures.
- Live single/options eval: single 40/40, options 54/54, average score 100, critical failures 0, failed records 0.
- Repeated live eval: 4 reports, 188 records, average score 100, failed runs 0, failed records 0, critical failures 0, empty outputs 0, duplicate options 0.
- App-size impact: 0. No Harper binary or Harper integration code is bundled.
- Latency impact: no new process launch, bundled model, or background linting path. The change runs inside the existing validation pass.
- Decision: Harper was useful as a comparison point, but it did not add enough value for this pass. Keeping it out avoids app-size, code-signing, sandbox, packaging, and competing-provider complexity while preserving Apple Intelligence as the selected-text provider.
- Residual risk: the validation gate can reject or repair bad provider output; it cannot guarantee Apple Intelligence will always produce a perfect correction. If the provider repeatedly returns unchanged or low-quality text and no deterministic safe fallback exists, Lineform returns "Suggestion unavailable" instead of showing a bad unchanged suggestion.
