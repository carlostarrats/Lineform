# Review Follow-ups Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three review findings with contained fixes (tab-close VoiceOver action, stale All Files search during first scan, Quick Look inline formatting) and document one intentional behavior (undo reset on tab switch).

**Architecture:** Four independent changes. Two are small SwiftUI/AppKit edits (tab accessibility action, view `.onChange` re-search). One is a doc-only change. The largest extracts the Quick Look Markdown renderer into its own AppKit-only file so it becomes unit-testable, then adds an inline-formatting pass (bold/italic/code/links/strikethrough) with code-first precedence.

**Tech Stack:** Swift, SwiftUI, AppKit, TextKit (`NSAttributedString`), XCTest. macOS document-based app. Hand-rolled `.pbxproj` (objectVersion 56, sequential `1F0000xx` IDs).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-18-review-followups-design.md`.
- Default test gate (run from repo root; warn the user first — ad-hoc re-sign can trigger a TCC Documents prompt that blocks the run):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
- No new dependencies. No iCloud entitlement added to Debug. Keep changes scoped; no unrelated refactors or metadata churn.
- pbxproj edits follow the repo convention: edit the 4 sections (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase files) with sequential `1F0000xx` IDs; verify any new ID is unused via `grep` before inserting.
- Every commit message ends with the two trailer lines used in this repo:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Ak8gDXcrh6iZ2sYNDhceV4
  ```
  (Omitted from the sample `git commit` steps below for brevity — include them.)

---

### Task 1: Stale All Files search — re-run when roots populate

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift` (add `.onChange` observers on `fileBrowserStore.iCloudRoot` / `workspaceRoot` near the other search `.onChange`s around line 500–508)
- Test: `LineformTests/CrossFileSearchModelTests.swift` (document the re-search-supersedes-empty contract)

**Interfaces:**
- Consumes: `CrossFileSearchModel.search(query:entries:)` (existing, debounced/latest-wins), `EditorContainerView.updateCrossFileSearch()` (existing, private), `OutlineFileBrowserStore.iCloudRoot` / `.workspaceRoot` (existing `@Published OutlineFileRoot`, already `Equatable`), `searchScope` / `searchQuery` (existing `@State`).
- Produces: no new public symbols.

- [ ] **Step 1: Write the failing test**

Add to `LineformTests/CrossFileSearchModelTests.swift` (inside the existing class):

```swift
    // Reproduces the All Files "stale during first scan" bug at the model boundary: the
    // first search runs before the deferred scan has populated the roots (empty entries →
    // no results); when the roots publish, the view re-issues the search with the full
    // entry set and results appear — without the user editing the query.
    func testReSearchWithNewlyPopulatedEntriesSupersedesEmptyInitial() async {
        let reader = StubReader(texts: ["/found.md": "needle here"])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)

        // Scan not done yet: no entries → no results.
        await model.search(query: "needle", entries: [])?.value
        XCTAssertEqual(model.results, [])

        // Roots populated: re-issued search finds the file.
        await model.search(query: "needle", entries: [entry("/found.md")])?.value
        XCTAssertEqual(model.results.map(\.name), ["found.md"])
    }
```

- [ ] **Step 2: Run test to verify it passes as a contract check**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CrossFileSearchModelTests/testReSearchWithNewlyPopulatedEntriesSupersedesEmptyInitial
```
Expected: PASS (the model already supports this; the test pins the contract the view relies on). If it FAILS, stop — the model behavior differs from the plan's assumption.

- [ ] **Step 3: Wire the view to re-search when roots update**

In `Lineform/Editor/EditorContainerView.swift`, find the search `.onChange` cluster (currently ending near line 508 with `.onSubmit(of: .search)`). Add two observers immediately after `.onChange(of: isSearchFocused)`:

