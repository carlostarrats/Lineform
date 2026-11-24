import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// The ⋯ button and the word menu for VoiceOver and Dynamic Type: the status line's spoken label,
/// the values rows add (hidden and not-downloaded files, heading levels, the AI connection), the
/// announcements (Copied, Convert), and every section hosted at the default size and at AX5 with
/// its targets labelled and at least 44 pt, and nothing running off the side of the screen.
@MainActor
final class PhoneMenuAccessibilityTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var host: PhoneAccessibilityHost?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-a11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "PhoneMenuAccessibilityTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        host?.tearDown()
        host = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Spoken text

    /// The status line reads the name, the save state, then the counts in words, through a
    /// localized format: no ASCII comma hard-coded in code.
    func testStatusLabelIsALocalizedFormat() throws {
        let statistics = DocumentStatistics(text: "one two three")
        let counts = DocumentStatusText.countsAccessibilityText(statistics)
        let label = WordMenu.statusAccessibilityLabel(title: "Notes", saveState: WordMenu.notSavedYetText, statistics: statistics)
        XCTAssertTrue(label.hasPrefix("Notes"), label)
        XCTAssertTrue(label.contains(WordMenu.notSavedYetText), label)
        XCTAssertTrue(label.hasSuffix(counts), label)
        if interfaceLanguage == "en" {
            XCTAssertEqual(label, "Notes, Not saved yet, \(counts)")
        }
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(japanese.localizedString(forKey: "%@, %@, %@", value: nil, table: nil), "%@、%@、%@", "Japanese joins with its own comma")
    }

    func testFilesRowSaysHiddenAndNotDownloaded() throws {
        func item(hidden: Bool, placeholder: Bool) -> OutlineFileTreeItem {
            OutlineFileTreeItem(
                url: folder.appendingPathComponent("A.md"), name: "A.md", isDirectory: false, children: [],
                isHidden: hidden, isICloudPlaceholder: placeholder
            )
        }
        XCTAssertNil(FilesRow.accessibilityValue(for: item(hidden: false, placeholder: false)))
        let values = [
            FilesRow.accessibilityValue(for: item(hidden: true, placeholder: false)),
            FilesRow.accessibilityValue(for: item(hidden: false, placeholder: true)),
            FilesRow.accessibilityValue(for: item(hidden: true, placeholder: true)),
        ].compactMap { $0 }
        XCTAssertEqual(Set(values).count, 3, "each state reads differently: \(values)")
        XCTAssertTrue(values.allSatisfy { !$0.isEmpty })
        if interfaceLanguage == "en" {
            XCTAssertEqual(values, ["Hidden", "Not downloaded", "Hidden, not downloaded"])
        }
        XCTAssertEqual(FilesRow.nameLineLimit(for: .large), 1)
        XCTAssertEqual(FilesRow.nameLineLimit(for: .accessibility5), 3)
    }

    func testOutlineRowsSpeakTheirHeadingLevel() throws {
        let rows = OutlineModel.rows(for: "# Alpha\n## Beta\n### Gamma")
        XCTAssertEqual(rows.count, 3)
        let values = rows.map { OutlineSection.accessibilityValue(for: $0) }
        for (row, value) in zip(rows, values) {
            XCTAssertTrue(value.contains("\(row.item.level)"), value)
        }
        if interfaceLanguage == "en" {
            XCTAssertEqual(values, ["Heading level 1", "Heading level 2", "Heading level 3"])
        }
        XCTAssertEqual(OutlineSection.lineLimit(for: .large), 2)
        XCTAssertNil(OutlineSection.lineLimit(for: .accessibility3))
        // The Mac sidebar's level icons.
        XCTAssertEqual(OutlineSection.iconName(forHeadingLevel: 1), "textformat.size")
        XCTAssertEqual(OutlineSection.iconName(forHeadingLevel: 2), "list.bullet.indent")
        XCTAssertEqual(OutlineSection.iconName(forHeadingLevel: 4), "text.alignleft")
    }

    /// "Copied" is announced: a value change alone is not re-read by VoiceOver.
    func testBasicsCopyAnnouncesCopied() throws {
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("lineform-a11y-\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        var announced: [String] = []
        let state = BasicsCopyState(announce: { text in announced.append(text) })
        let rows = MarkdownReference.sections.flatMap(\.rows)
        let codeRow = try XCTUnwrap(rows.first { $0.copyAffordance() != nil })
        let labelRow = try XCTUnwrap(rows.first { $0.copyAffordance() == nil })

        XCTAssertFalse(state.copy(labelRow, to: board))
        XCTAssertEqual(announced, [], "nothing copied, nothing said")
        XCTAssertTrue(state.copy(codeRow, to: board))
        XCTAssertEqual(announced, [BasicsSection.copiedText])
        XCTAssertFalse(BasicsSection.copiedText.isEmpty)
    }

    func testConvertAnnouncementsAndLeavingHints() throws {
        let plain = ExportPrintSection.conversionAnnouncement(for: .plainText)
        let markdown = ExportPrintSection.conversionAnnouncement(for: .markdown)
        XCTAssertNotEqual(plain, markdown)
        XCTAssertFalse(WordMenuItem.themes.accessibilityHint?.isEmpty ?? true)
        XCTAssertFalse(WordMenuItem.readAloud.accessibilityHint?.isEmpty ?? true)
        if interfaceLanguage == "en" {
            XCTAssertEqual(plain, "Converted to plain text")
            XCTAssertEqual(markdown, "Converted to Markdown")
            XCTAssertEqual(WordMenuItem.themes.accessibilityHint, "Closes the menu and opens the reading themes.")
        }
    }

    // MARK: - Hosted

    func testMoreButtonIsLabelledAndLargeEnough() async throws {
        for size in Self.sizes {
            let host = try await host(MoreButton(profile: .original, action: {}).padding(40), contentSize: size)
            let elements = host.elements()
            let button = try XCTUnwrap(elements.first { $0.label == MoreButton.accessibilityTitle }, "\(elements)")
            XCTAssertTrue(button.isInteractive)
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            host.tearDown()
        }
    }

    /// The word list: every word a labelled 44 pt button, the status line one element, the
    /// corner button labelled Close menu, nothing off the side at AX5.
    func testWordList() async throws {
        for size in Self.sizes {
            let document = try await makeDocument()
            let host = try await host(wordMenu(document: document), contentSize: size, tall: true)
            let elements = host.elements()
            for item in WordMenuItem.visible(hasHistory: false) {
                let word = try XCTUnwrap(elements.first { $0.label == item.title }, "\(item) in \(elements)")
                XCTAssertTrue(word.isInteractive, item.title)
            }
            XCTAssertNotNil(elements.first { $0.label == WordMenuCornerButton.Glyph.close.accessibilityLabel }, "\(elements)")
            XCTAssertNotNil(elements.first { $0.identifier == "wordMenu.status" }, "\(elements)")
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testFilesSection() async throws {
        try Data("hello".utf8).write(to: folder.appendingPathComponent("A rather long file name for a phone.md"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".Secret.md"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Journal"), withIntermediateDirectories: true)
        let store = makeStore()
        await store.setShowsHidden(true)
        store.setVisible(true)
        await store.scanIfVisible()
        for size in Self.sizes {
            let document = try await makeDocument()
            let host = try await host(page(FilesSection(store: store, document: document, onDismiss: {})), contentSize: size, tall: true)
            try await waitFor(host) { $0.contains { $0.label?.contains("Secret") == true } }
            let elements = host.elements()
            let hidden = try XCTUnwrap(elements.first { $0.label == ".Secret" }, "\(elements)")
            XCTAssertTrue((hidden.object.accessibilityValue ?? "").contains(FilesRow.accessibilityValue(for: OutlineFileTreeItem(
                url: folder.appendingPathComponent(".Secret.md"), name: ".Secret.md", isDirectory: false, children: [], isHidden: true
            )) ?? "-"))
            // Swipe actions are custom actions too.
            XCTAssertTrue((hidden.object.accessibilityCustomActions ?? []).contains { $0.name == FilesRowAction.delete.title })
            XCTAssertNotNil(elements.first { $0.label?.contains("Journal") == true }, "folders are rows")
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testOutlineSection() async throws {
        for size in Self.sizes {
            let host = try await host(
                page(OutlineSection(text: "# Alpha\n## Beta\n### Gamma", editor: RecordingEditorCommands(text: ""), onDismiss: {})),
                contentSize: size
            )
            try await waitFor(host) { $0.contains { $0.label == "Gamma" } }
            let gamma = try XCTUnwrap(host.elements().first { $0.label == "Gamma" })
            XCTAssertEqual(gamma.object.accessibilityValue, String(localized: "Heading level \(3)"))
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testBasicsSection() async throws {
        for size in Self.sizes {
            let host = try await host(page(BasicsSection()), contentSize: size)
            let elements = host.elements()
            let header = try XCTUnwrap(elements.first { $0.label == WordMenuItem.basics.title }, "\(elements)")
            XCTAssertTrue(header.traits.contains(.header), "the page title is a header")
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testExportPrintSection() async throws {
        for size in Self.sizes {
            let document = try await makeDocument()
            let host = try await host(
                page(ExportPrintSection(document: document, exportCommands: ExportCommands(document: document, profile: { .original }), onDismiss: {})),
                contentSize: size, tall: true
            )
            XCTAssertNotNil(host.elements().first { $0.label?.contains(ExportPrintSection.saveAsTitle) == true })
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testSettingsSection() async throws {
        let settings = AppSettings(defaults: defaults)
        for size in Self.sizes {
            let host = try await host(
                page(SettingsSection(settings: settings, files: makeStore(), editor: RecordingEditorCommands(text: ""))),
                contentSize: size, tall: true
            )
            let elements = host.elements()
            let darkMode = try XCTUnwrap(elements.first { $0.label == SettingsSection.rows[0].title }, "\(elements)")
            XCTAssertEqual(darkMode.object.accessibilityHint, SettingsSection.rows[0].note, "the note is the hint, not the label")
            XCTAssertNotNil(elements.first { $0.identifier == "settings.checkDocument" }, "Check Document Now lives here")
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testAboutAndConnectSections() async throws {
        let aiStore = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        for size in Self.sizes {
            let about = try await host(page(AboutSection(updateCommand: PhoneUpdateCommand.shared)), contentSize: size)
            XCTAssertNotNil(about.elements().first { $0.label == AboutSection.versionText() })
            about.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(about)
            about.tearDown()

            let connect = try await host(page(ConnectAISection(store: aiStore)), contentSize: size, tall: true)
            connect.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(connect)
            connect.tearDown()
        }
    }

    // MARK: - Helpers

    private static let sizes: [UIContentSizeCategory] = [.large, .accessibilityExtraExtraExtraLarge]

    /// A page as the menu draws it: the palette in the environment, on the wash.
    private func page<Content: View>(_ content: Content) -> some View {
        content
            .environment(\.wordMenuPalette, WordMenuPalette(isDark: false))
            .background(WordMenuPalette(isDark: false).wash)
    }

    private func wordMenu(document: OpenDocument) -> some View {
        WordMenu(
            document: document,
            editor: RecordingEditorCommands(text: ""),
            files: makeStore(),
            settings: AppSettings(defaults: defaults),
            profile: .original,
            exportCommands: nil,
            mode: .write,
            aiStore: AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain()),
            onClose: {}, onThemes: {}, onReadAloud: {}, onShowHistoryPassage: { _ in }, onAskAI: {}
        )
    }

    /// `tall`: a window several screens high, so a lazy stack lays out every row at AX5 (the
    /// check is about width, not about what one screen shows).
    private func host<Content: View>(
        _ view: Content, contentSize: UIContentSizeCategory, tall: Bool = false
    ) async throws -> PhoneAccessibilityHost {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = tall ? CGSize(width: scene.screen.bounds.width, height: 5000) : nil
        let host = try await PhoneAccessibilityHost(view, contentSize: contentSize, size: size)
        self.host = host
        return host
    }

    private func makeDocument() async throws -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: FakeUbiquitousItems(arrivingText: nil))
        await document.prepare()
        return document
    }

    private func makeStore() -> FilesStore {
        FilesStore(
            defaults: defaults,
            iCloudFolder: { nil },
            deviceFolder: folder,
            bookmarks: FakeBookmarks(resolvesTo: nil),
            fileOperations: RecordingFileOperations()
        )
    }

    private func waitFor(
        _ host: PhoneAccessibilityHost,
        _ condition: ([PhoneAccessibilityHost.Element]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(host.elements()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            host.window.layoutIfNeeded()
        }
        await host.settle()
        XCTAssertTrue(condition(host.elements()), "\(host.elements())")
    }

    /// Text that grows with Dynamic Type must wrap, never run off the sides of the screen. Lists
    /// scroll vertically, so the bottom edge may cut a row; `scrollsSideways` names elements in a
    /// sideways-scrolling bar, which the side edges may cut.
    private func assertNothingRunsOffTheSide(
        _ host: PhoneAccessibilityHost,
        scrollsSideways: Set<String> = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bounds = host.windowFrameOnScreen.insetBy(dx: -0.5, dy: -0.5)
        let elements = host.elements()
        XCTAssertFalse(elements.isEmpty, file: file, line: line)
        for element in elements where !element.frame.isEmpty && element.frame.intersects(bounds) {
            guard !scrollsSideways.contains(element.name) else { continue }
            XCTAssertTrue(
                element.frame.minX >= bounds.minX && element.frame.maxX <= bounds.maxX,
                "\(element) runs off the side at \(host.contentSize.rawValue)",
                file: file, line: line
            )
        }
    }

    private static func textFields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        func walk(_ view: UIView) {
            if let field = view as? UITextField { found.append(field) }
            view.subviews.forEach { walk($0) }
        }
        walk(view)
        return found.sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }
}
