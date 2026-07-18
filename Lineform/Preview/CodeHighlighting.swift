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

// TODO(Task 2): replace this stub with the real HTML scanner in the same file.
enum HTMLScanner {
    static func tokens(source: String) -> [CodeToken] { [] }
}
