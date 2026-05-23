import XCTest
@testable import Lineform

final class ReadingAssistPreferenceTests: XCTestCase {
    func testFocusPresetEnablesNativeFocusAndTypewriterAids() {
        let profile = ReadingPreset.focus.profile

        XCTAssertEqual(profile.focusMode, .currentParagraph)
        XCTAssertTrue(profile.typewriterModeEnabled)
        XCTAssertFalse(profile.reduceMotionEnabled)
    }

    func testDyslexiaPresetEnablesReadingRulerWithoutMotion() {
        let profile = ReadingPreset.dyslexia.profile

        XCTAssertTrue(profile.readingRulerEnabled)
        XCTAssertTrue(profile.reduceMotionEnabled)
    }
}