```swift
        // When the deferred Workspace/iCloud scans land, the roots republish. If the user is
        // in All Files with a live query, re-issue the cross-file search so first-ever All
        // Files results are not stale against the pre-scan (empty) snapshot. The model is
        // debounced + latest-wins, so a burst of republishes collapses to one fresh scan.
        .onChange(of: fileBrowserStore.iCloudRoot) { _, _ in
            reissueCrossFileSearchIfActive()
        }
        .onChange(of: fileBrowserStore.workspaceRoot) { _, _ in
            reissueCrossFileSearchIfActive()
        }
```

Then add this private helper next to `updateCrossFileSearch()` (near line 1450):

```swift
    /// Re-runs the All Files scan when the scanned roots change, but only while All Files is
    /// the active scope with a non-empty query — otherwise there is nothing to refresh.
    private func reissueCrossFileSearchIfActive() {
        guard searchScope == .allFiles,
              !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        updateCrossFileSearch()
    }
```

- [ ] **Step 4: Build to verify the view compiles**

Run:
```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift LineformTests/CrossFileSearchModelTests.swift
git commit -m "Refresh All Files search when the first Workspace/iCloud scan lands"
```

---

### Task 2: Tab close — VoiceOver custom action

**Files:**
- Modify: `Lineform/Editor/TabBarView.swift` (the selection `Button` in `tabButton(for:)`, around lines 76–96)

**Interfaces:**
- Consumes: `onCloseTab: (UUID) -> Void` (existing closure), `tabStore.tabCount` (existing), `tab.id` (existing).
- Produces: no new symbols. Visual output byte-identical; only the accessibility tree gains a per-tab "Close tab" action when `tabCount > 1`.

- [ ] **Step 1: Add the accessibility action to the selection Button**

In `Lineform/Editor/TabBarView.swift`, the selection `Button` currently ends with:

```swift
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tab.title))
            .accessibilityValue(isSelected ? Text("selected") : Text(""))
```

Append a conditional accessibility action so assistive tech can close any tab without a pointer hover (the visible × stays hover-only, unchanged). Replace the three lines above with:

```swift
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tab.title))
            .accessibilityValue(isSelected ? Text("selected") : Text(""))
            // The visible × is deliberately pointer-hover-only (design: no close affordance
            // at rest). VoiceOver / Switch Control users reach close through this custom
            // action instead — same gating as the visible ×: only when more than one tab is
            // open (closing a lone tab is not a tab operation).
            .accessibilityActions {
                if tabStore.tabCount > 1 {
                    Button("Close tab") { onCloseTab(tab.id) }
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the tab color guard test (proves no visual regression)**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/EditorDisplayModeTests/testTabColorsMeetAAAgainstTheirFillsInEveryTheme
```
Expected: PASS (colors/metrics untouched — this confirms the a11y edit changed nothing visual).

- [ ] **Step 4: Commit**

```bash
git add Lineform/Editor/TabBarView.swift
git commit -m "Add a VoiceOver Close tab action so tab close isn't pointer-only"
```

Note: SwiftUI accessibility actions are not introspectable from XCTest, so there is no unit test for the action itself. Manual verification: open 2+ tabs, enable VoiceOver (⌘F5), navigate to a tab, and confirm "Close tab" appears in the actions menu (VO-Command-Space).

---

### Task 3: Document undo-reset-on-tab-switch

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift` (comment at the `removeAllActions()` call in `activateSelectedTab`, around line 1066)
- Modify: `CLAUDE.md` (multi-document tabs bullet — add a one-line known-limitation note)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add the code comment**

In `Lineform/Editor/EditorContainerView.swift`, `activateSelectedTab()`, the line:

```swift
        backingDocument.undoManager?.removeAllActions()
```

(the first occurrence, immediately after `activeWindow?.setTitleWithRepresentedFilename(...)`) — add a comment directly above it:

```swift
        // KNOWN LIMITATION (intentional): tabs share the window's single undo manager, so
        // switching tabs clears undo history — a user cannot ⌘Z edits made in a tab after
        // switching away and back. Per-tab undo stacks are a large, regression-prone change
        // deliberately out of scope. See docs/superpowers/specs/2026-07-18-review-followups-design.md.
        backingDocument.undoManager?.removeAllActions()
