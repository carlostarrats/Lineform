# Lineform Agent Guide

This file is for AI coding agents working in the Lineform repo. Read it before making changes. It explains what the app is, what quality means here, and how to verify work.

## Product Context

Lineform is a free native macOS Markdown editor for calm writing, real local files, and readable long-form text. V1.0 is the first public version of the app. The app should feel quiet, native, file-based, and trustworthy. It is not a web editor, not a note-taking database, and not a cloud writing service.

Public-facing links:

- Product website: `https://lineform-site.vercel.app`
- GitHub repo: `https://github.com/carlostarrats/Lineform`
- Public download target: `https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.0.dmg`

Core product principles:

- Real files: documents are plain UTF-8 Markdown or text files that remain portable across Finder, iCloud Drive, Git, and other editors.
- Local-first privacy: there is no account system, no analytics by default, and no document upload.
- Native macOS behavior: prefer SwiftUI, AppKit, TextKit, document-based app patterns, system controls, and platform conventions.
- Calm writing: UI should reduce noise and support long drafting/review sessions.
- Trustworthy intelligence: AI suggestions must be useful, selected-text scoped, structurally safe for Markdown, and never show protocol tags, placeholders, dummy text, or prompt artifacts.

## Main Features

- Document-based macOS app for Markdown and plain text files.
- Write mode for editing source Markdown.
- Read mode for rendered, calmer reading.
- Split/Preview mode for side-by-side writing and preview.
- Markdown outline navigation from document headings.
- Markdown formatting commands for common writing actions.
- Markdown syntax highlighting and range analysis.
- Reading profiles for type size, line height, block spacing, margins, column width, caret width, focus, ruler, and themes.
- Apple Books-style reader themes plus accessibility-oriented font and contrast options.
- Apple Intelligence-backed selected-text editing when available.
- Native Writing Tools protection around Markdown regions such as fenced code and front matter.
- Local release/help resources bundled in the app.
- Sparkle-backed update checks in release builds when a real EdDSA public key and appcast are configured.
- Standard macOS About panel showing `V1.0`.

## Architecture Map

Important directories:

- `Lineform/App`: app entry point, menu commands, notifications, and update-check wiring.
- `Lineform/Documents`: document model, UTF-8 Markdown/text file read/write, save status.
- `Lineform/Editor`: editing container, TextKit bridge, selection context, syntax highlighting, formatting commands, writing tools protections.
- `Lineform/Preview`: Markdown preview rendering and preview view bridge.
- `Lineform/Outline`: Markdown heading parser and outline sidebar UI.
- `Lineform/ReadingExperience`: reading profiles, presets, themes, fonts, and reading experience controls.
- `Lineform/Intelligence`: selected-text AI actions, prompts, runner, validation, suggestions, diffing, request coordination, and eval rubric.
- `Lineform/Resources`: bundled privacy/help/release/accessibility docs.
- `LineformTests`: XCTest coverage for app behavior, editor behavior, reading experience, Markdown handling, and intelligence quality.
- `docs`: deeper project docs, including AI benchmark docs and implementation specs/plans.

Prefer existing module boundaries. Do not move responsibilities across directories unless the change clearly improves maintainability and is directly needed.

## Intelligent Editing

The app exposes these selected-text actions:

- `Proofread`: fix grammar, spelling, punctuation, and obvious typos only.
- `Rewrite`: improve flow while preserving meaning and tone.
- `Summarize`: concise summary preserving essential points.
- `Make Shorter`: shorter text preserving essential meaning.
- `Clean Markdown`: normalize Markdown formatting while preserving content and structure.

The selected-text AI path is intentionally defensive:

- `IntelligentEditingPromptBuilder` builds action-specific prompts.
- `FoundationModelsIntelligentEditingService` talks to Apple Foundation Models when available and validates responses.
- `IntelligentEditingRunner` scopes requests to the selected range, validates replacements, and creates suggestions.
- `IntelligentEditingRequestCoordinator` coordinates async selected-text requests and prevents stale suggestions from applying after document changes.
- `IntelligentEditingEvaluationRubric` scores output quality and blocks bad classes of responses.
- Deterministic fallbacks are allowed only when they pass the same rubric.

Never allow these to reach users:

- `<<<LINEFORM_OPTION_1>>>` or any Lineform protocol/control tag.
- Placeholder text, dummy text, lorem ipsum, TODO text, or prompt explanations.
- Empty suggestions after a loading state.
- Unchanged output for transform actions such as rewrite, shorten, summarize, or messy Markdown cleanup.
- Suggestions that include unselected nearby context.
- Suggestions that damage Markdown structures such as lists, blockquotes, tables, links, front matter, or fenced code.
- Suggestions that invent or reverse local/privacy/storage facts.
- Duplicate rewrite options.

Any user-reported bad AI output must become a deterministic regression case before or alongside the fix.

## AI Benchmark Docs

The primary benchmark doc is:

- `docs/intelligent-editing-benchmarks.md`

Use it when changing prompts, fallback behavior, validation, Apple Intelligence integration, selected-text flow, or Markdown intelligence behavior.

Supporting design/plan docs:

- `docs/superpowers/specs/2026-05-27-comprehensive-intelligent-editing-quality-design.md`
- `docs/superpowers/plans/2026-05-27-comprehensive-intelligent-editing-quality.md`

