import XCTest
@testable import Lineform

final class AppUpdateCheckTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }
    private let good = #"{"resultCount":1,"results":[{"version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id1234567890?mt=12"}]}"#

    func testDecodesVersionAndStoreURL() {
        let listing = AppStoreLookup.decode(json(good))
        XCTAssertEqual(listing?.version, "1.9.0")
        XCTAssertEqual(listing?.storeURL.host, "apps.apple.com")
    }
    func testRejectsZeroResults() {
        XCTAssertNil(AppStoreLookup.decode(json(#"{"resultCount":0,"results":[]}"#)))
    }
    func testRejectsNonHTTPSOrForeignHost() {
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://", with: "http://"))))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "apps.apple.com", with: "apps.apple.com.evil.example"))))
    }
    /// "Host exactly apps.apple.com" must be literally true: no userinfo, no port.
    func testRejectsStoreURLWithUserPasswordOrPort() {
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://apps.apple.com", with: "https://x@apps.apple.com"))))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://apps.apple.com", with: "https://x:secret@apps.apple.com"))))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://apps.apple.com", with: "https://apps.apple.com:8443"))))
    }
    func testRejectsMalformedVersion() {
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "1.9.0", with: "1.9-beta"))))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "1.9.0", with: String(repeating: "9", count: 40)))))
    }
    func testRejectsHTMLAndOversizedPayload() {
        XCTAssertNil(AppStoreLookup.decode(json("<html>Sign in to Wi-Fi</html>")))
        XCTAssertNil(AppStoreLookup.decode(Data(count: AppStoreLookup.maximumPayloadBytes + 1)))
    }
    func testNewerStoreVersionIsAnUpdate() {
        let listing = AppStoreLookup.decode(json(good))
        XCTAssertEqual(AppStoreLookup.result(listing: listing, currentVersion: "1.8.0"),
                       .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: listing!.storeURL))
    }
    func testSameOrOlderStoreVersionIsUpToDate() {
        let listing = AppStoreLookup.decode(json(good))
        XCTAssertEqual(AppStoreLookup.result(listing: listing, currentVersion: "1.9.0"), .upToDate(current: "1.9.0"))
        XCTAssertEqual(AppStoreLookup.result(listing: listing, currentVersion: "1.10.0"), .upToDate(current: "1.10.0"))
    }
    func testMissingListingIsFailureNotUpToDate() {
        XCTAssertEqual(AppStoreLookup.result(listing: nil, currentVersion: "1.8.0"), .failed)
    }
}
