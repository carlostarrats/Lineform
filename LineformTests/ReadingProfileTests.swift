import XCTest
@testable import Lineform

final class ReadingProfileTests: XCTestCase {
    func testOriginalPresetUsesReadableDefaults() {
        let profile = ReadingProfile.original

        XCTAssertEqual(profile.name, "Original")
        XCTAssertGreaterThanOrEqual(profile.fontSize, 16)
        XCTAssertGreaterThan(profile.lineHeightMultiple, 1)
        XCTAssertGreaterThan(profile.columnWidth, 500)
    }

    func testReadingProfileCodableRoundTripPreservesValues() throws {
        let profile = ReadingProfile.original
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ReadingProfile.self, from: encoded)

        XCTAssertEqual(decoded, profile)
    }
}
