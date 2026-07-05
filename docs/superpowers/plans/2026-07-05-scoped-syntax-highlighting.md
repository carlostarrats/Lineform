# Scoped Write-mode Syntax Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound the per-typing-pass Write-mode syntax-highlight cost to the on-screen region plus a margin, eliminating the ~121 ms whole-document re-tokenize that causes large-doc typing stutter, while keeping small-doc/no-scroll highlighting byte-identical and layout stable.

**Architecture:** Split `MarkdownSyntaxHighlighter.highlight` into a whole-document **base pass** (uniform font/paragraph-style/kern/color → stable layout) and a **scoped token pass** (tokenize + colorize only a line-snapped window around the visible range). The text view drives scope: full refresh on load/profile/replacement, token-only pass on typing-pause and on a new coalesced scroll-settle handler. The range analyzer is line-local, so a line-snapped window yields byte-identical tokens — no fence-state scan needed.

**Tech Stack:** Swift, AppKit (NSTextView / NSLayoutManager / NSTextStorage / NSClipView), XCTest.

## Global Constraints

- Existing highlighter behavior must stay **byte-identical** for small docs and any `LineformTextView` with no enclosing scroll view (all current tests must pass unchanged).
- Default test gate: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO` (Xcode quit; warn user re: TCC Documents prompt).
- Do NOT add fenced-code-content suppression (behavior change, out of scope). Do NOT background-thread the highlighter.
- Do NOT weaken hosted motion tests; if a new hosted test class is added, update BOTH `Lineform.xctestplan` (skippedTests) and `LineformHosted.xctestplan` (selectedTests) in lockstep (`TestPlanGuardTests` enforces this).
- Margin constant ≈ 3000 chars; scroll-settle debounce ≈ 0.05 s.

---

### Task 1: Pure scope-range helper `scopedTokenRange`

**Files:**
- Modify: `Lineform/Editor/MarkdownSyntaxHighlighter.swift`
- Test: `LineformTests/ScopedSyntaxHighlightingTests.swift` (create)

**Interfaces:**
- Produces: `static func scopedTokenRange(visibleRange: NSRange, margin: Int, in text: NSString) -> NSRange` — expands `visibleRange` by `margin` each side, snaps to line boundaries, clamps to `[0, text.length]`. Empty text → `NSRange(location: 0, length: 0)`.

- [ ] **Step 1: Write failing tests**

```swift
import AppKit
import XCTest
@testable import Lineform

final class ScopedSyntaxHighlightingTests: XCTestCase {
    private func lines(_ n: Int) -> String {
        (1...n).map { "Line \($0) with `code` and [a](b)." }.joined(separator: "\n")
    }

