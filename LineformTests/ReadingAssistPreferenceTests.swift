import XCTest
@testable import Lineform

final class ReadingAssistPreferenceTests: XCTestCase {
    func testFocusPresetEnablesReadingRulerAndTypewriterAids() {
        let profile = ReadingPreset.focus.profile

        XCTAssertEqual(profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(profile.focusMode, .off)
        XCTAssertTrue(profile.readingRulerEnabled)
        XCTAssertFalse(profile.reduceMarkdownNoise)
        XCTAssertTrue(profile.typewriterModeEnabled)
        XCTAssertEqual(profile.insertionPointWidth, ReadingProfile.original.insertionPointWidth)
        XCTAssertFalse(profile.reduceMotionEnabled)
    }

    func testCalmPresetUsesAccessibleTypefaceWithoutFocusAids() {
        let profile = ReadingPreset.calm.profile

        XCTAssertEqual(profile.fontID, .atkinsonHyperlegible)
        XCTAssertEqual(profile.focusMode, .off)
        XCTAssertFalse(profile.reduceMarkdownNoise)
        XCTAssertFalse(profile.readingRulerEnabled)
        XCTAssertFalse(profile.typewriterModeEnabled)
    }
}
