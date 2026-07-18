# Read-Aloud / Text-to-Speech Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native, offline read-aloud feature that speaks the *markdown-stripped* text of the current document (not the raw markup), started from the selection / caret / whole document, with an **Edit ▸ Speech** submenu (Start Speaking / Pause-Resume / Stop).

**Architecture:** Two owned, testable seams plus thin wiring:
1. `SpeechTextExtractor` — a **pure** enum that turns document markdown into a clean spoken string by reusing `markdownBlocks(in:)` and a focused inline-marker-stripping pass. Fully unit-tested, no AV dependency.
2. `SpeechController` — an `ObservableObject` state machine (`.idle`/`.speaking`/`.paused`) driving `AVSpeechSynthesizer` **behind a `SpeechSynthesizing` protocol** so the state machine is unit-tested with a fake and **no real audio**.
3. Menu wiring in `AppCommands.swift` posting window-scoped notifications (the `printDocument`/`exportPDF` pattern), plus a shared `LineformSpeechMenuState` so the menu label/enablement track the key window.
4. Selection/caret resolution in `EditorContainerView`, which owns the window's `SpeechController`.

**Tech Stack:** Swift, AVFoundation (AVSpeechSynthesizer), SwiftUI, AppKit, XCTest

## Global Constraints
- Native `AVSpeechSynthesizer` — offline, free, **NO network, NO new entitlement** (consistent with local-first).
- Speaks **STRIPPED** text (inline `#`, `*`, `_`, backticks, `~~`, link/image syntax removed); **skips fenced code, `$`/`$$` math, and ```mermaid blocks** entirely.
- Content read: headings (as plain title), paragraphs, list items, blockquotes, callouts (`> [!NOTE]` marker dropped), and table cells (cell-by-cell); `![alt](url)` → its alt text (or filename fallback).
- Start point: **selection** → else **caret-to-end** (Write/Split) → else **whole document** (Read, no live caret). Speech stops at the end.
- **Edit ▸ Speech** submenu: Start Speaking / Pause · Resume / Stop. **No default keyboard shortcut** in v1 (avoids collisions; macOS assigns none).
- **System default voice + rate** in v1 (no pickers).
- The extractor and the controller state machine **MUST** be unit-tested with no real audio. Menu wiring and selection/caret resolution are **manual-verified** (they bridge live AppKit/AV state that unit tests can't exercise meaningfully).
- New files under `Lineform/ReadingExperience/`; new tests under `LineformTests/`. Add each new `.swift` file to the Xcode project by editing the 4 pbxproj sections with sequential `1F0000xx` IDs (objectVersion 56, no synced groups — see the `pbxproj-handrolled-ids` memory note). Both product files must be in the **Lineform** app target and both test files in the **LineformTests** target.
- Out of scope (v1, do not build): spoken-word karaoke highlight, voice/rate/pitch pickers, reading code/math/diagrams aloud, persisted playback position.
- **CROSS-PLAN ORDERING (read this):** this plan's `SpeechTextExtractor` switches over `MarkdownBlock`, whose cases GROW as sibling features land. Implement E **after** C (`code-block-highlighting-copy`), B (`callouts-admonitions`), and A (`inline-local-image-rendering`) in this batch. When those are merged, the enum also has **`.fencedCode` (skip — do not speak), `.callout` (speak the body + optional title, drop the `[!TYPE]` marker), and `.image` (speak the alt text)**. Swift's exhaustive `switch` will force you to handle them — do so per this note. If, and only if, E is implemented *before* C, code still lives inside `.lines` and must be skipped by tracking ` ``` `/`~~~` fence state within the `.lines` run (via `MermaidFence.isFenceDelimiter`). See `2026-07-18-competitor-features-execution-order.md`.

---

## Task 1 — `SpeechTextExtractor.spokenText(from:)` (pure, fully tested)

**Files:**
- `Lineform/ReadingExperience/SpeechTextExtractor.swift` (new, product)
- `LineformTests/SpeechTextExtractorTests.swift` (new, test)

