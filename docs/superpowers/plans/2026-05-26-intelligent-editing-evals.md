# Intelligent Editing Evals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic and opt-in live eval tests for Lineform's Apple Intelligence editing prompts, then refine prompts and validation until the evals pass.

**Architecture:** Introduce a focused eval type in the intelligence module that owns golden tasks and rubric scoring. Tests use the eval type directly for deterministic CI checks and optionally run the same corpus through the real Foundation Models service when explicitly enabled.

**Tech Stack:** Swift 6, XCTest, FoundationModels when available through the existing `FoundationModelsIntelligentEditingService`.

---

### Task 1: Add Failing Eval Rubric Tests

**Files:**
- Create: `LineformTests/IntelligentEditingEvaluationTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing test**

Create `LineformTests/IntelligentEditingEvaluationTests.swift` with tests that reference `IntelligentEditingEvaluationSuite`, `IntelligentEditingEvaluationTask`, and `IntelligentEditingEvaluationRubric`.

- [ ] **Step 2: Register the test file**

Add `IntelligentEditingEvaluationTests.swift` to the `LineformTests` group and test target sources in `Lineform.xcodeproj/project.pbxproj`.

- [ ] **Step 3: Verify the test fails**

Run:

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/IntelligentEditingEvaluationTests
```

Expected: compile failure because the eval suite and rubric types do not exist yet.

### Task 2: Implement Eval Corpus and Rubric

**Files:**
- Create: `Lineform/Intelligence/IntelligentEditingEvaluation.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`
- Test: `LineformTests/IntelligentEditingEvaluationTests.swift`

- [ ] **Step 1: Add production eval types**

Create `IntelligentEditingEvaluationTask`, `IntelligentEditingSelectionLength`, `IntelligentEditingEvaluationResult`, `IntelligentEditingEvaluationRubric`, and `IntelligentEditingEvaluationSuite`.

- [ ] **Step 2: Register production file**

Add `IntelligentEditingEvaluation.swift` to the `Lineform` group and app target sources in `Lineform.xcodeproj/project.pbxproj`.

- [ ] **Step 3: Verify rubric tests pass**

Run the same targeted evaluation test command. Expected: PASS.

### Task 3: Add Runner Rejection Tests

**Files:**
- Modify: `LineformTests/IntelligentEditingRunnerTests.swift`
- Modify: `Lineform/Intelligence/IntelligentEditingRunner.swift`

- [ ] **Step 1: Write failing tests**

Add tests proving the runner rejects `Lorem ipsum`, `TODO`, unchanged rewrite output, and leaked nearby context for short selections.

- [ ] **Step 2: Verify tests fail**

Run:

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/IntelligentEditingRunnerTests
```

Expected: at least the new rejection tests fail.

- [ ] **Step 3: Implement validation**

Use the eval rubric from `IntelligentEditingRunner.validatedReplacement` so runner behavior matches benchmark behavior.

- [ ] **Step 4: Verify tests pass**

Run the targeted runner tests. Expected: PASS.

### Task 4: Refine Prompt Builder

**Files:**
- Modify: `Lineform/Intelligence/IntelligentEditingPromptBuilder.swift`
- Modify: `Lineform/Intelligence/IntelligentEditingService.swift`
- Modify: `LineformTests/IntelligentEditingPromptBuilderTests.swift`
- Test: `LineformTests/IntelligentEditingEvaluationTests.swift`

- [ ] **Step 1: Add failing prompt contract tests**

Assert prompts include explicit output-contract, invalid-output, action-rubric, and length-category guidance. Assert option prompts do not include placeholder text that can be copied as a response.

- [ ] **Step 2: Verify prompt tests fail**

Run:

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/IntelligentEditingPromptBuilderTests
```

Expected: new prompt-contract assertions fail.

- [ ] **Step 3: Update prompts**

Rewrite the builder output into structured sections, add action-specific criteria, and replace multi-option placeholder examples with neutral tag-only instructions.

- [ ] **Step 4: Verify prompt and eval tests pass**

Run prompt and evaluation tests. Expected: PASS.

### Task 5: Add Live Opt-In Eval

**Files:**
- Modify: `LineformTests/IntelligentEditingEvaluationTests.swift`
- Test: `Lineform/Intelligence/IntelligentEditingService.swift`

- [ ] **Step 1: Add live eval test**

Add an XCTest that skips unless `LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1` or `/private/tmp/lineform-run-live-intelligence-evals` exists, calls `FoundationModelsIntelligentEditingService`, evaluates each replacement with the rubric, and fails with task names and reasons if score falls below threshold.

- [ ] **Step 2: Verify default skip**

Run evaluation tests without the environment variable. Expected: deterministic tests pass and live eval skips.

- [ ] **Step 3: Run full verification**

Run:

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```

Expected: PASS.
