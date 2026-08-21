# Code Block Syntax Highlighting + Copy Button Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This feature shipped. Use `docs/architecture/rendering.md` for
> current behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give fenced code blocks calm, native, per-language syntax highlighting in Read/Preview modes plus a hover "Copy" pill, without adding a dependency, without touching Write mode, and without any bytes on disk or color in exported PDFs.

**Architecture:** A new dependency-free tokenizer (`Lineform/Preview/CodeHighlighting.swift`) behind the `CodeSyntaxHighlighting` protocol (mirroring `MathImageProviding` / `MermaidImageProviding`). A theme-derived `CodeSyntaxPalette` added to `DiagramCardStyle.swift`. A new `.fencedCode` case in `MarkdownBlockGrouping.swift` that routes plain ```` ``` ```` / `~~~` code fences out of `.lines` (parallel to how `mermaid` / `$$` math are already routed). A new `MarkdownPreviewRenderer.appendCodeBlock(...)` emitter gated by a threaded `highlightsCode` flag (true on screen, **false** from `DocumentExportRenderer`). A hover copy pill drawn as an overlay in `MarkdownPreviewTextView`, reusing the existing `.checkboxSourceRange` mouse/hit-test precedent (new `.codeBlockSourceRange` attribute).

**Tech Stack:** Swift, AppKit, TextKit, XCTest

## Global Constraints
- Native tokenizer only — **NO** new SPM dependency, no bundled grammar blobs. Compact per-language keyword sets + a shared UTF-16 scanner.
- **Read/Preview only.** The Write-mode highlighter (`MarkdownSyntaxHighlighter`) is untouched — the scoped, line-local Write invariant and typing performance are unaffected.
- **Export/PDF code stays MONOCHROME** — `DocumentExportRenderer` passes `highlightsCode: false`, so `appendCodeBlock` applies no token colors and the exported code is plain dark-ink monospace.
- **Display-only, zero bytes on disk.** Highlighting is pure `NSAttributedString` foreground attributes over ranges — no rasters, no cache, no images, and it never writes to the `.md` or to exports.
- **Line numbers are out of scope** (parked). No numbered gutter.
- **Non-code routing must stay byte-identical.** Only plain code fences change routing; prose, headings, inline constructs, mermaid, math, lists, blockquotes, tables are unchanged.
- Token ranges are **UTF-16 `NSRange`s** (scan via `NSString`) so they map straight onto `NSAttributedString` runs.
- The copy pill is an **overlay** (never part of the attributed string), so it never affects layout, selection, wrapping, or printed output. The pill is **manual-verified** (an overlay-drawn hover affordance is not unit-testable); everything else has unit tests.
- Follow existing seams and names exactly (`BlockRenderedAttachment`, `MermaidFence`, `appendBlockSeparator`, `.checkboxSourceRange`, `Theme.builtIn`, `usesDarkChrome`).

---

## Task 1 — `CodeSyntaxHighlighter` tokenizer: shared scanner + script/C-like languages

Covers Swift, JavaScript, TypeScript, Python, JSON, Bash (identifier/keyword + string + comment + number model). HTML/CSS are Task 2. New file `Lineform/Preview/CodeHighlighting.swift`.

**Files:**
- `Lineform/Preview/CodeHighlighting.swift` (new)
- `LineformTests/CodeSyntaxHighlighterTests.swift` (new)

**Interfaces:**
- Produces:
  - `enum CodeTokenKind { case keyword, string, comment, number, type, plain }`
  - `struct CodeToken: Equatable { let range: NSRange; let kind: CodeTokenKind }`
  - `protocol CodeSyntaxHighlighting { func tokens(for source: String, language: String) -> [CodeToken] }`
  - `struct CodeSyntaxHighlighter: CodeSyntaxHighlighting`
  - `enum CodeLanguage: String { case swift, javascript, typescript, python, json, bash, html, css }`
  - `enum CodeLanguageResolver { static func resolve(_ raw: String) -> CodeLanguage? }`
  - `enum CodeFence { static func language(fromOpening trimmedLine: String) -> String }`
  - `struct CodeGrammar` + static grammars `.swift`, `.javascriptLike`, `.python`, `.json`, `.bash`
  - `enum ScriptScanner { static func tokens(source: String, grammar: CodeGrammar) -> [CodeToken] }`

### Steps

- [ ] **Failing test** — create `LineformTests/CodeSyntaxHighlighterTests.swift`:

```swift
import XCTest
@testable import Lineform

final class CodeSyntaxHighlighterTests: XCTestCase {
    private let highlighter = CodeSyntaxHighlighter()

    /// The kinds covering `source`, one entry per token in order, for compact assertions.
    private func kinds(_ source: String, _ language: String) -> [CodeTokenKind] {
        highlighter.tokens(for: source, language: language).map { $0.kind }
    }