    func testScopedTokenRangeExpandsByMarginAndSnapsToLineBoundaries() {
        let text = "aaaa\nbbbb\ncccc\ndddd\neeee" as NSString // 5 lines, 4 chars + \n each
        // Visible = the "cccc" line (location 10, length 4). Margin 1 char each side.
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: 10, length: 4), margin: 1, in: text
        )
        // 10-1=9 snaps back to start of "bbbb" (loc 5); 14+1=15 snaps to end of "dddd" line (loc 19).
        XCTAssertEqual(scope, NSRange(location: 5, length: 14))
    }

    func testScopedTokenRangeClampsAtDocumentEdges() {
        let text = "aaaa\nbbbb\ncccc" as NSString // length 14
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: 0, length: 4), margin: 10_000, in: text
        )
        XCTAssertEqual(scope, NSRange(location: 0, length: 14))
    }

    func testScopedTokenRangeOnEmptyTextIsEmpty() {
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: 0, length: 0), margin: 3000, in: "" as NSString
        )
        XCTAssertEqual(scope, NSRange(location: 0, length: 0))
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL** (no such method)

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/ScopedSyntaxHighlightingTests`
Expected: compile failure / FAIL.

- [ ] **Step 3: Implement `scopedTokenRange`**

Add to `MarkdownSyntaxHighlighter` (near the other statics):

```swift
static func scopedTokenRange(visibleRange: NSRange, margin: Int, in text: NSString) -> NSRange {
    let length = text.length
    guard length > 0 else { return NSRange(location: 0, length: 0) }

    let lowerBound = max(0, visibleRange.location - margin)
    let upperBound = min(length, NSMaxRange(visibleRange) + margin)

    let start = text.lineRange(for: NSRange(location: min(lowerBound, length - 1), length: 0)).location
    let end: Int
    if upperBound >= length {
        end = length
    } else {
        end = NSMaxRange(text.lineRange(for: NSRange(location: upperBound, length: 0)))
    }
    return NSRange(location: start, length: max(0, end - start))
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownSyntaxHighlighter.swift LineformTests/ScopedSyntaxHighlightingTests.swift
git commit -m "Task 2: pure scopedTokenRange helper (margin + line-boundary snap)"
```

---

### Task 2: Scoped tokenization helper `tokens(in:scope:)` proven byte-identical

**Files:**
- Modify: `Lineform/Editor/MarkdownSyntaxHighlighter.swift`
- Test: `LineformTests/ScopedSyntaxHighlightingTests.swift`

**Interfaces:**
- Consumes: private `analyzer` (`MarkdownRangeAnalyzer`) already on the class.
- Produces: `func tokens(in text: NSString, scope: NSRange) -> [MarkdownTokenRange]` — tokenizes only `text.substring(with: scope)`, offset back to absolute positions. Empty scope → `[]`.

- [ ] **Step 1: Write failing byte-identical test**

```swift
extension ScopedSyntaxHighlightingTests {
    func testScopedTokensEqualWholeDocTokensFilteredToWindow() {
        // Multi-construct doc incl. a fenced block and headings/lists so a naive
        // scope could diverge if there were cross-line state (there isn't).
        let doc = """
        # Heading one
        - list item with `code`
        > a quote
        ```
        # not a heading (inside fence)
        - not a list
        ```
        Paragraph with [link](https://example.com) and more.
        Another `span` here.
        """
        let ns = doc as NSString
        let highlighter = MarkdownSyntaxHighlighter()

        // Window snapped over the middle (covering the fence + surrounding lines).
        let window = MarkdownSyntaxHighlighter.scopedTokenRange(
            visibleRange: NSRange(location: ns.length / 3, length: ns.length / 3),
            margin: 5, in: ns
        )

        let scoped = highlighter.tokens(in: ns, scope: window)
        let wholeFiltered = MarkdownRangeAnalyzer().ranges(in: doc).filter {
            $0.range.location >= window.location && NSMaxRange($0.range) <= NSMaxRange(window)
        }

        let sort: (MarkdownTokenRange, MarkdownTokenRange) -> Bool = {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length < $1.range.length
        }
        XCTAssertEqual(scoped.sorted(by: sort), wholeFiltered.sorted(by: sort))
        XCTAssertFalse(scoped.isEmpty)
    }

    func testScopedTokensEmptyScopeIsEmpty() {
        let highlighter = MarkdownSyntaxHighlighter()
        XCTAssertTrue(highlighter.tokens(in: "# H" as NSString, scope: NSRange(location: 0, length: 0)).isEmpty)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `tokens(in:scope:)`)

Run: `-only-testing:LineformTests/ScopedSyntaxHighlightingTests`
Expected: compile failure / FAIL.

- [ ] **Step 3: Implement `tokens(in:scope:)`**

```swift
func tokens(in text: NSString, scope: NSRange) -> [MarkdownTokenRange] {
    let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: text.length))
    guard clamped.length > 0 else { return [] }
    let substring = text.substring(with: clamped)
    return analyzer.ranges(in: substring).map { token in
        MarkdownTokenRange(
            kind: token.kind,
            range: NSRange(location: token.range.location + clamped.location, length: token.range.length)
        )
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownSyntaxHighlighter.swift LineformTests/ScopedSyntaxHighlightingTests.swift
git commit -m "Task 2: scoped tokens(in:scope:) proven byte-identical to whole-doc"
```

---

### Task 3: Refactor `highlight` into base pass + scoped token pass; add `refreshTokens` and `range(_:covers:)`

**Files:**
- Modify: `Lineform/Editor/MarkdownSyntaxHighlighter.swift:160-178`
- Test: `LineformTests/ScopedSyntaxHighlightingTests.swift`

**Interfaces:**
- Consumes: `tokens(in:scope:)` (Task 2), `baseAttributes(for:)`, `attributes(for:profile:)`.
- Produces:
  - `func highlight(textView: NSTextView, profile: ReadingProfile = .original, tokenScope: NSRange? = nil)` — full base pass over the whole doc + token pass over `tokenScope` (nil → whole doc; nil is the current byte-identical behavior).
  - `func refreshTokens(textView: NSTextView, profile: ReadingProfile, scope: NSRange)` — resets only `scope` to base, then applies tokens in `scope`. No whole-doc write.
  - `static func range(_ outer: NSRange, covers inner: NSRange) -> Bool` — `inner ⊆ outer`.

- [ ] **Step 1: Write failing tests**

```swift
extension ScopedSyntaxHighlightingTests {
    @MainActor
    func testHighlightWithTokenScopeColorsOnlyInsideScope() {
        // Heading at top (loc 0) and a heading far below; scope only the top.
        let doc = "# Top heading\n" + String(repeating: "plain body line\n", count: 200) + "# Bottom heading"
        let textView = LineformTextView()
        textView.string = doc
        let highlighter = MarkdownSyntaxHighlighter()

        let topScope = NSRange(location: 0, length: 13) // "# Top heading"
        highlighter.highlight(textView: textView, profile: .original, tokenScope: topScope)

        let storage = textView.textStorage!
        let markerColor = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        let topMarker = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        assertSameRGB(topMarker!, markerColor) // '#' colored in scope

        let bottomHashLocation = (doc as NSString).range(of: "# Bottom heading").location
        let bottomMarker = storage.attribute(.foregroundColor, at: bottomHashLocation, effectiveRange: nil) as? NSColor
        // Off-scope '#' stays base text color, NOT marker color.
        assertSameRGB(bottomMarker!, Theme.theme(for: .original).textColor)
    }

    @MainActor
    func testRefreshTokensColorsOnlyItsScopeAndLeavesRestUntouched() {
        let doc = "# A\n# B\n# C"
        let textView = LineformTextView()
        textView.string = doc
        let highlighter = MarkdownSyntaxHighlighter()
        // Start from all-base (no tokens applied anywhere).
        highlighter.highlight(textView: textView, profile: .original, tokenScope: NSRange(location: 0, length: 0))

        let storage = textView.textStorage!
        let base = Theme.theme(for: .original).textColor
        assertSameRGB(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor, base)

        // Refresh only the second heading's line ("# B" starts at loc 4).
        highlighter.refreshTokens(textView: textView, profile: .original, scope: NSRange(location: 4, length: 3))
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        assertSameRGB(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as! NSColor, marker) // '#' of B
        assertSameRGB(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor, base)   // A still base
    }

    func testRangeCovers() {
        XCTAssertTrue(MarkdownSyntaxHighlighter.range(NSRange(location: 0, length: 10), covers: NSRange(location: 2, length: 3)))
        XCTAssertFalse(MarkdownSyntaxHighlighter.range(NSRange(location: 0, length: 10), covers: NSRange(location: 8, length: 5)))
    }

    // Small helper mirroring the existing WritingTools test util.
    private func assertSameRGB(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let ac = a.usingColorSpace(.sRGB)!, bc = b.usingColorSpace(.sRGB)!
        XCTAssertEqual(ac.redComponent, bc.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.greenComponent, bc.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.blueComponent, bc.blueComponent, accuracy: 0.01, file: file, line: line)
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Refactor the highlighter**

Replace the existing `highlight(textView:profile:)` (lines ~160-178) with:

```swift
@MainActor
func highlight(textView: NSTextView, profile: ReadingProfile = .original, tokenScope: NSRange? = nil) {
    guard let storage = textView.textStorage else { return }
    let selectedRange = textView.selectedRange()
    let fullRange = NSRange(location: 0, length: storage.length)
    let scope = NSIntersectionRange(tokenScope ?? fullRange, fullRange)

    storage.beginEditing()
    storage.setAttributes(Self.baseAttributes(for: profile), range: fullRange)
    applyTokenAttributes(in: storage, profile: profile, scope: scope)
    storage.endEditing()
    textView.setSelectedRange(selectedRange)
}

@MainActor
func refreshTokens(textView: NSTextView, profile: ReadingProfile, scope: NSRange) {
    guard let storage = textView.textStorage else { return }
    let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
    guard clamped.length > 0 else { return }
    let selectedRange = textView.selectedRange()

    storage.beginEditing()
    storage.setAttributes(Self.baseAttributes(for: profile), range: clamped)
    applyTokenAttributes(in: storage, profile: profile, scope: clamped)
    storage.endEditing()
    textView.setSelectedRange(selectedRange)
}

private func applyTokenAttributes(in storage: NSTextStorage, profile: ReadingProfile, scope: NSRange) {
    guard scope.length > 0 else { return }
    for token in tokens(in: storage.string as NSString, scope: scope) where NSMaxRange(token.range) <= storage.length {
        storage.addAttributes(attributes(for: token.kind, profile: profile), range: token.range)
    }
}

static func range(_ outer: NSRange, covers inner: NSRange) -> Bool {
    inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
}
```

(The `attributes(for:profile:)` private method stays unchanged.)

- [ ] **Step 4: Run new tests + full suite — expect PASS (byte-identical preserved)**

Run: `-only-testing:LineformTests/ScopedSyntaxHighlightingTests` then the full default gate.
Expected: PASS; existing `LineformTextViewWritingToolsTests` / `LargeDocumentPerformanceTests` unchanged.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownSyntaxHighlighter.swift LineformTests/ScopedSyntaxHighlightingTests.swift
git commit -m "Task 2: split highlight into whole-doc base + scoped token passes"
```

---

### Task 4: Wire the text view — scoped typing pass + coalesced scroll-settle refresh

**Files:**
- Modify: `Lineform/Editor/LineformTextView.swift` (highlight entry points ~133-139, add scope helper + scroll observation)
- Test: `LineformTests/ScopedSyntaxHighlightingTests.swift`

**Interfaces:**
- Consumes: `highlight(textView:profile:tokenScope:)`, `refreshTokens(textView:profile:scope:)`, `MarkdownSyntaxHighlighter.scopedTokenRange`, `MarkdownSyntaxHighlighter.range(_:covers:)`.
- Produces: text-view-internal wiring; adds `func currentVisibleTokenScope() -> NSRange?` (nil when no enclosing scroll view) and `@objc func refreshVisibleTokensAfterScroll()`.

- [ ] **Step 1: Write failing test — no scroll view falls back to full highlight (byte-identical)**

```swift
extension ScopedSyntaxHighlightingTests {
    @MainActor
    func testNoScrollViewFallsBackToFullHighlight() {
        // A bare text view (no scroll view) must colorize a heading anywhere in the doc.
        let doc = String(repeating: "plain line\n", count: 300) + "# Deep heading"
        let textView = LineformTextView()
        textView.string = doc
        textView.refreshMarkdownHighlighting()

        let storage = textView.textStorage!
        let deepHash = (doc as NSString).range(of: "# Deep heading").location
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        assertSameRGB(storage.attribute(.foregroundColor, at: deepHash, effectiveRange: nil) as! NSColor, marker)
        XCTAssertNil(textView.currentVisibleTokenScope()) // no scroll view → nil scope
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`currentVisibleTokenScope` missing)

- [ ] **Step 3: Implement text-view wiring**

Add constants near the top of `LineformTextView` (with the other `static let`s):

```swift
static let highlightMargin = 3000
static let scrollHighlightDebounce: TimeInterval = 0.05
```

Add stored state (near the other `private var`s):

```swift
private var lastHighlightedTokenRange: NSRange?
private var scrollBoundsObservation: NSObjectProtocol?
```

Replace `refreshMarkdownHighlighting()` / `refreshMarkdownHighlightingAfterTypingDelay()` (lines ~133-139) with:

```swift
func refreshMarkdownHighlighting() {
    let scope = currentVisibleTokenScope()
    markdownHighlighter.highlight(textView: self, profile: activeReadingProfile, tokenScope: scope)
    lastHighlightedTokenRange = scope ?? NSRange(location: 0, length: (string as NSString).length)
}

@objc func refreshMarkdownHighlightingAfterTypingDelay() {
    guard let scope = currentVisibleTokenScope() else {
        refreshMarkdownHighlighting()
        return
    }
    markdownHighlighter.refreshTokens(textView: self, profile: activeReadingProfile, scope: scope)
    lastHighlightedTokenRange = scope
}

func currentVisibleTokenScope() -> NSRange? {
    guard let visible = visibleCharacterRangeForHighlighting() else { return nil }
    return MarkdownSyntaxHighlighter.scopedTokenRange(
        visibleRange: visible, margin: Self.highlightMargin, in: string as NSString
    )
}

/// Visible char range WITHOUT forcing full-container layout (unlike
/// `visibleCharacterRangeForLayoutPreservation`, which calls `ensureLayout`).
/// `glyphRange(forBoundingRect:)` lays out lazily, only what the rect needs.
private func visibleCharacterRangeForHighlighting() -> NSRange? {
    guard
        let layoutManager,
        let textContainer,
        let scrollView = enclosingScrollView
    else { return nil }

    var visibleRect = scrollView.contentView.bounds
    visibleRect.origin.x -= textContainerOrigin.x
    visibleRect.origin.y -= textContainerOrigin.y
    let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
    return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
}

@objc func refreshVisibleTokensAfterScroll() {
    guard let scope = currentVisibleTokenScope() else { return }
    if let last = lastHighlightedTokenRange, MarkdownSyntaxHighlighter.range(last, covers: scope) {
        return // already highlighted; ordinary in-margin scroll does no work
    }
    markdownHighlighter.refreshTokens(textView: self, profile: activeReadingProfile, scope: scope)
    lastHighlightedTokenRange = scope
}

private func scheduleVisibleTokensRefreshAfterScroll() {
    let selector = #selector(refreshVisibleTokensAfterScroll)
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
    perform(selector, with: nil, afterDelay: Self.scrollHighlightDebounce, inModes: [.common])
}
```

Add scroll observation lifecycle. Add near the other overrides:

```swift
override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    setUpScrollBoundsObservationIfNeeded()
}

private func setUpScrollBoundsObservationIfNeeded() {
    guard scrollBoundsObservation == nil, let clipView = enclosingScrollView?.contentView else { return }
    clipView.postsBoundsChangedNotifications = true
    scrollBoundsObservation = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
    ) { [weak self] _ in
        self?.scheduleVisibleTokensRefreshAfterScroll()
    }
}
```

Add to `deinit` (create one if absent):

```swift
deinit {
    if let scrollBoundsObservation {
        NotificationCenter.default.removeObserver(scrollBoundsObservation)
    }
}
```

- [ ] **Step 4: Run new test + full default gate — expect PASS**

Run: full default gate. Expected: all pass (byte-identical fallback intact).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/LineformTextView.swift LineformTests/ScopedSyntaxHighlightingTests.swift
git commit -m "Task 2: scoped typing pass + coalesced scroll-settle re-highlight"
```