## Verification Commands

General deterministic test gate:

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

Use serial testing for the full suite. Some AppKit-hosted tests can contaminate each other when Xcode runs them in parallel.

Known AppKit test-harness warning:

- `EditorDisplayModeTests/testEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens` may log `[WarnOnce] It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out`.
- This warning was investigated in an isolated worktree on May 28, 2026. It appears when the test constructs the full `NSHostingView`/`NSWindow` editor harness via `makeEditorDrawerHarness()`.
- Sandbox checks ruled out the drawer notification, the tuned text-canvas drawer motion code, the AI composer `layoutSubtreeIfNeeded()` call, Lineform's SwiftUI toolbar/search modifiers, and `makeKeyAndOrderFront` as direct causes.
- Do not weaken or replace the full hosted drawer-motion harness just to silence this warning. The harness protects real UI motion regressions. Revisit only if the warning appears during normal app use, becomes a CI failure, or has a proven user-visible layout symptom.

Live Apple Intelligence single/options eval:

```sh
(
  touch /private/tmp/lineform-run-live-intelligence-evals
  trap 'rm -f /private/tmp/lineform-run-live-intelligence-evals' EXIT
  xcodebuild test \
    -project Lineform.xcodeproj \
    -scheme Lineform \
    -destination 'platform=macOS' \
    -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsEvalIsOptIn \
    -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsOptionEvalIsOptIn
)
```

Repeated live Apple Intelligence stability eval:

```sh
(
  touch /private/tmp/lineform-run-repeated-live-intelligence-evals
  trap 'rm -f /private/tmp/lineform-run-repeated-live-intelligence-evals' EXIT
  xcodebuild test \
    -project Lineform.xcodeproj \
    -scheme Lineform \
    -destination 'platform=macOS' \
    -only-testing:LineformTests/IntelligentEditingEvaluationTests/testRepeatedLiveFoundationModelsEvalIsOptIn
)
```

For prompt, validation, fallback, or intelligence UI changes, run:

- focused tests for the changed code
- full deterministic suite
- live single/options eval when Apple Intelligence is available
- repeated live eval before calling quality acceptable

Live eval reports are attached to `.xcresult` bundles and include JSON records for selected text, document context, replacements, failures, scores, quality bands, empty outputs, duplicate options, and repeated-run stability.

## Quality Bar

Before claiming a change is complete:

- Run the commands that prove the claim.
- Read the output and report exact pass/fail counts.
- Do not rely on a green deterministic test when a live provider path is part of the requirement.
- Do not call AI output quality acceptable without checking the generated eval records.
- Do not hide residual risk. If a manual UI state was not exercised, say so.

For intelligent editing, acceptable means:

- 100% pass rate in the relevant eval report.
- Average score is 100.
- Critical failure count is 0.
- Empty output count is 0.
- Duplicate option count is 0 for repeated live option runs.
- Actual replacement text is inspectable and appropriate for Lineform's writing context.

## Coding Guidelines

- Follow existing patterns before introducing new abstractions.
- Keep edits scoped to the feature or bug being handled.
- Prefer structured parsing/helpers over ad hoc string manipulation when reasonable.
- Keep Markdown handling structure-preserving.
- Keep UI native, restrained, and task-focused.
- Avoid unrelated refactors and metadata churn.
- Preserve user work in the git tree. Do not revert changes you did not make.
- Use focused tests for narrow changes and broader tests for shared behavior.

## Privacy And Safety

Lineform is local-first. Do not add behavior that uploads document contents, requires an account, collects analytics by default, or converts user documents into an app-owned database without an explicit product decision.

Apple Intelligence features should degrade gracefully:

- The editor remains usable when intelligence is unavailable.
- Availability errors should be clear and non-destructive.
- Suggestions should never apply to changed/stale selections.
- Rejected or invalid model output should not reach the document.

## Credits And Third-Party Materials

Keep attribution accurate when changing fonts, bundled resources, README copy, app metadata, or release docs:

- Atkinson Hyperlegible is bundled under the SIL Open Font License 1.1 and is credited to Braille Institute of America, Inc.
- OpenDyslexic is bundled under the SIL Open Font License 1.1 and is credited to Abbie Gonzalez, with Reserved Font Name OpenDyslexic.
- The bundled font license files must remain in `Lineform/Resources/Fonts`.
- `Lineform/Resources/FontLicenseReview.md` should stay in sync with the bundled font set.
- Harper is credited only as inspiration and comparison material for private, local-first writing assistance. It is not bundled with Lineform and is not a runtime dependency.
- Sparkle is bundled for macOS update checking and must be credited in public docs/notices when release or dependency documentation changes.

## Documentation Expectations

Update docs when behavior, workflows, or quality gates change:

- Keep `README.md` user-facing: prominent download, website, privacy, about, credits, and only a compact source-build section.
- Use this `AGENTS.md` for AI coding agent context and repo operating rules.
- Use `docs/intelligent-editing-benchmarks.md` for intelligence eval coverage and commands.
- Use `docs/release/github-sparkle-release.md` for GitHub Releases, DMG packaging, and Sparkle appcast steps.
- Use `Lineform/Resources/*.md` for user-facing bundled app/help/release docs.

Keep this file current when major features, architecture, or verification gates change.