    /// The substrings each token covers, for exact-range assertions.
    private func slices(_ source: String, _ language: String) -> [(String, CodeTokenKind)] {
        let ns = source as NSString
        return highlighter.tokens(for: source, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    // MARK: - Language resolution / aliases

    func testLanguageResolutionAndAliases() {
        XCTAssertEqual(CodeLanguageResolver.resolve("swift"), .swift)
        XCTAssertEqual(CodeLanguageResolver.resolve("JS"), .javascript)
        XCTAssertEqual(CodeLanguageResolver.resolve("javascript"), .javascript)
        XCTAssertEqual(CodeLanguageResolver.resolve("ts"), .typescript)
        XCTAssertEqual(CodeLanguageResolver.resolve("py"), .python)
        XCTAssertEqual(CodeLanguageResolver.resolve("  Bash "), .bash)
        XCTAssertEqual(CodeLanguageResolver.resolve("shell"), .bash)
        XCTAssertEqual(CodeLanguageResolver.resolve("json"), .json)
        XCTAssertNil(CodeLanguageResolver.resolve("yaml"))
        XCTAssertNil(CodeLanguageResolver.resolve(""))
    }

    func testUnknownOrAbsentLanguageProducesNoTokens() {
        XCTAssertTrue(highlighter.tokens(for: "let x = 1", language: "yaml").isEmpty)
        XCTAssertTrue(highlighter.tokens(for: "let x = 1", language: "").isEmpty)
    }

    // MARK: - Fence language extraction

    func testFenceLanguageExtraction() {
        XCTAssertEqual(CodeFence.language(fromOpening: "```swift"), "swift")
        XCTAssertEqual(CodeFence.language(fromOpening: "~~~ts"), "ts")
        XCTAssertEqual(CodeFence.language(fromOpening: "``` js  extra"), "js")
        XCTAssertEqual(CodeFence.language(fromOpening: "```"), "")
        XCTAssertEqual(CodeFence.language(fromOpening: "not a fence"), "")
    }

    // MARK: - Swift

    func testSwiftKeywordStringCommentNumber() {
        let src = "let x = 42 // note\nlet s = \"hi\""
        let out = slices(src, "swift")
        XCTAssertTrue(out.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(out.contains { $0 == ("42", .number) })
        XCTAssertTrue(out.contains { $0 == ("// note", .comment) })
        XCTAssertTrue(out.contains { $0 == ("\"hi\"", .string) })
    }

    func testSwiftCapitalizedIdentifierIsType() {
        let out = slices("let v: MyType = go()", "swift")
        XCTAssertTrue(out.contains { $0 == ("MyType", .type) })
    }

    func testSwiftMultiLineBlockComment() {
        let out = slices("a\n/* one\ntwo */\nb", "swift")
        XCTAssertTrue(out.contains { $0 == ("/* one\ntwo */", .comment) })
    }

    // MARK: - JavaScript / TypeScript share a grammar

    func testJavaScriptAndTypeScriptTokenizeIdentically() {
        let src = "const n = 3.14; // pi"
        XCTAssertEqual(kinds(src, "js"), kinds(src, "ts"))
        XCTAssertTrue(slices(src, "js").contains { $0 == ("const", .keyword) })
        XCTAssertTrue(slices(src, "js").contains { $0 == ("3.14", .number) })
    }

    func testJavaScriptTemplateAndSingleQuoteStrings() {
        let out = slices("let a = 'x'; let b = `y`;", "js")
        XCTAssertTrue(out.contains { $0 == ("'x'", .string) })
        XCTAssertTrue(out.contains { $0 == ("`y`", .string) })
    }

    // MARK: - Python

    func testPythonHashCommentAndKeyword() {
        let out = slices("def f(): # hi\n    return 1", "python")
        XCTAssertTrue(out.contains { $0 == ("def", .keyword) })
        XCTAssertTrue(out.contains { $0 == ("return", .keyword) })
        XCTAssertTrue(out.contains { $0 == ("# hi", .comment) })
        XCTAssertTrue(out.contains { $0 == ("1", .number) })
    }

    // MARK: - JSON

    func testJsonStringsNumbersAndLiterals() {
        let out = slices("{\"k\": 12, \"b\": true}", "json")
        XCTAssertTrue(out.contains { $0 == ("\"k\"", .string) })
        XCTAssertTrue(out.contains { $0 == ("12", .number) })
        XCTAssertTrue(out.contains { $0 == ("true", .keyword) })
    }

    // MARK: - Bash

    func testBashHashCommentAndKeyword() {
        let out = slices("if true; then # go\n  echo \"hi\"\nfi", "bash")
        XCTAssertTrue(out.contains { $0 == ("if", .keyword) })
        XCTAssertTrue(out.contains { $0 == ("then", .keyword) })
        XCTAssertTrue(out.contains { $0 == ("# go", .comment) })
        XCTAssertTrue(out.contains { $0 == ("\"hi\"", .string) })
    }

    // MARK: - Non-overlap / ordering invariant

    func testTokensAreOrderedAndNonOverlapping() {
        let tokens = highlighter.tokens(for: "let x = \"a\" // c", language: "swift")
        var cursor = 0
        for t in tokens {
            XCTAssertGreaterThanOrEqual(t.range.location, cursor)
            cursor = NSMaxRange(t.range)
        }
    }
}
```

- [ ] **Run to fail:** `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CodeSyntaxHighlighterTests` → expect build failure (types undefined).

- [ ] **Minimal impl** — create `Lineform/Preview/CodeHighlighting.swift`:

```swift
import Foundation

/// A calm, dependency-free syntax tokenizer for fenced code blocks, rendered in Read/Preview only.
/// Isolated behind `CodeSyntaxHighlighting` (mirroring `MathImageProviding` / `MermaidImageProviding`).
/// Ranges are UTF-16 `NSRange`s so they map directly onto `NSAttributedString` runs. Operates on the
/// WHOLE fenced-block body — multi-line strings/comments are fine (this is a bounded block, NOT the
/// line-local Write highlighter).
enum CodeTokenKind: Equatable {
    case keyword, string, comment, number, type, plain
}

struct CodeToken: Equatable {
    let range: NSRange
    let kind: CodeTokenKind
}

protocol CodeSyntaxHighlighting {
    /// Non-overlapping token ranges for `source` in `language` (in order). Empty for unknown or
    /// absent languages (caller then renders monospace-only).
    func tokens(for source: String, language: String) -> [CodeToken]
}

/// Supported v1 languages after alias normalization.
enum CodeLanguage: String {
    case swift, javascript, typescript, python, json, bash, html, css
}

/// Normalize a fence info tag (lowercased, aliases) to a supported language, or nil.
enum CodeLanguageResolver {
    static func resolve(_ raw: String) -> CodeLanguage? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "swift": return .swift
        case "js", "javascript", "jsx", "node": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "py", "python", "python3": return .python
        case "json": return .json
        case "sh", "bash", "shell", "zsh", "shellscript": return .bash
        case "html", "xml", "xhtml": return .html
        case "css", "scss": return .css
        default: return nil
        }
    }
}

/// Extracts the first word of a fence's info string (the language tag), lowercased. "" when absent.
enum CodeFence {
    static func language(fromOpening trimmedLine: String) -> String {
        let marker: String
        if trimmedLine.hasPrefix("```") { marker = "```" }
        else if trimmedLine.hasPrefix("~~~") { marker = "~~~" }
        else { return "" }
        let info = trimmedLine.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)?.lowercased() ?? ""
    }
}

/// A compact per-language rule set for `ScriptScanner`. A few dozen bytes each — no external tables.
struct CodeGrammar {
    var keywords: Set<String> = []
    /// Known builtin/type identifiers rendered as `.type`.
    var types: Set<String> = []
    /// Line comment prefix, e.g. "//" or "#".
    var lineComment: String?
    /// Block comment delimiters, e.g. ("/*", "*/").
    var blockComment: (open: String, close: String)?
    /// String delimiter characters, e.g. ["\"", "'", "`"].
    var stringDelimiters: [unichar] = []
    /// When true, a Capitalized identifier that is not a keyword renders as `.type` (Swift/TS-ish).
    var capitalizedIdentifiersAreTypes: Bool = false

