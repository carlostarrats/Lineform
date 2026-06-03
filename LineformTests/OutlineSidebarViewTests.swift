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
    func testSidebarFileOpenerDoesNotPromptOrReloadCurrentDocument() throws {
        let controller = RecordingDocumentController()
        let url = URL(fileURLWithPath: "/tmp/LineformTests/Current.md")
        let document = TestDocument()
        document.setValue(url, forKey: "fileURL")
        let windowController = NSWindowController(window: NSWindow())
        document.addWindowController(windowController)
        var replacement: LineformDocument?

        LineformSidebarFileOpener.open(
            url,
            replacing: try XCTUnwrap(windowController.window),
            updateEditorDocument: { loadedDocument in
                replacement = loadedDocument
                return loadedDocument.id
            },
            documentController: controller
        )

        XCTAssertEqual(controller.openedURLs, [])
        XCTAssertNil(replacement)
        XCTAssertEqual(document.canCloseCallCount, 0)
    }

    @MainActor
    func testSidebarFileReplacementLoadsSelectedFileIntoCurrentDocumentSession() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let url = folder.appendingPathComponent("Next.md")
        try "# Next\n\nSame window.".write(to: url, atomically: true, encoding: .utf8)

        let controller = RecordingDocumentController()
        let backingDocument = TestDocument()
        let previousURL = folder.appendingPathComponent("Previous.md")
        backingDocument.setValue(previousURL, forKey: "fileURL")
        backingDocument.updateChangeCount(.changeDone)
        var replacement: LineformDocument?
        let activeDocumentID = UUID()

        try LineformSidebarFileOpener.replaceCurrentDocument(
            with: url,
            backingDocument: backingDocument,
            updateEditorDocument: { loadedDocument in
                replacement = loadedDocument
                return activeDocumentID
            },
            documentController: controller
        )

        XCTAssertEqual(replacement?.text, "# Next\n\nSame window.")
        XCTAssertEqual(replacement?.textFormat, .markdown)
        XCTAssertEqual(backingDocument.fileURL?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(backingDocument.fileType, LineformDocument.contentType(for: url).identifier)
        XCTAssertFalse(backingDocument.isDocumentEdited)
        XCTAssertEqual(controller.recentDocumentURLs, [url])
        XCTAssertEqual(controller.openedURLs, [])
        XCTAssertNotNil(DocumentSaveStatus.shared.savedAt(for: activeDocumentID))
    }

    @MainActor
    func testSidebarFileReplacementOnlyRetargetsChosenWindowWhenMultipleDocumentsAreOpen() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let firstOriginalURL = folder.appendingPathComponent("First.md")
        let firstReplacementURL = folder.appendingPathComponent("First Replacement.md")
        let secondURL = folder.appendingPathComponent("Second.md")
        try "# First".write(to: firstOriginalURL, atomically: true, encoding: .utf8)
        try "# First Replacement".write(to: firstReplacementURL, atomically: true, encoding: .utf8)
        try "# Second".write(to: secondURL, atomically: true, encoding: .utf8)

        let controller = RecordingDocumentController()
        let firstDocument = TestDocument()
        let secondDocument = TestDocument()
        firstDocument.setValue(firstOriginalURL, forKey: "fileURL")
        secondDocument.setValue(secondURL, forKey: "fileURL")
        secondDocument.updateChangeCount(.changeDone)

        let firstWindowController = NSWindowController(window: NSWindow())
        let secondWindowController = NSWindowController(window: NSWindow())
        firstDocument.addWindowController(firstWindowController)
        secondDocument.addWindowController(secondWindowController)
        var firstReplacement: LineformDocument?
        let firstDocumentID = UUID()
        let secondReplacement: LineformDocument? = nil

        try LineformSidebarFileOpener.replaceCurrentDocument(
            with: firstReplacementURL,
            backingDocument: firstDocument,
            window: try XCTUnwrap(firstWindowController.window),
            updateEditorDocument: { loadedDocument in
                firstReplacement = loadedDocument
                return firstDocumentID
            },
            documentController: controller
        )

        XCTAssertEqual(firstReplacement?.text, "# First Replacement")
        XCTAssertNil(secondReplacement)
        XCTAssertEqual(firstDocument.fileURL?.standardizedFileURL, firstReplacementURL.standardizedFileURL)
        XCTAssertFalse(firstDocument.isDocumentEdited)
        XCTAssertEqual(firstWindowController.window?.representedURL?.standardizedFileURL, firstReplacementURL.standardizedFileURL)
        XCTAssertEqual(secondDocument.fileURL?.standardizedFileURL, secondURL.standardizedFileURL)
        XCTAssertTrue(secondDocument.isDocumentEdited)
        XCTAssertEqual(secondWindowController.window?.representedURL?.standardizedFileURL, secondURL.standardizedFileURL)
        XCTAssertEqual(controller.recentDocumentURLs, [firstReplacementURL])
        XCTAssertEqual(controller.openedURLs, [])
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
    private(set) var recentDocumentURLs: [URL] = []

    func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        openedURLs.append(url)
        completionHandler(nil, false, nil)
    }

    func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.append(url)
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
