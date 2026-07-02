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
        store.refreshICloud()

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
        store.refreshICloud()

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
        store.refreshICloud()

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
    func testSelectedFileRowUsesSoftTranslucentAccentTint() {
        // A translucent tint (native source-list selection), never a solid fill, and clearly
        // stronger than the hover feedback so the current file reads as selected.
        XCTAssertGreaterThan(OutlineSidebarView.rowSelectionFillOpacity, OutlineSidebarView.rowHoverFillOpacity)
        XCTAssertLessThan(OutlineSidebarView.rowSelectionFillOpacity, 0.4)
    }

    @MainActor
    func testFileRowIsSelectedOnlyForTheCurrentlyShownFile() {
        let current = URL(fileURLWithPath: "/Users/writer/Documents/notes/today.md")

        // The shown file matches; a different file does not.
        XCTAssertTrue(OutlineSidebarView.fileRowIsSelected(itemURL: current, isDirectory: false, currentFileURL: current))
        XCTAssertFalse(OutlineSidebarView.fileRowIsSelected(
            itemURL: URL(fileURLWithPath: "/Users/writer/Documents/notes/other.md"),
            isDirectory: false,
            currentFileURL: current
        ))
    }

    @MainActor
    func testFileRowIsSelectedNeverMatchesFoldersOrUntitledDocuments() {
        let current = URL(fileURLWithPath: "/Users/writer/Documents/notes/today.md")

        // A folder whose URL equals the current file's is still never selectable.
        XCTAssertFalse(OutlineSidebarView.fileRowIsSelected(itemURL: current, isDirectory: true, currentFileURL: current))
        // An untitled document (no on-disk URL) selects nothing.
        XCTAssertFalse(OutlineSidebarView.fileRowIsSelected(itemURL: current, isDirectory: false, currentFileURL: nil))
    }

    @MainActor
    func testFileRowIsSelectedStandardizesRelativePathComponents() {
        // The match survives non-canonical `.`/`..` components — the same standardization the
        // sidebar file opener uses (OutlineSidebarView line ~1356) so a file opened from the
        // sidebar reliably matches its own row.
        XCTAssertTrue(OutlineSidebarView.fileRowIsSelected(
            itemURL: URL(fileURLWithPath: "/Users/writer/Documents/notes/today.md"),
            isDirectory: false,
            currentFileURL: URL(fileURLWithPath: "/Users/writer/Documents/drafts/../notes/today.md")
        ))
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

    @MainActor
    func testEnsureDownloadedRequestsEveryICloudFileRecursivelyButNotFolders() {
        let downloader = RecordingUbiquitousDownloader()
        let items = [
            OutlineFileTreeItem(
                url: URL(fileURLWithPath: "/c/Documents/a.md"),
                name: "a.md",
                isDirectory: false,
                children: []
            ),
            OutlineFileTreeItem(
                url: URL(fileURLWithPath: "/c/Documents/Sub"),
                name: "Sub",
                isDirectory: true,
                children: [
                    OutlineFileTreeItem(
                        url: URL(fileURLWithPath: "/c/Documents/Sub/b.md"),
                        name: "b.md",
                        isDirectory: false,
                        children: []
                    ),
                    OutlineFileTreeItem(
                        url: URL(fileURLWithPath: "/c/Documents/Sub/c.txt"),
                        name: "c.txt",
                        isDirectory: false,
                        children: []
                    ),
                ]
            ),
        ]

        let requested = OutlineFileBrowserStore.ensureDownloaded(items, using: downloader)

        // Every file (including nested) is asked to download; folders are not.
        XCTAssertEqual(Set(downloader.requestedURLs.map(\.lastPathComponent)), ["a.md", "b.md", "c.txt"])
        XCTAssertEqual(Set(requested.map(\.lastPathComponent)), ["a.md", "b.md", "c.txt"])
    }

    @MainActor
    func testEnsureDownloadedSkipsItemsThatCannotBeMaterialized() {
        let downloader = ThrowingUbiquitousDownloader()
        let items = [
            OutlineFileTreeItem(
                url: URL(fileURLWithPath: "/c/Documents/a.md"),
                name: "a.md",
                isDirectory: false,
                children: []
            ),
        ]

        let requested = OutlineFileBrowserStore.ensureDownloaded(items, using: downloader)

        // A throwing (non-ubiquitous/transient) item must be skipped, not crash.
        XCTAssertTrue(requested.isEmpty)
    }

    @MainActor
    func testFilesTabKeepsLineformICloudFilesDownloaded() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let downloader = RecordingUbiquitousDownloader()
        let store = OutlineFileBrowserStore(
            defaults: defaults,
            fileManager: .default,
            iCloudDocumentsURLProvider: { _ in folder },
            iCloudDownloader: downloader
        )
        store.refreshICloud()

        // Listing the iCloud container must proactively keep its files downloaded.
        XCTAssertEqual(downloader.requestedURLs.map(\.lastPathComponent), ["Draft.md"])
    }

    // MARK: - Hidden folders
    // The user-facing "Show Hidden Folders" control now lives in the View menu; its title
    // and shortcut are asserted in AppCommandNotificationTests. The store behavior below is
    // unchanged.

    func testLegacyTreeItemSnapshotDecodesWithHiddenFalse() throws {
        let legacyJSON = """
        [{"url":"file:///tmp/Draft.md","name":"Draft.md","isDirectory":false,"children":[]}]
        """.data(using: .utf8)!
        let items = try JSONDecoder().decode([OutlineFileTreeItem].self, from: legacyJSON)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "Draft.md")
        XCTAssertEqual(items.first?.isHidden, false)
    }

    func testTreeItemRoundTripsHiddenFlag() throws {
        let item = OutlineFileTreeItem(url: URL(fileURLWithPath: "/tmp/.claude"), name: ".claude", isDirectory: true, children: [], isHidden: true)
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([OutlineFileTreeItem].self, from: data)
        XCTAssertEqual(decoded.first?.isHidden, true)
    }

    @MainActor
    func testHiddenFoldersExcludedByDefault() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "# Notes".write(to: folder.appendingPathComponent(".claude/notes.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "# Readme".write(to: folder.appendingPathComponent("node_modules/readme.md"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in folder })
        store.refreshICloud()
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["Draft.md"])
    }

    @MainActor
    func testShowHiddenFoldersRevealsDotFoldersButNotBlocklist() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "# Notes".write(to: folder.appendingPathComponent(".claude/notes.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "# Readme".write(to: folder.appendingPathComponent("node_modules/readme.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "# Git".write(to: folder.appendingPathComponent(".git/config.md"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in folder })
        store.showsHiddenFolders = true
        store.refreshICloud()

        XCTAssertEqual(store.iCloudRoot.items.map(\.name), [".claude", "Draft.md"])
        let claude = try XCTUnwrap(store.iCloudRoot.items.first { $0.name == ".claude" })
        XCTAssertTrue(claude.isHidden)
        XCTAssertEqual(claude.children.map(\.name), ["notes.md"])
        XCTAssertEqual(claude.children.first?.isHidden, true)
        let draft = try XCTUnwrap(store.iCloudRoot.items.first { $0.name == "Draft.md" })
        XCTAssertFalse(draft.isHidden)
    }

    @MainActor
    func testTogglingHiddenFoldersOffFiltersInMemory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try "# Draft".write(to: folder.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "# Notes".write(to: folder.appendingPathComponent(".claude/notes.md"), atomically: true, encoding: .utf8)

        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in folder })
        store.showsHiddenFolders = true
        store.refreshICloud()
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), [".claude", "Draft.md"])

        // Toggling OFF filters the already-scanned tree; hidden rows disappear even though
        // no fresh scan ran (the fast path republishes the cached superset, filtered).
        store.showsHiddenFolders = false
        XCTAssertEqual(store.iCloudRoot.items.map(\.name), ["Draft.md"])
    }

    @MainActor
    func testShowHiddenFoldersPreferencePersists() throws {
        let suiteName = "LineformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in nil })
        first.showsHiddenFolders = true

        let second = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in nil })
        XCTAssertTrue(second.showsHiddenFolders)
    }

}

private final class RecordingUbiquitousDownloader: UbiquitousItemDownloader {
    private(set) var requestedURLs: [URL] = []

    func startDownloadingUbiquitousItem(at url: URL) throws {
        requestedURLs.append(url)
    }
}

private struct ThrowingDownloadError: Error {}

private final class ThrowingUbiquitousDownloader: UbiquitousItemDownloader {
    func startDownloadingUbiquitousItem(at url: URL) throws {
        throw ThrowingDownloadError()
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
