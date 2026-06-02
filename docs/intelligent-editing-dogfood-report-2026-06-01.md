# Intelligent Editing Dogfood Report - 2026-06-01

This report used sanitized Lineform-like writing only. No private document content was added.

## Before

Initial live dogfood run:

- Total cases: 13
- Passed: 8
- Failed: 5
- Provider failures: 3
- Option count mismatches: 1
- Duplicate options: 0
- Clean failures: 1
- Watch notes: 1

Failures found:

- `proofread-placeholder-lorem`: placeholder rejection was misclassified as provider failure.
- `rewrite-awkward-local-files`: weak rewrite kept vague wording such as `mushy`.
- `rewrite-short-options`: live output collapsed to two options.
- `summarize-local-first-flow`: provider output failed without a useful fallback.
- `shorten-preserve-privacy`: provider output failed without a useful fallback.

Watch note:

- `dialect-proofread-colour`: Apple changed `colour` to `color`. This remains watch-only until there is real user pressure for dialect behavior.

## After

Final live dogfood run:

- Total cases: 13
- Passed: 13
- Failed: 0
- Average score: 100
- Provider failures: 0
- Option count mismatches: 0
- Duplicate options: 0
- Clean failures: 2
- Watch notes: 1

Key final replacements:

- `rewrite-awkward-local-files`: `The file workflow is mostly working but the description of local and portable is unclear.`
- `rewrite-short-options`: `Cat in the hat.`, `A cat in the hat.`, `The cat in the hat.`
- `summarize-local-first-flow`: `Lineform keeps documents as plain Markdown or text files on disk, and Intelligence features work on selected text and show suggestions before anything is applied.`
- `shorten-preserve-privacy`: `The app should keep writing private, use local files, and avoid accounts, analytics, or document upload.`

## Promotions

The following behavior classes were promoted into deterministic coverage:

- Vague rewrite output that preserves the same weak wording is rejected and repaired.
- Short malformed rewrite options must remain semantically distinct after punctuation normalization.
- Multi-paragraph summary fallback preserves coverage from each selected paragraph.
- Sentence shorten fallback preserves privacy/local-file meaning when provider output no-ops.
- Placeholder and unrecognizable input are both clean failures, not successful no-op suggestions.
