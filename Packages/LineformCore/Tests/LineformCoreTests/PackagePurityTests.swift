import XCTest

/// The package must stay shareable with the iOS app, so no UI framework may enter it.
/// Reads the sources from the repo via `#filePath`, not the built module.
final class PackagePurityTests: XCTestCase {
    func testNoUIFrameworkImportsInTheCorePackage() throws {
        XCTAssertEqual(try uiFrameworkImports(inTarget: "LineformCore"), [])
    }

    /// The same rule for the test-support target, which iOS test targets will link too.
    func testNoUIFrameworkImportsInTheTestSupportTarget() throws {
        XCTAssertEqual(try uiFrameworkImports(inTarget: "LineformCoreTestSupport"), [])
    }

    /// Without `bundle:`, `String(localized:)` resolves against `Bundle.main` — the APP's catalog —
    /// so a package string shows English silently in every other language. Multi-line calls are
    /// followed to their closing parenthesis; comments and string contents are ignored.
    func testEveryLocalizedStringInTheCorePackageNamesABundle() throws {
        let (calls, offenders) = try localizedCallsWithoutBundle(inTarget: "LineformCore")
        XCTAssertGreaterThan(calls, 100, "found almost no String(localized:) calls; the scan has gone blind")
        XCTAssertEqual(offenders, [], "String(localized:) without a bundle: argument")
    }

    private func localizedCallsWithoutBundle(inTarget target: String) throws -> (calls: Int, offenders: [String]) {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(target)")
        let call = try NSRegularExpression(pattern: #"\b(?:Attributed)?String\s*\(\s*localized\s*:"#)
        let bundleLabel = try NSRegularExpression(pattern: #"\bbundle\s*:"#)
        var calls = 0
        var offenders: [String] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            let text = code as NSString
            for match in call.matches(in: code, range: NSRange(location: 0, length: text.length)) {
                calls += 1
                // From the call's `(` to its matching `)`; only arguments at depth 1 count.
                let open = text.range(of: "(", range: NSRange(location: match.range.location,
                                                              length: match.range.length)).location
                var depth = 0, index = open, topLevel = ""
                while index < text.length {
                    let c = UnicodeScalar(text.character(at: index)).map(Character.init) ?? " "
                    if c == "(" || c == "[" || c == "{" { depth += 1 }
                    if c == ")" || c == "]" || c == "}" { depth -= 1; if depth == 0 { break } }
                    topLevel.append(depth == 1 ? c : " ")
                    index += 1
                }
                if bundleLabel.firstMatch(in: topLevel, range: NSRange(topLevel.startIndex..., in: topLevel)) == nil {
                    let line = text.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
                    offenders.append("\(url.lastPathComponent):\(line)")
                }
            }
        }
        return (calls, offenders)
    }

    /// The source with comments and string-literal contents blanked out (line breaks kept, so
    /// line numbers survive). Interpolations stay code, so a call nested in one is still found.
    private static func codeOnly(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var i = 0
        // Each open string: its `#` count, whether it is `"""`, and the paren depth of the
        // interpolation we are in (0 = in the literal text itself).
        var strings: [(hashes: Int, multiline: Bool, interpolationDepth: Int)] = []
        func at(_ s: String, _ j: Int) -> Bool {
            let t = Array(s)
            return j + t.count <= chars.count && Array(chars[j..<(j + t.count)]) == t
        }
        func blank(_ c: Character) -> Character { c == "\n" ? "\n" : " " }
        while i < chars.count {
            let c = chars[i]
            if let top = strings.last, top.interpolationDepth == 0 {
                let close = (top.multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: top.hashes)
                let escape = "\\" + String(repeating: "#", count: top.hashes)
                if at(close, i) {
                    strings.removeLast(); out += close; i += close.count; continue
                }
                if at(escape + "(", i) {
                    strings[strings.count - 1].interpolationDepth = 1
                    out += String(repeating: " ", count: escape.count) + "("; i += escape.count + 1; continue
                }
                if at(escape, i), i + escape.count < chars.count {
                    out += String(repeating: " ", count: escape.count); out.append(blank(chars[i + escape.count]))
                    i += escape.count + 1; continue
                }
                out.append(blank(c)); i += 1; continue
            }
            if at("//", i) {
                while i < chars.count, chars[i] != "\n" { out.append(" "); i += 1 }
                continue
            }
            if at("/*", i) {
                var depth = 0
                repeat {
                    if at("/*", i) { depth += 1; out += "  "; i += 2 }
                    else if at("*/", i) { depth -= 1; out += "  "; i += 2 }
                    else { out.append(blank(chars[i])); i += 1 }
                } while depth > 0 && i < chars.count
                continue
            }
            var hashes = 0
            while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
            if at("\"", i + hashes) {
                let multiline = at("\"\"\"", i + hashes)
                let opener = String(repeating: "#", count: hashes) + (multiline ? "\"\"\"" : "\"")
                strings.append((hashes, multiline, 0)); out += opener; i += opener.count; continue
            }
            if !strings.isEmpty {
                if c == "(" { strings[strings.count - 1].interpolationDepth += 1 }
                if c == ")" { strings[strings.count - 1].interpolationDepth -= 1 }
            }
            out.append(c); i += 1
        }
        return out
    }

    /// Plain imports, plus attributes (`@preconcurrency import`), access levels (`public import`)
    /// and kind imports (`import struct SwiftUI.Color`), and submodules (`import AppKit.NSColor`).
    private static let banned = try! NSRegularExpression(pattern:
        #"^(@\w+(\(.*?\))?\s+)*((public|package|internal|fileprivate|private)\s+)?import\s+((typealias|struct|class|enum|protocol|let|var|func)\s+)?(AppKit|SwiftUI|Cocoa|UIKit|WebKit)\b"#)

    private func uiFrameworkImports(inTarget target: String) throws -> [String] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(target)")
        var offenders: [String] = []
        var scanned = 0
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if Self.banned.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    offenders.append("\(url.lastPathComponent): \(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 0, "scanned no files in Sources/\(target); the path is wrong")
        return offenders
    }
}
