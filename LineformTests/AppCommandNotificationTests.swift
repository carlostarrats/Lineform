import XCTest
@testable import Lineform

final class AppCommandNotificationTests: XCTestCase {
    func testReadingExperienceCommandUsesStableNotificationName() {
        XCTAssertEqual(
            LineformAppNotification.showReadingExperience.name.rawValue,
            "Lineform.showReadingExperience"
        )
    }

    func testNotificationPayloadCarriesActiveWindowIdentifier() {
        let payload = LineformAppNotification.Payload(windowNumber: 42, value: EditorDisplayMode.read.rawValue)

        XCTAssertTrue(payload.matches(windowNumber: 42))
        XCTAssertFalse(payload.matches(windowNumber: 7))
        XCTAssertEqual(payload.value, "read")
    }
}