**Interfaces (exact signatures):**
```swift
enum SpeechTextExtractor {
    /// Convert document markdown into a clean spoken string: inline markers stripped,
    /// fenced code / math / mermaid / thematic-rule blocks skipped, image → alt text,
    /// blocks and lines emitted as separate units joined by "\n" so the synthesizer
    /// pauses naturally between them.
    static func spokenText(from markdown: String) -> String

    /// Strip inline markdown markers from a single line, keeping the words:
    /// `**b**`→`b`, `_i_`→`i`, `` `c` ``→`c`, `~~s~~`→`s`, `[t](u)`→`t`, `![a](u)`→`a`.
    /// Earliest-token-wins scan (mirrors `MarkdownPreviewRenderer.nextInlineToken`), and
    /// recursively strips a token's inner text so `**[a](b)**`→`a`.
    static func stripInlineMarkers(_ line: String) -> String
}
```

**Reused seams (exact names — do not re-derive):**
- `markdownBlocks(in lines: [String]) -> [MarkdownBlock]` (`Lineform/Preview/MarkdownBlockGrouping.swift`). Cases: `.lines(Range<Int>)`, `.singleLineMath`, `.fencedMath`, `.mermaid`, `.horizontalRule`, `.blockquote(lines: [MarkdownQuoteLine], lastLineIndex:)`, `.list(items: [MarkdownListItem], lastLineIndex:)`, `.table(MarkdownTable, lastLineIndex:)`.
- `MarkdownHeadingParser.heading(in line: String) -> (level: Int, title: String)?` (`Lineform/Outline/MarkdownHeadingParser.swift`).
- `MermaidFence.isFenceDelimiter(_ trimmedLine: String) -> Bool` (`Lineform/Preview/MermaidRendering.swift`) — used to skip regular ``` code fences that live *inside* a `.lines` run.
- `MarkdownTable` has `headers: [String]` and `rows: [[String]]`.
- `MarkdownQuoteLine` has `text: String`; `MarkdownListItem` has `text: String` (already checkbox-marker-stripped).

**Design notes (load-bearing):**
- A `.lines` block contains body, headings, **and fenced code**. Walk it line-by-line tracking a local `inFence` toggled by `MermaidFence.isFenceDelimiter`; skip the delimiter line and all lines while `inFence`. Headings → speak `heading.title` stripped; other lines → speak the line stripped.
- `.singleLineMath`, `.fencedMath`, `.mermaid`, `.horizontalRule` → emit nothing.
- Callouts: a blockquote whose line text begins with a `[!TYPE]` token has that token dropped before stripping (so `> [!NOTE] Heads up` reads "Heads up"; a bare `> [!NOTE]` line emits nothing).
- The inline regex patterns are **copied from `MarkdownPreviewRenderer`** (the source of truth). If those patterns change there, mirror them here — note the coupling in a comment.

### Steps
- [ ] Write `LineformTests/SpeechTextExtractorTests.swift` with a failing suite (real XCTest, complete Swift):
```swift
import XCTest
@testable import Lineform

