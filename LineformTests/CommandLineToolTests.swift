import XCTest
@testable import Lineform

final class CommandLineToolTests: XCTestCase {
    func testParseOpenSingleAndMultiple() {
        XCTAssertEqual(LineformCLICommand.parse(["a.md"]), .open(["a.md"]))
        XCTAssertEqual(LineformCLICommand.parse(["a.md", "b.md"]), .open(["a.md", "b.md"]))
    }

    func testParseStdinDash() {
        XCTAssertEqual(LineformCLICommand.parse(["-"]), .readStdin)
    }

    func testParseVersionAndHelp() {
        XCTAssertEqual(LineformCLICommand.parse(["--version"]), .version)
        XCTAssertEqual(LineformCLICommand.parse(["--help"]), .help)
        XCTAssertEqual(LineformCLICommand.parse([]), .help)
    }

    func testParseUnknownFlagIsInvalid() {
        XCTAssertEqual(LineformCLICommand.parse(["--nope"]), .invalid("--nope"))
    }

    func testValidateEmpty() {
        XCTAssertEqual(LineformPipeValidation.validate(Data()), .empty)
    }

    func testValidateNUL() {
        XCTAssertEqual(LineformPipeValidation.validate(Data([0x41, 0x00, 0x42])), .notText)
    }

    func testValidateTooLargeBoundary() {
        XCTAssertEqual(LineformPipeValidation.validate(Data(repeating: 0x41, count: 11), maxBytes: 10), .tooLarge)
        XCTAssertEqual(LineformPipeValidation.validate(Data(repeating: 0x41, count: 10), maxBytes: 10), .ok)
    }

    func testPipedFileName() {
        XCTAssertEqual(
            LineformCLIPaths.pipedFileName(timestamp: "20260701-101112", unique: "ab12cd34"),
            "piped-20260701-101112-ab12cd34.md"
        )
    }

    func testPipedTimestampFormat() {
        let date = Date(timeIntervalSince1970: 0)
        let stamp = LineformCLIPaths.pipedTimestamp(from: date)
        // 15-char date + '-' + 3-char millis: yyyyMMdd-HHmmss-SSS
        XCTAssertEqual(stamp.count, "yyyyMMdd-HHmmss-SSS".count)
        XCTAssertTrue(stamp.contains("-"))
    }

