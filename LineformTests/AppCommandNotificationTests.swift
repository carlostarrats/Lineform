import XCTest
@testable import Lineform

final class AppCommandNotificationTests: XCTestCase {
    func testReadingExperienceCommandUsesStableNotificationName() {
        XCTAssertEqual(
            LineformAppNotification.showReadingExperience.name.rawValue,
            "Lineform.showReadingExperience"
        )
    }
}
