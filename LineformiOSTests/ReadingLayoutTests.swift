import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The reading profile in the iPhone editor: TextKit 1, the theme's page and caret, the base
/// Markdown style, and the reading column from `EditorReadingLayout`. (The first four cases moved
/// here from `PlainTextEditorTests` when `LineformTextView` replaced `PlainTextEditor`.)
@MainActor
final class ReadingLayoutTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testEditorIsTextKit1() {
        let textView = LineformTextView.make(profile: .original)
        XCTAssertNil(textView.textLayoutManager, "the editor must stay on TextKit 1")
        XCTAssertNotNil(textView.layoutManager)
    }

    func testEditorUsesThemePageColour() {
        let textView = LineformTextView.make(profile: .original)
        let theme = Theme.theme(for: ReadingProfile.original)
        XCTAssertEqual(textView.backgroundColor, theme.backgroundColor)
        XCTAssertEqual(textView.tintColor, HighlighterSelection.caretColor(for: theme), "the caret and handles are the highlighter's blue for the theme")
    }

    func testTypingUsesTheBaseMarkdownStyle() throws {
        let textView = LineformTextView.make(profile: .original)
        let expected = MarkdownTextStyle.baseAttributes(for: .original)
        let font = try XCTUnwrap(textView.typingAttributes[.font] as? UIFont)
        XCTAssertEqual(font, expected[.font] as? UIFont)
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? UIColor, expected[.foregroundColor] as? UIColor)
        XCTAssertEqual(textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle, expected[.paragraphStyle] as? NSParagraphStyle)
    }

    func testColumnInsetsComeFromEditorReadingLayout() {
        let profile = ReadingProfile.original
        let textView = LineformTextView.make(profile: profile)
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        textView.layoutIfNeeded()
        let side = EditorReadingLayout.horizontalInset(forContainerWidth: 402, profile: profile)
        XCTAssertEqual(side, CGFloat(profile.marginWidth), "on an iPhone the margin is what limits the column")
        XCTAssertEqual(textView.textContainerInset.left, side)
        XCTAssertEqual(textView.textContainerInset.right, side)
        XCTAssertEqual(textView.textContainer.lineFragmentPadding, 0)

        textView.frame = CGRect(x: 0, y: 0, width: CGFloat(profile.columnWidth) + 400, height: 800)
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.textContainerInset.left, 200, "wider than the column: the column is centred")
    }

    func testProfileChangeReappliesFontAndInsets() throws {
        let textView = LineformTextView.make(profile: .original)
        textView.frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        textView.setDocumentText("# Title\n\nBody text.\n")
        textView.layoutIfNeeded()

        var profile = ReadingProfile.original
        profile.fontID = .openDyslexic
        profile.fontSize = 20
        profile.lineHeightMultiple = 1.6
        profile.columnWidth = 600
        textView.profile = profile
        textView.layoutIfNeeded()

        let expected = MarkdownTextStyle.baseAttributes(for: profile)
        let expectedFont = try XCTUnwrap(expected[.font] as? UIFont)
        XCTAssertEqual(expectedFont.familyName, "OpenDyslexic", "the bundled font is registered at launch")
        XCTAssertEqual(expectedFont.pointSize, 20)
        let body = 10
        XCTAssertEqual(textView.textStorage.attribute(.font, at: body, effectiveRange: nil) as? UIFont, expectedFont)
        XCTAssertEqual(textView.textStorage.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle,
                       expected[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(textView.typingAttributes[.font] as? UIFont, expectedFont)
        let side = EditorReadingLayout.horizontalInset(forContainerWidth: 1_000, profile: profile)
        XCTAssertEqual(side, 200)
        XCTAssertEqual(textView.textContainerInset.left, side)
        XCTAssertEqual(textView.textContainerInset.right, side)
    }

    func testDarkThemeRepaintsPageAndCaret() {
        let textView = LineformTextView.make(profile: .original)
        var profile = ReadingProfile.original
        let dark = ThemeID.allCases.first { Theme.theme(for: $0).usesDarkChrome } ?? profile.themeID
        profile.themeID = dark
        textView.profile = profile
        let theme = Theme.theme(for: profile)
        XCTAssertEqual(textView.backgroundColor, theme.backgroundColor)
        XCTAssertEqual(textView.tintColor, HighlighterSelection.caretColor(for: theme))
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? UIColor, theme.textColor)
    }

    /// The editor observes the per-device `ReadingProfileStore`: a change reaches the editor at
    /// once, with no relaunch.
    func testStoreChangeReachesTheEditorWithoutRelaunch() async throws {
        let suite = "ReadingLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingProfileStore(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = OpenDocument(folderProvider: { folder })
        let textView = try host(DocumentScreen(document: document, profileStore: store))
        XCTAssertEqual(textView.profile, store.activeProfile)

        store.update { $0.fontSize = 26 }
        let deadline = Date().addingTimeInterval(3)
        while textView.profile.fontSize != 26, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(textView.profile.fontSize, 26)
        XCTAssertEqual((textView.typingAttributes[.font] as? UIFont)?.pointSize, 26)
    }

    private func host(_ view: some View) throws -> LineformTextView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        self.window = window
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.layoutIfNeeded()
            if let editor = Self.editor(in: window) { return editor }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        throw NoEditor()
    }

    private static func editor(in view: UIView) -> LineformTextView? {
        if let editor = view as? LineformTextView { return editor }
        for subview in view.subviews {
            if let editor = editor(in: subview) { return editor }
        }
        return nil
    }
}

private struct NoEditor: Error {}
