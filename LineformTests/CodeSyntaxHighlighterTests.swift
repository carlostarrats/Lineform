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
