import XCTest
@testable import LineformCore

final class PackageSmokeTests: XCTestCase {
    /// A key that moved with `MarkdownReference` resolves to its Japanese translation through the
    /// package's own bundle. If the catalog did not compile into `Bundle.module`, or the key were
    /// left behind in the app catalog, the lookup would return the English key.
    func testModuleBundleHasTheStringCatalog() throws {
        let japanese = try XCTUnwrap(
            Bundle.lineformCore.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)),
            "ja.lproj missing from LineformCore's bundle"
        )
        let key = "Strikethrough."
        let translated = japanese.localizedString(forKey: key, value: nil, table: nil)
        XCTAssertFalse(translated.isEmpty)
        XCTAssertNotEqual(translated, key, "\(key) is not translated in the package's ja.lproj")
    }
}