---

### Task 5: Hosted integration test — scroll reveals colorized text

**Files:**
- Test: `LineformTests/ScopedHighlightingScrollHostedTests.swift` (create)
- Modify: `Lineform.xctestplan` (add to skippedTests), `LineformHosted.xctestplan` (add to selectedTests)

**Interfaces:**
- Consumes: `refreshMarkdownHighlighting()`, `refreshVisibleTokensAfterScroll()`, `currentVisibleTokenScope()`.

- [ ] **Step 1: Add the class to BOTH test plans (lockstep)**

In `Lineform.xctestplan`, add `"ScopedHighlightingScrollHostedTests"` to the `skippedTests` array (keep alphabetical-ish with the others). In `LineformHosted.xctestplan`, add the same string to `selectedTests`. (`TestPlanGuardTests` will fail if these drift.)

- [ ] **Step 2: Write the hosted integration test**

```swift
import AppKit
import XCTest
@testable import Lineform

/// Hosted (scroll-geometry) integration: a large doc in a real NSScrollView colorizes
/// the visible top on a full refresh, leaves deep off-screen text at base color, then
/// colorizes it after a programmatic scroll + settle. Lives in the HOSTED plan because
/// it depends on real layout/scroll geometry (timing/environment-sensitive), like the
/// other quarantined view tests.
final class ScopedHighlightingScrollHostedTests: XCTestCase {
    @MainActor
    func testScrollRevealsColorizedHeading() {
        let doc = "# Top\n" + String(repeating: "plain body line\n", count: 4000) + "# Bottom heading"

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scrollView.hasVerticalScroller = true
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        textView.string = doc
        textView.applyTypography(.original)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let storage = textView.textStorage!
        let ns = doc as NSString
        let bottomHash = ns.range(of: "# Bottom heading").location
        let marker = MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original)
        let base = Theme.theme(for: .original).textColor

        // Deep bottom heading is off-screen + past the margin → base color after a full refresh.
        textView.refreshMarkdownHighlighting()
        let before = storage.attribute(.foregroundColor, at: bottomHash, effectiveRange: nil) as! NSColor
        assertSameRGB(before, base)

        // Scroll to the bottom and run the (debounced) refresh synchronously.
        let docHeight = textView.frame.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, docHeight - 300)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.refreshVisibleTokensAfterScroll()

        let after = storage.attribute(.foregroundColor, at: bottomHash, effectiveRange: nil) as! NSColor
        assertSameRGB(after, marker)

        window.close()
    }

    private func assertSameRGB(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let ac = a.usingColorSpace(.sRGB)!, bc = b.usingColorSpace(.sRGB)!
        XCTAssertEqual(ac.redComponent, bc.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.greenComponent, bc.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ac.blueComponent, bc.blueComponent, accuracy: 0.01, file: file, line: line)
    }
}
```