final class SpeechTextExtractorTests: XCTestCase {
    func testStripsInlineEmphasisAndCodeMarkers() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("**bold** and _italic_ and `code`"),
                       "bold and italic and code")
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("a ~~struck~~ word"), "a struck word")
    }

    func testStripsLinkToDisplayTextAndImageToAlt() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("see [the docs](https://x.com)"),
                       "see the docs")
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("![a diagram](img.png) here"),
                       "a diagram here")
    }

    func testStripsNestedInlineMarkers() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("**[a](b)**"), "a")
    }

    func testImageWithEmptyAltFallsBackToFilename() {
        XCTAssertEqual(SpeechTextExtractor.stripInlineMarkers("![](photos/cat.png)"), "cat.png")
    }

    func testHeadingReadsTitleWithoutHashes() {
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "# Hello World"), "Hello World")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "### A **bold** section"), "A bold section")
    }

    func testParagraphsBecomeSeparateSpokenUnits() {
        let md = "First line.\nSecond line."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "First line.\nSecond line.")
    }

    func testFencedCodeIsSkipped() {
        let md = "Before.\n```swift\nlet x = 1\nprint(x)\n```\nAfter."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Before.\nAfter.")
    }

    func testBlockMathIsSkipped() {
        let md = "Intro.\n$$\n\\int x\\,dx\n$$\nOutro."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Intro.\nOutro.")
    }

    func testSingleLineMathIsSkipped() {
        let md = "Intro.\n$$E = mc^2$$\nOutro."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Intro.\nOutro.")
    }

    func testMermaidIsSkipped() {
        let md = "Intro.\n```mermaid\nflowchart TD\nA-->B\n```\nOutro."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Intro.\nOutro.")
    }

    func testHorizontalRuleIsSkipped() {
        let md = "Above.\n\n---\n\nBelow."
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Above.\nBelow.")
    }

    func testListItemsAreReadAsPlainText() {
        let md = "- first item\n- **second** item\n1. numbered one"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md),
                       "first item\nsecond item\nnumbered one")
    }

    func testCheckboxItemsReadTextWithoutMarker() {
        let md = "- [ ] todo one\n- [x] done two"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "todo one\ndone two")
    }

    func testBlockquoteIsRead() {
        let md = "> quoted wisdom\n> more of it"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "quoted wisdom\nmore of it")
    }

    func testCalloutMarkerIsDropped() {
        let md = "> [!NOTE] Remember this\n> and this"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md), "Remember this\nand this")
    }

    func testTableIsReadCellByCell() {
        let md = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n| Alan | 41 |"
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: md),
                       "Name, Age\nAda, 36\nAlan, 41")
    }

    func testEmptyDocumentProducesEmptyString() {
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: ""), "")
        XCTAssertEqual(SpeechTextExtractor.spokenText(from: "   \n\n  "), "")
    }
}
```
- [ ] Run the suite and confirm it FAILS to build (type `SpeechTextExtractor` does not exist):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/SpeechTextExtractorTests`
- [ ] Create `Lineform/ReadingExperience/SpeechTextExtractor.swift` with the complete implementation:
```swift
import Foundation

/// Pure conversion from document markdown into a clean spoken string for `SpeechController`.
/// Reuses `markdownBlocks(in:)` and a focused inline-marker-stripping pass so bold/italic/
/// code/link/image punctuation is removed but the words remain, and code / math / mermaid /
/// thematic-rule blocks are skipped entirely (not readable long-form prose). No AV dependency.
enum SpeechTextExtractor {
    // Patterns are COPIED from `MarkdownPreviewRenderer` (the source of truth). If those change,
    // mirror them here so spoken text matches the rendered text.
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
    private static let calloutRegex = try! NSRegularExpression(pattern: #"^\[![^\]\n]+\][ \t]*"#)

    static func spokenText(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        let blocks = markdownBlocks(in: lines)
        var units: [String] = []

        for block in blocks {
            switch block {
            case .lines(let range):
                appendLineRun(lines, range, into: &units)
            case .blockquote(let quoteLines, _):
                for quote in quoteLines {
                    append(stripCallout(quote.text), into: &units)
                }
            case .list(let items, _):
                for item in items {
                    append(item.text, into: &units)
                }
            case .table(let table, _):
                appendRow(table.headers, into: &units)
                for row in table.rows { appendRow(row, into: &units) }
            case .singleLineMath, .fencedMath, .mermaid, .horizontalRule:
                break // skipped: not readable long-form prose
            }
        }

        return units.joined(separator: "\n")
    }

    static func stripInlineMarkers(_ line: String) -> String {
        let nsLine = line as NSString
        guard nsLine.length > 0 else { return "" }
        var result = ""
        var location = 0
        while location < nsLine.length {
            guard let token = nextToken(in: line, nsLine: nsLine, from: location) else {
                result += nsLine.substring(from: location)
                break
            }
            if token.range.location > location {
                result += nsLine.substring(with: NSRange(location: location, length: token.range.location - location))
            }
            result += token.replacement
            location = token.range.location + token.range.length
        }
        return result
    }

    // MARK: - Block helpers

    private static func appendLineRun(_ lines: [String], _ range: Range<Int>, into units: inout [String]) {
        var inFence = false
        for index in range {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if MermaidFence.isFenceDelimiter(trimmed) {
                inFence.toggle()
                continue // the ``` / ~~~ delimiter itself is never spoken
            }
            if inFence { continue } // fenced code contents are skipped
            if let heading = MarkdownHeadingParser.heading(in: line) {
                append(heading.title, into: &units)
            } else {
                append(line, into: &units)
            }
        }
    }

    private static func appendRow(_ cells: [String], into units: inout [String]) {
        let spoken = cells
            .map { stripInlineMarkers($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        appendRaw(spoken, into: &units)
    }

    /// Strip inline markers from `text`, then append if non-empty after trimming.
    private static func append(_ text: String, into units: inout [String]) {
        appendRaw(stripInlineMarkers(text), into: &units)
    }

    private static func appendRaw(_ text: String, into units: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { units.append(trimmed) }
    }

    /// Drop a leading GitHub callout token (`[!NOTE]`, `[!WARNING]`, …) from a blockquote line.
    private static func stripCallout(_ text: String) -> String {
        let ns = text as NSString
        guard let match = calloutRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return text
        }
        return ns.substring(from: match.range.length)
    }

    // MARK: - Inline token scan

    private struct Token {
        var range: NSRange
        var replacement: String
    }

    private static func nextToken(in line: String, nsLine: NSString, from location: Int) -> Token? {
        var earliest: Token?

        func consider(_ candidate: Token?) {
            guard let candidate else { return }
            if let current = earliest, current.range.location <= candidate.range.location { return }
            earliest = candidate
        }

        func captured(_ regex: NSRegularExpression) -> Token? {
            let searchRange = NSRange(location: location, length: nsLine.length - location)
            guard let match = regex.firstMatch(in: line, range: searchRange) else { return nil }
            let inner = nsLine.substring(with: match.range(at: 1))
            return Token(range: match.range, replacement: stripInlineMarkers(inner))
        }

        consider(captured(boldRegex))
        consider(captured(italicRegex))
        consider(captured(codeRegex))
        consider(captured(strikethroughRegex))
        consider(imageToken(in: line, nsLine: nsLine, from: location))
        consider(captured(linkRegex))
        return earliest
    }

    /// `![alt](url)` → the alt text, or the URL's filename when there is no alt (so a lone image
    /// still reads as something). Never resolves or touches the file — pure string work.
    private static func imageToken(in line: String, nsLine: NSString, from location: Int) -> Token? {
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = imageRegex.firstMatch(in: line, range: searchRange) else { return nil }
        let alt = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let replacement: String
        if !alt.isEmpty {
            replacement = stripInlineMarkers(alt)
        } else {
            let filename = imageFilename(from: nsLine.substring(with: match.range(at: 2)))
            replacement = filename.isEmpty ? "Image" : filename
        }
        return Token(range: match.range, replacement: replacement)
    }

    private static func imageFilename(from url: String) -> String {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let withoutFragment = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
        let last = withoutFragment.split(separator: "/").last.map(String.init) ?? withoutFragment
        return last.trimmingCharacters(in: .whitespaces)
    }
}
```
- [ ] Add the new file to the Xcode project (`Lineform` target) via the 4 pbxproj sections with fresh `1F0000xx` IDs; add the test file to the `LineformTests` target the same way.
- [ ] Run the suite and confirm all tests PASS:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/SpeechTextExtractorTests`
  Expected: `** TEST SUCCEEDED **`, `SpeechTextExtractorTests` all green.
