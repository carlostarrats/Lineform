# Callouts / Admonitions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render GitHub-style callouts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) as calm, monochrome admonitions in Read/Preview (and export), reusing the existing blockquote machinery. Write mode continues to show source. Unknown types degrade to plain blockquotes.

**Architecture:** A pure classifier `MarkdownCallout.parse` inspects the first quote line's stripped text and returns a `CalloutKind` + optional custom title. `markdownBlocks(in:)` promotes a `.blockquote` whose first line parses as a callout into a new `.callout(kind:title:body:lastLineIndex:)` block; all other routing is byte-identical. `MarkdownPreviewRenderer` gains `appendCallout(...)` which prepends a monochrome title row (tinted SF Symbol + title, medium weight, ink tone) and renders the body via a new shared `appendQuoteLines(...)` helper extracted verbatim from `appendBlockquote`. A one-line `MarkdownReference` row teaches the syntax.

**Tech Stack:** Swift, AppKit, TextKit, XCTest

## Global Constraints
- 5 GitHub types only (`note`, `tip`, `important`, `warning`, `caution`); unknown type → plain blockquote (no error).
- Case-insensitive type match. Optional Obsidian-style custom title on the marker line (`> [!NOTE] Remember this`).
- Monochrome only — the SF Symbol and title are tinted to `theme.textColor` (ink), NO per-type color, no colored background, no accent bar.
- Read/Preview + PDF/RTF export render callouts; Write shows source (existing markup highlighting is untouched — this plan adds no Write-mode code).
- The refactor extracting `appendQuoteLines` from `appendBlockquote` MUST keep existing blockquote output byte-identical — the existing blockquote render tests stay green unchanged.
- All new detection is line-local (matches within one quote line's text), preserving the scoped-syntax-highlighting invariant in CLAUDE.md.
- No new dependency. No Format-menu insertion command (out of scope). No collapsible callouts, no drawn left bar, no nested-callout special-casing (out of scope).
- Keep `MarkdownReference` within its `MarkdownReferenceTests` length discipline (explanation ≤ 90 chars).

## Verification command (per-test)
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<ClassName>/<testName>
```
Full default plan on the final task:
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
```
> TCC caveat (CLAUDE.md): a CLI test run may prompt "'Lineform' would like to access files in your Documents folder." Warn the user and have them click Allow; do not run unattended.

---

## Task 1 — `MarkdownCallout.parse` pure classifier + `CalloutKind`

Add the `CalloutKind` enum and the pure `MarkdownCallout` classifier. No routing yet.

**Files:**
- `Lineform/Preview/MarkdownBlockGrouping.swift` — add `CalloutKind` and `enum MarkdownCallout` (place after `MarkdownBlockquote`, ~line 196, before `MarkdownHorizontalRule`).
- `LineformTests/MarkdownCalloutTests.swift` — new test file.

**Interfaces:**
```swift
/// The 5 GitHub-standard callout kinds. Raw values are the lowercased marker types matched
/// case-insensitively against `> [!TYPE]`.
enum CalloutKind: String, Equatable {
    case note, tip, important, warning, caution

    /// The default title shown when the marker line carries no custom title.
    var displayName: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    /// The monochrome SF Symbol drawn in the title row (tinted to the ink tone, never colored).
    var symbolName: String {
        switch self {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }
}

/// Pure callout-marker classifier. Operates on the FIRST quote line's already-stripped text
/// (markers removed by `MarkdownBlockquote.quoteLine`), so it sees `[!NOTE]` / `[!NOTE] Title`.
enum MarkdownCallout {
    /// Returns `(kind, title)` when `firstQuoteText` is `[!TYPE]` (optionally `[!TYPE] Custom title`)
    /// with a KNOWN type. `title` is the trimmed remainder, or `nil` when absent/empty. Unknown type,
    /// missing `!`, empty type (`[!]`), or any other shape → `nil` (caller keeps it a blockquote).
    static func parse(firstQuoteText: String) -> (kind: CalloutKind, title: String?)?
}
```

**Steps:**
- [ ] Write `LineformTests/MarkdownCalloutTests.swift` with a failing suite:
  ```swift
  import XCTest
  @testable import Lineform

  final class MarkdownCalloutTests: XCTestCase {
      func testEachKnownTypeParses() {
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!NOTE]")?.kind, .note)
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!TIP]")?.kind, .tip)
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!IMPORTANT]")?.kind, .important)
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!WARNING]")?.kind, .warning)
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!CAUTION]")?.kind, .caution)
      }

      func testTypeMatchIsCaseInsensitive() {
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!note]")?.kind, .note)
          XCTAssertEqual(MarkdownCallout.parse(firstQuoteText: "[!Warning]")?.kind, .warning)
      }

      func testNoCustomTitleYieldsNilTitle() {
          let parsed = MarkdownCallout.parse(firstQuoteText: "[!NOTE]")
          XCTAssertEqual(parsed?.kind, .note)
          XCTAssertNil(parsed?.title)
      }

      func testCustomTitleIsCapturedAndTrimmed() {
          let parsed = MarkdownCallout.parse(firstQuoteText: "[!NOTE]   Remember this  ")
          XCTAssertEqual(parsed?.kind, .note)
          XCTAssertEqual(parsed?.title, "Remember this")
      }

      func testTrailingWhitespaceOnlyIsNotATitle() {
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!TIP]   ")?.title)
      }

      func testUnknownTypeReturnsNil() {
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!FOO]"))
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!FOO] title"))
      }

      func testMalformedMarkersReturnNil() {
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!]"))          // empty type
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[NOTE]"))       // missing !
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "!NOTE"))        // no brackets
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "text [!NOTE]")) // marker not at start
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: ""))            // empty
          XCTAssertNil(MarkdownCallout.parse(firstQuoteText: "[!NOTE"))       // unclosed
      }
  }
  ```
- [ ] Run to fail (compile error: `MarkdownCallout`/`CalloutKind` don't exist):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownCalloutTests`
- [ ] Add to `Lineform/Preview/MarkdownBlockGrouping.swift` (after the `MarkdownBlockquote` enum, before `MarkdownHorizontalRule`) the `CalloutKind` enum (as above) and:
  ```swift
  enum MarkdownCallout {
      // Anchored at the start of the stripped text: `[!TYPE]` then optional whitespace + title.
      // Type is 1+ letters; the trailing `.*` captures a custom title (may be empty/whitespace).
      private static let regex = try! NSRegularExpression(pattern: #"^\[!([A-Za-z]+)\][ \t]*(.*)$"#)

      static func parse(firstQuoteText: String) -> (kind: CalloutKind, title: String?)? {
          let ns = firstQuoteText as NSString
          guard let match = regex.firstMatch(in: firstQuoteText, range: NSRange(location: 0, length: ns.length)) else {
              return nil
          }
          let typeText = ns.substring(with: match.range(at: 1)).lowercased()
          guard let kind = CalloutKind(rawValue: typeText) else { return nil }
          let rawTitle = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
          let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
          return (kind: kind, title: trimmed.isEmpty ? nil : trimmed)
      }
  }
  ```
  Add the `Lineform/Preview/MarkdownBlockGrouping.swift` file reference is unchanged (already in the target). Register the NEW test file `LineformTests/MarkdownCalloutTests.swift` in the pbxproj (4 sections, sequential `1F0000xx` IDs — see the pbxproj memory note) so it compiles into `LineformTests`.
- [ ] Run to pass (same `-only-testing` command). Confirm all 7 tests pass.
- [ ] Commit: `Callouts: pure MarkdownCallout.parse classifier + CalloutKind (5 types)`

---

## Task 2 — `.callout` block routing in `MarkdownBlockGrouping`

Promote a callout-marker blockquote into `.callout`; everything else stays a `.blockquote`.

**Files:**
- `Lineform/Preview/MarkdownBlockGrouping.swift` — add the `.callout` case to `enum MarkdownBlock` (~line 30, next to `.blockquote`) and branch the blockquote emission (~line 338-348).
- `LineformTests/MarkdownBlockGroupingTests.swift` — add tests in the `// MARK: - Blockquote` section (~line 109-138).

**Interfaces:**
```swift
// New case on `enum MarkdownBlock: Equatable`:
/// A blockquote whose first line is a GitHub callout marker (`> [!TYPE]`). `title` is the optional
/// custom title from the marker line; `body` is the remaining quote lines (markers stripped).
/// `lastLineIndex` is the last original line the block covers, for the trailing-newline rule.
case callout(kind: CalloutKind, title: String?, body: [MarkdownQuoteLine], lastLineIndex: Int)
```

**Steps:**
- [ ] Add failing tests to `LineformTests/MarkdownBlockGroupingTests.swift` after `testBlockquoteLineParsingHandlesSpacedNesting`:
  ```swift
  // MARK: - Callouts

  func testCalloutMarkerBecomesCalloutBlockWithBodySplit() {
      XCTAssertEqual(
          markdownBlocks(in: ["> [!NOTE]", "> body one", "> body two"]),
          [
              .callout(
                  kind: .note,
                  title: nil,
                  body: [
                      MarkdownQuoteLine(depth: 1, text: "body one"),
                      MarkdownQuoteLine(depth: 1, text: "body two")
                  ],
                  lastLineIndex: 2
              )
          ]
      )
  }

  func testCalloutCapturesCustomTitleAndEmptyBody() {
      XCTAssertEqual(
          markdownBlocks(in: ["> [!TIP] Do this"]),
          [.callout(kind: .tip, title: "Do this", body: [], lastLineIndex: 0)]
      )
  }

  func testUnknownTypeStaysBlockquote() {
      XCTAssertEqual(
          markdownBlocks(in: ["> [!FOO]", "> body"]),
          [.blockquote(lines: [
              MarkdownQuoteLine(depth: 1, text: "[!FOO]"),
              MarkdownQuoteLine(depth: 1, text: "body")
          ], lastLineIndex: 1)]
      )
  }

  func testPlainBlockquoteStaysBlockquote() {
      XCTAssertEqual(
          markdownBlocks(in: ["> just a quote"]),
          [.blockquote(lines: [MarkdownQuoteLine(depth: 1, text: "just a quote")], lastLineIndex: 0)]
      )
  }

  func testCalloutMarkerInsideCodeFenceIsNotACallout() {
      XCTAssertEqual(markdownBlocks(in: ["```", "> [!NOTE]", "```"]), [.lines(0..<3)])
  }

  func testTextBeforeAndAfterCalloutRoutesUnchanged() {
      XCTAssertEqual(
          markdownBlocks(in: ["intro", "> [!WARNING]", "> careful", "outro"]),
          [
              .lines(0..<1),
              .callout(kind: .warning, title: nil,
                       body: [MarkdownQuoteLine(depth: 1, text: "careful")], lastLineIndex: 2),
              .lines(3..<4)
          ]
      )
  }
  ```
- [ ] Run to fail (`.callout` case missing → compile error):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownBlockGroupingTests`
- [ ] Add the `.callout` case to `enum MarkdownBlock` right after the `.blockquote` case (~line 30) with the doc comment above.
- [ ] In `markdownBlocks(in:)`, change the blockquote emission block (~line 338-348) to branch on the first line. Replace:
  ```swift
          blocks.append(.blockquote(lines: quoteLines, lastLineIndex: cursor - 1))
          index = cursor
          continue
  ```
  with:
  ```swift
          if let firstText = quoteLines.first?.text,
             let callout = MarkdownCallout.parse(firstQuoteText: firstText) {
              blocks.append(.callout(
                  kind: callout.kind,
                  title: callout.title,
                  body: Array(quoteLines.dropFirst()),
                  lastLineIndex: cursor - 1
              ))
          } else {
              blocks.append(.blockquote(lines: quoteLines, lastLineIndex: cursor - 1))
          }
          index = cursor
          continue
  ```
  (The `flushLines`, scan loop, and `firstQuote`/`cursor` logic above are unchanged.)
- [ ] Run to pass. Confirm the 6 new tests plus the existing `testBlockquote*` tests all pass (existing blockquote grouping is unchanged for non-marker quotes).
- [ ] Commit: `Callouts: route [!TYPE] blockquotes to a .callout block (unknown → blockquote)`

---

## Task 3 — Refactor `appendBlockquote` → shared `appendQuoteLines` (byte-identical)

Pure extraction. No behavior change. The `.callout` case is NOT yet dispatched (that is Task 4), so the render switch is still non-exhaustive — add a temporary passthrough or complete Task 4 immediately after. To keep the tree compiling, this task adds a `.callout` dispatch stub that renders the body as a plain blockquote; Task 4 replaces the stub with the real title row.

**Files:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift` — extract `appendQuoteLines` from `appendBlockquote` (~line 338-370); add the `.callout` dispatch case in `render(...)`'s switch (~line 137-139).

**Interfaces:**
```swift
/// Emit a run of blockquote lines: each indented by its nesting depth (markers hidden) and gently
/// de-emphasized. Inline styling (bold/italic/code/link/math) still renders. Shared by
/// `appendBlockquote` and `appendCallout` so the two produce identical body output.
private func appendQuoteLines(
    _ quoteLines: [MarkdownQuoteLine],
    to output: NSMutableAttributedString,
    baseAttributes baseBody: [NSAttributedString.Key: Any],
    profile: ReadingProfile,
    theme: Theme,
    mathProvider: MathImageProviding
)
```

**Steps:**
- [ ] Add a failing byte-identity test to `LineformTests/MarkdownPreviewRendererTests.swift` (near `testBlockquoteIndentsAndHidesMarker`, ~line 91) that pins the current blockquote output so the refactor is provably byte-identical:
  ```swift
  func testBlockquoteBodyMatchesSharedQuoteRendering() throws {
      // A quote and a callout body over the same lines must render identical body runs.
      let quote = MarkdownPreviewRenderer().render("> alpha\n> beta", profile: .original)
      XCTAssertEqual(quote.string, "alpha\nbeta")
      let firstStyle = try XCTUnwrap(quote.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
      XCTAssertGreaterThan(firstStyle.headIndent, 0)
      // De-emphasis: quote body foreground is the theme ink at reduced alpha (not full ink).
      let color = try XCTUnwrap(quote.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
      XCTAssertLessThan(color.alphaComponent, 1.0)
  }
  ```
- [ ] Run to fail if it does not compile yet, else it passes against current code — that is fine; its purpose is to lock behavior BEFORE the refactor. Run it green first:
  `... -only-testing:LineformTests/MarkdownPreviewRendererTests/testBlockquoteBodyMatchesSharedQuoteRendering`
- [ ] Extract the body of `appendBlockquote` verbatim into a new `appendQuoteLines(...)` with the signature above (copy the exact loop, `quoteColor`, `indentStep`, and per-line paragraph/attribute code from ~line 346-369). Then make `appendBlockquote` a one-line delegator:
  ```swift
  private func appendBlockquote(
      _ quoteLines: [MarkdownQuoteLine],
      to output: NSMutableAttributedString,
      baseAttributes baseBody: [NSAttributedString.Key: Any],
      profile: ReadingProfile,
      theme: Theme,
      mathProvider: MathImageProviding
  ) {
      appendQuoteLines(quoteLines, to: output, baseAttributes: baseBody, profile: profile, theme: theme, mathProvider: mathProvider)
  }
  ```
- [ ] Add a TEMPORARY `.callout` dispatch case to the `render(...)` switch (after the `.blockquote` case, ~line 139) so the switch stays exhaustive:
  ```swift
  case .callout(let kind, let title, let body, let lastLineIndex):
      appendCallout(kind: kind, title: title, body: body, to: output, baseAttributes: bodyAttributes, profile: profile, theme: theme, mathProvider: mathProvider)
      appendBlockSeparator(afterLine: lastLineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
  ```
  To compile this task before Task 4 exists, add a MINIMAL `appendCallout` stub that renders only the body (title row lands in Task 4):
  ```swift
  private func appendCallout(
      kind: CalloutKind,
      title: String?,
      body: [MarkdownQuoteLine],
      to output: NSMutableAttributedString,
      baseAttributes baseBody: [NSAttributedString.Key: Any],
      profile: ReadingProfile,
      theme: Theme,
      mathProvider: MathImageProviding
  ) {
      appendQuoteLines(body, to: output, baseAttributes: baseBody, profile: profile, theme: theme, mathProvider: mathProvider)
  }
  ```
- [ ] Run the full blockquote render suite + the new test to prove byte-identity:
  `... -only-testing:LineformTests/MarkdownPreviewRendererTests`
  Confirm `testBlockquoteIndentsAndHidesMarker`, `testNestedBlockquoteIndentsFurther`, and `testBlockquoteBodyMatchesSharedQuoteRendering` all pass unchanged.
- [ ] Commit: `Callouts: extract appendQuoteLines from appendBlockquote (byte-identical) + callout dispatch stub`

---

## Task 4 — `appendCallout` real render: monochrome title row (SF Symbol + title) + body

Replace the Task 3 stub with the real title row. Structure is unit-verified where possible; the exact visual tint/weight is manual-verified across light/dark themes.

**Files:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift` — replace the `appendCallout` stub; add a private `calloutSymbolImage(...)` helper (place near `appendCallout`).
- `LineformTests/MarkdownPreviewRendererTests.swift` — add render-structure tests.

**Interfaces:**
```swift
private func appendCallout(
    kind: CalloutKind,
    title: String?,
    body: [MarkdownQuoteLine],
    to output: NSMutableAttributedString,
    baseAttributes baseBody: [NSAttributedString.Key: Any],
    profile: ReadingProfile,
    theme: Theme,
    mathProvider: MathImageProviding
)

/// A monochrome SF Symbol image tinted to `color` (the theme ink), sized to the body font, for the
/// callout title row. Returns nil if the symbol is unavailable (caller then omits the glyph).
private func calloutSymbolImage(for kind: CalloutKind, color: NSColor, pointSize: CGFloat) -> NSImage?
```

**Steps:**
- [ ] Add failing render-structure tests to `LineformTests/MarkdownPreviewRendererTests.swift`:
  ```swift
  func testCalloutRendersDefaultTitleAndBody() throws {
      let rendered = MarkdownPreviewRenderer().render("> [!NOTE]\n> body text", profile: .original)
      // Title row shows the capitalized type name; body follows on its own line.
      XCTAssertTrue(rendered.string.contains("Note"))
      XCTAssertTrue(rendered.string.contains("body text"))
      // A leading SF-Symbol attachment glyph (object-replacement char) precedes the title.
      XCTAssertTrue(rendered.string.contains("\u{FFFC}"))
      let attachment = rendered.attribute(.attachment, at: 0, effectiveRange: nil)
      XCTAssertNotNil(attachment)
  }

  func testCalloutUsesCustomTitleWhenPresent() {
      let rendered = MarkdownPreviewRenderer().render("> [!TIP] Pro move\n> details", profile: .original)
      XCTAssertTrue(rendered.string.contains("Pro move"))
      XCTAssertFalse(rendered.string.contains("Tip")) // custom title replaces the default name
      XCTAssertTrue(rendered.string.contains("details"))
  }

  func testCalloutTitleIsFullInkNotDeemphasized() throws {
      // Title row ink is the theme text color at full alpha (monochrome, not the 0.8 body tint).
      let rendered = MarkdownPreviewRenderer().render("> [!WARNING]\n> body", profile: .original)
      // Find the first title glyph (skip the attachment char at 0 and the following space).
      let ns = rendered.string as NSString
      let titleIndex = ns.range(of: "Warning").location
      XCTAssertNotEqual(titleIndex, NSNotFound)
      let color = try XCTUnwrap(rendered.attribute(.foregroundColor, at: titleIndex, effectiveRange: nil) as? NSColor)
      XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
  }

  func testCalloutWithNoBodyRendersOnlyTitleRow() {
      let rendered = MarkdownPreviewRenderer().render("> [!CAUTION]", profile: .original)
      XCTAssertTrue(rendered.string.contains("Caution"))
      XCTAssertFalse(rendered.string.contains("\n")) // no body → no separator newline
  }

  func testCalloutBodyIsIndentedLikeBlockquote() throws {
      let rendered = MarkdownPreviewRenderer().render("> [!NOTE]\n> quoted body", profile: .original)
      let ns = rendered.string as NSString
      let bodyIndex = ns.range(of: "quoted body").location
      let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: bodyIndex, effectiveRange: nil) as? NSParagraphStyle)
      XCTAssertGreaterThan(style.headIndent, 0)
  }
  ```
- [ ] Run to fail:
  `... -only-testing:LineformTests/MarkdownPreviewRendererTests`
- [ ] Replace the `appendCallout` stub with the real implementation:
  ```swift
  /// Emit a monochrome callout: a title row (tinted SF Symbol + title, medium weight, full ink)
  /// indented like the quote body, then the body via the shared `appendQuoteLines`. No color, no
  /// background, no bar — restraint over the multi-color admonition look, and export-safe.
  private func appendCallout(
      kind: CalloutKind,
      title: String?,
      body: [MarkdownQuoteLine],
      to output: NSMutableAttributedString,
      baseAttributes baseBody: [NSAttributedString.Key: Any],
      profile: ReadingProfile,
      theme: Theme,
      mathProvider: MathImageProviding
  ) {
      let indentStep: CGFloat = 22
      let paragraph = mutableParagraphStyle(from: baseBody)
      paragraph.firstLineHeadIndent = indentStep
      paragraph.headIndent = indentStep

      let baseFont = (baseBody[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CGFloat(profile.fontSize))
      let titleFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

      var titleAttributes = baseBody
      titleAttributes[.paragraphStyle] = paragraph
      titleAttributes[.foregroundColor] = theme.textColor
      titleAttributes[.font] = titleFont

      // Tinted SF Symbol, baseline-aligned to the title font, carrying the title paragraph style so
      // the glyph shares the row's indent.
      if let symbol = calloutSymbolImage(for: kind, color: theme.textColor, pointSize: titleFont.pointSize) {
          let attachment = NSTextAttachment()
          attachment.image = symbol
          attachment.bounds = CGRect(x: 0, y: titleFont.descender, width: symbol.size.width, height: symbol.size.height)
          let glyph = NSMutableAttributedString(attachment: attachment)
          glyph.addAttributes(titleAttributes, range: NSRange(location: 0, length: glyph.length))
          output.append(glyph)
          output.append(NSAttributedString(string: " ", attributes: titleAttributes))
      }

      let titleText = title ?? kind.displayName
      output.append(NSAttributedString(string: titleText, attributes: titleAttributes))

      if !body.isEmpty {
          output.append(NSAttributedString(string: "\n", attributes: titleAttributes))
          appendQuoteLines(body, to: output, baseAttributes: baseBody, profile: profile, theme: theme, mathProvider: mathProvider)
      }
  }

  private func calloutSymbolImage(for kind: CalloutKind, color: NSColor, pointSize: CGFloat) -> NSImage? {
      guard let base = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.displayName) else {
          return nil
      }
      let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
          .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
      return base.withSymbolConfiguration(config) ?? base
  }
  ```
- [ ] Run to pass:
  `... -only-testing:LineformTests/MarkdownPreviewRendererTests`
  Confirm the 5 new callout render tests pass and every pre-existing blockquote render test is still green.
- [ ] MANUAL verification (record in the commit body): run the app, render a document with all 5 callout types in Read and Preview across a light theme and a dark theme (Quiet/Night). Confirm: monochrome (symbol + title read in the ink tone, no per-type color, no background box), title row uses the default type name unless a custom title is present, body indents like a blockquote, and Write mode still shows raw `> [!TYPE]` source. Then File ▸ Export as PDF and confirm the title row + body appear monochrome in the exported PDF.
- [ ] Commit: `Callouts: render monochrome title row (tinted SF Symbol + title) + shared body`

---

## Task 5 — `MarkdownReference` Info-tab row + tests

Teach the syntax in the Info sidebar tab, staying within the length discipline.

**Files:**
- `Lineform/Outline/MarkdownReference.swift` — add one row to the "Markdown Basics" section (~line 38, near the `> quote` row).
- `LineformTests/MarkdownReferenceTests.swift` — extend `testBasicsIncludesCoreSyntax` (~line 15).

**Interfaces:** none (data-only).

**Steps:**
- [ ] Update `testBasicsIncludesCoreSyntax` in `LineformTests/MarkdownReferenceTests.swift` to require the callout row, and add a focused test:
  ```swift
  func testBasicsIncludesCalloutSyntax() {
      let basics = MarkdownReference.sections.first { $0.title == "Markdown Basics" }
      let syntaxes = basics?.rows.map(\.syntax) ?? []
      XCTAssertTrue(syntaxes.contains("> [!NOTE]"), "missing callout row")
  }
  ```
- [ ] Run to fail:
  `... -only-testing:LineformTests/MarkdownReferenceTests`
- [ ] Add the row to the "Markdown Basics" section right after the `> quote` row (~line 38). Explanation must be ≤ 90 chars (guarded by `testExplanationsStayConcise`):
  ```swift
  Row(syntax: "> [!NOTE]", explanation: "Callout. Also TIP, IMPORTANT, WARNING, CAUTION. Add a title after the marker."),
  ```
  (Length: 78 chars — within the 90 limit.)
- [ ] Run to pass:
  `... -only-testing:LineformTests/MarkdownReferenceTests`
  Confirm `testExplanationsStayConcise`, `testSectionsCoverEveryGroupAndAreNonEmpty`, `testBasicsIncludesCoreSyntax`, and the new `testBasicsIncludesCalloutSyntax` all pass.
- [ ] Run the FULL default plan to prove nothing regressed:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
  Read the output; report exact pass/fail counts.
- [ ] Commit: `Callouts: Info-tab reference row for > [!NOTE] callouts`

---

## Notes for the implementer
- The `.callout` case makes `MarkdownBlock`'s synthesized `Equatable` cover `CalloutKind` (String-backed, Equatable), `String?`, and `[MarkdownQuoteLine]` (Equatable) — no manual conformance needed.
- `NSImage.SymbolConfiguration(paletteColors:)` and `withSymbolConfiguration(_:)` are macOS 12+; Lineform targets current macOS, so no availability guard is required. If `NSImage(systemSymbolName:)` ever returns nil, `appendCallout` omits the glyph and still renders the title text — degrade, never crash.
- Do NOT add a Format-menu insertion command or Write-mode highlighting change — out of scope; the existing markup highlighter already colors the literal `> [!NOTE]` source acceptably.
- Keep `-parallel-testing-enabled NO`. These are pure default-plan tests (no hosted window), so no hosted-plan run is required for this feature.
- Per the task instruction: do NOT commit unless the executing skill/checkpoints direct it; the commit lines above are the intended commit points for a subagent-driven run.
