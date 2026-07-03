import XCTest
@testable import Lineform

final class AppCommandsSidebarFileTests: XCTestCase {
    @MainActor
    func testFileMenuGetsRenameAndDeleteCommandsWithEllipsisTitles() {
        // Three-period ellipsis matches the pre-existing File-menu convention ("Save As...").
        XCTAssertEqual(AppMenuConfiguration.renameFileCommandTitle, "Rename...")
        XCTAssertEqual(AppMenuConfiguration.deleteFileCommandTitle, "Delete...")
    }

    @MainActor
    func testCurrentFileMenuStateTracksURLAndIgnoresRedundantSets() {
        let state = LineformCurrentFileMenuState()
        XCTAssertNil(state.currentFileURL)

        let url = URL(fileURLWithPath: "/tmp/A.md")
        state.setCurrentFileURL(url)
        XCTAssertEqual(state.currentFileURL, url)

        state.setCurrentFileURL(url)
        XCTAssertEqual(state.currentFileURL, url)

        state.setCurrentFileURL(nil)
        XCTAssertNil(state.currentFileURL)
    }

    @MainActor
    func testSidebarFileNotificationNamesAreDistinct() {
        let names = [
            LineformAppNotification.refreshSidebarFiles.name,
            LineformAppNotification.sidebarItemRenamed.name,
            LineformAppNotification.sidebarFileDeleted.name,
            LineformAppNotification.renameCurrentFile.name,
            LineformAppNotification.deleteCurrentFile.name
        ]
        XCTAssertEqual(Set(names).count, names.count)
    }
}
