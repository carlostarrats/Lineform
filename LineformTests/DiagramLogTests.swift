import XCTest
@testable import Lineform

final class DiagramLogTests: XCTestCase {
    private func entry(hash: String, error: String = "err", count: Int = 1) -> DiagramLogEntry {
        DiagramLogEntry(sourceHash: hash, sourceSnippet: "src", error: error, appVersion: "1.0", count: count, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testMergeDedupsAndBumpsCount() {
        let now = Date(timeIntervalSince1970: 100)
        let existing = [entry(hash: "a", count: 1)]
        let merged = DiagramLog.merge(existing, adding: entry(hash: "a", error: "err2"), now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.count, 2)
        XCTAssertEqual(merged.first?.lastSeen, now)
        XCTAssertEqual(merged.first?.error, "err2")
    }

    func testMergeAppendsDistinctHash() {
        let now = Date(timeIntervalSince1970: 100)
        let merged = DiagramLog.merge([entry(hash: "a")], adding: entry(hash: "b"), now: now)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.sourceHash).sorted(), ["a", "b"])
    }

    func testSourceHashIsStableAndDistinct() {
        XCTAssertEqual(DiagramLog.sourceHash("graph TD; A-->B"), DiagramLog.sourceHash("graph TD; A-->B"))
        XCTAssertNotEqual(DiagramLog.sourceHash("graph TD; A-->B"), DiagramLog.sourceHash("graph TD; A-->C"))
    }

    func testReadableReportEmptyAndPopulated() {
        XCTAssertTrue(DiagramLog.readableReport([]).contains("no entries"))
        let report = DiagramLog.readableReport([entry(hash: "abc", error: "parse error", count: 3)])
        XCTAssertTrue(report.contains("parse error"))
        XCTAssertTrue(report.contains("×3"))
        XCTAssertTrue(report.contains("abc"))
    }
}