    static let swift = CodeGrammar(
        keywords: ["let", "var", "func", "return", "if", "else", "guard", "for", "while", "in",
                   "switch", "case", "default", "struct", "class", "enum", "protocol", "extension",
                   "import", "self", "init", "deinit", "static", "public", "private", "internal",
                   "fileprivate", "open", "final", "override", "throws", "throw", "try", "catch",
                   "do", "nil", "true", "false", "where", "as", "is", "some", "any", "async", "await",
                   "weak", "unowned", "lazy", "mutating", "typealias", "associatedtype", "defer"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: [0x22],
        capitalizedIdentifiersAreTypes: true
    )

    static let javascriptLike = CodeGrammar(
        keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
                   "switch", "case", "default", "break", "continue", "class", "extends", "new",
                   "this", "super", "import", "export", "from", "as", "async", "await", "yield",
                   "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "delete",
                   "void", "null", "undefined", "true", "false", "interface", "type", "enum",
                   "implements", "public", "private", "protected", "readonly", "namespace"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: [0x22, 0x27, 0x60],
        capitalizedIdentifiersAreTypes: true
    )

    static let python = CodeGrammar(
        keywords: ["def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
                   "class", "import", "from", "as", "with", "try", "except", "finally", "raise",
                   "lambda", "pass", "break", "continue", "yield", "global", "nonlocal", "assert",
                   "del", "is", "None", "True", "False", "async", "await", "self"],
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: [0x22, 0x27],
        capitalizedIdentifiersAreTypes: false
    )

    static let json = CodeGrammar(
        keywords: ["true", "false", "null"],
        lineComment: nil,
        blockComment: nil,
        stringDelimiters: [0x22],
        capitalizedIdentifiersAreTypes: false
    )

    static let bash = CodeGrammar(
        keywords: ["if", "then", "elif", "else", "fi", "for", "in", "do", "done", "while", "until",
                   "case", "esac", "function", "return", "exit", "echo", "export", "local", "read",
                   "cd", "source", "set", "unset", "true", "false", "break", "continue"],
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: [0x22, 0x27],
        capitalizedIdentifiersAreTypes: false
    )
}

/// A single-pass UTF-16 scanner for script/C-like languages. Emits non-overlapping tokens in order;
/// unmatched characters are simply not emitted (the caller leaves them at the default code color).
enum ScriptScanner {
    static func tokens(source: String, grammar: CodeGrammar) -> [CodeToken] {
        let s = source as NSString
        let n = s.length
        var tokens: [CodeToken] = []
        var i = 0

        func matches(_ literal: String, at index: Int) -> Bool {
            let lit = literal as NSString
            guard index + lit.length <= n else { return false }
            return s.substring(with: NSRange(location: index, length: lit.length)) == literal
        }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
        }
        func isIdentPart(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) }

        while i < n {
            let c = s.character(at: i)

            // Block comment (multi-line).
            if let bc = grammar.blockComment, matches(bc.open, at: i) {
                let start = i
                i += (bc.open as NSString).length
                while i < n && !matches(bc.close, at: i) { i += 1 }
                if i < n { i += (bc.close as NSString).length }
                tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }

            // Line comment.
            if let lc = grammar.lineComment, matches(lc, at: i) {
                let start = i
                while i < n && s.character(at: i) != 0x0A { i += 1 }
                tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }

            // String (respects backslash escapes; runs to matching delimiter or end-of-source, so a
            // template literal / triple-quote spanning lines is one string token).
            if grammar.stringDelimiters.contains(c) {
                let start = i
                i += 1
                while i < n {
                    let d = s.character(at: i)
                    if d == 0x5C { i += 2; continue }   // backslash escape
                    i += 1
                    if d == c { break }
                }
                tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            }

            // Number (integer/float/hex-ish; a leading identifier char never starts a number).
            if isDigit(c) {
                let start = i
                i += 1
                while i < n {
                    let d = s.character(at: i)
                    if isDigit(d) || d == 0x2E || d == 0x5F
                        || (d >= 0x61 && d <= 0x66) || (d >= 0x41 && d <= 0x46) // a-f / A-F (hex)
                        || d == 0x78 || d == 0x58 { i += 1 } else { break }      // x / X
                }
                tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: .number))
                continue
            }

            // Identifier / keyword / type.
            if isIdentStart(c) {
                let start = i
                i += 1
                while i < n && isIdentPart(s.character(at: i)) { i += 1 }
                let word = s.substring(with: NSRange(location: start, length: i - start))
                let kind: CodeTokenKind
                if grammar.keywords.contains(word) { kind = .keyword }
                else if grammar.types.contains(word) { kind = .type }
                else if grammar.capitalizedIdentifiersAreTypes, let f = word.unicodeScalars.first,
                        f.value >= 0x41 && f.value <= 0x5A { kind = .type }
                else { kind = .plain }
                if kind != .plain {
                    tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: kind))
                }
                continue
            }

            i += 1   // plain / punctuation / whitespace
        }
        return tokens
    }
}

/// The shipped tokenizer: normalizes the language then dispatches to the right grammar/scanner.
struct CodeSyntaxHighlighter: CodeSyntaxHighlighting {
    func tokens(for source: String, language: String) -> [CodeToken] {
        guard let lang = CodeLanguageResolver.resolve(language) else { return [] }
        switch lang {
        case .swift: return ScriptScanner.tokens(source: source, grammar: .swift)
        case .javascript, .typescript: return ScriptScanner.tokens(source: source, grammar: .javascriptLike)
        case .python: return ScriptScanner.tokens(source: source, grammar: .python)
        case .json: return ScriptScanner.tokens(source: source, grammar: .json)
        case .bash: return ScriptScanner.tokens(source: source, grammar: .bash)
        case .css: return ScriptScanner.tokens(source: source, grammar: CodeGrammar(lineComment: nil, blockComment: ("/*", "*/"), stringDelimiters: [0x22, 0x27]))
        case .html: return HTMLScanner.tokens(source: source)   // Task 2
        }
    }
}
```

> **Note:** the `.css` / `.html` arms above reference Task 2 output. Until Task 2 lands, temporarily stub `HTMLScanner` inside this file (`enum HTMLScanner { static func tokens(source: String) -> [CodeToken] { [] } }`) so Task 1 compiles; Task 2 replaces the stub with the real scanner in the same file. The `.css` grammar is finalized in Task 2.

- [ ] **Run to pass:** same `-only-testing:LineformTests/CodeSyntaxHighlighterTests` command → all green. Report exact count.
- [ ] **Register the new files** in `Lineform.xcodeproj/project.pbxproj` (4 sections, sequential `1F0000xx` IDs — see the `pbxproj-handrolled-ids` memory note): `CodeHighlighting.swift` in the app target, `CodeSyntaxHighlighterTests.swift` in the test target.
- [ ] **Commit:** `Code highlighting: dependency-free tokenizer + script-language grammars`

---

## Task 2 — HTML + CSS markup scanners

HTML needs a tag-aware scanner (the generic ident/keyword model does not fit markup). CSS is handled by the generic `ScriptScanner` with a CSS grammar; this task finalizes and tests it.

**Files:**
- `Lineform/Preview/CodeHighlighting.swift` (replace the `HTMLScanner` stub; finalize the `.css` grammar in `CodeSyntaxHighlighter`)
- `LineformTests/CodeSyntaxHighlighterTests.swift` (extend)

**Interfaces:**
- Produces: `enum HTMLScanner { static func tokens(source: String) -> [CodeToken] }`

### Steps

- [ ] **Failing test** — append to `CodeSyntaxHighlighterTests.swift`:

```swift
extension CodeSyntaxHighlighterTests {
    func testHTMLTagsCommentsAndAttributeValues() {
        let src = "<!-- c -->\n<a href=\"x\">hi</a>"
        let ns = src as NSString
        let out = highlighter.tokens(for: src, language: "html").map { (ns.substring(with: $0.range), $0.kind) }
        XCTAssertTrue(out.contains { $0 == ("<!-- c -->", .comment) })
        XCTAssertTrue(out.contains { $0 == ("a", .keyword) })      // tag name (open)
        XCTAssertTrue(out.contains { $0 == ("\"x\"", .string) })   // attribute value
        XCTAssertTrue(out.contains { $0 == ("a", .keyword) && true }) // closing </a> tag name too
    }