```

- [ ] **Step 2: Add the CLAUDE.md note**

In `CLAUDE.md`, find the multi-document tabs bullet (starts with `**Multi-document tabs**:`). Append this sentence at the end of that bullet (before the next bullet), keeping the existing prose intact:

```
 **Known limitation (intentional):** tabs share the window's single undo manager, so switching tabs clears undo history (`activateSelectedTab` calls `undoManager.removeAllActions()`); per-tab undo stacks are deliberately out of scope (see `docs/superpowers/specs/2026-07-18-review-followups-design.md`).
```

- [ ] **Step 3: Build to verify the comment edit didn't break the file**

Run:
```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift CLAUDE.md
git commit -m "Document the intentional undo reset on tab switch"
```

---

### Task 4: Extract QuickLookMarkdownRenderer into its own testable file

**Files:**
- Create: `LineformQuickLook/QuickLookMarkdownRenderer.swift` (the whole `QuickLookMarkdownRenderer` enum, `import AppKit` only)
- Modify: `LineformQuickLook/QuickLookPreviewProvider.swift` (remove the enum; keep `PreviewViewController`)
- Modify: `Lineform.xcodeproj/project.pbxproj` (new file ref + membership in the extension target AND the test target)
- Test: `LineformTests/QuickLookMarkdownRendererTests.swift` (new — a smoke test that the type is reachable from the test target and block rendering is unchanged)

**Interfaces:**
- Consumes: nothing new.
- Produces: `enum QuickLookMarkdownRenderer` compiled into both `LineformQuickLook` and `LineformTests`, with its existing `static func render(_ text: String) -> NSAttributedString` reachable from tests.

- [ ] **Step 1: Create the new file with the extracted enum**

Cut the **entire** `enum QuickLookMarkdownRenderer { … }` block (currently lines ~58–452 of `LineformQuickLook/QuickLookPreviewProvider.swift`) and paste it verbatim into a new file `LineformQuickLook/QuickLookMarkdownRenderer.swift` with this header:

```swift
import AppKit

// Extracted from QuickLookPreviewProvider.swift so the renderer is a pure, AppKit-only type
// that compiles into LineformTests (PreviewViewController stays behind, importing QuickLookUI).
```

Then the pasted `enum QuickLookMarkdownRenderer { … }` unchanged.

- [ ] **Step 2: Remove the enum from the original file**

In `LineformQuickLook/QuickLookPreviewProvider.swift`, delete the `enum QuickLookMarkdownRenderer { … }` block. Leave `import AppKit`, `import QuickLookUI`, and `PreviewViewController` (which calls `QuickLookMarkdownRenderer.render(...)`) intact. The two files are in the same target, so the call still resolves.

- [ ] **Step 3: Register the new file in the pbxproj (4 sections)**

First verify the chosen IDs are unused:
```sh
grep -c "1F00000100000000000004A5\|1F00000200000000000004A5\|1F00000300000000000004A5" Lineform.xcodeproj/project.pbxproj
```
Expected: `0`. (If any is non-zero, pick the next free `...4A6` suffix and adjust all three consistently.)

Make these four edits in `Lineform.xcodeproj/project.pbxproj`:

(a) **PBXBuildFile** — add two entries near the existing QuickLook build file (line ~135). One for the extension target, one for the test target (a file compiled into two targets needs one PBXBuildFile per target):
```
		1F00000100000000000004A5 /* QuickLookMarkdownRenderer.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000004A5 /* QuickLookMarkdownRenderer.swift */; };
		1F00000300000000000004A5 /* QuickLookMarkdownRenderer.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000004A5 /* QuickLookMarkdownRenderer.swift */; };
