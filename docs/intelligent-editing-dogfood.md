# Intelligent Editing Dogfood

This checklist is for manual review after deterministic tests pass. It catches awkward-but-passing output that a rubric may not score as a failure.

## Scope

Use sanitized local documents or copied scratch text. Do not add private user document content to the repo. When a problem is reproducible, reduce it to a safe synthetic fixture in `LineformTests/Fixtures/IntelligentEditingMessyWritingCorpus.json` or a focused regression test.

## Review Set

Run selected-text editing against examples that include:

- Clean short phrases that should remain unchanged under `Proofread`.
- Short messy phrases with typo or grammar ambiguity.
- Keyboard mash, placeholder text, or non-English-looking text that should fail cleanly.
- Awkward sentences and paragraphs for `Rewrite`.
- Multi-paragraph selections for `Summarize` and `Make Shorter`.
- Markdown lists, headings, links, tables, blockquotes, front matter, and fenced code.
- Names, brands, local product terms, and British/US spelling examples that could become false positives.
- User instructions for tone, direct word swaps, simplification, active voice, and Markdown-safe edits.

## Manual Checks

For every generated suggestion, check:

- It improves or correctly preserves the selected text.
- It does not include nearby unselected context.
- It preserves meaning, facts, local-first/privacy claims, and Markdown structure.
- `Proofread` fixes correctness without rewriting style.
- `Rewrite` options are meaningfully different and not duplicates.
- `Summarize` and `Make Shorter` preserve essential points.
- Bad input fails cleanly instead of showing unchanged or guessed output.
- No protocol tags, placeholders, dummy text, apology text, or prompt artifacts appear.

## Automated Dogfood Harness

The opt-in dogfood harness runs sanitized real-ish writing through the same selected-text runner as the app and writes a JSON report with replacements, scores, clean failures, provider failures, duplicate options, option-count mismatches, and watch-only false-positive notes.

Run it with:

```sh
(
  touch /private/tmp/lineform-run-live-dogfood-evals
  trap 'rm -f /private/tmp/lineform-run-live-dogfood-evals' EXIT
  xcodebuild test \
    -project Lineform.xcodeproj \
    -scheme Lineform \
    -destination 'platform=macOS' \
    -only-testing:LineformTests/IntelligentEditingDogfoodTests/testLiveDogfoodEvalIsOptIn \
    -parallel-testing-enabled NO
)
```

The report is also attached to the `.xcresult` bundle as `lineform-intelligence-dogfood-report.json`.

Latest recorded pass:

- `docs/intelligent-editing-dogfood-report-2026-06-01.md`

Use report fields this way:

- `failures`: real blocking failures that should become a corpus case, focused regression, prompt/rubric adjustment, or provider handling fix.
- `cleanFailureKind`: expected rejection of unusable input, such as unrecognizable keyboard mash or placeholder text.
- `watchNotes`: non-blocking false-positive signals, such as dialect spelling changes, that should be promoted only if users hit them in real writing.
- `providerFailureCount`: live Apple provider instability that needs monitoring over time.

## Outcome

Record failures as one of:

- New corpus case.
- New focused regression test.
- Prompt/rubric/fallback adjustment.
- Provider instability note if Apple output is inconsistent but safely rejected.

Do not call intelligent editing quality acceptable from manual review alone. Manual dogfood supplements the deterministic suite and live eval reports; it does not replace them.
