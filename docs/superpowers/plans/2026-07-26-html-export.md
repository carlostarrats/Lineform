# HTML Export + Export As Submenu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the open document as a real `.html` file, and move every non-Markdown target out of Save As into a new File ▸ Export As submenu.

**Architecture:** A new pure `MarkdownHTMLRenderer` walks the existing `[MarkdownBlock]` grouping that the preview renderer already uses, emitting semantic HTML with **one-to-one** fidelity to the source. `SaveAsFormat` becomes `ExportFormat` (html/pdf/styledPDF/rtf, no markdown), `SaveAsPanelController` becomes `ExportPanelController` (Paper Size row only, no Format popup), and Save As collapses to a plain Markdown-only panel.

**Tech Stack:** Swift 5, SwiftUI + AppKit, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-26-html-export-design.md`

## Global Constraints

- **One-to-one output.** Image paths, link URLs, and remote `http(s)` URLs are emitted **exactly as written** — never resolved, rewritten, inlined, or replaced. Do not add a special case for unsaved documents or unreachable files.
- **Only generated images embed.** Math and mermaid have no user-authored path, so they emit as `data:` URI PNGs. Nothing else embeds.
- `MarkdownHTMLRenderer.swift` must import **only Foundation** — no AppKit, no SwiftUI. Its tests run in the **default** test plan.
- Escape `&`, `<`, `>`, `"` in all text and attribute values.
- No syntax-highlight color spans. Code fences emit `<pre><code class="language-x">`.
- Never add a keyboard shortcut to an Export As row.
- `SaveAsConflict` stays on the Markdown path only.
- New Xcode files use the repo's hand-rolled pbxproj IDs: build file `1F000001…`, file ref `1F000002…`, sharing a trailing serial. **Next free serials are `04B5` and `04B6`** (current max is `04B4`).
- Verification during development is **build + `-only-testing`**, never the full suite. The full suite runs once at the end.

---

### Task 1: HTML escaping and inline emitter

**Files:**
- Create: `Lineform/Preview/MarkdownHTMLRenderer.swift`
- Create: `LineformTests/MarkdownHTMLRendererTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (4 sections, serials `04B5` app / `04B6` test)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MarkdownHTMLRenderer.escape(_ text: String) -> String`
  - `MarkdownHTMLRenderer.inlineHTML(_ line: String) -> String`

- [ ] **Step 1: Write the failing test**

Create `LineformTests/MarkdownHTMLRendererTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MarkdownHTMLRendererTests: XCTestCase {

    // MARK: Escaping

    func testEscapeReplacesMarkupCharacters() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.escape("a & b < c > d \" e"),
            "a &amp; b &lt; c &gt; d &quot; e"
        )
    }

    func testEscapeLeavesOrdinaryTextAlone() {
        XCTAssertEqual(MarkdownHTMLRenderer.escape("plain text 123"), "plain text 123")
    }

    // MARK: Inline

    func testInlineEmitsStrongEmphasisCodeAndStrikethrough() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("**bold** and _italic_ and `code` and ~~gone~~"),
            "<strong>bold</strong> and <em>italic</em> and <code>code</code> and <del>gone</del>"
        )
    }

    func testInlineEmitsLinkWithHrefExactlyAsWritten() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("see [the docs](../guide/index.html)"),
            #"see <a href="../guide/index.html">the docs</a>"#
        )
    }

    func testInlineEmitsImageWithSourcePathExactlyAsWritten() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("![flow diagram](images/flow.png)"),
            #"<img src="images/flow.png" alt="flow diagram">"#
        )
    }

    func testInlineLeavesRemoteURLsUntouched() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("![x](https://example.com/a.png)"),
            #"<img src="https://example.com/a.png" alt="x">"#
        )
    }

    func testInlineEscapesSurroundingTextAndAttributes() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML(#"5 < 6 [a "b"](p?x=1&y=2)"#),
            #"5 &lt; 6 <a href="p?x=1&amp;y=2">a &quot;b&quot;</a>"#
        )
    }

    func testInlineImageWinsOverLinkAtSamePosition() {
        XCTAssertEqual(
            MarkdownHTMLRenderer.inlineHTML("![a](b.png)"),
            #"<img src="b.png" alt="a">"#
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHTMLRendererTests
```

Expected: build failure — `cannot find 'MarkdownHTMLRenderer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Lineform/Preview/MarkdownHTMLRenderer.swift`:

```swift
import Foundation

/// Pure Markdown → HTML emitter over the same `[MarkdownBlock]` grouping the preview renderer
/// uses (`markdownBlocks(in:)`), so a new block construct becomes one new case here and nothing
/// else.
///
/// **Output is ONE-TO-ONE with the source.** Image paths, link URLs, and remote URLs are emitted
/// exactly as the user wrote them — never resolved, rewritten, or inlined. Someone exporting HTML
/// is technical and their intent is what they typed: if they keep the `.html` beside the `.md`,
/// their relative paths keep working. Self-contained output is what PDF export is for. Do not
/// "improve" this by embedding local files or degrading unresolvable paths to alt text.
///
/// Math and mermaid are the only embedded bytes, because they have no user-authored path — the
/// picture is generated from the `$$…$$` / ```mermaid source at export time. They come from an
/// injected provider, which is also what keeps this file free of AppKit so its tests stay in the
/// default test plan.
enum MarkdownHTMLRenderer {

    /// A picture the app generates rather than one the user pointed at.
    enum GeneratedImage: Equatable {
        case math(latex: String)
        case mermaid(source: String)
    }

    /// PNG bytes for a generated image, or `nil` to fall back to emitting the source as text.
    typealias GeneratedImageProvider = (GeneratedImage) -> Data?

    // MARK: Escaping

    /// Escapes the four characters that can break out of text or an attribute value.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: Inline

    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#)

    private struct Token {
        enum Kind { case bold, italic, code, strikethrough, image, link }
        var kind: Kind
        var text: String
        /// Destination for image/link; empty otherwise.
        var destination: String
        var range: NSRange
    }

