# Info Sidebar Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blocking "Info" Markdown-reference modal with a third, always-available sidebar tab ("Info") so users can consult syntax while writing.

**Architecture:** Add `.info` to the existing `OutlineSidebarTab` enum; render a static, stacked, theme-aware reference view in the sidebar; then delete the old `MarkdownBasicsModal`/`MarkdownBasicsOverlay` and its toolbar button. Reference content lives in a new pure data type so it is testable and reusable independently of the view.

**Tech Stack:** SwiftUI + AppKit (`NSViewRepresentable` segmented control), XCTest, macOS document app.

## Global Constraints

- Two test plans; run the **default** plan as the gate: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`. No hosted tests are needed for this feature (no window motion, no modal).
- **No sidebar width/resize changes** (min 220 / ideal 260 / max 300 stay as-is).
- **No new preference; no persistence** of the selected tab (per-window `@State`, resets to Outline on new windows).
- **No new color palette.** Reuse the sidebar's existing theme-aware colors: `OutlineSidebarView.primaryTextColor(usesDarkChrome:)` (syntax) and `secondaryTextColor(usesDarkChrome:)` (explanation).
- **Keep** shared Muse chrome (`MuseModalChrome`, `museModalCard`, `MuseModalHeader`) — Settings still uses it. Only the Markdown-basics modal is removed.
- Explanations must **wrap, never truncate**; syntax line is **monospaced**.
- Contrast: explanation (secondary) text must meet **WCAG AA (≥ 4.5)** against the sidebar background in both chrome modes (light chrome bg `NSColor(calibratedWhite: 0.988, alpha: 1)`, dark chrome bg `NSColor(calibratedWhite: 0.18, alpha: 1)`). Dark chrome = Quiet/Night themes.

---

### Task 1: Reference content model

**Files:**
- Create: `Lineform/Outline/MarkdownReference.swift`
- Test: `LineformTests/MarkdownReferenceTests.swift`

**Interfaces:**
- Produces:
  - `struct MarkdownReference` with `static let sections: [MarkdownReference.Section]`
  - `struct MarkdownReference.Section: Identifiable, Equatable { var title: String; var rows: [Row]; var id: String { title } }`
  - `struct MarkdownReference.Row: Identifiable, Equatable { var syntax: String; var explanation: String; var rendersSyntaxAsCode: Bool = true; var id: String { syntax } }`
  - `var MarkdownReference.Row.accessibilityLabel: String` → `"\(explanation) Syntax: \(syntax)"`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Lineform

final class MarkdownReferenceTests: XCTestCase {
    func testSectionsCoverEveryGroupAndAreNonEmpty() {
        let titles = MarkdownReference.sections.map(\.title)
        XCTAssertEqual(titles, ["Markdown Basics", "Diagrams", "Math", "Search"])
        for section in MarkdownReference.sections {
            XCTAssertFalse(section.rows.isEmpty, section.title)
        }
    }

    func testBasicsIncludesCoreSyntax() {
        let basics = MarkdownReference.sections.first { $0.title == "Markdown Basics" }
        let syntaxes = basics?.rows.map(\.syntax) ?? []
        for expected in ["# Title", "**bold**", "- [x] done", "| a | b |"] {
            XCTAssertTrue(syntaxes.contains(expected), "missing \(expected)")
        }
    }

    // Guards the narrow-column rewrite: a future edit can't silently re-bloat copy.
    func testExplanationsStayConcise() {
        for section in MarkdownReference.sections {
            for row in section.rows {
                XCTAssertLessThanOrEqual(
                    row.explanation.count, 90,
                    "too wordy for the sidebar: \(row.syntax) — \(row.explanation)"
                )
            }
        }
    }

    func testBlockSpacingIsNotRenderedAsCode() {
        let row = MarkdownReference.sections
            .flatMap(\.rows)
            .first { $0.syntax == "Block Spacing" }
        XCTAssertEqual(row?.rendersSyntaxAsCode, false)
    }

    func testAccessibilityLabelReadsExplanationThenSyntax() {
        let row = MarkdownReference.Row(syntax: "**bold**", explanation: "Bold.")
        XCTAssertEqual(row.accessibilityLabel, "Bold. Syntax: **bold**")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownReferenceTests`
