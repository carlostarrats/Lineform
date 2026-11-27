import XCTest
@testable import Lineform

final class ExportMenuTests: XCTestCase {
    func testExportNotificationHasItsOwnName() {
        XCTAssertEqual(
            LineformAppNotification.exportDocument.name,
            Notification.Name("Lineform.exportDocument")
        )
        XCTAssertNotEqual(
            LineformAppNotification.exportDocument.name,
            LineformAppNotification.saveAsDocument.name
        )
    }

    func testEveryExportFormatRoundTripsThroughThePayloadValue() {
        // The menu row encodes its format in the payload's `value`; the handler decodes it.
        for format in ExportFormat.allCases {
            let encoded = String(format.rawValue)
            XCTAssertEqual(ExportFormat(rawValue: Int(encoded) ?? -1), format)
        }
    }

    @MainActor
    func testEveryExportRowHasAMenuIcon() {
        // The menu titles carry a trailing "..." that `normalizedTitle` strips, so the map keys
        // are the bare lowercased titles.
        for format in ExportFormat.allCases {
            let key = MainMenuIconDecorator.normalizedTitle("\(format.title)...")
            XCTAssertNotNil(
                MainMenuIconDecorator.symbolsByTitle[key],
                "No SF Symbol mapped for the \(format.title) export row (key: \(key))"
            )
        }
        XCTAssertNotNil(MainMenuIconDecorator.symbolsByTitle["export as"])
    }

}