    /// Emits one source line's inline markup. Token text is escaped but NOT re-scanned, matching
    /// the preview renderer's single-pass behavior.
    static func inlineHTML(_ line: String) -> String {
        let nsLine = line as NSString
        var out = ""
        var location = 0

        while location < nsLine.length {
            guard let token = nextToken(in: line, nsLine: nsLine, from: location) else {
                out += escape(nsLine.substring(from: location))
                break
            }
            if token.range.location > location {
                out += escape(nsLine.substring(
                    with: NSRange(location: location, length: token.range.location - location)
                ))
            }
            out += emit(token)
            location = NSMaxRange(token.range)
        }

        return out
    }

    private static func emit(_ token: Token) -> String {
        let text = escape(token.text)
        switch token.kind {
        case .bold: return "<strong>\(text)</strong>"
        case .italic: return "<em>\(text)</em>"
        case .code: return "<code>\(text)</code>"
        case .strikethrough: return "<del>\(text)</del>"
        case .image: return "<img src=\"\(escape(token.destination))\" alt=\"\(text)\">"
        case .link: return "<a href=\"\(escape(token.destination))\">\(text)</a>"
        }
    }

    private static func nextToken(in line: String, nsLine: NSString, from location: Int) -> Token? {
        var earliest: Token?
        consider(token(boldRegex, .bold, line, nsLine, location), &earliest)
        consider(token(italicRegex, .italic, line, nsLine, location), &earliest)
        consider(token(codeRegex, .code, line, nsLine, location), &earliest)
        consider(token(strikethroughRegex, .strikethrough, line, nsLine, location), &earliest)
        consider(token(imageRegex, .image, line, nsLine, location), &earliest)
        consider(token(linkRegex, .link, line, nsLine, location), &earliest)
        return earliest
    }

    /// Earliest match wins. `<=` keeps the FIRST considered token at a tie, which is why `.image`
    /// is considered before `.link`: for `![a](b)` the link regex also matches, one character
    /// later, so position alone already resolves it — but a tie must not flip the result.
    private static func consider(_ candidate: Token?, _ earliest: inout Token?) {
        guard let candidate else { return }
        if let current = earliest, current.range.location <= candidate.range.location { return }
        earliest = candidate
    }

    private static func token(
        _ regex: NSRegularExpression,
        _ kind: Token.Kind,
        _ line: String,
        _ nsLine: NSString,
        _ location: Int
    ) -> Token? {
        let searchRange = NSRange(location: location, length: nsLine.length - location)
        guard let match = regex.firstMatch(in: line, range: searchRange) else { return nil }
        let destination = match.numberOfRanges > 2 ? nsLine.substring(with: match.range(at: 2)) : ""
        return Token(
            kind: kind,
            text: nsLine.substring(with: match.range(at: 1)),
            destination: destination,
            range: match.range
        )
    }
}
```

- [ ] **Step 4: Add both files to the Xcode project**

Edit `Lineform.xcodeproj/project.pbxproj` in **four** places each (this project has no synced groups — files are invisible to the build until all four exist). Copy the `MarkdownTableEditing` entries as the template:

1. `PBXBuildFile` section — add near line 17 (tests) and line 93 (app):
```
		1F00000100000000000004B5 /* MarkdownHTMLRenderer.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000004B5 /* MarkdownHTMLRenderer.swift */; };
		1F00000100000000000004B6 /* MarkdownHTMLRendererTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000004B6 /* MarkdownHTMLRendererTests.swift */; };
```
2. `PBXFileReference` section:
```
		1F00000200000000000004B5 /* MarkdownHTMLRenderer.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarkdownHTMLRenderer.swift; sourceTree = "<group>"; };
		1F00000200000000000004B6 /* MarkdownHTMLRendererTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarkdownHTMLRendererTests.swift; sourceTree = "<group>"; };
```
3. `PBXGroup` children — `MarkdownHTMLRenderer.swift` into the **Preview** group (the one already listing `MarkdownBlockGrouping.swift`), `MarkdownHTMLRendererTests.swift` into the **LineformTests** group.
4. `PBXSourcesBuildPhase` files — the app target's phase gets `…04B5 /* MarkdownHTMLRenderer.swift in Sources */,`, the test target's phase gets `…04B6 /* MarkdownHTMLRendererTests.swift in Sources */,`.

- [ ] **Step 5: Run test to verify it passes**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHTMLRendererTests
```

