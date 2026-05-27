# Comprehensive Intelligent Editing Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand Lineform's Apple Intelligence quality system from known regression checks into a broad confidence gate for realistic selected-text editing workflows.

**Architecture:** Extend the existing evaluation suite and XCTest live reports instead of adding a new framework. Add one app-level coordinator seam so the loading-to-result behavior can be tested without fragile SwiftUI introspection.

**Tech Stack:** Swift 6, XCTest, FoundationModels opt-in live evals, existing Lineform intelligence runner/service/evaluation types.

---

### Task 1: Expanded Corpus And Adversarial Rubric

**Files:**
- Modify: `Lineform/Intelligence/IntelligentEditingEvaluation.swift`
- Modify: `LineformTests/IntelligentEditingEvaluationTests.swift`

- [ ] Add failing tests that require coverage for Markdown links, tables, blockquotes, numbered lists, nested lists, code-only selections, weird whitespace, fact preservation, and mixed-language text.
- [ ] Add failing tests that reject apology/explanation output, fact invention, polarity reversal, Markdown table corruption, and awkward generic rewrite filler.
- [ ] Add the missing golden tasks and scenario names to `IntelligentEditingEvaluationSuite`.
- [ ] Tighten `IntelligentEditingEvaluationRubric` until the adversarial tests pass.

### Task 2: Fallback Matrix For Expanded Tasks

**Files:**
- Modify: `Lineform/Intelligence/IntelligentEditingService.swift`
- Modify: `LineformTests/IntelligentEditingRunnerTests.swift`

- [ ] Extend the existing all-golden-task fallback matrix to include the new tasks.
- [ ] Run it and capture failures from unsupported deterministic fallbacks.
- [ ] Add conservative deterministic fallbacks for the new benchmark tasks.
- [ ] Verify every new fallback passes the same rubric used by live evals.

### Task 3: Repeated Live Eval Aggregation

**Files:**
- Modify: `LineformTests/IntelligentEditingEvaluationTests.swift`
- Modify: `docs/intelligent-editing-benchmarks.md`

- [ ] Add tests for a repeated-run summary that aggregates multiple live reports.
- [ ] Implement repeated live eval report fields: run count, failed run count, critical failure count, average score, empty output count, duplicate option count.
- [ ] Add an opt-in live repeated test controlled by a repeat-count environment variable or marker file.
- [ ] Document the repeated live gate and extraction flow.

### Task 4: App-Level Request Flow Harness

**Files:**
- Create: `Lineform/Intelligence/IntelligentEditingRequestCoordinator.swift`
- Modify: `Lineform/Editor/EditorContainerView.swift`
- Modify: `LineformTests/IntelligentEditingRunnerTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

- [ ] Add failing tests for loading-to-ready, loading-to-expired, and loading-to-failed selected-text flows.
- [ ] Implement `IntelligentEditingRequestCoordinator` using `IntelligentEditingRunner`.
- [ ] Route `EditorContainerView` through the coordinator while preserving existing UI behavior.
- [ ] Verify coordinator tests catch the no-answer/silent-disappear class by requiring explicit ready/expired/failed outcomes.

### Task 5: Verification And Commit

**Files:**
- Modify: `docs/intelligent-editing-benchmarks.md`

- [ ] Run focused intelligence tests.
- [ ] Run repeated live evals with Apple Intelligence available.
- [ ] Export and inspect attached JSON reports for known weak strings and summary failures.
- [ ] Run full XCTest suite.
- [ ] Commit only the quality/eval changes, leaving unrelated untracked files untouched.