- [ ] **Step 3: Run the hosted plan (Xcode quit, quiet machine)**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -testPlan LineformHosted -only-testing:LineformTests/ScopedHighlightingScrollHostedTests`
Expected: PASS. If scroll geometry proves flaky in this environment, verify the behavior in-app instead and keep the class (it documents intent); note the residual in the tracker.

- [ ] **Step 4: Run the default gate to confirm TestPlanGuard still green**

Run: default gate. Expected: `TestPlanGuardTests` passes (plans partition correctly), all default tests pass.

- [ ] **Step 5: Commit**

```bash
git add LineformTests/ScopedHighlightingScrollHostedTests.swift Lineform.xctestplan LineformHosted.xctestplan
git commit -m "Task 2: hosted integration test — scroll reveals colorized text"
```

---

## Self-Review

- **Spec coverage:** base pass (Task 3) ✓; scoped token pass (Task 3) ✓; entry points load/profile/replacement (Task 4, `refreshMarkdownHighlighting`) ✓; typing pass (Task 4) ✓; scroll-settle handler + coalesce + covered-guard (Task 4) ✓; margin/debounce constants (Task 4) ✓; `scopedTokenRange` (Task 1) ✓; byte-identical `tokens` (Task 2) ✓; no-scroll-view fallback (Task 4 test) ✓; hosted scroll integration (Task 5) ✓; no fence scan / no threading (constraints) ✓.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `highlight(textView:profile:tokenScope:)`, `refreshTokens(textView:profile:scope:)`, `tokens(in:scope:)`, `scopedTokenRange(visibleRange:margin:in:)`, `range(_:covers:)`, `currentVisibleTokenScope()`, `refreshVisibleTokensAfterScroll()` used identically across tasks. ✓