Expected: 7 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Preview/MarkdownHTMLRenderer.swift LineformTests/MarkdownHTMLRendererTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add HTML escaping and inline emitter"
```

---

### Task 2: Block emitter

**Files:**
- Modify: `Lineform/Preview/MarkdownHTMLRenderer.swift`
- Modify: `LineformTests/MarkdownHTMLRendererTests.swift`

**Interfaces:**
- Consumes: `MarkdownHTMLRenderer.escape`, `.inlineHTML` (Task 1); `markdownBlocks(in: [String]) -> [MarkdownBlock]`, `MarkdownHeadingParser.heading(in:)`, `MarkdownListItem`, `MarkdownQuoteLine`, `MarkdownTable`, `MarkdownTableAlignment`, `CalloutKind` (existing).
- Produces: `MarkdownHTMLRenderer.body(for text: String, generatedImage: GeneratedImageProvider) -> String` — the `<body>` inner HTML, no shell.

- [ ] **Step 1: Write the failing test**

Append to `LineformTests/MarkdownHTMLRendererTests.swift`, inside the class:

```swift
    // MARK: Blocks

    private func body(_ markdown: String) -> String {
        MarkdownHTMLRenderer.body(for: markdown, generatedImage: { _ in nil })
    }

    func testHeadingsBecomeHeadingTags() {
        XCTAssertTrue(body("# Title").contains("<h1>Title</h1>"))
        XCTAssertTrue(body("### Deeper").contains("<h3>Deeper</h3>"))
    }

    func testHeadingTextGetsInlineTreatment() {
        XCTAssertTrue(body("## A **bold** heading").contains("<h2>A <strong>bold</strong> heading</h2>"))
    }

    func testParagraphLinesJoinWithLineBreaks() {
        XCTAssertTrue(body("one\ntwo").contains("<p>one<br>two</p>"))
    }

    func testBlankLineSeparatesParagraphs() {
        let html = body("one\n\ntwo")
        XCTAssertTrue(html.contains("<p>one</p>"))
        XCTAssertTrue(html.contains("<p>two</p>"))
    }

    func testBulletListBecomesUnorderedList() {
        let html = body("- a\n- b")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>a</li>"))
        XCTAssertTrue(html.contains("<li>b</li>"))
        XCTAssertTrue(html.contains("</ul>"))
    }

    func testNumberedListBecomesOrderedList() {
        let html = body("1. a\n1. b")
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>a</li>"))
    }

    func testNestedListNestsTags() {
        let html = body("- a\n  - b")
        XCTAssertTrue(html.contains("<ul><li>a<ul><li>b</li></ul></li></ul>"))
    }

    func testTaskItemsBecomeDisabledCheckboxes() {
        let html = body("- [ ] todo\n- [x] done")
        XCTAssertTrue(html.contains(#"<input type="checkbox" disabled> todo"#))
        XCTAssertTrue(html.contains(#"<input type="checkbox" disabled checked> done"#))
    }

    func testBlockquoteBecomesBlockquote() {
        XCTAssertTrue(body("> quoted").contains("<blockquote><p>quoted</p></blockquote>"))
    }

    func testNestedBlockquoteNests() {
        XCTAssertTrue(body("> > deep").contains("<blockquote><blockquote><p>deep</p></blockquote></blockquote>"))
    }

    func testCalloutCarriesKindClassAndTitle() {
        let html = body("> [!WARNING]\n> careful")
        XCTAssertTrue(html.contains(#"<blockquote class="callout callout-warning">"#))
        XCTAssertTrue(html.contains(#"<p class="callout-title">Warning</p>"#))
        XCTAssertTrue(html.contains("careful"))
    }

    func testCalloutUsesCustomTitleWhenGiven() {
        XCTAssertTrue(body("> [!NOTE] Heads up\n> body").contains(#"<p class="callout-title">Heads up</p>"#))
    }

    func testTableEmitsHeaderBodyAndAlignment() {
        let html = body("| a | b |\n| :-- | --: |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<thead>"))
        XCTAssertTrue(html.contains(#"<th style="text-align:left">a</th>"#))
        XCTAssertTrue(html.contains(#"<th style="text-align:right">b</th>"#))
        XCTAssertTrue(html.contains("<tbody>"))
        XCTAssertTrue(html.contains(#"<td style="text-align:left">1</td>"#))
    }

    func testFencedCodeCarriesLanguageClassAndIsEscaped() {
        let html = body("```swift\nlet a = b < c\n```")
        XCTAssertTrue(html.contains(#"<pre><code class="language-swift">"#))
        XCTAssertTrue(html.contains("let a = b &lt; c"))
        XCTAssertFalse(html.contains("b < c"))
    }

    func testFencedCodeWithoutLanguageOmitsClass() {
        XCTAssertTrue(body("```\nx\n```").contains("<pre><code>"))
    }

    func testFencedCodeIsNotInlineParsed() {
        XCTAssertTrue(body("```\n**not bold**\n```").contains("**not bold**"))
    }

    func testHorizontalRuleBecomesHR() {
        XCTAssertTrue(body("a\n\n---\n\nb").contains("<hr>"))
    }

    func testOwnLineImageKeepsPathExactly() {
        XCTAssertTrue(body("![d](images/a.png)").contains(#"<img src="images/a.png" alt="d">"#))
    }

    func testRelativePathIsNeverRewritten() {
        // The single most important guarantee: what the user wrote is what comes out, with no
        // resolution against any document directory and no data: inlining.
        let html = body("![d](../shared/pic.png)")
        XCTAssertTrue(html.contains(#"src="../shared/pic.png""#))
        XCTAssertFalse(html.contains("data:"))
    }

    func testNoUnescapedAngleBracketSurvivesFromSourceText() {
        XCTAssertFalse(body("a < b and 3 > 2").contains("a < b"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHTMLRendererTests
```

Expected: build failure — `type 'MarkdownHTMLRenderer' has no member 'body'`.

- [ ] **Step 3: Write minimal implementation**

Append inside `enum MarkdownHTMLRenderer` in `Lineform/Preview/MarkdownHTMLRenderer.swift`:

```swift
    // MARK: Blocks

    /// The `<body>` inner HTML for a whole document. No shell — `html(for:title:generatedImage:)`
    /// wraps this.
    static func body(for text: String, generatedImage: GeneratedImageProvider) -> String {
        let lines = text.components(separatedBy: "\n")
        var out = ""
        for block in markdownBlocks(in: lines) {
            out += html(for: block, lines: lines, generatedImage: generatedImage)
        }
        return out
    }

    private static func html(
        for block: MarkdownBlock,
        lines: [String],
        generatedImage: GeneratedImageProvider
    ) -> String {
        switch block {
        case let .lines(range):
            return linesHTML(Array(lines[range]))
        case let .singleLineMath(latex, _):
            return generatedHTML(.math(latex: latex), fallback: latex, generatedImage: generatedImage)
        case let .fencedMath(latex, _):
            return generatedHTML(.math(latex: latex), fallback: latex, generatedImage: generatedImage)
        case let .mermaid(source, _):
            return generatedHTML(.mermaid(source: source), fallback: source, generatedImage: generatedImage)
        case .horizontalRule:
            return "<hr>"
        case let .blockquote(quoteLines, _):
            return quoteHTML(quoteLines)
        case let .callout(kind, title, body, _):
            return calloutHTML(kind: kind, title: title, body: body)
        case let .list(items, _):
            return listHTML(items)
        case let .table(table, _):
            return tableHTML(table)
        case let .fencedCode(language, body, _, _):
            let openTag = language.isEmpty ? "<pre><code>" : "<pre><code class=\"language-\(escape(language))\">"
            return "\(openTag)\(escape(body))</code></pre>"
        case let .image(alt, path, _, _):
            return "<p><img src=\"\(escape(path))\" alt=\"\(escape(alt))\"></p>"
        }
    }

    /// A run of ordinary lines: headings become heading tags, and maximal runs of non-blank
    /// lines become one paragraph whose source line breaks are preserved as `<br>` (matching how
    /// Read mode lays the same lines out).
    private static func linesHTML(_ lines: [String]) -> String {
        var out = ""
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out += "<p>\(paragraph.joined(separator: "<br>"))</p>"
            paragraph.removeAll()
        }

        for line in lines {
            if let heading = MarkdownHeadingParser.heading(in: line) {
                flush()
                let level = min(max(heading.level, 1), 6)
                out += "<h\(level)>\(inlineHTML(heading.title))</h\(level)>"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(inlineHTML(line))
            }
        }
        flush()
        return out
    }

    private static func listHTML(_ items: [MarkdownListItem]) -> String {
        var out = ""
        /// One entry per currently-open list, innermost last: its tag and its indent level.
        var open: [(tag: String, level: Int)] = []

        for item in items {
            let tag = item.ordinal == nil ? "ul" : "ol"

            while let last = open.last, last.level > item.indentLevel {
                out += "</\(last.tag)></li>"
                open.removeLast()
            }

            if let last = open.last, last.level == item.indentLevel {
                if last.tag == tag {
                    out += "</li>"
                } else {
                    // A bullet run turning into a numbered run at the same depth closes one list
                    // and opens the other, rather than emitting mismatched tags.
                    out += "</li></\(last.tag)>"
                    open.removeLast()
                    out += "<\(tag)>"
                    open.append((tag, item.indentLevel))
                }
            } else {
                // Deeper than anything open (or nothing open): nest inside the current item.
                out += "<\(tag)>"
                open.append((tag, item.indentLevel))
            }

            out += "<li>\(itemHTML(item))"
        }

        while let last = open.popLast() {
            out += "</li></\(last.tag)>"
        }
        return out
    }

    private static func itemHTML(_ item: MarkdownListItem) -> String {
        guard let checkbox = item.checkbox else { return inlineHTML(item.text) }
        let checked = checkbox.isChecked ? " checked" : ""
        return "<input type=\"checkbox\" disabled\(checked)> \(inlineHTML(item.text))"
    }

    private static func quoteHTML(_ quoteLines: [MarkdownQuoteLine]) -> String {
        var out = ""
        var depth = 0
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out += "<p>\(paragraph.joined(separator: "<br>"))</p>"
            paragraph.removeAll()
        }

        for line in quoteLines {
            if line.depth != depth {
                flush()
                while depth < line.depth { out += "<blockquote>"; depth += 1 }
                while depth > line.depth { out += "</blockquote>"; depth -= 1 }
            }
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(inlineHTML(line.text))
            }
        }
        flush()
        while depth > 0 { out += "</blockquote>"; depth -= 1 }
        return out
    }

    private static func calloutHTML(kind: CalloutKind, title: String?, body: [MarkdownQuoteLine]) -> String {
        let heading = title?.isEmpty == false ? title! : kind.displayName
        var out = "<blockquote class=\"callout callout-\(kind.rawValue)\">"
        out += "<p class=\"callout-title\">\(escape(heading))</p>"
        // Body lines are already marker-stripped; render them at depth 0 inside this blockquote.
        out += quoteHTML(body.map { MarkdownQuoteLine(depth: 0, text: $0.text) })
        out += "</blockquote>"
        return out
    }

    private static func tableHTML(_ table: MarkdownTable) -> String {
        func style(_ index: Int) -> String {
            let alignment = table.alignments.indices.contains(index) ? table.alignments[index] : .left
            switch alignment {
            case .left: return "left"
            case .center: return "center"
            case .right: return "right"
            }
        }

        var out = "<table><thead><tr>"
        for (index, header) in table.headers.enumerated() {
            out += "<th style=\"text-align:\(style(index))\">\(inlineHTML(header))</th>"
        }
        out += "</tr></thead><tbody>"
        for row in table.rows {
            out += "<tr>"
            for (index, cell) in row.enumerated() {
                out += "<td style=\"text-align:\(style(index))\">\(inlineHTML(cell))</td>"
            }
            out += "</tr>"
        }
        out += "</tbody></table>"
        return out
    }

    /// Math and mermaid: the only embedded bytes, because there is no user path to preserve.
    /// A provider that declines falls back to the source as preformatted text, so a broken
    /// formula or diagram never loses content.
    private static func generatedHTML(
        _ image: GeneratedImage,
        fallback: String,
        generatedImage: GeneratedImageProvider
    ) -> String {
        guard let data = generatedImage(image) else {
            return "<pre><code>\(escape(fallback))</code></pre>"
        }
        let base64 = data.base64EncodedString()
        return "<p><img src=\"data:image/png;base64,\(base64)\" alt=\"\(escape(fallback))\"></p>"
    }
```

- [ ] **Step 4: Run test to verify it passes**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHTMLRendererTests
```

Expected: all tests PASS. If `testNestedListNestsTags` fails, check `MarkdownList.parse`'s indent rule — two columns of leading space is one level, so `  - b` is level 1.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Preview/MarkdownHTMLRenderer.swift LineformTests/MarkdownHTMLRendererTests.swift
git commit -m "Emit HTML for every markdown block type"
```

---

### Task 3: Document shell

**Files:**
- Modify: `Lineform/Preview/MarkdownHTMLRenderer.swift`
- Modify: `LineformTests/MarkdownHTMLRendererTests.swift`

**Interfaces:**
- Consumes: `MarkdownHTMLRenderer.body(for:generatedImage:)` (Task 2).
- Produces: `MarkdownHTMLRenderer.html(for text: String, title: String, generatedImage: GeneratedImageProvider) -> String`

- [ ] **Step 1: Write the failing test**

Append inside the test class:

```swift
    // MARK: Document shell

    func testHTMLHasDoctypeCharsetAndTitle() {
        let html = MarkdownHTMLRenderer.html(for: "# Hi", title: "My Notes", generatedImage: { _ in nil })
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains(#"<meta charset="utf-8">"#))
        XCTAssertTrue(html.contains("<title>My Notes</title>"))
        XCTAssertTrue(html.contains("<h1>Hi</h1>"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }

    func testTitleIsEscaped() {
        let html = MarkdownHTMLRenderer.html(for: "", title: "A & B <c>", generatedImage: { _ in nil })
        XCTAssertTrue(html.contains("<title>A &amp; B &lt;c&gt;</title>"))
    }

    func testShellEmbedsStylesAndReferencesNothingExternal() {
        let html = MarkdownHTMLRenderer.html(for: "# Hi", title: "t", generatedImage: { _ in nil })
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertFalse(html.contains("<link"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testMathEmbedsProvidedImageBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let html = MarkdownHTMLRenderer.html(for: "$$x^2$$", title: "t", generatedImage: { image in
            guard case .math = image else { return nil }
            return png
        })
        XCTAssertTrue(html.contains("data:image/png;base64,\(png.base64EncodedString())"))
        XCTAssertTrue(html.contains(#"alt="x^2""#))
    }

    func testMermaidFallsBackToSourceWhenProviderDeclines() {
        let html = MarkdownHTMLRenderer.html(
            for: "```mermaid\ngraph TD;\n```",
            title: "t",
            generatedImage: { _ in nil }
        )
        XCTAssertTrue(html.contains("graph TD;"))
        XCTAssertFalse(html.contains("data:"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHTMLRendererTests
```

Expected: build failure — no `html(for:title:generatedImage:)`.

- [ ] **Step 3: Write minimal implementation**

Append inside `enum MarkdownHTMLRenderer`:

```swift
    // MARK: Document

    /// A complete standalone HTML document. The stylesheet is embedded and nothing is fetched:
    /// no `<link>`, no `<script>`, no web fonts. The page is neutral light with a readable
    /// measure — the reader's theme is deliberately not carried, matching the rule that an
    /// exported PDF is always the white page.
    static func html(for text: String, title: String, generatedImage: GeneratedImageProvider) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body(for: text, generatedImage: generatedImage))
        </body>
        </html>
        """
    }

    private static let stylesheet = """
        body { max-width: 42em; margin: 3em auto; padding: 0 1.5em;
               font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
               color: #1a1a1a; background: #fff; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.5em; }
        p { margin: 0 0 1em; }
        img { max-width: 100%; height: auto; }
        a { color: #0645ad; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em;
               background: #f4f4f4; padding: 0.15em 0.35em; border-radius: 3px; }
        pre { background: #f4f4f4; padding: 1em; overflow-x: auto; border-radius: 4px; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0 0 1em; padding: 0.1em 1.2em; border-left: 3px solid #d0d0d0;
                     color: #444; }
        .callout { border-left-width: 4px; background: #f8f8f8; padding: 0.8em 1.2em; }
        .callout-title { font-weight: 600; margin-bottom: 0.4em; }
        table { border-collapse: collapse; margin: 0 0 1em; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 0.4em 0.7em; }
        th { background: #f4f4f4; }
        hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
        ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
        input[type="checkbox"] { margin-right: 0.4em; }
        """
```

- [ ] **Step 4: Run test to verify it passes**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/MarkdownHTMLRendererTests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Preview/MarkdownHTMLRenderer.swift LineformTests/MarkdownHTMLRendererTests.swift
git commit -m "Wrap emitted HTML in a self-contained document shell"
```

---

### Task 4: ExportFormat model and Export panel

**Files:**
- Modify: `Lineform/Editor/SaveAsExport.swift:7-57` (replace `SaveAsFormat`), `:145-239` (replace `SaveAsPanelController`)
- Modify: `LineformTests/SaveAsFormatDescriptionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `enum ExportFormat: Int, CaseIterable { case html, pdf, styledPDF, rtf }` with `title`, `description`, `pathExtension`, `contentType`, `usesPaper`
  - `final class ExportPanelController: NSObject` with `init(panel:baseName:format:paperTitles:selectedPaper:)` and `let paperPopup: NSPopUpButton`

- [ ] **Step 1: Write the failing test**

Replace the whole body of `LineformTests/SaveAsFormatDescriptionTests.swift`:

```swift
import XCTest
@testable import Lineform

final class SaveAsFormatDescriptionTests: XCTestCase {
    func testEveryFormatHasADistinctDescription() {
        let descriptions = ExportFormat.allCases.map(\.description)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
        XCTAssertEqual(Set(descriptions).count, ExportFormat.allCases.count)
    }

    func testStyledPDFDescriptionMentionsImages() {
        XCTAssertTrue(ExportFormat.styledPDF.description.lowercased().contains("image"))
    }

    func testPlainPDFDescriptionMentionsSource() {
        XCTAssertTrue(ExportFormat.pdf.description.lowercased().contains("source"))
    }

    func testMarkdownIsNotAnExportFormat() {
        // Markdown is Save As, not Export As. A "markdown" export entry would put two routes on
        // the same file and reintroduce the confusion the split exists to remove.
        XCTAssertFalse(ExportFormat.allCases.map(\.pathExtension).contains("md"))
    }

    func testHTMLFormatUsesHTMLExtensionAndNoPaper() {
        XCTAssertEqual(ExportFormat.html.pathExtension, "html")
        XCTAssertFalse(ExportFormat.html.usesPaper)
    }

    func testOnlyPDFFormatsUsePaper() {
        XCTAssertEqual(ExportFormat.allCases.filter(\.usesPaper), [.pdf, .styledPDF])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/SaveAsFormatDescriptionTests
```

Expected: build failure — `cannot find 'ExportFormat' in scope`.

- [ ] **Step 3: Write minimal implementation**

In `Lineform/Editor/SaveAsExport.swift`, replace `enum SaveAsFormat` (lines 7-57) with:

```swift
/// A target for File ▸ Export As. Markdown is deliberately absent: saving your document is
/// Save As, exporting a copy in another format is Export As, and keeping a Markdown entry here
/// would put two routes on the same file.
enum ExportFormat: Int, CaseIterable {
    case html, pdf, styledPDF, rtf

    var title: String {
        switch self {
        case .html: return "HTML"
        case .pdf: return "PDF"
        case .styledPDF: return "Styled PDF"
        case .rtf: return "Rich Text (.rtf)"
        }
    }

    /// Shown under the format's name in the export panel.
    var description: String {
        switch self {
        case .html: return "A web page — your image and link paths kept exactly as written."
        case .pdf: return "Plain markdown source — shows #, ** as typed."
        case .styledPDF: return "Rendered like Read mode — with images, tables, math & diagrams."
        case .rtf: return "Styled text for Word, Pages & Google Docs."
        }
    }

    var pathExtension: String {
        switch self {
        case .html: return "html"
        case .pdf, .styledPDF: return "pdf"
        case .rtf: return "rtf"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: return .html
        case .pdf, .styledPDF: return .pdf
        case .rtf: return .rtf
        }
    }

    var usesPaper: Bool { self == .pdf || self == .styledPDF }

    /// The menu row's SF Symbol (see `MainMenuIconDecorator`).
    var symbolName: String {
        switch self {
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .pdf: return "doc.plaintext"
        case .styledPDF: return "doc.richtext"
        case .rtf: return "textformat"
        }
    }
}
```

Then replace `final class SaveAsPanelController` (lines 145-239) with:

```swift
/// Owns the export panel's accessory: a one-line description of the chosen format, plus a Paper
/// Size popup for the two PDF formats. There is no Format popup — File ▸ Export As already chose
/// the format, so the panel only collects what is still open.
@MainActor
final class ExportPanelController: NSObject {
    let paperPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 25))
    private let format: ExportFormat

    init(panel: NSSavePanel, baseName: String, format: ExportFormat, paperTitles: [String], selectedPaper: Int) {
        self.format = format
        super.init()

        let name = baseName.isEmpty ? "Untitled" : baseName
        panel.nameFieldStringValue = "\(name).\(format.pathExtension)"
        panel.allowedContentTypes = [format.contentType]

        for title in paperTitles { paperPopup.addItem(withTitle: title) }
        if paperTitles.indices.contains(selectedPaper) { paperPopup.selectItem(at: selectedPaper) }
        paperPopup.setAccessibilityLabel("Paper Size")

        panel.accessoryView = makeAccessory()
    }

    private func makeAccessory() -> NSView {
        let description = NSTextField(wrappingLabelWithString: format.description)
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 11)
        description.alignment = .center
        description.isSelectable = false
        description.preferredMaxLayoutWidth = 280

        var views: [NSView] = [description]
        if format.usesPaper {
            let label = NSTextField(labelWithString: "Paper Size:")
            label.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [label, paperPopup])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            views.append(row)
        }

        // The accessory HUGS its content (no fixed width, no edge-pinning): NSSavePanel then
        // centers it horizontally, like TextEdit's format popup. Pinning it full-width
        // left-aligns it.
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        return stack
    }
}
```

This leaves `EditorContainerView.swift:1859` broken until Task 6; that is expected and Task 6 fixes it. To keep the tree building between commits, do Task 5 and Task 6 before running the full suite.

- [ ] **Step 4: Run test to verify it passes**

The app target will not compile yet (`EditorContainerView` still calls `SaveAsPanelController`). Verify the model compiles by type-checking the file only:

```sh
swiftc -parse Lineform/Editor/SaveAsExport.swift
```

Expected: no errors about `ExportFormat`. Full test run happens at the end of Task 6.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/SaveAsExport.swift LineformTests/SaveAsFormatDescriptionTests.swift
git commit -m "Replace SaveAsFormat with ExportFormat and a format-free export panel"
```

---

### Task 5: Export As submenu and icons

**Files:**
- Modify: `Lineform/App/LineformAppNotification.swift:19-20` (add case), `:29-77` (add name)
- Modify: `Lineform/App/AppCommands.swift:318-347` (save group)
- Modify: `Lineform/App/MainMenuIconDecorator.swift:189+` (`symbolsByTitle`)
- Modify: `LineformTests/MarkdownHTMLRendererTests.swift` (no) — instead create: `LineformTests/ExportMenuTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (serial `04B7` for the new test file)

**Interfaces:**
- Consumes: `ExportFormat` (Task 4).
- Produces: `LineformAppNotification.exportDocument`, posted with `Payload(value: String(format.rawValue))`.

- [ ] **Step 1: Write the failing test**

Create `LineformTests/ExportMenuTests.swift`:

```swift
import XCTest
@testable import Lineform

final class ExportMenuTests: XCTestCase {
    func testExportNotificationHasItsOwnName() {
        XCTAssertEqual(
            LineformAppNotification.exportDocument.name,
            Notification.Name("Lineform.exportDocument")
        )
        XCTAssertNotEqual(
            LineformAppNotification.exportDocument.name,
            LineformAppNotification.saveAsDocument.name
        )
    }

    func testEveryExportFormatRoundTripsThroughThePayloadValue() {
        // The menu row encodes its format in the payload's `value`; the handler decodes it.
        for format in ExportFormat.allCases {
            let encoded = String(format.rawValue)
            XCTAssertEqual(ExportFormat(rawValue: Int(encoded) ?? -1), format)
        }
    }

    func testEveryExportRowHasAMenuIcon() {
        for format in ExportFormat.allCases {
            let key = MainMenuIconDecorator.normalizedTitle(format.title)
            XCTAssertNotNil(
                MainMenuIconDecorator.symbolsByTitle[key],
                "No SF Symbol mapped for the \(format.title) export row (key: \(key))"
            )
        }
        XCTAssertNotNil(MainMenuIconDecorator.symbolsByTitle["export as"])
    }

    func testExportIconsAreDistinctFromEachOther() {
        let symbols = ExportFormat.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }
}
```

If `normalizedTitle` is `private`, make it `static` and internal (not `private`) in `MainMenuIconDecorator` so the test can call it — it is pure string normalization with no behavior of its own.

- [ ] **Step 2: Run test to verify it fails**

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:LineformTests/ExportMenuTests
```

Expected: build failure — `type 'LineformAppNotification' has no member 'exportDocument'`.

- [ ] **Step 3: Add the notification case**

In `Lineform/App/LineformAppNotification.swift`, add `case exportDocument` immediately after `case saveAsDocument` (line 20), and in the `name` switch add:

```swift
        case .exportDocument:
            return Notification.Name("Lineform.exportDocument")
```

- [ ] **Step 4: Add the menu**

In `Lineform/App/AppCommands.swift`, inside `CommandGroup(replacing: .saveItem)`, immediately after the Save As `Button` and its `.keyboardShortcut(...)` (line ~332) and **before** the `Divider()`, insert:

```swift
            // Export writes a COPY in another format and never touches the open document —
            // deliberately separate from Save As, which retargets the .md file itself. No
            // keyboard shortcuts: exporting is infrequent and a four-row submenu is already fast.
            Menu("Export As") {
                ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                    Button("\(format.title)...") {
                        LineformAppNotification.exportDocument.post(
                            object: LineformAppNotification.activeWindowPayload(value: String(format.rawValue))
                        )
                    }
                }
            }
```

- [ ] **Step 5: Add the icons**

In `Lineform/App/MainMenuIconDecorator.swift`, in `symbolsByTitle`, after the `"save as"` entry:

```swift
        // Export As pairs against Save: down means bytes land in your file, up means a copy leaves.
        "export as": "square.and.arrow.up",
        "html": "chevron.left.forwardslash.chevron.right",
        "pdf": "doc.plaintext",
        "styled pdf": "doc.richtext",
        "rich text (.rtf)": "textformat",
```

Confirm `normalizedTitle` strips the trailing `...` — if it does not, use keys that include it. Check the function before choosing the key text.

- [ ] **Step 6: Run test to verify it passes**

The app target still will not compile until Task 6. Run this after Task 6 completes.

- [ ] **Step 7: Commit**

```bash
git add Lineform/App/LineformAppNotification.swift Lineform/App/AppCommands.swift Lineform/App/MainMenuIconDecorator.swift LineformTests/ExportMenuTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add File > Export As submenu with per-format icons"
```

---

### Task 6: Wire Save As and Export As handlers

**Files:**
- Modify: `Lineform/Editor/EditorContainerView.swift:51-54` (error state), `:160-190` (alerts), `:388-391` (notification receivers), `:1855-1942` (handlers)

**Interfaces:**
- Consumes: `ExportFormat`, `ExportPanelController` (Task 4); `LineformAppNotification.exportDocument` (Task 5); `MarkdownHTMLRenderer.html(for:title:generatedImage:)` (Task 3).
- Produces: nothing downstream.

- [ ] **Step 1: Add the HTML error state**

Next to `rtfExportErrorFileName` (line 54) add:

```swift
    @State private var htmlExportErrorFileName: String?
```

And next to the RTF alert (lines ~178-186) add a matching alert — copy the RTF alert verbatim and change every `rtfExportErrorFileName` to `htmlExportErrorFileName` and the message's format name to HTML. Never cross-wire the states.

- [ ] **Step 2: Receive the notification**

Next to the `saveAsDocument` receiver (line ~388):

```swift
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.exportDocument.name)) { notification in
            guard isActiveWindow(notification) else { return }
            guard let raw = notificationPayloadValue(notification), let value = Int(raw),
                  let format = ExportFormat(rawValue: value) else { return }
            exportDocument(format)
        }
```

Match the existing receiver's window-scoping guard exactly — copy whatever line 389 uses rather than inventing one.

- [ ] **Step 3: Reduce saveAsDocument to Markdown only**

Replace `private func saveAsDocument()` (lines 1855-1942) with:

```swift
    /// File ▸ Save As… — retargets the document's own .md file. Markdown only: every other
    /// format is File ▸ Export As, which writes a copy and leaves this document alone.
    private func saveAsDocument() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = "\(base).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel's own "Replace?" warning is about the file on DISK; it says nothing about
            // that file also being open in another tab, whose stale snapshot would autosave right
            // back over whatever we write here. Refuse and name the tab instead of clobbering.
            // Checked against EVERY window's tabs, not just this one's.
            if let conflictingTab = SaveAsConflict.conflictingTabTitle(
                destination: url, tabs: EditorTabStore.allOpenTabs, activeTabID: tabStore.selectedTabID) {
                saveAsConflictTabTitle = conflictingTab
                return
            }
            // A real macOS "Save As": drive the backing document's own save-as so the write goes
            // through the FileDocument machinery (recordWrite → the savedAt observer re-points the
            // reload watcher and currentFileURL), and AppKit retargets NSDocument.fileURL — so the
            // open document (and an Untitled one) actually BECOMES this file, autosave following it.
            // A raw Data.write would leave the in-app document detached from the file on disk.
            if let backingDocument = activeWindow?.windowController?.document as? NSDocument {
                let fileType = LineformDocument.contentType(for: url).identifier
                backingDocument.save(to: url, ofType: fileType, for: .saveAsOperation) { error in
                    if error != nil { markdownSaveErrorFileName = url.lastPathComponent }
                }
            } else {
                do {
                    try Data(document.text.utf8).write(to: url, options: .atomic)
                } catch {
                    markdownSaveErrorFileName = url.lastPathComponent
                }
            }
        }

        if let window = activeWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }
```

- [ ] **Step 4: Add the export handler**

Immediately after `saveAsDocument()`:

```swift
    /// File ▸ Export As ▸ … — writes a COPY in the chosen format. The open document is never
    /// retargeted, so there is no cross-tab clobber to guard against: .html/.pdf/.rtf are not
    /// openable document types, so no tab can be holding one.
    private func exportDocument(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let controller = ExportPanelController(
            panel: panel,
            baseName: base,
            format: format,
            paperTitles: ExportPaperSize.allCases.map(\.displayName),
            selectedPaper: ExportPaperSize.allCases.firstIndex(of: defaultExportPaperSize) ?? 0
        )

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let paperIndex = controller.paperPopup.indexOfSelectedItem
            let paper = ExportPaperSize.allCases.indices.contains(paperIndex)
                ? ExportPaperSize.allCases[paperIndex] : .usLetter
            let dir = currentFileURL?.deletingLastPathComponent()

            switch format {
            case .html:
                let title = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
                let html = MarkdownHTMLRenderer.html(
                    for: document.text,
                    title: title,
                    generatedImage: { generated in
                        exportGeneratedImagePNG(generated)
                    }
                )
                do {
                    // Atomic: a failed write leaves no partial file, and any file being
                    // overwritten survives intact unless the write fully succeeds.
                    try Data(html.utf8).write(to: url, options: .atomic)
                } catch {
                    htmlExportErrorFileName = url.lastPathComponent
                }
            case .pdf, .styledPDF:
                let preset: ExportTypographyPreset = (format == .styledPDF) ? .styled : .standard
                // NSPrintOperation writes straight to its target, so a mid-write failure would
                // leave a truncated PDF — and when overwriting, would already have destroyed the
                // file that was there. Staging the render means a failure leaves it untouched.
                let runExport = {
                    let succeeded = DocumentExportRenderer.writePDFAtomically(
                        text: document.text,
                        profile: readingProfileStore.activeProfile,
                        paper: paper,
                        preset: preset,
                        documentDirectory: dir,
                        to: url
                    )
                    if !succeeded { pdfExportErrorFileName = url.lastPathComponent }
                }
                if format == .styledPDF {
                    withImageAccessGrantsIfNeeded(documentDirectory: dir, perform: runExport)
                } else {
                    runExport()
                }
            case .rtf:
                do {
                    let data = try DocumentExportRenderer.rtfData(
                        for: document, profile: readingProfileStore.activeProfile, paper: paper)
                    try data.write(to: url, options: .atomic)
                } catch {
                    rtfExportErrorFileName = url.lastPathComponent
                }
            }
        }

        if let window = activeWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    /// PNG bytes for a generated math/mermaid image, or nil so the emitter falls back to source
    /// text. This is the ONLY place HTML export produces image bytes — user-authored image paths
    /// are passed through untouched by the renderer and never read from disk.
    private func exportGeneratedImagePNG(_ generated: MarkdownHTMLRenderer.GeneratedImage) -> Data? {
        let image: NSImage?
        switch generated {
        case let .math(latex):
            guard case let .rendered(rendered, _) = mathImageProvider.outcome(
                latex: latex,
                style: .display,
                foreground: DiagramPalette.ink(isDark: false),
                pointSize: 16,
                scale: 2
            ) else { return nil }
            image = rendered
        case let .mermaid(source):
            guard case let .rendered(rendered) = mermaidImageProvider.outcome(
                source: source,
                background: .white,
                foreground: DiagramPalette.ink(isDark: false),
                scale: 2
            ) else { return nil }
            image = rendered
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
```

**Adapt the two `outcome(...)` calls to the real enums.** Read `MathRenderOutcome` and `MermaidRenderOutcome` in `Lineform/Preview/MathRendering.swift` and `MermaidRendering.swift` and match their exact case names and associated values — the shapes above are the expected form, not verified signatures. Likewise confirm how `EditorContainerView` already reaches a math/mermaid provider (it renders the preview, so one exists); reuse that reference rather than constructing a new provider per export.

- [ ] **Step 5: Build and run the focused tests**

```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS'
```

Expected: BUILD SUCCEEDED. Then:

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownHTMLRendererTests \
  -only-testing:LineformTests/ExportMenuTests \
  -only-testing:LineformTests/SaveAsFormatDescriptionTests
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/EditorContainerView.swift
git commit -m "Route Save As to Markdown and Export As to HTML/PDF/RTF"
```

---

### Task 7: Manual QA, full suite, and docs

**Files:**
- Modify: `docs/architecture/export-and-print.md`
- Modify: `Claude.md` (**note the lowercase filename** — `git add CLAUDE.md` stages nothing on this case-insensitive checkout and silently drops the edit)

- [ ] **Step 1: Build and drive the real app**

```sh
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -showBuildSettings | grep -m1 BUILT_PRODUCTS_DIR
```

Open a test document with the **full path** to the fresh build — never a bare `open`, which hands the file to whatever Lineform Launch Services prefers (usually an installed release) and reads exactly like the fix failing:

```sh
open -a "<BUILT_PRODUCTS_DIR>/Lineform.app" /tmp/html-export-qa.md
```

Use a document containing: headings, a nested list, a task list, a table with `:--`/`--:` alignment, a fenced code block with `<` in it, a blockquote, a `> [!WARNING]` callout, a relative-path image, a remote image URL, a link, inline math, and a mermaid block.

Verify by hand:
- File ▸ Save As… shows **no Format popup** and defaults to `.md`
- File ▸ Export As shows four rows, each with its icon, and the parent row has `square.and.arrow.up`
- Export As ▸ HTML… writes a file that opens in a browser with correct structure
- The exported HTML's `<img src>` for the relative image is **byte-identical to what the document says**
- Export As ▸ PDF… and ▸ Styled PDF… still show Paper Size; HTML and Rich Text do not
- All four exports leave the open document untouched (title bar shows no unsaved change, the `.md` on disk is unmodified)

- [ ] **Step 2: Fix anything the QA pass turns up**

Re-run the focused tests after each fix. If the submenu icons do **not** render, the cause is almost certainly `MainMenuIconDecorator`'s notification hook not firing for a submenu — do not "fix" it by walking `NSApp.mainMenu` on a tracking hook, which decorates the outgoing menu while the bare one is drawn (CLAUDE.md). Hook the submenu's own `NSMenu.didAddItemNotification` instead.

- [ ] **Step 3: Run the full default suite**

**Warn the user first:** a CLI test run re-signs the host ad-hoc and can raise a TCC prompt for Documents access that blocks the run. Do not run it unattended.

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

Expected: all tests pass. Report the exact count.

- [ ] **Step 4: Update the docs**

In `docs/architecture/export-and-print.md`, revise the "Save As with a Format picker" bullet: the picker is gone, Save As is Markdown-only, and export lives in File ▸ Export As. Keep every existing load-bearing note that still applies (the `.saveAsOperation` rule, `writePDFAtomically`, the `SaveAsConflict` guard now being Markdown-only, the hugging accessory). Add a short bullet for HTML export covering the one-to-one rule and why only math/mermaid embed.

In `Claude.md`, update the one Main Features line about Save As and its Format picker to describe Save As plus Export As with HTML. Add nothing else — no new invariant unless the work created a rule that can never be broken.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture/export-and-print.md Claude.md
git commit -m "Document HTML export and the Save As / Export As split"
```

---

## Self-Review

**Spec coverage:** Menu structure → Task 5. Panel behavior and paper size → Tasks 4, 6. `SaveAsConflict` staying Markdown-only → Task 6. Icons → Task 5 (map) and Task 7 (real-build verification, as the spec requires). One-to-one rule → Tasks 1-2 with dedicated tests. Block mapping table → Task 2. Math/mermaid embedding + injected provider → Tasks 2, 3, 6. Document shell → Task 3. Testing section → Tasks 1-3, 5. "Not doing" list → no task adds any of it.

**Type consistency:** `GeneratedImage` / `GeneratedImageProvider` / `body(for:generatedImage:)` / `html(for:title:generatedImage:)` are used identically in Tasks 1-3 and 6. `ExportFormat` and `ExportPanelController` are defined in Task 4 and consumed in Tasks 5-6 with matching signatures.

**Known unverified points**, flagged in-task rather than guessed: the exact `MathRenderOutcome` / `MermaidRenderOutcome` case shapes (Task 6 Step 4), whether `normalizedTitle` strips a trailing ellipsis (Task 5 Step 5), and whether the icon decorator's hook reaches a submenu (Task 7 Step 2).
