# Search Simplification Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the custom search-highlight overlay so the toolbar search bar behaves like a normal native search — current match shown by the text view's own selection — and make Return in the search field jump to the next occurrence.

**Architecture:** Search already selects the active match through the existing `requestedSelection` binding (native selection). The custom blue/yellow overlay drawn in `LineformTextView` is redundant and creates the half-broken feel (orphan yellow matches with no way to reach them). This plan deletes that overlay and its now-dead helpers, then wires the existing `EditorSearchResolver.nextIndex` + `selectSearchMatch(at:)` (currently dead code) to the search field's submit action.

**Tech Stack:** Swift, SwiftUI (`.searchable`, `.onSubmit(of: .search)`), AppKit (`NSTextView`), XCTest.

## Global Constraints

- Keep the always-present toolbar search field (SwiftUI `.searchable`, placement `.toolbar`). Do not replace it with the native find bar.
- No new UI: no next/previous arrow controls, no "1 of N" counter.
- Native selection is the only visual indicator of the current match.
- Return advances to the next occurrence and wraps; no Find Previous.
- Read-mode search behavior (reveal by switching to Write) is unchanged and out of scope.
- Do not touch `usesFindPanel` / `isIncrementalSearchingEnabled` on the text views.
- Test gate (run serially, quit Xcode first — see `CLAUDE.md`):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
    -destination 'platform=macOS' -parallel-testing-enabled NO
  ```

---

### Task 1: Delete the custom search overlay and dead resolver helpers

**Files:**
- Modify: `Lineform/Editor/LineformTextView.swift` (remove overlay state, draw call, `setSearchHighlights`, `drawSearchHighlightsIfNeeded`, `visibleCharacterRangeForSearchHighlights`)
- Modify: `Lineform/Editor/MarkdownTextViewRepresentable.swift` (remove `searchRanges`/`activeSearchRange` props and the `setSearchHighlights` call)
- Modify: `Lineform/Editor/EditorContainerView.swift` (stop passing overlay params; remove now-unused `activeSearchRange` computed property)
- Modify: `Lineform/Editor/EditorSearchResolver.swift` (remove `visibleMatches` and `previousIndex`)
- Test: `LineformTests/EditorDisplayModeTests.swift` (drop `visibleMatches` test, drop `previousIndex` assertions)

**Interfaces:**
- Consumes: nothing new.
- Produces: `MarkdownTextViewRepresentable` no longer has `searchRanges` / `activeSearchRange` parameters. `LineformTextView` no longer has `setSearchHighlights(_:activeRange:)`. `EditorSearchResolver` no longer has `visibleMatches(...)` or `previousIndex(...)`. `EditorSearchResolver.matches`, `refreshState`, `nextIndex`, `accessibilitySummary` remain.

- [ ] **Step 1: Update the tests first (remove coverage of deleted code)**

In `LineformTests/EditorDisplayModeTests.swift`, replace `testEditorSearchNavigationWrapsBetweenMatches` (remove the two `previousIndex` assertions and rename to reflect next-only advance):

```swift
    func testEditorSearchAdvancesToNextMatchAndWraps() {
        let matches = [
            NSRange(location: 4, length: 5),
            NSRange(location: 18, length: 5),
            NSRange(location: 30, length: 5)
        ]

        XCTAssertEqual(EditorSearchResolver.nextIndex(after: nil, matchCount: matches.count), 0)
        XCTAssertEqual(EditorSearchResolver.nextIndex(after: 0, matchCount: matches.count), 1)
        XCTAssertEqual(EditorSearchResolver.nextIndex(after: 2, matchCount: matches.count), 0)
    }
```

Delete the whole `testEditorSearchVisibleMatchesIncludesOnlyVisibleAndActiveRanges` function (the `visibleMatches` helper is being removed).

In `testEditorSearchIgnoresEmptyAndWhitespaceQueries`, delete the `previousIndex` line so it reads:

```swift
    func testEditorSearchIgnoresEmptyAndWhitespaceQueries() {
        XCTAssertTrue(EditorSearchResolver.matches(in: "Anything", query: "").isEmpty)
        XCTAssertTrue(EditorSearchResolver.matches(in: "Anything", query: "   ").isEmpty)
        XCTAssertNil(EditorSearchResolver.nextIndex(after: nil, matchCount: 0))
    }
```

- [ ] **Step 2: Remove `visibleMatches` and `previousIndex` from the resolver**

In `Lineform/Editor/EditorSearchResolver.swift`, delete the `visibleMatches(_:activeRange:visibleCharacterRange:)` function (the `static func visibleMatches...` block) and the `previousIndex(before:matchCount:)` function. Leave `matches`, `refreshState`, `nextIndex`, `accessibilitySummary`, and `EditorSearchToolbarPresentation` untouched.

- [ ] **Step 3: Remove the overlay from `LineformTextView`**

In `Lineform/Editor/LineformTextView.swift`:

Delete the two stored properties:

```swift
    private var searchHighlightRanges: [NSRange] = []
    private var activeSearchHighlightRange: NSRange?
```

In `drawBackground(in:)`, delete the call:

```swift
        drawSearchHighlightsIfNeeded()
```

Delete the `setSearchHighlights(_:activeRange:)` method:

```swift
    func setSearchHighlights(_ ranges: [NSRange], activeRange: NSRange?) {
        searchHighlightRanges = ranges
        activeSearchHighlightRange = activeRange
        needsDisplay = true
    }