    func testPipedDirectoryUnderHome() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        XCTAssertEqual(
            LineformCLIPaths.pipedDirectory(home: home).path,
            "/Users/x/Library/Application Support/Lineform/Piped"
        )
    }

    func testResolveAbsoluteAndRelative() {
        let base = URL(fileURLWithPath: "/work", isDirectory: true)
        XCTAssertEqual(LineformCLIPaths.resolve("/abs/x.md", relativeTo: base).path, "/abs/x.md")
        XCTAssertEqual(LineformCLIPaths.resolve("sub/x.md", relativeTo: base).path, "/work/sub/x.md")
    }

    func testStaleReturnsOldEntriesOnly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let recent = now.addingTimeInterval(-1 * 24 * 3600)
        let a = URL(fileURLWithPath: "/p/a.md"), b = URL(fileURLWithPath: "/p/b.md"), c = URL(fileURLWithPath: "/p/c.md")
        let result = LineformPipedHousekeeping.stale(
            entries: [(a, old), (b, recent), (c, old)],
            now: now,
            olderThan: 7 * 24 * 3600
        )
        XCTAssertEqual(result, [a, c])
    }

    func testMessages() {
        XCTAssertEqual(LineformCLIMessages.noSuchFile("x"), "lineform: no such file: x")
        XCTAssertEqual(LineformCLIMessages.isDirectory("d"), "lineform: d is a directory (not supported yet)")
        XCTAssertEqual(LineformCLIMessages.emptyInput, "lineform: empty input")
        XCTAssertEqual(LineformCLIMessages.notText, "lineform: input is not text")
        XCTAssertEqual(LineformCLIMessages.tooLarge, "lineform: input too large (limit 10 MB)")
    }

    /// The pipe guard must accept exactly what the app will open. A NUL check alone let any
    /// non-UTF-8 byte sequence through, so the failure surfaced later as a corrupt-file error on
    /// a document the user could not connect to the pipe that produced it.
    func testPipeValidationRejectsWhatTheDocumentLoaderWouldReject() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])   // "café" in Latin-1
        XCTAssertEqual(LineformPipeValidation.validate(latin1), .notText)
        XCTAssertThrowsError(try LineformDocument(markdownData: latin1))

        let utf8 = Data("café\n".utf8)
        XCTAssertEqual(LineformPipeValidation.validate(utf8), .ok)
        XCTAssertNoThrow(try LineformDocument(markdownData: utf8))

        // NUL is valid UTF-8, so the decode alone would accept it — the binary check still matters.
        XCTAssertEqual(LineformPipeValidation.validate(Data([0x41, 0x00, 0x42])), .notText)
    }

    // MARK: - Shared piped directory

    /// The app and the `lineform` helper must resolve the piped directory through ONE function.
    /// If they disagree, a pipe writes somewhere the app never looks and silently opens nothing —
    /// there is no error to see. This is the paired-definition rule applied to a filesystem path.
    /// Sandboxed (released) builds: piped files must land in the SHARED group container. Anywhere
    /// else and a sandboxed helper's write is redirected into its own container, invisible to the app.
    func testSharedPipedDirectoryUsesTheGroupContainerWhenAvailable() {
        let container = URL(fileURLWithPath: "/Groups/group.TV4QZT7A7X.com.lineform", isDirectory: true)
        var requested: String?
        let resolved = LineformCLIPaths.sharedPipedDirectory(
            home: URL(fileURLWithPath: "/Users/testfixture"),
            groupContainer: { identifier in requested = identifier; return container }
        )
        XCTAssertEqual(requested, LineformCLIPaths.appGroupIdentifier)
        XCTAssertEqual(
            resolved.standardizedFileURL,
            container.appendingPathComponent(LineformCLIPaths.pipedRelativePath, isDirectory: true).standardizedFileURL
        )
    }

    /// Debug builds have no group entitlement (ad-hoc signing cannot satisfy one), so the resolver
    /// must fall back to the documented home-relative path rather than yielding nothing.
    func testSharedPipedDirectoryFallsBackToTheHomeRelativePathWithoutAGroup() {
        let home = URL(fileURLWithPath: "/Users/testfixture")
        let resolved = LineformCLIPaths.sharedPipedDirectory(home: home, groupContainer: { _ in nil })
        XCTAssertEqual(
            resolved.standardizedFileURL,
            LineformCLIPaths.pipedDirectory(home: home).standardizedFileURL
        )
    }

    /// Whichever branch is taken, the trailing structure is identical, so a file written by one
    /// side is found by the other at the same relative location.
    func testSharedPipedDirectoryAlwaysEndsInTheSameRelativePath() {
        let home = URL(fileURLWithPath: "/Users/testfixture")
        let container = URL(fileURLWithPath: "/Groups/g", isDirectory: true)
        for resolved in [
            LineformCLIPaths.sharedPipedDirectory(home: home, groupContainer: { _ in container }),
            LineformCLIPaths.sharedPipedDirectory(home: home, groupContainer: { _ in nil }),
        ] {
            XCTAssertTrue(
                resolved.path.hasSuffix(LineformCLIPaths.pipedRelativePath),
                "expected a path ending in \(LineformCLIPaths.pipedRelativePath), got \(resolved.path)"
            )
        }
    }

    /// The group identifier is compiled into both the app's entitlements and the helper's. A typo
    /// here is invisible until a sandboxed pipe silently writes to the wrong container.
    func testAppGroupIdentifierMatchesTheEntitlementFiles() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LineformTests
            .deletingLastPathComponent()   // repo root
        for relative in ["Lineform/Lineform.entitlements", "HelperTool/HelperTool.entitlements"] {
            let url = repoRoot.appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                text.contains(LineformCLIPaths.appGroupIdentifier),
                "\(relative) does not declare \(LineformCLIPaths.appGroupIdentifier)"
            )
        }
    }
}
