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

    func testDiagramLogDirectoryUnderHome() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        XCTAssertEqual(
            LineformCLIPaths.diagramLogDirectory(home: home).path,
            "/Users/x/Library/Application Support/Lineform/DiagramLog"
        )
    }

    func testResolveAbsoluteAndRelative() {
        let base = URL(fileURLWithPath: "/work", isDirectory: true)
        XCTAssertEqual(LineformCLIPaths.resolve("/abs/x.md", relativeTo: base).path, "/abs/x.md")
        XCTAssertEqual(LineformCLIPaths.resolve("sub/x.md", relativeTo: base).path, "/work/sub/x.md")
    }

    func testStaleReturnsOldUnopenedOnly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let recent = now.addingTimeInterval(-1 * 24 * 3600)
        let a = URL(fileURLWithPath: "/p/a.md"), b = URL(fileURLWithPath: "/p/b.md"), c = URL(fileURLWithPath: "/p/c.md")
        let result = LineformPipedHousekeeping.stale(
            entries: [(a, old), (b, recent), (c, old)],
            now: now,
            olderThan: 7 * 24 * 3600,
            openDocumentURLs: [c]
        )
        XCTAssertEqual(result, [a])
    }

    func testMessages() {
        XCTAssertEqual(LineformCLIMessages.noSuchFile("x"), "lineform: no such file: x")
        XCTAssertEqual(LineformCLIMessages.isDirectory("d"), "lineform: d is a directory (not supported yet)")
        XCTAssertEqual(LineformCLIMessages.emptyInput, "lineform: empty input")
        XCTAssertEqual(LineformCLIMessages.notText, "lineform: input is not text")
    }
}
