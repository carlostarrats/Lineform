import AppKit
import XCTest
@testable import Lineform

final class OutlineSidebarViewTests: XCTestCase {
    @MainActor
    func testEmptyOutlineMessageExplainsHowToPopulateSidebar() {
        XCTAssertEqual(OutlineSidebarView.emptyStateTitle, "No headings yet")
        XCTAssertEqual(OutlineSidebarView.emptyStatePossibilityMessage, "No sections. No hierarchy. Just possibilities.")
        XCTAssertEqual(OutlineSidebarView.emptyStateInstruction, "Add # Title or ## Section to build an outline.")
        XCTAssertEqual(OutlineSidebarView.emptyStateTopPadding, 10)
        XCTAssertEqual(OutlineSidebarView.emptyStateHorizontalPadding, 16)
        XCTAssertEqual(OutlineSidebarView.emptyStateTitleBodySpacing, 7)
        XCTAssertEqual(OutlineSidebarView.emptyStateMessageInstructionSpacing, 24)
        XCTAssertEqual(OutlineSidebarView.emptyStateTitleFontSize, 13)
        XCTAssertEqual(OutlineSidebarView.emptyStateBodyFontSize, 12)
    }

    @MainActor
    func testOutlineTitleDoesNotUseIcon() {
        XCTAssertFalse(OutlineSidebarView.titleShowsIcon)
    }

    @MainActor
    func testOutlineTitleOnlyShowsForEmptyDrawer() {
        let items = MarkdownOutlineParser().items(in: "# Title")

        XCTAssertFalse(OutlineSidebarView.showsTitle(for: []))
        XCTAssertFalse(OutlineSidebarView.showsTitle(for: items))
    }

    @MainActor
    func testOutlineDrawerAddsOutlineAndFilesTabs() {
        XCTAssertEqual(OutlineSidebarView.tabTitles, ["Outline", "Files"])
        XCTAssertTrue(OutlineSidebarView.tabsFillAvailableWidth)
        XCTAssertTrue(OutlineSidebarView.tabsUseNativeEqualWidthSegments)
        XCTAssertTrue(OutlineSidebarView.tabsUseExplicitThemeAppearance)
        XCTAssertEqual(OutlineSidebarView.tabAppearanceName(usesDarkChrome: false), .aqua)
        XCTAssertEqual(OutlineSidebarView.tabAppearanceName(usesDarkChrome: true), .darkAqua)
    }

    @MainActor
    func testFilesTabUsesICloudAndReplaceableWorkspaceRoots() {
        XCTAssertEqual(OutlineSidebarView.fileRootTitles, ["Lineform iCloud", "Workspace"])
        XCTAssertEqual(OutlineSidebarView.chooseWorkspaceButtonTitle, "Choose")
        XCTAssertEqual(OutlineSidebarView.replaceWorkspaceButtonTitle, "Replace")
        XCTAssertTrue(OutlineSidebarView.iCloudUnavailableShowsLabel)
        XCTAssertEqual(OutlineSidebarView.iCloudUnavailableStatusTitle, "Unavailable")
        XCTAssertTrue(OutlineSidebarView.filesRowsFillAvailableWidth)
        XCTAssertEqual(OutlineSidebarView.filesContentHorizontalPadding, 10)
        XCTAssertEqual(OutlineSidebarView.filesRootRowHeight, 28)
        XCTAssertEqual(OutlineSidebarView.filesChildRowHeight, 26)
        XCTAssertLessThan(OutlineSidebarView.filesUnavailableRootOpacity, 0.7)
        XCTAssertTrue(OutlineSidebarView.filesActionUsesPillStyle)
        XCTAssertTrue(OutlineSidebarView.filesActionButtonsUseHighContrastFill)
        XCTAssertTrue(OutlineSidebarView.filesActionButtonsReverseInDarkMode)
        XCTAssertTrue(OutlineSidebarView.filesActionButtonsShowHoverState)
        XCTAssertFalse(OutlineSidebarView.filesRootRowsShowLeadingIcons)
        XCTAssertTrue(OutlineSidebarView.filesRootRowsAlwaysShowDisclosure)
        XCTAssertTrue(OutlineSidebarView.filesRootTextFollowsDisclosureDirectly)
        XCTAssertTrue(OutlineSidebarView.filesRootDisclosureIsVisualOnly)
        XCTAssertTrue(OutlineSidebarView.filesRootTextTogglesCollapse)
        XCTAssertTrue(OutlineSidebarView.fileSelectionReplacesCurrentWindow)
        XCTAssertTrue(OutlineSidebarView.fileSelectionUsesNativeSavePrompt)
        XCTAssertEqual(OutlineSidebarView.workspaceDisconnectedSystemImage, "exclamationmark.triangle.fill")
    }

    @MainActor
    func testSidebarFileOpenerFallsBackToOpeningWhenNoCurrentWindowIsAvailable() {
        let controller = RecordingDocumentController()
        let url = URL(fileURLWithPath: "/tmp/LineformTests/Fallback.md")

        LineformSidebarFileOpener.open(url, replacing: nil, documentController: controller)

        XCTAssertEqual(controller.openedURLs, [url])
    }

