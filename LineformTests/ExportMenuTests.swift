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

    @MainActor
    func testExportIconsAreDistinctFromEachOther() {
        // Four rows sharing one glyph would read as four copies of the same command.
        let symbols = ExportFormat.allCases.compactMap {
            MainMenuIconDecorator.symbolsByTitle[MainMenuIconDecorator.normalizedTitle("\($0.title)...")]
        }
        XCTAssertEqual(symbols.count, ExportFormat.allCases.count)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }

    @MainActor
    func testExportAsIconIsTheOutboundCounterpartOfSave() {
        // Save is square.and.arrow.down: bytes land in your file. Export is the same glyph
        // pointing out: a copy leaves. The pairing is what makes the split legible at a glance.
        XCTAssertEqual(MainMenuIconDecorator.symbolsByTitle["export as"], "square.and.arrow.up")
        XCTAssertEqual(MainMenuIconDecorator.symbolsByTitle["save"], "square.and.arrow.down")
    }
}
