import XCTest
@testable import LineformCore

/// New iPhone documents save into iCloud Drive's Lineform folder when there is one, and into the
/// app's own Documents folder otherwise (iCloud off, signed out, or a Debug build with no iCloud
/// entitlement). Neither test touches the real container: both inject the ubiquity lookup.
final class DocumentFolderResolverTests: XCTestCase {
    private let local = URL(fileURLWithPath: "/tmp/lineform-tests/Documents", isDirectory: true)

    func testResolverPrefersICloud() {
        let iCloud = URL(fileURLWithPath: "/tmp/lineform-tests/iCloud/Documents", isDirectory: true)
        let resolver = DocumentFolderResolver(ubiquityDocumentsURL: { iCloud }, localDocumentsURL: local)
        XCTAssertEqual(resolver.saveFolder(), iCloud)
    }

    func testResolverFallsBackToDevice() {
        let resolver = DocumentFolderResolver(ubiquityDocumentsURL: { nil }, localDocumentsURL: local)
        XCTAssertEqual(resolver.saveFolder(), local)
    }

    func testResolverNamesEachFolderOnItsOwn() {
        let iCloud = URL(fileURLWithPath: "/tmp/lineform-tests/iCloud/Documents", isDirectory: true)
        XCTAssertEqual(DocumentFolderResolver(ubiquityDocumentsURL: { iCloud }, localDocumentsURL: local).iCloudFolder(), iCloud)
        XCTAssertNil(DocumentFolderResolver(ubiquityDocumentsURL: { nil }, localDocumentsURL: local).iCloudFolder())
        XCTAssertEqual(DocumentFolderResolver(ubiquityDocumentsURL: { iCloud }, localDocumentsURL: local).deviceFolder, local)
    }
}