- [ ] Commit: `Read-aloud: pure SpeechTextExtractor (markdown → spoken string) + tests`

---

## Task 2 — `SpeechController` state machine + `SpeechSynthesizing` protocol (tested with a fake, no audio)

**Files:**
- `Lineform/ReadingExperience/SpeechController.swift` (new, product)
- `LineformTests/SpeechControllerTests.swift` (new, test)

**Interfaces (exact signatures):**
```swift
enum SpeechState: Equatable { case idle, speaking, paused }

/// Small seam over `AVSpeechSynthesizer` so the controller is testable without audio.
protocol SpeechSynthesizing: AnyObject {
    var onFinish: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    func speak(_ text: String)
    func pause()
    func continueSpeaking()
    func stop()
}

@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var state: SpeechState
    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer())
    func startSpeaking(_ text: String)   // empty/whitespace text is a no-op (stays idle)
    func pauseOrResume()                 // .speaking↔.paused; no-op when .idle
    func stop()                          // → .idle
}

/// Production adapter (uses AVFoundation; not unit-tested — audio path).
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate
```

**Design notes:**
- `startSpeaking`: if `text` is empty after trimming → no-op. If already `.speaking`/`.paused`, `stop()` first, then speak. Set `state = .speaking`, call `synthesizer.speak(text)`.
- `pauseOrResume`: `.speaking` → `synthesizer.pause()`, `state = .paused`; `.paused` → `synthesizer.continueSpeaking()`, `state = .speaking`; `.idle` → no-op.
- `stop`: `synthesizer.stop()`, `state = .idle`.
- Finish handling: controller sets `synthesizer.onFinish` in `init` to a `[weak self]` closure that sets `state = .idle` **only if not already idle** (a user `stop()` on the real synth also fires cancel, which the adapter must NOT forward as finish — see adapter).

