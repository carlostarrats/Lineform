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
