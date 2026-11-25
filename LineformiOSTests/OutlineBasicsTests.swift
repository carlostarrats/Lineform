import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Menu sheet's Outline and Markdown Basics sections: the heading tree of the current text
/// (rebuilt 0.3 s after the text changes), a heading tap that closes the sheet and scrolls the
/// heading to the top, the empty state, and Basics rows that copy their Markdown.
@MainActor
final class OutlineBasicsTests: XCTestCase {
    private var window: UIWindow?
    private var pasteboard: UIPasteboard?

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let pasteboard { UIPasteboard.remove(withName: pasteboard.name) }
    }

    // MARK: - Outline

    func testOutlineListsHeadingsInOrder() async throws {
        let text = "# Title\r\nIntro\r\n## One\r\n### One A\r\n## Two\r\n```\r\n# not a heading\r\n```\r\n# Second"
        let model = OutlineModel(text: text)
        XCTAssertEqual(model.rows.map(\.item.title), ["Title", "One", "One A", "Two", "Second"],
                       "document order; a fenced # line is code, not a heading")
        XCTAssertEqual(model.rows.map(\.depth), [0, 1, 2, 1, 0], "indented by the heading tree")
        let source = text as NSString
        XCTAssertEqual(source.substring(with: model.rows[2].item.characterRange), "### One A")

        // A change waits out the 0.3 s rebuild delay, then lands; an edit inside the delay restarts it.
        XCTAssertEqual(OutlineModel.rebuildDelay, .milliseconds(300))
        model.textChanged("# Changed")
        XCTAssertEqual(model.rows.map(\.item.title), ["Title", "One", "One A", "Two", "Second"], "not before the delay")
        try await Task.sleep(for: .milliseconds(150))
        model.textChanged("# Latest\n## Child")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.rows.first?.item.title, "Title", "the second edit restarted the delay")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.rows.map(\.item.title), ["Latest", "Child"], "the latest text wins")
        XCTAssertEqual(model.rows.map(\.depth), [0, 1])
    }

    func testTapHeadingDismissesAndScrolls() throws {
        let text = "# Top\n\nBody\n\n## Target\nMore"
        let model = OutlineModel(text: text)
        let target = try XCTUnwrap(model.rows.last)
        let commands = RecordingEditorCommands(text: text)
        var events: [String] = []
        commands.onScroll = { events.append("scroll \($0.location)") }

        OutlineSection.open(target, editor: commands, dismiss: { events.append("dismiss") })

        let location = (text as NSString).range(of: "## Target").location
        XCTAssertEqual(events, ["dismiss", "scroll \(location)"],
                       "the sheet closes, then the heading is scrolled to the top of the surface on screen")
        XCTAssertEqual(commands.scrolled, [target.item.characterRange])
        XCTAssertEqual(commands.selected, [], "a heading tap moves the view, not the selection")

        // Through the live commands in Write, the heading lands at the top of the editor.
        let lines = (0..<120).map { "Line \($0) of the body text." }.joined(separator: "\n")
        let long = "# Start\n\(lines)\n## Far\n\(lines)\nEnd"
        let (live, editor) = try liveCommands(text: long, mode: .write)
        let far = try XCTUnwrap(OutlineModel(text: long).rows.last)
        OutlineSection.open(far, editor: live, dismiss: {})
        editor.layoutIfNeeded()
        let top = try XCTUnwrap(editor.topVisibleSourceLocation())
        let farLine = (long as NSString).lineRange(for: NSRange(location: far.item.characterRange.location, length: 0))
        XCTAssertTrue(NSLocationInRange(top, farLine) || abs(top - far.item.characterRange.location) < 40,
                      "the Far heading is at the top (top \(top), heading \(far.item.characterRange.location))")
    }

    func testOutlineEmptyState() throws {
        try skipUnlessEnglishInterface()
        // pinned-en: the Mac's empty-state wording.
        XCTAssertEqual(OutlineSection.emptyText, "Add # Title or ## Section to build an outline.")
        XCTAssertFalse(OutlineSection.emptyText.contains("Mac"))
        XCTAssertFalse(OutlineSection.emptyText.localizedCaseInsensitiveContains("sidebar"))
        XCTAssertEqual(OutlineModel(text: "Just prose.\n\nMore prose.").rows, [])
        XCTAssertEqual(OutlineModel(text: "").rows, [])

        let window = try host(OutlineSection(text: "No headings here.", editor: RecordingEditorCommands(text: ""), onDismiss: {}))
        settle(window)
        XCTAssertNotNil(Self.find("Add # Title or ## Section to build an outline.", in: window), "the empty state shows")

        let filled = try host(OutlineSection(text: "# Alpha\n## Beta", editor: RecordingEditorCommands(text: ""), onDismiss: {}))
        settle(filled)
        XCTAssertNotNil(Self.find("Alpha", in: filled))
        XCTAssertNotNil(Self.find("Beta", in: filled))
        XCTAssertNil(Self.find("Add # Title", in: filled))
    }

    // MARK: - Markdown Basics

    /// Markdown Basics is the mockup's groups, each its own card: every reference row exactly
    /// once, the first section split into Headings, Emphasis, Lists, Links & images and Blocks,
    /// and every code row named.
    func testBasicsGroupsShowEveryRowOnce() throws {
        try skipUnlessEnglishInterface()
        let groups = BasicsSection.groups
        XCTAssertEqual(Array(groups.prefix(5).map(\.title)), ["Headings", "Emphasis", "Lists", "Links & images", "Blocks"])
        XCTAssertEqual(Set(groups.flatMap(\.rows).map(\.id)), Set(MarkdownReference.sections.flatMap(\.rows).map(\.id)))
        XCTAssertEqual(groups.flatMap(\.rows).count, MarkdownReference.sections.flatMap(\.rows).count)
        let bold = try XCTUnwrap(MarkdownReference.sections.flatMap(\.rows).first { $0.id == "**bold**" })
        XCTAssertEqual(BasicsSection.name(for: bold), "Bold")
        for row in MarkdownReference.sections.flatMap(\.rows) {
            XCTAssertFalse(BasicsSection.name(for: row).isEmpty, row.id)
        }
    }

    func testBasicsRowCopies() async throws {
        try skipUnlessEnglishInterface()
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("lineform-basics-\(UUID().uuidString)"), create: true))
        pasteboard = board
        XCTAssertEqual(BasicsSection.sections, MarkdownReference.sections, "the package's sections, in order")
        XCTAssertEqual(BasicsSection.copiedDuration, .seconds(1))
        // pinned-en
        XCTAssertEqual(BasicsSection.copiedText, "Copied")

        let rows = MarkdownReference.sections.flatMap(\.rows)
        let codeRow = try XCTUnwrap(rows.first { $0.copyAffordance() != nil })
        let labelRow = try XCTUnwrap(rows.first { $0.copyAffordance() == nil })
        let state = BasicsCopyState()

        XCTAssertTrue(state.copy(codeRow, to: board))
        XCTAssertEqual(board.string, codeRow.copyAffordance()?.text, "the row's copy affordance lands on the pasteboard")
        XCTAssertEqual(state.copiedRowID, codeRow.id, "the row shows Copied")

        board.string = "kept"
        XCTAssertFalse(state.copy(labelRow, to: board), "a label row has nothing to copy")
        XCTAssertEqual(board.string, "kept")
        XCTAssertEqual(state.copiedRowID, codeRow.id)

        try await Task.sleep(for: .milliseconds(1250))
        XCTAssertNil(state.copiedRowID, "Copied shows for 1 s")
    }

    // MARK: - Helpers

    private func liveCommands(text: String, mode: EditorDisplayMode) throws -> (LiveEditorCommands, LineformTextView) {
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        host.view.addSubview(editor)
        window.isHidden = false
        self.window = window
        editor.layoutIfNeeded()
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        keepers.append(keeper)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outline-\(UUID().uuidString)")
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: OutlineTestUbiquitousItems())
        return (LiveEditorCommands(positionKeeper: keeper, document: document, mode: mode), editor)
    }

    private var keepers: [ModePositionKeeper] = []
    private var hosts: [UIWindow] = []

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        hosts.append(window)
        self.window = window
        return window
    }

    private func settle(_ window: UIWindow, ticks: Int = 10) {
        for _ in 0..<ticks {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
        }
    }

    /// The first accessibility element whose label contains `label`.
    static func find(_ label: String, in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if let own = root.accessibilityLabel, own.contains(label), !(root is UIWindow) { return root }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        if let elements = root.accessibilityElements as? [NSObject] { children += elements }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = root.accessibilityElement(at: index) as? NSObject { children.append(element) }
            }
        }
        for child in children where child !== root {
            if let found = find(label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

/// Editor commands that record what a section asked for, over a plain string.
@MainActor
final class RecordingEditorCommands: EditorCommands {
    var text: String
    var scrolled: [NSRange] = []
    var selected: [NSRange] = []
    var replaced: [(range: NSRange, replacement: String)] = []
    var replacedAll: [(ranges: [NSRange], replacement: String)] = []
    var onScroll: (NSRange) -> Void = { _ in }
    var onSelect: (NSRange) -> Void = { _ in }

    /// When set, the text as some other owner holds it (an `OpenDocument`), in place of `text`.
    var liveText: (() -> String)?

    init(text: String) { self.text = text }

    var currentText: String { liveText?() ?? text }
    func scrollToCharacterRange(_ range: NSRange) {
        scrolled.append(range)
        onScroll(range)
    }
    func selectRange(_ range: NSRange) {
        selected.append(range)
        onSelect(range)
    }
    func insertTable() {}
    func reformatTable() {}
    @discardableResult func replace(range: NSRange, with replacement: String) -> Bool {
        replaced.append((range, replacement))
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        return true
    }
    @discardableResult func replaceAll(ranges: [NSRange], with replacement: String) -> Bool {
        replacedAll.append((ranges, replacement))
        guard let edit = LiveEditorCommands.combinedReplacement(in: text, ranges: ranges, with: replacement) else { return false }
        text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return true
    }
}

private struct OutlineTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