### Steps
- [ ] Write `LineformTests/SpeechControllerTests.swift` with a failing suite (real XCTest, complete Swift, uses a fake — no audio):
```swift
import XCTest
@testable import Lineform

@MainActor
final class SpeechControllerTests: XCTestCase {
    final class FakeSynthesizer: SpeechSynthesizing {
        var onFinish: (() -> Void)?
        private(set) var isSpeaking = false
        private(set) var isPaused = false
        private(set) var spokenTexts: [String] = []
        private(set) var stopCount = 0

        func speak(_ text: String) { spokenTexts.append(text); isSpeaking = true; isPaused = false }
        func pause() { isPaused = true }
        func continueSpeaking() { isPaused = false }
        func stop() { stopCount += 1; isSpeaking = false; isPaused = false }

        /// Simulate the synthesizer reaching the end of the utterance.
        func finish() { isSpeaking = false; onFinish?() }
    }

    func testStartsIdle() {
        let controller = SpeechController(synthesizer: FakeSynthesizer())
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartSpeakingMovesToSpeakingAndForwardsText() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("hello there")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(fake.spokenTexts, ["hello there"])
    }

    func testStartSpeakingEmptyTextIsNoOp() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("   \n ")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(fake.spokenTexts.isEmpty)
    }

    func testPauseResumeCycle() {
        let controller = SpeechController(synthesizer: FakeSynthesizer())
        controller.startSpeaking("text")
        controller.pauseOrResume()
        XCTAssertEqual(controller.state, .paused)
        controller.pauseOrResume()
        XCTAssertEqual(controller.state, .speaking)
    }

    func testPauseOrResumeWhileIdleIsNoOp() {
        let controller = SpeechController(synthesizer: FakeSynthesizer())
        controller.pauseOrResume()
        XCTAssertEqual(controller.state, .idle)
    }

    func testStopResetsToIdle() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("text")
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testStartingWhileSpeakingStopsThePrevious() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("first")
        controller.startSpeaking("second")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.spokenTexts, ["first", "second"])
    }

    func testFinishCallbackReturnsToIdle() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("text")
        fake.finish()
        XCTAssertEqual(controller.state, .idle)
    }

    func testFinishWhileAlreadyIdleStaysIdle() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        fake.finish()
        XCTAssertEqual(controller.state, .idle)
    }
}
```
- [ ] Run and confirm FAIL to build (`SpeechController`/`SpeechSynthesizing` do not exist):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/SpeechControllerTests`
- [ ] Create `Lineform/ReadingExperience/SpeechController.swift` with the complete implementation:
```swift
import AVFoundation
import Foundation

