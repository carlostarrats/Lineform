import XCTest
@testable import LineformCore

final class PackageSmokeTests: XCTestCase {
    func testModuleBundleHasTheStringCatalog() {
        XCTAssertNotNil(Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")
            ?? Bundle.module.url(forResource: "en", withExtension: "lproj"))
    }
}
