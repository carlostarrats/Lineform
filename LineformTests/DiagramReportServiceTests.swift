import XCTest
@testable import Lineform

final class DiagramReportServiceTests: XCTestCase {
    func testPayloadContainsExactlyThreeFields() {
        let payload = DiagramReportService.payload(source: "graph TD; A-->B", error: "boom", appVersion: "1.1.0")
        XCTAssertEqual(Set(payload.keys), ["source", "error", "appVersion"])
        XCTAssertEqual(payload["source"], "graph TD; A-->B")
        XCTAssertEqual(payload["error"], "boom")
        XCTAssertEqual(payload["appVersion"], "1.1.0")
    }

    func testReportLinkRoundTrips() {
        let hash = "abc123def456"
        let url = DiagramReportLink.url(hash: hash)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, DiagramReportLink.scheme)
        XCTAssertEqual(DiagramReportLink.hash(from: url!), hash)
    }

    func testReportLinkRejectsOtherSchemes() {
        XCTAssertNil(DiagramReportLink.hash(from: URL(string: "https://example.com/x")!))
    }

    func testRegistryStoresAndRecovers() {
        let registry = DiagramReportRegistry()
        registry.register(hash: "h1", source: "src", error: "err")
        XCTAssertEqual(registry.report(for: "h1")?.source, "src")
        XCTAssertEqual(registry.report(for: "h1")?.error, "err")
        XCTAssertNil(registry.report(for: "missing"))
        registry.reset()
        XCTAssertNil(registry.report(for: "h1"))
    }
}