enum SpeechState: Equatable { case idle, speaking, paused }

/// A small seam over `AVSpeechSynthesizer` so `SpeechController`'s state machine is unit-testable
/// with a fake and no real audio.
protocol SpeechSynthesizing: AnyObject {
    /// Invoked (on the main thread) when the current utterance finishes on its own. NOT invoked
    /// for a user-initiated `stop()`.
    var onFinish: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    func speak(_ text: String)
    func pause()
    func continueSpeaking()
    func stop()
}

/// Owns one synthesizer and a three-state transport machine (idle / speaking / paused). The menu
/// enable/disable and the Pause·Resume label read `state`. `stop()` is called on document close /
/// app quit by the owner (`EditorContainerView`).
@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var state: SpeechState = .idle
    private let synthesizer: SpeechSynthesizing

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        self.synthesizer.onFinish = { [weak self] in
            guard let self, self.state != .idle else { return }
            self.state = .idle
        }
    }

    func startSpeaking(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if state != .idle { synthesizer.stop() }
        state = .speaking
        synthesizer.speak(text)
    }

    func pauseOrResume() {
        switch state {
        case .speaking:
            synthesizer.pause()
            state = .paused
        case .paused:
            synthesizer.continueSpeaking()
            state = .speaking
        case .idle:
            break
        }
    }

    func stop() {
        guard state != .idle else { return }
        synthesizer.stop()
        state = .idle
    }
}

