import XCTest
@testable import LineformCore

/// The three web pages both apps link to. The Mac's Help menu forwards to these.
final class LineformLinksTests: XCTestCase {
    func testLinksAreTheSitePages() {
        XCTAssertEqual(LineformLinks.privacyPolicyURL, "https://lineform.app/privacy")
        XCTAssertEqual(LineformLinks.termsOfUseURL, "https://lineform.app/terms")
        XCTAssertEqual(LineformLinks.guideURL, "https://lineform.app/info/")
        for link in [LineformLinks.privacyPolicyURL, LineformLinks.termsOfUseURL, LineformLinks.guideURL] {
            XCTAssertEqual(URL(string: link)?.scheme, "https", "\(link) is a valid https URL")
        }
    }
}
