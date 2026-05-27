# Write Mode AI Action Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the automatic selected-text AI context menu with a persistent Write-mode toolbar toggle and floating AI action rail.

**Architecture:** Keep intelligence execution in `EditorContainerView` and add a small presentation layer for toolbar and rail visibility. Remove the mouse-selection auto menu from `LineformTextView` while preserving explicit menu bar commands.

**Tech Stack:** SwiftUI, AppKit `NSTextView`, XCTest, existing Lineform intelligence runner/coordinator.

---

### Task 1: Lock Toolbar And Rail Presentation Rules

**Files:**
- Modify: `LineformTests/EditorDisplayModeTests.swift`
- Modify: `LineformTests/IntelligentEditingActionTests.swift`
- Modify: `Lineform/Editor/EditorContainerView.swift`
- Modify: `Lineform/Intelligence/IntelligentEditingAction.swift`

- [ ] Write failing tests that `EditorToolbarAction.primaryActions(in: .write)` returns `[.intelligence, .markdownBasics, .readingExperience]`, and does not include `.intelligence` in `.read` or `.split`.
- [ ] Write a failing test that `IntelligentEditingAction.actionRailActions.map(\.title)` is `["Clean Markdown", "Proofread", "Rewrite", "Make Shorter"]`.
- [ ] Implement `.intelligence` toolbar action, Write-only visibility, and `actionRailActions`.
- [ ] Run focused tests: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/EditorDisplayModeTests -only-testing:LineformTests/IntelligentEditingActionTests -parallel-testing-enabled NO`.

### Task 2: Remove Automatic Selection Menu

**Files:**
- Modify: `LineformTests/LineformTextViewWritingToolsTests.swift`
- Modify: `Lineform/Editor/LineformTextView.swift`

- [ ] Replace automatic menu tests with failing assertions that mouse selection does not schedule an intelligence menu.
- [ ] Remove delayed automatic intelligence menu scheduling and popup code from `LineformTextView`.
- [ ] Keep right-click context menu focused on Cut/Copy/Paste and Markdown formatting.
- [ ] Run focused tests: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/LineformTextViewWritingToolsTests -parallel-testing-enabled NO`.

### Task 3: Add Floating Write-Mode Rail

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift`
- Modify: `LineformTests/EditorDisplayModeTests.swift`

- [ ] Write failing tests for `IntelligenceActionRailPresentation.isVisible(isEnabled:displayMode:)`: visible only when enabled and `displayMode == .write`.
- [ ] Add a floating vertical `IntelligenceActionRail` SwiftUI view aligned to the left of the editor shell.
- [ ] Render the rail only when the persisted toggle is on and display mode is Write.
- [ ] Disable action buttons when there is no non-empty selected text, intelligence is unavailable, or an edit is running.
- [ ] Wire each rail button to `runIntelligentEditingAction`.
- [ ] Run focused display/action tests.

### Task 4: Verify And Update Docs

**Files:**
- Modify: `Lineform/Resources/Help.md`

- [ ] Update user-facing help text to reference the toolbar AI rail instead of the editor context menu.
- [ ] Run focused tests from Tasks 1-3.
- [ ] Run full deterministic suite serially when feasible: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`.
