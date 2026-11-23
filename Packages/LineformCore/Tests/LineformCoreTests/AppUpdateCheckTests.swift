import XCTest
@testable import LineformCore

final class AppUpdateCheckTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }
    private let good = #"{"resultCount":1,"results":[{"version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id1234567890?mt=12"}]}"#

    func testDecodesVersionAndStoreURL() {
        let listing = AppStoreLookup.decode(json(good), platform: .mac)
        XCTAssertEqual(listing?.version, "1.9.0")
        XCTAssertEqual(listing?.storeURL.host, "apps.apple.com")
    }
    func testRejectsZeroResults() {
        XCTAssertNil(AppStoreLookup.decode(json(#"{"resultCount":0,"results":[]}"#), platform: .mac))
    }
    func testRejectsNonHTTPSOrForeignHost() {
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://", with: "http://")), platform: .mac))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "apps.apple.com", with: "apps.apple.com.evil.example")), platform: .mac))
    }
    /// "Host exactly apps.apple.com" must be literally true: no userinfo, no port.
    func testRejectsStoreURLWithUserPasswordOrPort() {
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://apps.apple.com", with: "https://x@apps.apple.com")), platform: .mac))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://apps.apple.com", with: "https://x:secret@apps.apple.com")), platform: .mac))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "https://apps.apple.com", with: "https://apps.apple.com:8443")), platform: .mac))
    }
    func testRejectsMalformedVersion() {
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "1.9.0", with: "1.9-beta")), platform: .mac))
        XCTAssertNil(AppStoreLookup.decode(json(good.replacingOccurrences(of: "1.9.0", with: String(repeating: "9", count: 40))), platform: .mac))
    }
    func testRejectsHTMLAndOversizedPayload() {
        XCTAssertNil(AppStoreLookup.decode(json("<html>Sign in to Wi-Fi</html>"), platform: .mac))
        XCTAssertNil(AppStoreLookup.decode(Data(count: AppStoreLookup.maximumPayloadBytes + 1), platform: .mac))
    }
    func testNewerStoreVersionIsAnUpdate() {
        let listing = AppStoreLookup.decode(json(good), platform: .mac)
        XCTAssertEqual(AppStoreLookup.result(listing: listing, currentVersion: "1.8.0"),
                       .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: listing!.storeURL))
    }
    func testSameOrOlderStoreVersionIsUpToDate() {
        let listing = AppStoreLookup.decode(json(good), platform: .mac)
        XCTAssertEqual(AppStoreLookup.result(listing: listing, currentVersion: "1.9.0"), .upToDate(current: "1.9.0"))
        XCTAssertEqual(AppStoreLookup.result(listing: listing, currentVersion: "1.10.0"), .upToDate(current: "1.10.0"))
    }
    func testMissingListingIsFailureNotUpToDate() {
        XCTAssertEqual(AppStoreLookup.result(listing: nil, currentVersion: "1.8.0"), .failed)
    }

    // MARK: The listing for each platform

    /// The Mac and the iPhone share one App Store listing (same bundle id). Checked by hand on
    /// 2026-11-23, before any iPhone build was on the store: every lookup form, `entity=software`
    /// included, answers with the Mac's `mac-software` entry. The iPhone must never read that
    /// entry as its own (it would offer a Mac-only version and open the Mac page).
    private let macEntry = #"{"resultCount":1,"results":[{"kind":"mac-software","version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id6800480078?mt=12&uo=4"}]}"#
    private let iPhoneEntry = #"{"resultCount":1,"results":[{"kind":"software","version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id6800480078?uo=4"}]}"#

    func testTheMacReadsTheMacEntryAndAnEntryWithNoKind() {
        XCTAssertEqual(AppStoreLookup.decode(json(macEntry), platform: .mac)?.version, "1.9.0")
        XCTAssertEqual(AppStoreLookup.decode(json(good), platform: .mac)?.version, "1.9.0",
                       "the Mac's behaviour is unchanged for an entry without a kind")
        XCTAssertNil(AppStoreLookup.decode(json(iPhoneEntry), platform: .mac), "the iPhone entry is not the Mac's")
    }

    func testTheIPhoneReadsOnlyTheIPhoneEntry() {
        let listing = AppStoreLookup.decode(json(iPhoneEntry), platform: .iPhone)
        XCTAssertEqual(listing?.version, "1.9.0")
        XCTAssertEqual(listing?.storeURL.absoluteString, "https://apps.apple.com/us/app/lineform/id6800480078?uo=4")
        XCTAssertNil(AppStoreLookup.decode(json(macEntry), platform: .iPhone),
                     "the Mac entry (what the store answers before an iPhone build is listed) is no listing")
        XCTAssertNil(AppStoreLookup.decode(json(good), platform: .iPhone), "an entry with no kind is not provably the iPhone's")
    }

    /// When both entries come back, each platform reads its own, whatever the order.
    func testEachPlatformPicksItsOwnEntryFromAMixedAnswer() {
        let mixed = #"{"resultCount":2,"results":[{"kind":"mac-software","version":"2.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id1?mt=12"},{"kind":"software","version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id1"}]}"#
        XCTAssertEqual(AppStoreLookup.decode(json(mixed), platform: .iPhone)?.version, "1.9.0")
        XCTAssertEqual(AppStoreLookup.decode(json(mixed), platform: .mac)?.version, "2.0")
    }

    /// The iPhone's mac-only answer is "couldn't check", never "up to date".
    func testTheMacEntryOnIPhoneIsAFailure() {
        XCTAssertEqual(AppStoreLookup.result(listing: AppStoreLookup.decode(json(macEntry), platform: .iPhone),
                                             currentVersion: "1.8.0"), .failed)
    }
}