Expected: FAIL — `cannot find 'MarkdownReference' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The Markdown syntax reference shown in the sidebar's Info tab. Pure data so it
/// is testable and independent of the view. Copy is deliberately terse for the
/// narrow sidebar column (see MarkdownReferenceTests.testExplanationsStayConcise).
struct MarkdownReference {
    struct Row: Identifiable, Equatable {
        var syntax: String
        var explanation: String
        /// Most rows render `syntax` in a monospaced "code" style. A few (e.g.
        /// "Block Spacing") are a plain label, not literal syntax.
        var rendersSyntaxAsCode: Bool = true

        var id: String { syntax }

        /// VoiceOver reads a coherent phrase — explanation first, then the raw
        /// syntax — instead of spelling out Markdown punctuation on its own.
        var accessibilityLabel: String { "\(explanation) Syntax: \(syntax)" }
    }

    struct Section: Identifiable, Equatable {
        var title: String
        var rows: [Row]

        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Markdown Basics", rows: [
            Row(syntax: "# Title", explanation: "Top-level heading."),
            Row(syntax: "## Section", explanation: "Smaller heading (more # = smaller)."),
            Row(syntax: "**bold**", explanation: "Bold."),
            Row(syntax: "_italic_", explanation: "Italic."),
            Row(syntax: "- bullet", explanation: "Bulleted list."),
            Row(syntax: "1. item", explanation: "Numbered list."),
            Row(syntax: "- [ ] to do", explanation: "Task, not done."),
            Row(syntax: "- [x] done", explanation: "Task, done. Click to toggle."),
            Row(syntax: "> quote", explanation: "Blockquote."),
            Row(syntax: "~~text~~", explanation: "Strikethrough."),
            Row(syntax: "`code`", explanation: "Inline code."),
            Row(syntax: "---", explanation: "Divider."),
            Row(syntax: "[text](url)", explanation: "Link."),
            Row(syntax: "![alt](url)", explanation: "Image (shown as a placeholder)."),
            Row(syntax: "| a | b |", explanation: "Table: header row, then |---|---|, then rows. Colons set alignment."),
            Row(syntax: "Block Spacing", explanation: "Adds space around blocks in Read and Preview.", rendersSyntaxAsCode: false),
        ]),
        Section(title: "Diagrams", rows: [
            Row(syntax: "```mermaid", explanation: "Fenced mermaid block renders as a diagram in Read/Preview. Write shows source."),
        ]),
        Section(title: "Math", rows: [
            Row(syntax: "$x^2 + y^2$", explanation: "Inline math."),
            Row(syntax: "$$…$$", explanation: "Centered equation block."),
            Row(syntax: "\\frac{a}{b}", explanation: "LaTeX supported: fractions, roots, Greek, sums, integrals."),
            Row(syntax: "it costs $5", explanation: "Plain dollar amounts stay as text."),
        ]),
        Section(title: "Search", rows: [
            Row(syntax: "Return", explanation: "While searching, jumps to the next match; wraps around."),
        ]),
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownReferenceTests`
Expected: PASS (5 tests).

> Note: `MarkdownReference.swift` must be added to the app target and the test file to the test target in the hand-rolled `Lineform.xcodeproj/project.pbxproj` (objectVersion 56, sequential `1F0000xx` IDs across the 4 sections — build file, file ref, group child, sources phase). Do this before running Step 4 or the type won't be found.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/MarkdownReference.swift LineformTests/MarkdownReferenceTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add MarkdownReference content model for the Info sidebar tab"
```

---

### Task 2: Add the `.info` tab case

**Files:**
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (enum near line 4; `OutlineSidebarSegmentedControl.updateNSView` near line 625)
- Test: `LineformTests/OutlineSidebarTabTests.swift` (create) or append to an existing outline test file

**Interfaces:**
- Consumes: nothing new.
- Produces: `OutlineSidebarTab.info` with `rawValue == "Info"`; `OutlineSidebarTab.allCases == [.outline, .files, .info]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Lineform

final class OutlineSidebarTabTests: XCTestCase {
    func testTabsIncludeInfoInOrder() {
        XCTAssertEqual(OutlineSidebarTab.allCases, [.outline, .files, .info])
        XCTAssertEqual(OutlineSidebarTab.info.rawValue, "Info")
        XCTAssertEqual(OutlineSidebarView.tabTitles, ["Outline", "Files", "Info"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineSidebarTabTests`
Expected: FAIL — `type 'OutlineSidebarTab' has no member 'info'`.

- [ ] **Step 3: Write minimal implementation**

Add the case to the enum (after `.files`):

```swift
enum OutlineSidebarTab: String, CaseIterable, Identifiable {
    case outline = "Outline"
    case files = "Files"
    case info = "Info"

    var id: Self { self }
}
```

Add the third segment width in `OutlineSidebarSegmentedControl.updateNSView` (the two existing `setWidth(0, forSegment:)` lines gain a third):

```swift
        nsView.setWidth(0, forSegment: 0)
        nsView.setWidth(0, forSegment: 1)
        nsView.setWidth(0, forSegment: 2)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineSidebarTabTests`