    func testHTMLPlainTextBetweenTagsIsNotTokenized() {
        // "hi" between tags produces no token (stays default code color).
        let tokens = highlighter.tokens(for: "<b>hi</b>", language: "html")
        let ns = "<b>hi</b>" as NSString
        XCTAssertFalse(tokens.contains { ns.substring(with: $0.range) == "hi" })
    }

    func testCSSCommentStringAndNumber() {
        let src = "/* c */\n.a { color: \"red\"; width: 12px; }"
        let ns = src as NSString
        let out = highlighter.tokens(for: src, language: "css").map { (ns.substring(with: $0.range), $0.kind) }
        XCTAssertTrue(out.contains { $0 == ("/* c */", .comment) })
        XCTAssertTrue(out.contains { $0 == ("\"red\"", .string) })
        XCTAssertTrue(out.contains { $0.1 == .number })   // 12 (px suffix handled by number scan)
    }

    func testUnknownLanguageStillEmptyAfterMarkupAdded() {
        XCTAssertTrue(highlighter.tokens(for: "<a>", language: "yaml").isEmpty)
    }
}
```

- [ ] **Run to fail:** `-only-testing:LineformTests/CodeSyntaxHighlighterTests/testHTMLTagsCommentsAndAttributeValues` → fail (stub returns `[]`).

- [ ] **Minimal impl** — replace the `HTMLScanner` stub in `CodeHighlighting.swift`:

```swift
/// A light HTML/XML scanner: comments `<!-- -->` → `.comment`, tag names (open/close) → `.keyword`,
/// quoted attribute values → `.string`. Text between tags stays untokenized (default code color).
enum HTMLScanner {
    static func tokens(source: String) -> [CodeToken] {
        let s = source as NSString
        let n = s.length
        var tokens: [CodeToken] = []
        var i = 0

        func matches(_ literal: String, at index: Int) -> Bool {
            let lit = literal as NSString
            guard index + lit.length <= n else { return false }
            return s.substring(with: NSRange(location: index, length: lit.length)) == literal
        }
        func isNameStart(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }
        func isNamePart(_ c: unichar) -> Bool {
            isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x3A
        }

        while i < n {
            // Comment.
            if matches("<!--", at: i) {
                let start = i
                i += 4
                while i < n && !matches("-->", at: i) { i += 1 }
                if i < n { i += 3 }
                tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            // Tag: `<name ...>` or `</name>`.
            if s.character(at: i) == 0x3C {   // '<'
                i += 1
                if i < n && s.character(at: i) == 0x2F { i += 1 }   // '/'
                if i < n && isNameStart(s.character(at: i)) {
                    let nameStart = i
                    i += 1
                    while i < n && isNamePart(s.character(at: i)) { i += 1 }
                    tokens.append(CodeToken(range: NSRange(location: nameStart, length: i - nameStart), kind: .keyword))
                }
                // Inside the tag: emit quoted attribute values as strings until '>'.
                while i < n && s.character(at: i) != 0x3E {   // '>'
                    let c = s.character(at: i)
                    if c == 0x22 || c == 0x27 {               // '"' or '\''
                        let start = i
                        i += 1
                        while i < n && s.character(at: i) != c { i += 1 }
                        if i < n { i += 1 }
                        tokens.append(CodeToken(range: NSRange(location: start, length: i - start), kind: .string))
                    } else {
                        i += 1
                    }
                }
                if i < n { i += 1 }   // consume '>'
                continue
            }
            i += 1
        }
        return tokens
    }
}
```

- [ ] Finalize the `.css` arm in `CodeSyntaxHighlighter.tokens(for:language:)` (keep it small — comments/strings/numbers only; selectors/properties stay `.plain`):

```swift
        case .css:
            return ScriptScanner.tokens(source: source, grammar: CodeGrammar(
                keywords: [],
                types: [],
                lineComment: nil,
                blockComment: ("/*", "*/"),
                stringDelimiters: [0x22, 0x27],
                capitalizedIdentifiersAreTypes: false
            ))
```

- [ ] **Run to pass:** `-only-testing:LineformTests/CodeSyntaxHighlighterTests` (whole class) → all green.
- [ ] **Commit:** `Code highlighting: HTML tag scanner + CSS grammar`

---

## Task 3 — `CodeSyntaxPalette` + AA contrast test

Maps `CodeTokenKind → NSColor`, derived from the theme, muted, light/dark aware. Added to `DiagramCardStyle.swift` alongside `DiagramPalette`. `.plain` returns the theme's own text color (unchanged code foreground). AA-verified against every `Theme.builtIn` background.

**Files:**
- `Lineform/Preview/DiagramCardStyle.swift` (add `CodeSyntaxPalette` after `DiagramPalette`, ~line 48)
- `LineformTests/CodeSyntaxPaletteContrastTests.swift` (new)

**Interfaces:**
- Consumes: `Theme` (`.textColor`, `.backgroundColor`, `.usesDarkChrome`), `CodeTokenKind`
- Produces: `enum CodeSyntaxPalette { static func color(for kind: CodeTokenKind, theme: Theme) -> NSColor }`

### Steps

- [ ] **Failing test** — create `LineformTests/CodeSyntaxPaletteContrastTests.swift`:

```swift
import XCTest
import AppKit
@testable import Lineform

final class CodeSyntaxPaletteContrastTests: XCTestCase {
    /// Every colored token role must clear WCAG AA (4.5:1) against every built-in theme's code
    /// background (the theme's own page color — code has no distinct box).
    func testEveryTokenColorMeetsAAAgainstEveryThemeBackground() {
        let coloredKinds: [CodeTokenKind] = [.keyword, .string, .comment, .number, .type]
        for theme in Theme.builtIn {
            for kind in coloredKinds {
                let fg = CodeSyntaxPalette.color(for: kind, theme: theme)
                let ratio = Self.contrastRatio(fg, theme.backgroundColor)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(kind) on \(theme.name) was \(ratio)"
                )
            }
        }
    }