    @MainActor
    func testSidebarFileOpenerDoesNotReopenCurrentDocument() throws {
        let controller = RecordingDocumentController()
        let url = URL(fileURLWithPath: "/tmp/LineformTests/Current.md")
        let document = TestDocument()
        document.setValue(url, forKey: "fileURL")
        let windowController = NSWindowController(window: NSWindow())
        document.addWindowController(windowController)

        LineformSidebarFileOpener.open(url, replacing: try XCTUnwrap(windowController.window), documentController: controller)

        XCTAssertEqual(controller.openedURLs, [])
        XCTAssertEqual(document.canCloseCallCount, 0)
    }

    @MainActor
    func testFilesTabReportsLineformICloudUnavailableWhenContainerCannotResolve() {
        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in nil }
        )

        XCTAssertEqual(store.iCloudRoot.title, "Lineform iCloud")
        XCTAssertEqual(store.iCloudRoot.state, .unavailable)
        XCTAssertEqual(store.iCloudRoot.items, [])
    }

    @MainActor
    func testFilesTabListsLineformICloudContainerWhenAccessible() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        try "not shown".write(to: folder.appendingPathComponent("Image.png"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in folder }
        )

        XCTAssertEqual(store.iCloudRoot.title, "Lineform iCloud")
        XCTAssertEqual(store.iCloudRoot.state, .available)
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["Draft.md"])
    }

    @MainActor
    func testFilesTabCreatesLineformICloudDocumentsFolderWhenContainerIsMaterialized() {
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: missingFolder)
        }
        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in missingFolder }
        )

        XCTAssertEqual(store.iCloudRoot.state, .available)
        XCTAssertEqual(store.iCloudRoot.items, [])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingFolder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testOutlineDrawerUsesFlatSidebarBackground() {
        XCTAssertFalse(OutlineSidebarView.usesSubtleGradientBackground)
        XCTAssertLessThan(OutlineSidebarView.backgroundOpacity, 1)
        XCTAssertGreaterThan(OutlineSidebarView.backgroundOpacity, 0.9)
    }

    @MainActor
    func testOutlineDrawerAdaptsChromeToEditorTheme() {
        XCTAssertFalse(OutlineSidebarView.usesThemeIndependentLightChrome)
        XCTAssertGreaterThan(OutlineSidebarView.lightBackgroundWhiteComponent, 0.95)
        XCTAssertLessThan(OutlineSidebarView.darkBackgroundWhiteComponent, 0.25)
        XCTAssertLessThan(OutlineSidebarView.primaryTextWhiteComponent, 0.25)
        XCTAssertGreaterThan(OutlineSidebarView.secondaryTextWhiteComponent, OutlineSidebarView.primaryTextWhiteComponent)
        XCTAssertLessThan(OutlineSidebarView.secondaryTextWhiteComponent, 0.55)
        XCTAssertGreaterThan(OutlineSidebarView.darkPrimaryTextWhiteComponent, 0.85)
        XCTAssertGreaterThan(OutlineSidebarView.darkSecondaryTextWhiteComponent, 0.60)
        XCTAssertLessThan(OutlineSidebarView.darkSecondaryTextWhiteComponent, OutlineSidebarView.darkPrimaryTextWhiteComponent)
    }

    @MainActor
    func testOutlineRowsExposeVisibleHoverFeedback() {
        XCTAssertTrue(OutlineSidebarView.rowsShowHoverFeedback)
        XCTAssertGreaterThan(OutlineSidebarView.rowHoverFillOpacity, 0)
        XCTAssertLessThan(OutlineSidebarView.rowHoverFillOpacity, 0.2)
    }

    @MainActor
    func testHeadingLevelsUseDistinctSidebarIcons() {
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 1), "textformat.size")
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 2), "list.bullet.indent")
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 3), "text.alignleft")
        XCTAssertEqual(OutlineSidebarView.iconName(forHeadingLevel: 6), "text.alignleft")
    }

    @MainActor
    func testOutlineTreeGroupsSectionsUnderNearestHigherLevelHeading() {
        let items = MarkdownOutlineParser().items(in: """
        # First
        ## First Section
        ### First Detail
        # Second
        ## Second Section
        """)

        let tree = OutlineSidebarView.outlineTree(from: items)

        XCTAssertEqual(tree.map(\.item.title), ["First", "Second"])
        XCTAssertEqual(tree.first?.children.map(\.item.title), ["First Section"])
        XCTAssertEqual(tree.first?.children.first?.children.map(\.item.title), ["First Detail"])
        XCTAssertEqual(tree.last?.children.map(\.item.title), ["Second Section"])
    }

}

@MainActor
private final class RecordingDocumentController: LineformDocumentOpening {
    private(set) var openedURLs: [URL] = []

    func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        openedURLs.append(url)
        completionHandler(nil, false, nil)
    }
}

@MainActor
private final class TestDocument: NSDocument {
    private(set) var canCloseCallCount = 0

    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        canCloseCallCount += 1
    }
}