```

Delete both `drawSearchHighlightsIfNeeded()` and the `visibleCharacterRangeForSearchHighlights()` wrapper:

```swift
    private func drawSearchHighlightsIfNeeded() {
        ...
    }

    private func visibleCharacterRangeForSearchHighlights() -> NSRange? {
        visibleCharacterRangeForLayoutPreservation()
    }
```

Do NOT touch `visibleCharacterRangeForLayoutPreservation()` — it is still used by scroll/layout preservation (line ~807).

- [ ] **Step 4: Remove the overlay from `MarkdownTextViewRepresentable`**

In `Lineform/Editor/MarkdownTextViewRepresentable.swift`, delete the two stored properties:

```swift
    var searchRanges: [NSRange] = []
    var activeSearchRange: NSRange?
```

And in `updateNSView`, delete the line:

```swift
        textView.setSearchHighlights(searchRanges, activeRange: activeSearchRange)
```

- [ ] **Step 5: Stop passing overlay params in `EditorContainerView`**

In `Lineform/Editor/EditorContainerView.swift`, in the `markdownEditor` computed property, delete these two argument lines from the `MarkdownTextViewRepresentable(...)` call:

```swift
            searchRanges: searchMatches,
            activeSearchRange: activeSearchRange,
```

Then delete the now-unused `activeSearchRange` computed property:

```swift
    private var activeSearchRange: NSRange? {
        guard let activeSearchIndex, searchMatches.indices.contains(activeSearchIndex) else {
            return nil
        }
        return searchMatches[activeSearchIndex]
    }
```

Keep `searchMatches` and `activeSearchIndex` state — they still drive selection, match count, and accessibility.

- [ ] **Step 6: Build and run the test gate**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```
Expected: build succeeds; suite passes. Report exact pass/fail counts. (The removed tests no longer reference deleted symbols; remaining `EditorSearchResolver` tests still compile.)

- [ ] **Step 7: Commit**

```bash
git add Lineform/Editor/LineformTextView.swift Lineform/Editor/MarkdownTextViewRepresentable.swift Lineform/Editor/EditorContainerView.swift Lineform/Editor/EditorSearchResolver.swift LineformTests/EditorDisplayModeTests.swift
git commit -m "Search: remove custom highlight overlay; rely on native selection"
```

---

### Task 2: Make Return in the search field jump to the next match

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift` (add `.onSubmit(of: .search)` and an `advanceToNextSearchMatch()` helper)

**Interfaces:**
- Consumes: `EditorSearchResolver.nextIndex(after:matchCount:)` and the existing `selectSearchMatch(at:)` (previously dead, now used).
- Produces: pressing Return in the toolbar search field advances the selected match and wraps.

- [ ] **Step 1: Add the submit handler and helper**

In `Lineform/Editor/EditorContainerView.swift`, add `.onSubmit(of: .search)` next to the existing `.onChange(of: searchQuery)` modifier (both attach to the same view in `body`):

```swift
        .onSubmit(of: .search) {
            advanceToNextSearchMatch()
        }
```

Add this method near `refreshSearchMatches` / `selectSearchMatch`:

```swift
    private func advanceToNextSearchMatch() {
        guard
            let next = EditorSearchResolver.nextIndex(
                after: activeSearchIndex,
                matchCount: searchMatches.count
            )
        else {
            return
        }
        selectSearchMatch(at: next)
    }
```

(`selectSearchMatch(at:)` already exists in this file; it sets `activeSearchIndex`, switches Read→Write if needed, and sets `requestedSelection` to the match — driving native selection.)

- [ ] **Step 2: Build and run the test gate**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```
Expected: build succeeds; suite passes (advance/wrap logic covered by `testEditorSearchAdvancesToNextMatchAndWraps`). Report exact counts.

- [ ] **Step 3: Manual QA in the running app**

Because the submit wiring lives in the SwiftUI view layer, verify by hand: launch the app, open a document with a repeated word, ⌘F, type the word — the first match selects (native selection, no yellow overlay on other matches); press Return repeatedly — selection walks to each subsequent match and wraps to the first. Confirm no yellow/blue overlay appears. Note in the report what was verified vs. what needs the user to confirm.

- [ ] **Step 4: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift
git commit -m "Search: Return jumps to next match"
```

---

### Task 3: Documentation and final verification

**Files:**
- Modify (only if a claim is now inaccurate): `CLAUDE.md` — the Main Features list does not currently describe the search overlay, so likely no change is needed. Do NOT add documentation just to add it.

- [ ] **Step 1: Check docs for now-false claims**

Grep for any doc text describing search highlighting:
```sh
grep -rn -i "search.*highlight\|yellow\|find next" CLAUDE.md README.md docs/ Lineform/Resources/ | grep -vi "syntax highlight"
```
If nothing describes the removed overlay behavior, make no doc change. If something does, correct it to match the new behavior (native selection + Return to advance).

- [ ] **Step 2: Final full-suite gate**

Run the serial test gate once more and report exact pass/fail counts:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

- [ ] **Step 3: Commit any doc change (skip if none)**

```bash
git add CLAUDE.md
git commit -m "Docs: describe simplified native search behavior"
```
