import XCTest
@testable import LineformCore
import LineformCoreTestSupport

/// Every test here runs over `StubURLProtocol` (or the local `FailingURLProtocol`); none
/// makes a real network request.
final class AppUpdateCheckerTests: XCTestCase {
    private let good = #"{"resultCount":1,"results":[{"version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id1234567890?mt=12"}]}"#

    override func setUp() {
        super.setUp()
        resetStub()
    }

    override func tearDown() {
        resetStub()
        super.tearDown()
    }

    private func resetStub() {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data()
        StubURLProtocol.declaredLength = nil
        StubURLProtocol.redirectTo = nil
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.requestedRequests = []
        StubURLProtocol.contentType = "application/json"
    }

    /// The checker's own configuration, with only the transport swapped for the stub, so
    /// the cookie and cache settings under test are the shipping ones.
    /// The Mac's checker unless a test asks for the iPhone's: `good` carries no `kind`, which only
    /// the Mac reads.
    private func checker(
        protocolClass: AnyClass = StubURLProtocol.self, platform: AppStorePlatform = .mac
    ) -> AppStoreUpdateChecker {
        let configuration = AppStoreUpdateChecker.makeConfiguration()
        configuration.protocolClasses = [protocolClass]
        return AppStoreUpdateChecker(platform: platform, session: URLSession(configuration: configuration))
    }

    func testReturnsUpdateAvailableForNewerStoreVersion() async {
        StubURLProtocol.body = Data(good.utf8)
        let result = await checker().check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .updateAvailable(current: "1.8.0", latest: "1.9.0",
                                                storeURL: URL(string: "https://apps.apple.com/us/app/lineform/id1234567890?mt=12")!))
    }

    /// Apple serves this endpoint as `text/javascript; charset=utf-8` (checked by hand on
    /// 2026-11-18), so that content type must be accepted.
    func testAcceptsAppleTextJavascriptContentType() async {
        StubURLProtocol.contentType = "text/javascript; charset=utf-8"
        StubURLProtocol.body = Data(good.utf8)
        let result = await checker().check(currentVersion: "1.9.0")
        XCTAssertEqual(result, .upToDate(current: "1.9.0"))
    }

    func testNon200IsFailed() async {
        StubURLProtocol.status = 503
        StubURLProtocol.body = Data(good.utf8)
        let result = await checker().check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .failed)
    }

    /// Isolates the Content-Type guard: the body is the VALID lookup JSON, so only the
    /// `text/html` header (a captive portal answering 200) can make this fail.
    func testHTMLContentTypeWith200IsFailedEvenForAValidBody() async {
        StubURLProtocol.contentType = "text/html"
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data(good.utf8)
        let result = await checker().check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .failed)
    }

    func testOversizedBodyIsFailedEvenWithALyingContentLength() async {
        StubURLProtocol.declaredLength = 10
        StubURLProtocol.body = Data(repeating: 0x20, count: AppStoreLookup.maximumPayloadBytes + 1)
        let result = await checker().check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .failed)
    }

    func testTransportErrorIsFailed() async {
        let result = await checker(protocolClass: FailingURLProtocol.self).check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .failed)
    }

    func testRequestCarriesNoCookiesNoBodyAndOnlyTheLookupURL() async throws {
        StubURLProtocol.body = Data(good.utf8)
        _ = await checker().check(currentVersion: "1.8.0")

        XCTAssertEqual(StubURLProtocol.requestedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.requestedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url, AppStoreUpdateChecker.lookupURL(for: .mac))

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "itunes.apple.com")
        XCTAssertEqual(components.path, "/lookup")
        let names = Set((components.queryItems ?? []).map(\.name))
        XCTAssertTrue(names.isSubset(of: ["bundleId", "entity"]), "unexpected query items: \(names)")
        XCTAssertEqual(components.queryItems?.first { $0.name == "bundleId" }?.value, "com.lineform.app")
    }

    /// URLSession attaches stored cookies below the URLProtocol layer, so a stub can't see
    /// them (checked by mutation: enabling cookies does not change the recorded request).
    /// The guarantee is the shipping session's configuration, read off a default checker.
    func testDefaultSessionSendsAndStoresNoCookies() {
        let configuration = AppStoreUpdateChecker().sessionConfiguration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, AppStoreUpdateChecker.timeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, AppStoreUpdateChecker.timeout)
        XCTAssertEqual(AppStoreUpdateChecker.timeout, 10)
    }

    /// Each platform asks for its own listing: the Mac `macSoftware`, the iPhone `software`
    /// (the iTunes lookup's iOS catalog). A plain checker asks for the platform it runs on.
    func testEachPlatformLooksUpItsOwnListing() throws {
        func entity(_ url: URL) throws -> String? {
            try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)).queryItems?
                .first { $0.name == "entity" }?.value
        }
        XCTAssertEqual(try entity(AppStoreUpdateChecker.lookupURL(for: .mac)), "macSoftware")
        XCTAssertEqual(try entity(AppStoreUpdateChecker.lookupURL(for: .iPhone)), "software")
        XCTAssertEqual(AppStoreUpdateChecker.lookupURL(for: .mac).absoluteString,
                       "https://itunes.apple.com/lookup?bundleId=com.lineform.app&entity=macSoftware",
                       "the Mac's lookup is unchanged")
        #if os(iOS)
        XCTAssertEqual(AppStorePlatform.current, .iPhone)
        #else
        XCTAssertEqual(AppStorePlatform.current, .mac)
        #endif
        XCTAssertEqual(AppStoreUpdateChecker.lookupURL, AppStoreUpdateChecker.lookupURL(for: .current))
    }

    func testTheIPhoneCheckerRequestsTheIPhoneListingAndReadsItsEntry() async throws {
        StubURLProtocol.contentType = "text/javascript; charset=utf-8"
        StubURLProtocol.body = Data(#"{"resultCount":1,"results":[{"kind":"software","version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id6800480078?uo=4"}]}"#.utf8)
        let result = await checker(platform: .iPhone).check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .updateAvailable(current: "1.8.0", latest: "1.9.0",
                                                storeURL: URL(string: "https://apps.apple.com/us/app/lineform/id6800480078?uo=4")!))
        XCTAssertEqual(StubURLProtocol.requestedURLs, [AppStoreUpdateChecker.lookupURL(for: .iPhone)])
    }

    /// Before an iPhone build is listed, the store answers the iPhone's lookup with the Mac
    /// entry (seen by hand on 2026-11-23). That is "couldn't check", never a Mac version offered.
    func testTheIPhoneCheckerRefusesTheMacEntry() async {
        StubURLProtocol.body = Data(#"{"resultCount":1,"results":[{"kind":"mac-software","version":"1.9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id6800480078?mt=12&uo=4"}]}"#.utf8)
        let result = await checker(platform: .iPhone).check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .failed)
    }

    func testTheMacCheckerRequestsTheMacListing() async {
        StubURLProtocol.body = Data(good.utf8)
        _ = await checker(platform: .mac).check(currentVersion: "1.8.0")
        XCTAssertEqual(StubURLProtocol.requestedURLs, [AppStoreUpdateChecker.lookupURL(for: .mac)])
    }

    func testLookupUsesReleaseBundleIDNotMainBundle() {
        XCTAssertTrue(AppStoreUpdateChecker.lookupURL.absoluteString.contains("bundleId=com.lineform.app&")
            || AppStoreUpdateChecker.lookupURL.absoluteString.hasSuffix("bundleId=com.lineform.app"))
    }
}

/// Fails every load the way an offline Mac does, without touching the network.
private final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