/// Production adapter over `AVSpeechSynthesizer` (system default voice + rate in v1). Offline,
/// no network, no entitlement. Not unit-tested — it is the real audio path; the state machine it
/// drives is tested via `SpeechSynthesizing`.
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    func speak(_ text: String) {
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func continueSpeaking() { synthesizer.continueSpeaking() }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    // A user `stop()` fires didCancel, NOT didFinish. The controller has already set `.idle`, so
    // we deliberately do nothing here (do not forward as a finish).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
```
- [ ] Add the product file to the `Lineform` target and the test file to `LineformTests` via the pbxproj sections (fresh `1F0000xx` IDs).
- [ ] Run and confirm all PASS:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/SpeechControllerTests`
  Expected: `** TEST SUCCEEDED **`, `SpeechControllerTests` all green.
- [ ] Commit: `Read-aloud: SpeechController state machine + SpeechSynthesizing seam + tests`

---

## Task 3 — Edit ▸ Speech menu wiring (manual-verified)

**Files:**
- `Lineform/App/LineformAppNotification.swift` (edit — add 3 cases)
- `Lineform/App/AppCommands.swift` (edit — add `LineformSpeechMenuState` + the Speech submenu)

**Interfaces (exact signatures):**
```swift
// LineformAppNotification: add cases
case startSpeaking
case pauseResumeSpeech
case stopSpeech
// …with matching Notification.Name("Lineform.startSpeaking") / ".pauseResumeSpeech" / ".stopSpeech"

// AppCommands.swift: shared menu state (mirrors LineformCurrentFileMenuState)
@MainActor
final class LineformSpeechMenuState: ObservableObject {
    static let shared: LineformSpeechMenuState
    @Published private(set) var state: SpeechState
    func setState(_ state: SpeechState)   // no-op if unchanged; else NSApp.mainMenu?.update()
}
```

**Design notes:**
- The Speech submenu lives in the **Edit** menu. Reuse the existing `CommandGroup(after: .pasteboard)` block that already holds Find / Find & Replace, appending a `Divider()` then a `Menu("Speech") { … }`.
- **Start Speaking** posts `startSpeaking` with `LineformAppNotification.activeWindowPayload()` (which already captures the key window's `NSTextView.selectedRange()`). Always enabled — like Print, a post with no key window is a safe no-op.
- **Pause · Resume**: title is `speechMenuState.state == .paused ? "Resume" : "Pause"`; `.disabled(speechMenuState.state == .idle)`; posts `pauseResumeSpeech` with `activeWindowPayload()`.
- **Stop**: `.disabled(speechMenuState.state == .idle)`; posts `stopSpeech` with `activeWindowPayload()`.
- Register `_speechMenuState = ObservedObject(...)` in `AppCommands.init` (default `.shared`) alongside the other menu states.

### Steps
- [ ] Add `case startSpeaking`, `case pauseResumeSpeech`, `case stopSpeech` to `LineformAppNotification` and their `Notification.Name` entries in the `name` switch (`"Lineform.startSpeaking"`, `"Lineform.pauseResumeSpeech"`, `"Lineform.stopSpeech"`).
- [ ] Add `LineformSpeechMenuState` to `AppCommands.swift` mirroring `LineformCurrentFileMenuState` (shared singleton, `@Published private(set) var state: SpeechState = .idle`, `setState(_:)` guarded then `NSApp.mainMenu?.update()`).
- [ ] Register it in `AppCommands` (`@ObservedObject private var speechMenuState`, added to `init` with default `.shared`).
- [ ] In the `CommandGroup(after: .pasteboard)` body, after the Find & Replace button, append:
```swift
Divider()

Menu("Speech") {
    Button("Start Speaking") {
        LineformAppNotification.startSpeaking.post(object: LineformAppNotification.activeWindowPayload())
    }

    Button(speechMenuState.state == .paused ? "Resume" : "Pause") {
        LineformAppNotification.pauseResumeSpeech.post(object: LineformAppNotification.activeWindowPayload())
    }
    .disabled(speechMenuState.state == .idle)

    Button("Stop") {
        LineformAppNotification.stopSpeech.post(object: LineformAppNotification.activeWindowPayload())
    }
    .disabled(speechMenuState.state == .idle)
}
```
- [ ] Build (no new unit tests — this is menu wiring):
  `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
  Expected: `** BUILD SUCCEEDED **`.
- [ ] **Manual verification** (record in the commit message): launch the app, confirm **Edit ▸ Speech** shows Start Speaking / Pause / Stop; with nothing speaking, Pause and Stop are disabled. (Full transport behavior is verified in Task 4 once the controller is wired.)
- [ ] Commit: `Read-aloud: Edit ▸ Speech submenu + window-scoped notifications + menu state`

---

## Task 4 — Selection / caret resolution in `EditorContainerView` (manual-verified)

**Files:**
- `Lineform/Editor/EditorContainerView.swift` (edit — own a `SpeechController`, receive the 3 notifications, resolve the source range, push state to the shared menu state, stop on close)

**Interfaces (exact signatures — private to `EditorContainerView`):**
```swift
@StateObject private var speechController = SpeechController()

private func startSpeakingCurrentDocument(_ notification: Notification)
private func speechSource(for payload: LineformAppNotification.Payload) -> String
```

**Design notes:**
- Add `@StateObject private var speechController = SpeechController()` to `EditorContainerView`.
- Three `.onReceive` handlers (mirror the `printDocument` handler — guard `notificationMatchesActiveWindow`):
  - `startSpeaking` → `startSpeakingCurrentDocument(notification)`
  - `pauseResumeSpeech` → `speechController.pauseOrResume()`
  - `stopSpeech` → `speechController.stop()`
- `startSpeakingCurrentDocument`: read the payload, compute `speechSource(...)`, run it through `SpeechTextExtractor.spokenText(from:)`, call `speechController.startSpeaking(...)`.
- `speechSource(for:)` implements the start-point rule using `document.text` (a `String`) and `payload.selectedRange` (UTF-16 `NSRange`) and the current `displayMode`:
  - selection present (`length > 0`, in bounds) → speak that substring;
  - else in `.write`/`.split` with a caret (`selectedRange.location <= length`) → speak from the caret to end;
  - else (Read, or no caret) → speak `document.text`.
- Keep the shared menu state live: add `.onChange(of: speechController.state)` pushing to `LineformSpeechMenuState.shared` **only when this window is key**, and also push the current state in the existing `NSWindow.didBecomeKeyNotification` handler so the menu tracks the frontmost window. On `NSWindow.willCloseNotification` for this window (existing handler), call `speechController.stop()`.

### Steps
- [ ] Add `@StateObject private var speechController = SpeechController()` to `EditorContainerView`.
- [ ] Add the three `.onReceive` blocks next to the existing `printDocument`/`exportPDF` handlers:
```swift
.onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.startSpeaking.name)) { notification in
    guard notificationMatchesActiveWindow(notification) else { return }
    startSpeakingCurrentDocument(notification)
}
.onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.pauseResumeSpeech.name)) { notification in
    guard notificationMatchesActiveWindow(notification) else { return }
    speechController.pauseOrResume()
}
.onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.stopSpeech.name)) { notification in
    guard notificationMatchesActiveWindow(notification) else { return }
    speechController.stop()
}
.onChange(of: speechController.state) { _, newState in
    if activeWindow?.isKeyWindow == true {
        LineformSpeechMenuState.shared.setState(newState)
    }
}
```
- [ ] Add the resolution helpers near the print helpers:
```swift
private func startSpeakingCurrentDocument(_ notification: Notification) {
    guard let payload = notification.object as? LineformAppNotification.Payload else { return }
    let source = speechSource(for: payload)
    speechController.startSpeaking(SpeechTextExtractor.spokenText(from: source))
}