Expected: PASS. (Add the new test file to the test target in the pbxproj first if created standalone.)

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineSidebarTabTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add .info case to OutlineSidebarTab with third equal-width segment"
```

---

### Task 3: Info tab view + wiring + contrast test

**Files:**
- Create: `Lineform/Outline/OutlineInfoTabView.swift`
- Modify: `Lineform/Outline/OutlineSidebarView.swift` (the `if selectedTab == .outline { … } else { … }` branch near line 352)
- Test: `LineformTests/OutlineInfoContrastTests.swift`

**Interfaces:**
- Consumes: `MarkdownReference.sections` (Task 1); `OutlineSidebarView.primaryTextColor(usesDarkChrome:)` / `secondaryTextColor(usesDarkChrome:)` — **these are `fileprivate` today; widen to internal (`static func`) so the view (different file) and the contrast test can call them.**
- Produces: `struct OutlineInfoTabView: View` taking `var usesDarkChrome: Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import Lineform

final class OutlineInfoContrastTests: XCTestCase {
    // Sidebar background is chrome-mode-based, not per-theme (dark chrome = Quiet/Night).
    private func background(darkChrome: Bool) -> NSColor {
        NSColor(calibratedWhite: darkChrome ? OutlineSidebarView.darkBackgroundWhiteComponent
                                             : OutlineSidebarView.lightBackgroundWhiteComponent,
                alpha: 1)
    }