```

(b) **PBXFileReference** — add near the QuickLook file ref (line ~283):
```
		1F00000200000000000004A5 /* QuickLookMarkdownRenderer.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickLookMarkdownRenderer.swift; sourceTree = "<group>"; };
```

(c) **PBXGroup children** — add to the `LineformQuickLook` group (currently lists `QuickLookPreviewProvider.swift`, `Info.plist`, `LineformQuickLook.entitlements` around line 531). Insert after `QuickLookPreviewProvider.swift`:
```
				1F00000200000000000004A5 /* QuickLookMarkdownRenderer.swift */,
```

(d) **PBXSourcesBuildPhase files** — add the extension-target build file to the QuickLook Sources phase (the `files = (` list that already contains `1F00000100000000000004A1 /* QuickLookPreviewProvider.swift in Sources */` around line 836):
```
				1F00000100000000000004A5 /* QuickLookMarkdownRenderer.swift in Sources */,
```
…and add the **test-target** build file to the LineformTests Sources phase (the `files = (` list that begins with `1F0000010000000000000001 /* LineformDocumentTests.swift in Sources */` around line 782):
```
				1F00000300000000000004A5 /* QuickLookMarkdownRenderer.swift in Sources */,
```

- [ ] **Step 4: Write the reachability + no-regression smoke test**

Create `LineformTests/QuickLookMarkdownRendererTests.swift`:

```swift
import XCTest
import AppKit
// No @testable import: QuickLookMarkdownRenderer is compiled directly into this test target.

final class QuickLookMarkdownRendererTests: XCTestCase {
    func testRendererIsReachableAndRendersHeadingBold() {
        let output = QuickLookMarkdownRenderer.render("# Title\n")
        XCTAssertTrue(output.string.contains("Title"))
        // Heading uses a bold font (existing block behavior, unchanged by the extraction).
        let font = output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testPlainParagraphRendersAsBodyText() {
        let output = QuickLookMarkdownRenderer.render("just some words\n")
        XCTAssertEqual(output.string, "just some words\n")
    }
}
```

- [ ] **Step 5: Run the new tests + build the extension**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/QuickLookMarkdownRendererTests
```
Expected: PASS (proves the renderer now compiles into the test target).

Then build the whole scheme (which builds the embedded extension) to prove the extension target still compiles with the file moved:
```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add LineformQuickLook/QuickLookMarkdownRenderer.swift LineformQuickLook/QuickLookPreviewProvider.swift Lineform.xcodeproj/project.pbxproj LineformTests/QuickLookMarkdownRendererTests.swift
git commit -m "Extract QuickLookMarkdownRenderer to its own AppKit-only, test-target file"
```

---

### Task 5: Quick Look inline formatting (bold/italic/code/links/strikethrough)

**Files:**
- Modify: `LineformQuickLook/QuickLookMarkdownRenderer.swift` (add the inline pass and apply it at every prose call site)
- Test: `LineformTests/QuickLookMarkdownRendererTests.swift` (add inline-formatting cases)

**Interfaces:**
- Consumes: existing block loop and its per-site `attrs` dictionaries.
- Produces: `static func applyInlineFormatting(to plain: String, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString` on `QuickLookMarkdownRenderer` (used internally; also exercised directly by tests).

- [ ] **Step 1: Write the failing inline tests**

Add to `LineformTests/QuickLookMarkdownRendererTests.swift`:

```swift
    private func base() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.labelColor]
    }

    private func hasTrait(_ s: NSAttributedString, _ trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        var found = false
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if let f = value as? NSFont, f.fontDescriptor.symbolicTraits.contains(trait) {
                found = true; stop.pointee = true
            }
        }
        return found
    }

    func testBoldMarkersRemovedAndTraitApplied() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "a **b** c", baseAttributes: base())
        XCTAssertEqual(s.string, "a b c")
        XCTAssertTrue(hasTrait(s, .bold))
    }

    func testItalicMarkersRemovedAndTraitApplied() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "a *b* c", baseAttributes: base())
        XCTAssertEqual(s.string, "a b c")
        XCTAssertTrue(hasTrait(s, .italic))
    }

    func testInlineCodeIsMonospacedAndLiteral() {
        // A marker inside code stays literal (code wins precedence).
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "x `**y**` z", baseAttributes: base())
        XCTAssertEqual(s.string, "x **y** z")
        XCTAssertTrue(hasTrait(s, .monoSpace))
        XCTAssertFalse(hasTrait(s, .bold))
    }

    func testLinkTextShownWithLinkAttribute() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "see [docs](https://example.com) now", baseAttributes: base())
        XCTAssertEqual(s.string, "see docs now")
        var url: Any?
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if value != nil { url = value; stop.pointee = true }
        }
        XCTAssertEqual((url as? URL)?.absoluteString, "https://example.com")
    }

    func testStrikethroughApplied() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "a ~~b~~ c", baseAttributes: base())
        XCTAssertEqual(s.string, "a b c")
        var struck = false
        s.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if let n = value as? Int, n != 0 { struck = true; stop.pointee = true }
        }
        XCTAssertTrue(struck)
    }

    func testUnderscoreInWordIsNotItalic() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: "snake_case_name", baseAttributes: base())
        XCTAssertEqual(s.string, "snake_case_name")
        XCTAssertFalse(hasTrait(s, .italic))
    }

    func testEscapedMarkerRendersLiterally() {
        let s = QuickLookMarkdownRenderer.applyInlineFormatting(to: #"a \*b\* c"#, baseAttributes: base())
        XCTAssertEqual(s.string, "a *b* c")
        XCTAssertFalse(hasTrait(s, .italic))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/QuickLookMarkdownRendererTests
```
Expected: FAIL / does-not-compile with "type 'QuickLookMarkdownRenderer' has no member 'applyInlineFormatting'".

- [ ] **Step 3: Implement the inline pass**

In `LineformQuickLook/QuickLookMarkdownRenderer.swift`, add these members to the `QuickLookMarkdownRenderer` enum (place them after `render(_:)`):

```swift
    // MARK: - Inline formatting

    private enum InlineStyle { case code, link, bold, italic, strikethrough }

    private struct InlineMatch {
        let range: NSRange           // full token incl. markers, in the source string
        let style: InlineStyle
        let inner: String            // display text (link text / emphasized text / code body)
        let url: String?             // link destination, else nil
    }

    // Ordered by precedence: earlier patterns win a tie at the same start location, so a
    // `**` is claimed as bold, not italic, and a delimiter inside code stays literal.
    // `(?<!\\)` on each opener lets a backslash-escaped marker fall through to plain text.
    private static let inlinePatterns: [(InlineStyle, NSRegularExpression)] = {
        func rx(_ p: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: p)
        }
        return [
            (.code,          rx(#"(?<!\\)`([^`]+)`"#)),
            (.link,          rx(#"(?<!\\)\[([^\]]*)\]\(([^)]*)\)"#)),
            (.bold,          rx(#"(?<!\\)\*\*([^*]+)\*\*"#)),
            (.bold,          rx(#"(?<!\\)__([^_]+)__"#)),
            (.italic,        rx(#"(?<!\\)\*([^*]+)\*"#)),
            (.italic,        rx(#"(?<![\w\\])_([^_]+)_(?![\w])"#)),
            (.strikethrough, rx(#"(?<!\\)~~([^~]+)~~"#)),
        ]
    }()

    /// Applies inline Markdown over `plain`, removing markers and layering inline attributes
    /// onto `baseAttributes` (which carry the block's font/color/paragraph style). Line-local:
    /// `plain` is a single already-block-classified line's text. Precedence: code, link, bold,
    /// italic, strikethrough (code/link contents recurse so bold-in-link works; code is literal).
    static func applyInlineFormatting(
        to plain: String,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let ns = plain as NSString
        let result = NSMutableAttributedString()
        var cursor = 0

        while cursor < ns.length {
            guard let match = earliestInlineMatch(in: ns, from: cursor) else { break }
            if match.range.location > cursor {
                let pre = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(NSAttributedString(string: unescapeInline(pre), attributes: baseAttributes))
            }
            result.append(styledToken(match, baseAttributes: baseAttributes))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let rest = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            result.append(NSAttributedString(string: unescapeInline(rest), attributes: baseAttributes))
        }
        return result
    }

    private static func earliestInlineMatch(in ns: NSString, from start: Int) -> InlineMatch? {
        let searchRange = NSRange(location: start, length: ns.length - start)
        var best: (match: NSTextCheckingResult, style: InlineStyle)?
        for (style, regex) in inlinePatterns {
            guard let m = regex.firstMatch(in: ns as String, options: [], range: searchRange) else { continue }
            if best == nil || m.range.location < best!.match.range.location {
                best = (m, style)
            }
            // An earliest-possible match (at `start`) from an earlier pattern can't be beaten.
            if best!.match.range.location == start { break }
        }
        guard let picked = best else { return nil }
        let inner = ns.substring(with: picked.match.range(at: 1))
        let url: String? = picked.style == .link ? ns.substring(with: picked.match.range(at: 2)) : nil
        return InlineMatch(range: picked.match.range, style: picked.style, inner: inner, url: url)
    }

    private static func styledToken(
        _ match: InlineMatch,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        switch match.style {
        case .code:
            var attrs = baseAttributes
            let size = (baseAttributes[.font] as? NSFont)?.pointSize ?? bodyFontSize
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
            return NSAttributedString(string: match.inner, attributes: attrs)   // literal contents
        case .link:
            let inner = applyInlineFormatting(to: match.inner, baseAttributes: baseAttributes)
            let styled = NSMutableAttributedString(attributedString: inner)
            let full = NSRange(location: 0, length: styled.length)
            if let urlString = match.url, let url = URL(string: urlString) {
                styled.addAttribute(.link, value: url, range: full)
            }
            styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: full)
            styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: full)
            return styled
        case .bold:
            return recursed(match.inner, baseAttributes: baseAttributes, adding: .bold)
        case .italic:
            return recursed(match.inner, baseAttributes: baseAttributes, adding: .italic)
        case .strikethrough:
            let inner = applyInlineFormatting(to: match.inner, baseAttributes: baseAttributes)
            let styled = NSMutableAttributedString(attributedString: inner)
            styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                range: NSRange(location: 0, length: styled.length))
            return styled
        }
    }

    private static func recursed(
        _ inner: String,
        baseAttributes: [NSAttributedString.Key: Any],
        adding trait: NSFontDescriptor.SymbolicTraits
    ) -> NSAttributedString {
        var childBase = baseAttributes
        childBase[.font] = fontAdding(trait, to: baseAttributes[.font] as? NSFont)
        return applyInlineFormatting(to: inner, baseAttributes: childBase)
    }

    private static func fontAdding(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont?) -> NSFont {
        let base = font ?? NSFont.systemFont(ofSize: bodyFontSize)
        let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(trait)
        )
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// Removes a single backslash that escapes a marker this renderer consumes.
    private static func unescapeInline(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: #"\\([*_`~\[\]()])"#)
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "$1"
        )
    }
```

- [ ] **Step 4: Apply the inline pass at every prose call site**

In the same file's `render(_:)`, route text through `applyInlineFormatting` instead of building plain `NSAttributedString(string:attributes:)`. Make these edits:

**(a) `flushParagraph()`** — replace its body's append:
```swift
        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                let content = paragraphBuffer.joined(separator: " ")
                let attrs = bodyAttributes()
                output.append(applyInlineFormatting(to: content, baseAttributes: attrs))
                output.append(NSAttributedString(string: "\n", attributes: attrs))
                paragraphBuffer = []
            }
        }
```

**(b) `appendParagraph(text:attributes:)`** — replace its append:
```swift
        func appendParagraph(text: String, attributes: [NSAttributedString.Key: Any] = [:]) {
            var attrs = bodyAttributes()
            attrs.merge(attributes) { _, new in new }
            output.append(applyInlineFormatting(to: text, baseAttributes: attrs))
            output.append(NSAttributedString(string: "\n", attributes: attrs))
        }
```

**(c) Headings** — replace the heading append (inside the `for level in 1...6` block):
```swift
                    output.append(applyInlineFormatting(to: content, baseAttributes: attrs))
                    output.append(NSAttributedString(string: "\n", attributes: attrs))
```
(replacing the single `output.append(NSAttributedString(string: content + "\n", attributes: attrs))`).

**(d) Blockquote** — replace the blockquote append:
```swift
                output.append(applyInlineFormatting(to: content, baseAttributes: attrs))
                output.append(NSAttributedString(string: "\n", attributes: attrs))
```

**(e) List items** — the marker + tab stay plain; only the content is formatted. First **delete** the now-unused line `let fullText = marker + "\t" + content + "\n"` (keep the `let marker = …` and `let content = match.content` lines above it). Then replace from `let color = themeTextColor` through the final append with:
```swift
                let color = themeTextColor
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont,
                    .foregroundColor: color
                ]
                let style = paragraphStyle(lineHeight: lineHeightMultiple, spacing: paragraphSpacing / 2)
                let baseIndent = CGFloat(level) * listIndentStep
                style.headIndent = baseIndent + listMarkerColumn
                style.firstLineHeadIndent = baseIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: baseIndent + listMarkerColumn, options: [:])]
                attrs[.paragraphStyle] = style
                attrs[.kern] = letterSpacing
                output.append(NSAttributedString(string: marker + "\t", attributes: attrs))
                output.append(applyInlineFormatting(to: content, baseAttributes: attrs))
                output.append(NSAttributedString(string: "\n", attributes: attrs))
```
(replacing the previous `let fullText = marker + "\t" + content + "\n"` and its single append.)

Leave table cells as-is for this pass (the space-padding alignment counts raw characters; stripping markers there would require reworking width math and is low value — noted as a non-goal below).

- [ ] **Step 5: Run the inline tests**

Run:
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/QuickLookMarkdownRendererTests
```
Expected: PASS (all inline cases + the Task 4 block cases).

- [ ] **Step 6: Build the extension to confirm it still compiles**

Run:
```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add LineformQuickLook/QuickLookMarkdownRenderer.swift LineformTests/QuickLookMarkdownRendererTests.swift
git commit -m "Render inline bold/italic/code/links/strikethrough in Quick Look previews"
```

---

### Final verification

- [ ] **Run the full default test gate** (warn the user about the possible TCC prompt first):
```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
```
Expected: all default-plan tests PASS. Report exact pass/fail counts.

- [ ] **Manual UI verification** (state not exercised by tests — say so if skipped):
  - VoiceOver: 2+ tabs open → each tab exposes a "Close tab" action.
  - All Files search: fresh window, first-ever All Files query returns results once the scan lands, without editing the query.
  - Quick Look: preview a `.md` with `**bold**`, `*italic*`, `` `code` ``, `[link](url)`, `~~strike~~` in Finder → markers are gone and styling shows.

## Non-goals (from the spec)

- No per-tab undo stacks (Task 3 is document-only).
- No visual change to the tab bar (Task 2 is accessibility-tree only).
- No inline formatting inside Quick Look **table cells** (monospace space-padding counts raw characters); no images, autolinks, or footnotes.
- The already-resolved tab-contrast finding is not revisited.