/// The text to speak, per the start-point rule: selection → caret-to-end (Write/Split) → whole
/// document (Read / no caret).
private func speechSource(for payload: LineformAppNotification.Payload) -> String {
    let ns = document.text as NSString
    if let range = payload.selectedRange, range.length > 0, NSMaxRange(range) <= ns.length {
        return ns.substring(with: range)
    }
    if displayMode != .read, let range = payload.selectedRange, range.location <= ns.length {
        return ns.substring(from: range.location)
    }
    return document.text
}
```
- [ ] In the existing `NSWindow.didBecomeKeyNotification` handler (the one guarded on `windowNumber`), add `LineformSpeechMenuState.shared.setState(speechController.state)` so the menu reflects the newly-key window.
- [ ] In the existing `NSWindow.willCloseNotification` handler for this window, call `speechController.stop()` so audio never outlives the window.
- [ ] Build:
  `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'`
  Expected: `** BUILD SUCCEEDED **`.
- [ ] **Manual verification** (the app cannot be driven by automated GUI here — ask the user to confirm, per the `gui-automation-blocked-for-app-qa` note): in a real build, with a document containing headings, prose, a code fence, a `$$…$$` block, a mermaid block, a list, a blockquote, and a table —
  - Write mode, no selection: **Start Speaking** reads from the caret to the end; markdown symbols are NOT spoken; the code fence, math, and mermaid are silent.
  - Select a paragraph: **Start Speaking** reads only the selection.
  - Read mode: **Start Speaking** reads the whole document.
  - **Pause** then **Resume** toggle correctly and the menu label flips; **Stop** returns to idle and disables Pause/Stop.
  - Closing the window mid-speech stops audio.
- [ ] Run the **full default plan** to confirm no regressions (warn the user about the TCC Documents prompt first, per the `cli-test-runs-cause-tcc-prompts` note):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
  Expected: `** TEST SUCCEEDED **`; report exact pass/fail counts, including `SpeechTextExtractorTests` and `SpeechControllerTests`.
- [ ] Commit: `Read-aloud: wire SpeechController into EditorContainerView (selection/caret resolution, menu state, stop-on-close)`

---

## Verification command (per task)
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<ClassName>/<testName>
```
Final task runs the full default plan (drop `-only-testing`).

## Done criteria
- `SpeechTextExtractorTests` and `SpeechControllerTests` green in the default plan; the extractor strips all inline markers and skips code/math/mermaid/rules, the controller state machine transitions correctly with a fake synthesizer (no audio in tests).
- Edit ▸ Speech submenu present with correct enable/disable and Pause·Resume label.
- Manual pass across Write/Read/Split, selection/caret/whole-doc, confirmed by the user.
- No new entitlement, no network, no new SPM dependency.