    func testPlainReusesThemeTextColor() {
        for theme in Theme.builtIn {
            XCTAssertEqual(
                CodeSyntaxPalette.color(for: .plain, theme: theme),
                theme.textColor
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

- [ ] **Run to fail:** `-only-testing:LineformTests/CodeSyntaxPaletteContrastTests` → fail (undefined `CodeSyntaxPalette`).

- [ ] **Minimal impl** — add to `DiagramCardStyle.swift` (after `DiagramPalette`):

```swift
/// Muted, monochrome-leaning token colors for fenced-code highlighting in Read/Preview. Derived
/// from the theme (light/dark aware), restrained so code reads calm rather than rainbow. `.plain`
/// reuses the theme's own text color (unchanged code foreground). Every colored role is AA-verified
/// against every `Theme.builtIn` background (`CodeSyntaxPaletteContrastTests`). Display-only.
enum CodeSyntaxPalette {
    static func color(for kind: CodeTokenKind, theme: Theme) -> NSColor {
        let dark = theme.usesDarkChrome
        switch kind {
        case .plain:
            return theme.textColor
        case .keyword:
            // A muted plum/violet — the one role allowed a little hue.
            return dark ? NSColor(srgbRed: 0.78, green: 0.62, blue: 0.86, alpha: 1)
                        : NSColor(srgbRed: 0.42, green: 0.24, blue: 0.55, alpha: 1)
        case .string:
            // Muted green.
            return dark ? NSColor(srgbRed: 0.55, green: 0.80, blue: 0.60, alpha: 1)
                        : NSColor(srgbRed: 0.16, green: 0.44, blue: 0.24, alpha: 1)
        case .comment:
            // Low-chroma grey — deliberately the quietest role, still AA.
            return dark ? NSColor(srgbRed: 0.58, green: 0.60, blue: 0.60, alpha: 1)
                        : NSColor(srgbRed: 0.42, green: 0.44, blue: 0.44, alpha: 1)
        case .number:
            // Muted amber/brown.
            return dark ? NSColor(srgbRed: 0.85, green: 0.70, blue: 0.48, alpha: 1)
                        : NSColor(srgbRed: 0.55, green: 0.38, blue: 0.12, alpha: 1)
        case .type:
            // Muted teal/blue.
            return dark ? NSColor(srgbRed: 0.55, green: 0.76, blue: 0.82, alpha: 1)
                        : NSColor(srgbRed: 0.15, green: 0.40, blue: 0.50, alpha: 1)
        }
    }
}
```

> If any role fails AA on a specific theme, darken the light variant / lighten the dark variant until the test is green — keep the test as the source of truth (same discipline as `EditorStatusColors`). The lightest light background is `LineformColors.originalBackground`/`paperBackground` and the darkest dark is Night (`white 0.09`); tune against those two extremes.

- [ ] **Run to pass:** `-only-testing:LineformTests/CodeSyntaxPaletteContrastTests` → green. Register the new test file in the pbxproj test target.
- [ ] **Commit:** `Code highlighting: theme-derived CodeSyntaxPalette + AA contrast test`

---

## Task 4 — `.fencedCode` block routing in `MarkdownBlockGrouping`

Route plain ```` ``` ```` / `~~~` code fences out of `.lines` into a new `.fencedCode` case (parallel to mermaid/math). This is the one structural change; existing grouping tests that assumed fenced code stayed in `.lines` are **updated** to the new routing, and new tests prove non-code routing (mermaid, math, prose, lists, tables, blockquotes, rules) stays byte-identical.

**Files:**
- `Lineform/Preview/MarkdownBlockGrouping.swift` (add the enum case ~line 36; add the fence split in `markdownBlocks(in:)` — new branch placed AFTER the mermaid branch, ~line 308, and BEFORE the table/rule/quote/list branches; keep it gated on `!inFence`)
- `LineformTests/MarkdownBlockGroupingTests.swift` (update fence-related tests; add `.fencedCode` tests)

**Interfaces:**
- Consumes: `MermaidFence.isFenceDelimiter`, `MermaidFence.isMermaidOpening`, `CodeFence.language(fromOpening:)`
- Produces: `case fencedCode(language: String, body: String, openingIndex: Int, closingIndex: Int?)` on `MarkdownBlock`

### Steps

- [ ] **Failing/updated tests** — in `MarkdownBlockGroupingTests.swift`:
  - Replace `testFencedCodeStaysInsideALinesRun` with:

```swift
    func testPlainCodeFenceBecomesFencedCodeBlock() {
        XCTAssertEqual(
            markdownBlocks(in: ["before", "```", "code", "```", "after"]),
            [.lines(0..<1),
             .fencedCode(language: "", body: "code", openingIndex: 1, closingIndex: 3),
             .lines(4..<5)]
        )
    }

    func testCodeFenceCarriesLanguageTag() {
        XCTAssertEqual(
            markdownBlocks(in: ["```swift", "let x = 1", "```"]),
            [.fencedCode(language: "swift", body: "let x = 1", openingIndex: 0, closingIndex: 2)]
        )
    }

    func testMultiLineCodeBodyIsJoinedByNewline() {
        XCTAssertEqual(
            markdownBlocks(in: ["```js", "a", "b", "```"]),
            [.fencedCode(language: "js", body: "a\nb", openingIndex: 0, closingIndex: 3)]
        )
    }

    func testUnclosedCodeFenceHasNilClosingIndex() {
        XCTAssertEqual(
            markdownBlocks(in: ["```py", "x = 1"]),
            [.fencedCode(language: "py", body: "x = 1", openingIndex: 0, closingIndex: nil)]
        )
    }

    func testEmptyCodeFenceHasEmptyBody() {
        XCTAssertEqual(
            markdownBlocks(in: ["```", "```"]),
            [.fencedCode(language: "", body: "", openingIndex: 0, closingIndex: 1)]
        )
    }
```

  - Update the tests that relied on fenced code staying in `.lines`, so their expectations reflect `.fencedCode` while proving the *inner* content is NOT mis-parsed as math/rule/quote/table (the real invariant those tests protect):

```swift
    func testDollarInsideCodeFenceIsNotMath() {
        // `$$` inside a code fence stays code, not a math block.
        XCTAssertEqual(
            markdownBlocks(in: ["```", "$$", "```"]),
            [.fencedCode(language: "", body: "$$", openingIndex: 0, closingIndex: 2)]
        )
    }

    func testDashesInsideCodeFenceAreNotRule() {
        XCTAssertEqual(
            markdownBlocks(in: ["```", "---", "```"]),
            [.fencedCode(language: "", body: "---", openingIndex: 0, closingIndex: 2)]
        )
    }

    func testBlockquoteInsideCodeFenceIsNotAQuote() {
        XCTAssertEqual(
            markdownBlocks(in: ["```", "> a", "```"]),
            [.fencedCode(language: "", body: "> a", openingIndex: 0, closingIndex: 2)]
        )
    }

    func testPipesInsideCodeFenceAreNotATable() {
        XCTAssertEqual(
            markdownBlocks(in: ["```", "| a | b |", "|---|---|", "```"]),
            [.fencedCode(language: "", body: "| a | b |\n|---|---|", openingIndex: 0, closingIndex: 3)]
        )
    }
```

  - Add a byte-identity guard for non-code routing (mermaid + math + prose unchanged):

```swift
    func testNonCodeConstructsRouteUnchangedAlongsideCode() {
        let blocks = markdownBlocks(in: [
            "intro",
            "```mermaid", "graph TD;A-->B;", "```",
            "```swift", "let x = 1", "```",
            "$$", "y^2", "$$",
            "- item"
        ])
        XCTAssertEqual(blocks[0], .lines(0..<1))
        XCTAssertEqual(blocks[1], .mermaid(source: "graph TD;A-->B;", closingIndex: 3))
        XCTAssertEqual(blocks[2], .fencedCode(language: "swift", body: "let x = 1", openingIndex: 4, closingIndex: 6))
        XCTAssertEqual(blocks[3], .fencedMath(latex: "y^2", closingIndex: 9))
        guard case .list = blocks[4] else { return XCTFail("expected a list") }
    }
```

- [ ] **Run to fail:** `-only-testing:LineformTests/MarkdownBlockGroupingTests` → fail (undefined `.fencedCode`).

- [ ] **Minimal impl** — in `MarkdownBlockGrouping.swift`:
  - Add the case to `MarkdownBlock`:

```swift
    /// A plain ``` / ~~~ fenced code block (NOT mermaid — that is routed separately above).
    /// `language` is the fence's info tag (lowercased first word, "" when absent), `body` is the
    /// inner lines joined by "\n", `openingIndex` is the opening fence line, and `closingIndex` is
    /// the closing fence line or `nil` when the block ran to end-of-document unclosed.
    case fencedCode(language: String, body: String, openingIndex: Int, closingIndex: Int?)
```

  - Insert a new branch in `markdownBlocks(in:)`, immediately AFTER the `MermaidFence.isMermaidOpening` branch (so mermaid still wins) and BEFORE the table branch. It must be gated `!inFence` and must NOT itself be a mermaid opening (already excluded, since mermaid was checked first):

```swift
        if !inFence, MermaidFence.isFenceDelimiter(trimmed) {
            // A plain code fence: consume to the next fence delimiter as its own block so it renders
            // through appendCodeBlock (highlighting + copy pill), parallel to mermaid/math routing.
            flushLines(upTo: index)
            let language = CodeFence.language(fromOpening: trimmed)
            var body: [String] = []
            var cursor = index + 1
            var closing: Int?
            while cursor < lines.count {
                if MermaidFence.isFenceDelimiter(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    closing = cursor
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            blocks.append(.fencedCode(
                language: language,
                body: body.joined(separator: "\n"),
                openingIndex: index,
                closingIndex: closing
            ))
            index = (closing ?? lines.count - 1) + 1
            continue
        }
```

  - **Remove** the now-dead fence-toggle at the bottom of the loop (the `if MermaidFence.isFenceDelimiter(trimmed) { inFence.toggle() }` before `linesStart = index`): with code fences consumed into `.fencedCode`, an opening fence never reaches that tail. The `inFence` variable itself stays (still read by the `!inFence` guards) but is never set true anymore — **delete `var inFence` and every `!inFence` guard**, simplifying each special-block branch to run unconditionally, since a code fence is now consumed wholesale before any inner line is inspected. Verify each existing "inside a code fence" test (updated above) still passes, proving inner `$$` / `---` / `>` / `|` lines are captured as `body` and never re-parsed.

> **Rationale for deleting `inFence`:** previously `inFence` existed so that `$$`, mermaid, rules, quotes, and tables were ignored *while scanning through* a code fence line-by-line inside a `.lines` run. Now the entire fence (opening → closing) is consumed in one branch before the loop advances, so no inner line is ever visited by the special-block checks. Keep the deletion surgical and re-run the full grouping suite to confirm.

- [ ] **Run to pass:** `-only-testing:LineformTests/MarkdownBlockGroupingTests` → all green. Report count.
- [ ] **Commit:** `Code highlighting: route plain code fences to a .fencedCode block`

---

## Task 5 — `appendCodeBlock` render + `highlightsCode` flag + export-monochrome test

Thread a `highlightsCode` flag through `MarkdownPreviewRenderer.render(...)`, add the `.fencedCode` dispatch arm, and implement `appendCodeBlock`: monospace body (fence delimiter lines hidden, like other markup), token colors applied only when `highlightsCode` and the language is recognized, and a `.codeBlockSourceRange` attribute for the copy pill. `DocumentExportRenderer` passes `highlightsCode: false` → monochrome.

**Files:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift` (add `.codeBlockSourceRange` key ~line 11; add `highlightsCode` + `codeHighlighter` params to `render` ~line 47; add the `.fencedCode` dispatch arm ~line 146; add `appendCodeBlock` sibling of `appendMermaidBlock` ~line 466)
- `Lineform/Preview/DocumentExportRenderer.swift` (pass `highlightsCode: false` in `makeExportTextView`, ~line 102)
- `Lineform/Preview/MarkdownPreviewViewRepresentable.swift` (on-screen render already defaults `highlightsCode: true` — no change needed if the default is true; confirm)
- `LineformTests/MarkdownPreviewRendererTests.swift` (extend)

**Interfaces:**
- Consumes: `CodeSyntaxHighlighting` (default `CodeSyntaxHighlighter()`), `CodeSyntaxPalette.color(for:theme:)`, `MarkdownBlock.fencedCode`, existing `codeAttributes`, `lineRanges`
- Produces:
  - `static let codeBlockSourceRange = NSAttributedString.Key("lineform.codeBlockSourceRange")`
  - `render(..., highlightsCode: Bool = true, codeHighlighter: CodeSyntaxHighlighting = CodeSyntaxHighlighter())`
  - `private func appendCodeBlock(language:body:openingIndex:closingIndex:to:lines:lineRanges:profile:theme:highlightsCode:codeHighlighter:codeAttributes:codeBlockSpacingAttributes:blockSpacingLineIndexes:)`

### Steps

- [ ] **Failing test** — append to `MarkdownPreviewRendererTests.swift`:

```swift
extension MarkdownPreviewRendererTests {
    private func renderReadMode(_ text: String, highlightsCode: Bool = true) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 600,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            reportRegistry: DiagramReportRegistry(),
            appVersion: "0",
            highlightsCode: highlightsCode
        )
    }

    /// The set of distinct non-nil foreground colors applied over the rendered code body.
    private func codeForegroundColors(in attributed: NSAttributedString, bodySubstring: String) -> Set<NSColor> {
        let full = attributed.string as NSString
        let bodyRange = full.range(of: bodySubstring)
        guard bodyRange.location != NSNotFound else { return [] }
        var colors: Set<NSColor> = []
        attributed.enumerateAttribute(.foregroundColor, in: bodyRange, options: []) { value, _, _ in
            if let c = value as? NSColor { colors.insert(c) }
        }
        return colors
    }

    func testReadModeCodeIsMultiColored() {
        let out = renderReadMode("```swift\nlet x = 42\n```")
        // Highlighted code uses more than one foreground color (keyword + number + plain).
        XCTAssertGreaterThan(codeForegroundColors(in: out, bodySubstring: "let x = 42").count, 1)
    }

    func testExportModeCodeIsMonochrome() {
        let out = renderReadMode("```swift\nlet x = 42\n```", highlightsCode: false)
        // No coloring: the body is a single foreground color (the theme's code ink).
        XCTAssertEqual(codeForegroundColors(in: out, bodySubstring: "let x = 42").count, 1)
    }

    func testUnknownLanguageCodeIsMonochromeEvenInReadMode() {
        let out = renderReadMode("```yaml\nkey: value\n```")
        XCTAssertEqual(codeForegroundColors(in: out, bodySubstring: "key: value").count, 1)
    }

    func testFenceDelimitersAreNotRendered() {
        let out = renderReadMode("```swift\nlet x = 1\n```")
        XCTAssertFalse(out.string.contains("```"))
    }

    func testCodeBlockCarriesSourceRangeAttribute() {
        let out = renderReadMode("```swift\nlet x = 1\n```")
        let full = out.string as NSString
        let bodyRange = full.range(of: "let x = 1")
        var found: NSRange?
        out.enumerateAttribute(.codeBlockSourceRange, in: bodyRange, options: []) { value, _, stop in
            if let v = value as? NSValue { found = v.rangeValue; stop.pointee = true }
        }
        // Source range points at the body within the ORIGINAL text ("```swift\n" is 9 UTF-16 units).
        XCTAssertEqual(found, NSRange(location: 9, length: ("let x = 1" as NSString).length))
    }
}
```

- [ ] **Run to fail:** `-only-testing:LineformTests/MarkdownPreviewRendererTests` → fail (unknown `highlightsCode` label / missing attribute).

- [ ] **Minimal impl** — in `MarkdownPreviewRenderer.swift`:
  - Add the attribute key in the existing `extension NSAttributedString.Key`:

```swift
    /// Attached to a rendered fenced-code body; value is an `NSValue` boxing the `NSRange` of the
    /// code body in the SOURCE document, so the hover copy pill can copy the raw code.
    static let codeBlockSourceRange = NSAttributedString.Key("lineform.codeBlockSourceRange")
```

  - Add the two params to the full `render(...)` signature (defaults keep every existing caller working):

```swift
        appVersion: String,
        fitTablesToWidth: Bool = false,
        // True on screen (Read/Preview) → code is syntax-highlighted; false from
        // DocumentExportRenderer → code stays MONOCHROME in PDFs (user decision).
        highlightsCode: Bool = true,
        codeHighlighter: CodeSyntaxHighlighting = CodeSyntaxHighlighter()
    ) -> NSAttributedString {
```

  - Add the dispatch arm in the `for block in markdownBlocks(in: lines)` switch (after `.table`):

```swift
            case .fencedCode(let language, let body, let openingIndex, let closingIndex):
                appendCodeBlock(
                    language: language,
                    body: body,
                    openingIndex: openingIndex,
                    to: output,
                    lineRanges: lineRanges,
                    theme: theme,
                    highlightsCode: highlightsCode,
                    codeHighlighter: codeHighlighter,
                    codeAttributes: codeAttributes
                )
                appendBlockSeparator(afterLine: closingIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)
```

  - Add the emitter (sibling of `appendMermaidBlock`):

```swift
    /// Emit a fenced code block: monospace body (fence delimiter lines hidden, like other markup),
    /// optionally syntax-highlighted. Highlighting is pure foreground color over token ranges —
    /// display-only, no rasters, nothing written to disk. The whole body carries a
    /// `.codeBlockSourceRange` attribute (the body's range in the SOURCE document) so the hover copy
    /// pill can copy the raw code.
    private func appendCodeBlock(
        language: String,
        body: String,
        openingIndex: Int,
        to output: NSMutableAttributedString,
        lineRanges: [NSRange],
        theme: Theme,
        highlightsCode: Bool,
        codeHighlighter: CodeSyntaxHighlighting,
        codeAttributes: [NSAttributedString.Key: Any]
    ) {
        guard !body.isEmpty else { return }   // empty fence → nothing to render or copy

        let runStart = output.length
        let coded = NSMutableAttributedString(string: body, attributes: codeAttributes)

        // Syntax colors only on screen (highlightsCode) and only for a recognized language; export
        // and unknown languages stay monochrome (the codeAttributes foreground is untouched).
        if highlightsCode {
            for token in codeHighlighter.tokens(for: body, language: language) where token.kind != .plain {
                guard NSMaxRange(token.range) <= (body as NSString).length else { continue }
                coded.addAttribute(.foregroundColor, value: CodeSyntaxPalette.color(for: token.kind, theme: theme), range: token.range)
            }
        }

        // The body's range in the ORIGINAL document = the first body line's source start + body
        // length (body lines are contiguous, separated by "\n", exactly as joined during grouping).
        let bodyStart = openingIndex + 1 < lineRanges.count ? lineRanges[openingIndex + 1].location : lineRanges[openingIndex].location
        let sourceRange = NSRange(location: bodyStart, length: (body as NSString).length)
        coded.addAttribute(.codeBlockSourceRange, value: NSValue(range: sourceRange), range: NSRange(location: 0, length: coded.length))

        output.append(coded)
        _ = runStart
    }
```

  - In `DocumentExportRenderer.makeExportTextView`, add `highlightsCode: false` to the `render(...)` call (after `fitTablesToWidth: true`):

```swift
            fitTablesToWidth: true,
            highlightsCode: false
```

  - Confirm the on-screen path in `MarkdownPreviewTextView.apply` calls `render(...)` without `highlightsCode` (so it defaults to `true`) — no change needed.

- [ ] **Run to pass:** `-only-testing:LineformTests/MarkdownPreviewRendererTests` → green. Report count.
- [ ] **Commit:** `Code highlighting: appendCodeBlock render + highlightsCode flag (export monochrome)`

---

## Task 6 — Hover copy pill in `MarkdownPreviewTextView` (manual-verified)

An overlay-drawn "Copy" pill in the top-right of the hovered code block, reusing the view's existing mouse tracking + `NSLayoutManager` rect hit-testing (the `.checkboxSourceRange` precedent). On click it copies the block's raw source (sliced from the retained source text via the `.codeBlockSourceRange` attribute) to `NSPasteboard` and briefly flips the label to "Copied". **This is manual-verified** — an overlay-drawn hover affordance is not unit-testable; there are no new automated tests in this task, only a targeted manual QA pass.

**Files:**
- `Lineform/Preview/MarkdownPreviewViewRepresentable.swift` (`MarkdownPreviewTextView` — add hover tracking + overlay pill; the view already retains the source as `renderedText`)

**Interfaces:**
- Consumes: `.codeBlockSourceRange` attribute (source `NSRange`), `renderedText` (== source markdown), `activeProfile`/`Theme.theme(for:).usesDarkChrome`, `NSTrackingArea`, `NSLayoutManager.boundingRect(forGlyphRange:in:)`
- Produces: an overlay pill (a child `NSView` or `draw`-time drawn control) that never enters the attributed string.

### Steps (implementation — no failing test; manual QA gate at the end)

- [ ] Add mouse-move tracking so the view knows the hovered code block. In `configure()` (or `viewDidMoveToWindow`), install/refresh an `NSTrackingArea` with `[.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]`. Implement `override func updateTrackingAreas()` to remove/re-add it. On `mouseMoved(with:)`, hit-test the pointer to a code block:
  - Convert `event.locationInWindow` to the container point (same math as `checkboxSourceRange(at:)`).
  - `glyphIndex(for:in:)` → `characterIndexForGlyph(at:)` → read `.codeBlockSourceRange` at that char index (nil when not over code).
  - When over a code block, compute the **full attribute run** for `.codeBlockSourceRange` (via `attribute(_:at:longestEffectiveRange:in:)`) and the block's bounding rect (`boundingRect(forGlyphRange:in:)` over that run's glyph range), offset by `textContainerOrigin`. Position the pill in that rect's top-right (a few points of inset). Track the hovered run's rendered range so the pill hides when the pointer leaves it (and on `mouseExited`).

- [ ] Draw the pill as an **overlay**, never part of the attributed string:
  - Prefer a small child `NSView`/`NSButton`-like control added as a subview of the text view (positioned in view coordinates), OR draw it in an override of `draw(_:)` after `super.draw`. Either way it must not affect layout/selection/wrapping — mirror the Reconnect-pill treatment: a translucent, theme-aware capsule (page tint bleeds through), `usesDarkChrome`-aware fill/label color derived from `Theme.theme(for: activeProfile)`.
  - Label: "Copy"; on click → "Copied" for ~1s then back to "Copy" (or hide on mouse-out).

- [ ] Copy on click. When the pill is clicked (or in `mouseDown(with:)`, hit-test the pill rect BEFORE the checkbox path — the checkbox path already returns early, so order the pill check first and return):
  - Read the hovered block's `.codeBlockSourceRange` (source `NSRange`).
  - Slice the raw code from the retained source: `let source = renderedText as NSString?` — since `apply(text:profile:)` sets `renderedText = text` (the source markdown). Guard the range against `source.length`, then `source.substring(with: range)` → write to `NSPasteboard.general` (`clearContents()` + `setString(_:forType: .string)`).
  - Do NOT mutate the document (copy is read-only, unlike the checkbox toggle). Flip the label to "Copied".

- [ ] Ensure the pill is excluded from print/export. `DocumentExportRenderer` uses its own `ExportTextView` (a different class) and never installs this pill — confirm the pill lives only on `MarkdownPreviewTextView`, so exported/printed output can never contain it. (No code needed; verify by inspection and in the manual QA below.)

- [ ] Confirm no unit regressions: run the full default plan (below). Then perform **manual QA** (state it explicitly in the completion report — this affordance has no automated coverage):
  - Read mode + Preview/Split mode: hover a ```swift block → "Copy" pill appears top-right; click → clipboard holds the exact raw code (no fences); label flips to "Copied".
  - Repeat on a **light** theme (Original/Paper/Calm) and a **dark** theme (Quiet/Night) — pill fill/label read correctly in both (page tint bleeds through, `usesDarkChrome`-aware).
  - Hover an unknown-language / no-language fence → pill still appears and copies (highlighting absent, copy present — the spec's requirement).
  - Selection/scroll/wrapping unaffected by the pill; the pill never overlaps the checkbox toggle behavior.
  - **Export a PDF** of a doc with a code block → code is monochrome dark ink and the pill is absent from the PDF/print output.

- [ ] **Final full-suite run** (no `-only-testing`):

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

  Report exact pass/fail counts. (Warn the user first about the TCC Documents prompt — the ad-hoc-re-signed test host re-prompts; the run blocks until they click Allow. See the `cli-test-runs-cause-tcc-prompts` memory note.)

- [ ] **Commit:** `Code highlighting: hover copy pill in Read/Preview (overlay, manual-verified)`

---

## Verification command (per task)

```sh
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<ClassName>/<testName>
```

Final task runs the full default plan (no `-only-testing`). The hosted plan (`-testPlan LineformHosted`) is **not** required — this feature touches neither editor motion, drawer/inspector presentation, reload scroll, nor PDF-byte generation timing (the export change is a render-flag path, exercised by the pure `MarkdownPreviewRendererTests` in the default plan).

## Notes for the implementer
- The pbxproj is hand-rolled (objectVersion 56, no synced groups): add each new file across the 4 sections with sequential `1F0000xx` IDs (see the `pbxproj-handrolled-ids` memory note).
- Keep the tokenizer line-local-free assumption OUT of scope: unlike the Write highlighter, this operates on the whole bounded block, so multi-line strings/comments are intentional and fine.
- If a palette role fails AA on one theme, tune that variant until `CodeSyntaxPaletteContrastTests` is green — the test is the source of truth, not the hex values above.
- Do NOT commit beyond each task's own commit; do not touch `docs/appcast.xml`, version numbers, or release surfaces (this is a code feature, not a release).