    func testSecondaryExplanationTextMeetsAAInBothChromes() {
        for darkChrome in [false, true] {
            let text = OutlineSidebarView.secondaryTextColor(usesDarkChrome: darkChrome)
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(text, background(darkChrome: darkChrome)), 4.5,
                "secondary explanation text, darkChrome=\(darkChrome)"
            )
        }
    }

    func testPrimarySyntaxTextMeetsAAInBothChromes() {
        for darkChrome in [false, true] {
            let text = OutlineSidebarView.primaryTextColor(usesDarkChrome: darkChrome)
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(text, background(darkChrome: darkChrome)), 4.5,
                "primary syntax text, darkChrome=\(darkChrome)"
            )
        }
    }

    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB) ?? c
            func chan(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * chan(s.redComponent) + 0.7152 * chan(s.greenComponent) + 0.0722 * chan(s.blueComponent)
        }
        let l1 = lum(a), l2 = lum(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineInfoContrastTests`
Expected: FAIL to compile — `primaryTextColor`/`secondaryTextColor` are `fileprivate` (inaccessible).

- [ ] **Step 3a: Widen the color helpers to internal**

In `OutlineSidebarView.swift`, change both signatures from `fileprivate static func` to `static func`:

```swift
    static func primaryTextColor(usesDarkChrome: Bool) -> Color { … }   // was fileprivate
    static func secondaryTextColor(usesDarkChrome: Bool) -> Color { … } // was fileprivate
```

- [ ] **Step 3b: Create the Info tab view**

```swift
import SwiftUI

/// The sidebar Info tab: the Markdown syntax reference, stacked for the narrow
/// column (monospaced syntax over a plain-English explanation), section-ruled,
/// and theme-aware. Static content — no scan, no laziness concern.
struct OutlineInfoTabView: View {
    var usesDarkChrome: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(MarkdownReference.sections) { section in
                    section(section)
                }
            }
            .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Markdown reference")
    }

    private func section(_ section: MarkdownReference.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    self.row(row)
                    if index < section.rows.count - 1 {
                        Divider()
                            .overlay(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.08))
                    }
                }
            }
        }
    }

    private func row(_ row: MarkdownReference.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.syntax)
                .font(row.rendersSyntaxAsCode ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                .textSelection(.enabled)
            Text(row.explanation)
                .font(.footnote)
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .fixedSize(horizontal: false, vertical: true) // wrap, never truncate
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
```

- [ ] **Step 3c: Wire the tab-content switch**

Replace the `if selectedTab == .outline { … } else { … }` block in `OutlineSidebarView.body` with a three-way switch (Files branch keeps its exact existing modifiers/closures — only the surrounding structure changes):

```swift
                switch selectedTab {
                case .outline:
                    outlineContent
                case .files:
                    OutlineFileBrowserView( … existing arguments and .onAppear/.onDisappear/.onReceive chain unchanged … )
                case .info:
                    OutlineInfoTabView(usesDarkChrome: usesDarkChrome)
                }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/OutlineInfoContrastTests`
Expected: PASS (2 tests). Add `OutlineInfoTabView.swift` to the app target and the test file to the test target in the pbxproj first.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Outline/OutlineInfoTabView.swift Lineform/Outline/OutlineSidebarView.swift LineformTests/OutlineInfoContrastTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Render the Info sidebar tab (stacked, theme-aware, AA-contrast reference)"
```

---

### Task 4: Remove the old Info modal and toolbar button

**Files:**
- Modify: `Lineform/Editor/EditorChromeAndControls.swift` (delete `MarkdownBasicsModal`, `MarkdownBasicsOverlay`, and `EditorAuxiliaryPresentation.markdownBasics` near lines 30, 167, 332)
- Modify: `Lineform/Editor/EditorPresentation.swift` (`showsMarkdownBasics(in:)`, the `.markdownBasics` cases/lists)
- Modify: `Lineform/Editor/EditorContainerView.swift` (`isShowingMarkdownBasics` state ~line 10; presentation block ~lines 395-416; toggle case ~line 1188; any `isShowingMarkdownBasics` reset near lines 200-222)
- Modify: `Lineform/App/SettingsView.swift` (only if it references the deleted modal; keep shared Muse chrome references)
- Test: delete/trim any test that only exercised the modal (search below)

**Interfaces:**
- Consumes: nothing.
- Produces: no `markdownBasics` toolbar item, no `MarkdownBasics*` types; shared `MuseModalChrome`/`museModalCard`/`MuseModalHeader` remain.

- [ ] **Step 1: Inventory references (write down what must go)**

Run: `grep -rn "MarkdownBasics\|markdownBasics\|isShowingMarkdownBasics\|showsMarkdownBasics" Lineform LineformTests`
Expected: a fixed list across the files above (plus any tests). Every hit must be removed or, for shared-chrome hits, confirmed to reference `MuseModalChrome` only (keep those).

- [ ] **Step 2: Delete the modal types and toolbar item**

In `EditorChromeAndControls.swift`: delete `struct MarkdownBasicsModal`, `struct MarkdownBasicsOverlay`, `MarkdownGuideHeightKey` (if only used by the modal), and the `static let markdownBasics = EditorAuxiliaryPresentation(...)`. Leave `MuseModalChrome`, the `museModalCard` modifier, and `MuseModalHeader` intact (Settings uses them).

In `EditorPresentation.swift`: remove `showsMarkdownBasics(in:)`, the `.markdownBasics` enum case, and its entries in any toolbar-item arrays (e.g. `return [.markdownBasics, .readingExperience]` → `return [.readingExperience]`).

In `EditorContainerView.swift`: remove `@State private var isShowingMarkdownBasics`, the `if isShowingMarkdownBasics { museModalLayer(...) MarkdownBasicsModal(...) }` block and its `.animation(..., value: isShowingMarkdownBasics)`, the `.markdownBasics` toggle case, and any `isShowingMarkdownBasics = false` resets.

In `SettingsView.swift`: if a `MarkdownBasics`/`markdownBasics` reference exists that isn't a shared-chrome constant, remove it.

- [ ] **Step 3: Remove dead modal tests**

Delete or trim tests found in Step 1 that assert on `MarkdownBasicsModal` / `isShowingMarkdownBasics` / the `.markdownBasics` toolbar item. (Keep tests about `MuseModalChrome`/Settings.)

- [ ] **Step 4: Build + full default suite**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: BUILD SUCCEEDS; all default-plan tests PASS (including the three new test files). Then re-run the Step 1 grep — expected: only shared-chrome (`MuseModalChrome`) hits remain, zero `MarkdownBasics`/`isShowingMarkdownBasics`/`markdownBasics` toolbar/modal hits.

> TCC note: a CLI test run may prompt "'Lineform' would like to access files in your Documents folder." Click Allow; don't run unattended.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Remove the Info Markdown-basics modal and its toolbar button (moved to sidebar tab)"
```

---

## Self-Review

**Spec coverage:**
- Third "Info" tab → Task 2. ✓
- Move reference content into the tab → Tasks 1 + 3. ✓
- Stacked (syntax over explanation), monospaced syntax → Task 3 (`row` view). ✓
- Two-tone theme-aware colors, section rules → Task 3 + widened color helpers. ✓
- Rewritten concise copy → Task 1 (with `testExplanationsStayConcise` guard). ✓
- Accessibility (combined VO label, tab label, wrapping) → Task 1 (`accessibilityLabel`) + Task 3 (`.accessibilityLabel`, `.fixedSize` wrap, `accessibilityLabel("Markdown reference")`). ✓
- Contrast test vs both chrome backgrounds → Task 3. ✓
- Remove toolbar button + modal, keep shared Muse chrome → Task 4. ✓
- No width/preference/persistence changes → honored (not touched). ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `MarkdownReference.sections` / `.Section` / `.Row(syntax:explanation:rendersSyntaxAsCode:)` / `.accessibilityLabel` used identically in Tasks 1 and 3; `OutlineSidebarTab.info` and `primaryTextColor(usesDarkChrome:)`/`secondaryTextColor(usesDarkChrome:)` consistent across Tasks 2–3. ✓

**pbxproj:** Tasks 1–3 each add files to the hand-rolled project (objectVersion 56, sequential `1F0000xx` IDs, 4 sections per file) before their run step. ✓
