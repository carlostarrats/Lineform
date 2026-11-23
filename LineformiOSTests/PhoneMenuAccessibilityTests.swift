import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// The Menu button and the Menu sheet for VoiceOver and Dynamic Type: the header's spoken label,
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

    /// The header reads the save state, then the counts in words, through a localized format: no
    /// ASCII comma hard-coded in code.
    func testHeaderLabelIsALocalizedFormat() throws {
        let statistics = DocumentStatistics(text: "one two three")
        let counts = DocumentStatusText.countsAccessibilityText(statistics)
        let label = MenuSheet.headerAccessibilityLabel(saveState: MenuSheet.notSavedYetText, statistics: statistics)
        XCTAssertTrue(label.hasPrefix(MenuSheet.notSavedYetText), label)
        XCTAssertTrue(label.hasSuffix(counts), label)
        if interfaceLanguage == "en" {
            XCTAssertEqual(label, "Not saved yet, \(counts)")
        }
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(japanese.localizedString(forKey: "%@, %@", value: nil, table: nil), "%@、%@", "Japanese joins with its own comma")
    }

    func testDetentsOpenFullHeightAtAccessibilitySizes() {
        XCTAssertEqual(MenuSheet.detents(for: .large), [.medium, .large])
        XCTAssertEqual(MenuSheet.detents(for: .xxxLarge), [.medium, .large])
        XCTAssertEqual(MenuSheet.detents(for: .accessibility1), [.large])
        XCTAssertEqual(MenuSheet.detents(for: .accessibility5), [.large])
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

    func testConnectAIValueAndConvertAnnouncements() throws {
        XCTAssertEqual(SettingsSection.connectAIAccessibilityValue(providerName: "Claude"), "Claude")
        XCTAssertEqual(SettingsSection.connectAIAccessibilityValue(providerName: nil), SettingsSection.notConnectedText)
        let plain = DocumentSection.conversionAnnouncement(for: .plainText)
        let markdown = DocumentSection.conversionAnnouncement(for: .markdown)
        XCTAssertNotEqual(plain, markdown)
        XCTAssertFalse(MenuSheet.historyHint.isEmpty)
        if interfaceLanguage == "en" {
            XCTAssertEqual(SettingsSection.notConnectedText, "Not connected")
            XCTAssertEqual(plain, "Converted to plain text")
            XCTAssertEqual(markdown, "Converted to Markdown")
            XCTAssertEqual(MenuSheet.historyHint, "Closes the menu and opens History.")
        }
    }

    // MARK: - Hosted

    func testMenuButtonIsLabelledAndLargeEnough() async throws {
        for size in Self.sizes {
            let host = try await host(MenuButton(profile: .original, action: {}).padding(40), contentSize: size)
            let elements = host.elements()
            let button = try XCTUnwrap(elements.first { $0.label == MenuButton.accessibilityTitle }, "\(elements)")
            XCTAssertTrue(button.isInteractive)
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            host.tearDown()
        }
    }

    /// The header stacks at accessibility sizes (save state, then Done under it) and stays on
    /// one line at the default size; the section buttons and Done are 44 pt targets.
    func testSheetHeaderAndSectionBar() async throws {
        for size in Self.sizes {
            let document = try await makeDocument()
            let host = try await host(
                MenuSheet(document: document, editor: RecordingEditorCommands(text: ""), files: makeStore(), onDismiss: {}),
                contentSize: size
            )
            let elements = host.elements()
            let done = try XCTUnwrap(elements.first { $0.label == String(localized: "Done") }, "\(elements)")
            let status = try XCTUnwrap(elements.first { $0.label?.hasPrefix(MenuSheet.notSavedYetText) == true }, "\(elements)")
            if size.isAccessibilityCategory {
                XCTAssertGreaterThan(done.frame.midY, status.frame.maxY, "Done goes under the save state at \(size.rawValue)")
            } else {
                XCTAssertLessThan(done.frame.minY, status.frame.maxY, "Done shares the save state's line at \(size.rawValue)")
                XCTAssertGreaterThan(done.frame.minX, status.frame.maxX, "Done sits beside the save state")
            }
            let files = try XCTUnwrap(elements.first { $0.label == MenuSection.files.title }, "\(elements)")
            XCTAssertTrue(files.traits.contains(.selected), "the open section reads as selected")
            host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: Self.systemControls)
            assertNothingRunsOffTheSide(host, scrollsSideways: Set(MenuSection.allCases.map(\.title)))
            host.tearDown()
        }
    }

    func testFilesSection() async throws {
        try Data("hello".utf8).write(to: folder.appendingPathComponent("A rather long file name for a phone.md"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".Secret.md"))
        let store = makeStore()
        await store.setShowsHidden(true)
        for size in Self.sizes {
            let document = try await makeDocument()
            let host = try await host(FilesSection(store: store, document: document, onDismiss: {}), contentSize: size, tall: true)
            try await waitFor(host) { $0.contains { $0.label?.contains("Secret.md") == true } }
            let elements = host.elements()
            let hidden = try XCTUnwrap(elements.first { $0.label?.contains("Secret.md") == true }, "\(elements)")
            let expected = FilesRow.accessibilityValue(for: OutlineFileTreeItem(
                url: folder.appendingPathComponent(".Secret.md"), name: ".Secret.md", isDirectory: false, children: [], isHidden: true
            ))
            XCTAssertEqual(hidden.object.accessibilityValue, expected)
            host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: Self.systemControls)
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testOutlineSection() async throws {
        for size in Self.sizes {
            let host = try await host(
                OutlineSection(text: "# Alpha\n## Beta\n### Gamma", editor: RecordingEditorCommands(text: ""), onDismiss: {}),
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
            let host = try await host(BasicsSection(), contentSize: size)
            let elements = host.elements()
            let firstTitle = try XCTUnwrap(BasicsSection.sections.first?.title)
            let header = try XCTUnwrap(elements.first { $0.label == firstTitle }, "\(elements)")
            XCTAssertTrue(header.traits.contains(.header), "section titles are headers")
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    /// At AX5 the replace row goes vertical: the replacement field keeps the line's width.
    func testSearchSectionReplaceRow() async throws {
        for size in Self.sizes {
            let document = try await makeDocument()
            let commands = RecordingEditorCommands(text: "category cats")
            let host = try await host(
                SearchSection(document: document, editor: commands, files: makeStore(), onDismiss: {}),
                contentSize: size
            )
            try await waitFor(host) { _ in !Self.textFields(in: host.window).isEmpty }
            let query = try XCTUnwrap(Self.textFields(in: host.window).first)
            query.becomeFirstResponder()
            query.insertText("cat")
            let replacementLabel = String(localized: "Replacement text")
            try await waitFor(host) { $0.contains { $0.label == replacementLabel } }
            query.resignFirstResponder()
            await host.settle()
            let elements = host.elements()
            let field = try XCTUnwrap(elements.first { $0.label == replacementLabel }, "\(elements)")
            let replaceAll = try XCTUnwrap(elements.first { $0.label == String(localized: "Replace All") }, "\(elements)")
            if size.isAccessibilityCategory {
                XCTAssertGreaterThan(field.frame.width, host.window.bounds.width * 0.6, "the field keeps the line at \(size.rawValue)")
                XCTAssertGreaterThan(replaceAll.frame.midY, field.frame.maxY, "the buttons go under the field")
            } else {
                XCTAssertLessThan(replaceAll.frame.minY, field.frame.maxY, "one line at the default size")
            }
            host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: Self.systemControls)
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testDocumentSection() async throws {
        for size in Self.sizes {
            let document = try await makeDocument()
            let host = try await host(
                DocumentSection(document: document, editor: RecordingEditorCommands(text: ""), files: makeStore(), onDismiss: {}),
                contentSize: size
            )
            host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: Self.systemControls)
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    func testSettingsSection() async throws {
        let settings = AppSettings(defaults: defaults)
        let aiStore = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        for size in Self.sizes {
            let host = try await host(SettingsSection(settings: settings, aiStore: aiStore), contentSize: size, tall: true)
            let elements = host.elements()
            let darkMode = try XCTUnwrap(elements.first { $0.label == SettingsSection.rows[0].title }, "\(elements)")
            XCTAssertEqual(darkMode.object.accessibilityHint, SettingsSection.rows[0].note, "the note is the hint, not the label")
            let connect = try XCTUnwrap(elements.first { $0.identifier == "settings.connectAI" }, "\(elements)")
            XCTAssertEqual(connect.label, SettingsSection.connectAITitle)
            XCTAssertEqual(connect.object.accessibilityValue, SettingsSection.notConnectedText)
            host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: Self.systemControls)
            assertNothingRunsOffTheSide(host)
            host.tearDown()
        }
    }

    // MARK: - Helpers

    private static let sizes: [UIContentSizeCategory] = [.large, .accessibilityExtraExtraExtraLarge]

    /// System controls drawn at their own size, which no padding of ours can grow without
    /// changing how they look: the segmented filter's segments and a bordered button
    /// (Clear…), both about 32 pt tall at the default size.
    private static var systemControls: Set<String> {
        Set(SearchFilter.allCases.map(\.title) + [SettingsSection.clearHistoryTitle])
    }

    /// `tall`: a window several screens high, so a lazy list lays out every row at AX5 (the
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
