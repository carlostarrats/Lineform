import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The main screen's chrome for VoiceOver, Dynamic Type and touch: the mode pill, the floating
/// buttons, the notices, the Read view's pills and actions, and first run's VoiceOver timing.
@MainActor
final class PhoneChromeAccessibilityTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var defaultsSuite: String?
    private var posted: [(UIAccessibility.Notification, String?)] = []
    private var originalPost: ((UIAccessibility.Notification, Any?) -> Void)?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-a11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        originalPost = ChromeAnnouncer.post
        ChromeAnnouncer.post = { [weak self] notification, argument in
            self?.posted.append((notification, argument as? String))
        }
    }

    override func tearDown() async throws {
        if let originalPost { ChromeAnnouncer.post = originalPost }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: folder)
    }

    private var announcements: [String] {
        posted.filter { $0.0 == .announcement }.compactMap(\.1)
    }

    // MARK: - Mode pill

    func testModeSwitchSegmentsAreLabelledFullSizeTargetsAtEverySize() async throws {
        for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            var mode = EditorDisplayMode.read
            let view = ModeSwitch(mode: Binding(get: { mode }, set: { mode = $0 }))
            let host = try await PhoneAccessibilityHost(view, contentSize: size)
            defer { host.tearDown() }

            host.assertElementsInsideWindow()
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            let segments = host.elements().filter(\.isInteractive)
            XCTAssertEqual(segments.map(\.label), EditorDisplayMode.allCases.map(\.title), "one button per mode, in order")
            let selected = segments.filter { $0.traits.contains(.selected) }
            XCTAssertEqual(selected.map(\.label), [EditorDisplayMode.read.title], "the mode on screen is selected")
            for segment in segments {
                XCTAssertGreaterThanOrEqual(segment.frame.height, ModeSwitch.touchHeight - 0.5, "\(segment)")
            }
        }
    }

    func testModeSwitchFillIsOpaqueUnderReduceTransparency() {
        XCTAssertEqual(ModeSwitch.backgroundFillOpacity(usesDarkChrome: false, reduceTransparency: true), 1)
        XCTAssertEqual(ModeSwitch.backgroundFillOpacity(usesDarkChrome: true, reduceTransparency: true), 1)
        XCTAssertEqual(ModeSwitch.backgroundFillOpacity(usesDarkChrome: false, reduceTransparency: false), ModeSwitch.backgroundFillOpacity)
        XCTAssertEqual(ModeSwitch.backgroundFillOpacity(usesDarkChrome: true, reduceTransparency: false), ModeSwitch.darkBackgroundFillOpacity)
    }

    func testModeSwitchAnnouncesTheNewModeWithoutResettingTheCursor() async throws {
        let document = await preparedDocument(text: "# Title\n\nBody.\n")
        let window = try hostScreen(document: document, mode: .write)
        let editor = try await waitAsync { Self.find(LineformTextView.self, in: window) }
        XCTAssertTrue(editor.becomeFirstResponder())
        posted.removeAll()

        // ⌘E, as a hardware keyboard sends it: Write → Read.
        let command = try XCTUnwrap(Self.keyCommand(input: "e", flags: .command, from: editor))
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: nil, from: command, for: nil))
        _ = try await waitAsync { Self.find(LineformReadView.self, in: window) }

        XCTAssertTrue(posted.filter { $0.0 == .screenChanged }.isEmpty, "the cursor is never sent back to the top")
        let layoutChanges = posted.filter { $0.0 == .layoutChanged }
        XCTAssertEqual(layoutChanges.map(\.1), [EditorDisplayMode.read.title], "VoiceOver hears the new mode once")
    }

    func testModeChangeMovesTheCursorOnlyWhenTheSurfaceIsReplaced() {
        // Read replaces the editor, and the other modes replace Read's own view.
        XCTAssertEqual(ChromeAnnouncer.modeChangeNotification(from: .write, to: .read), .layoutChanged)
        XCTAssertEqual(ChromeAnnouncer.modeChangeNotification(from: .split, to: .read), .layoutChanged)
        XCTAssertEqual(ChromeAnnouncer.modeChangeNotification(from: .read, to: .write), .layoutChanged)
        XCTAssertEqual(ChromeAnnouncer.modeChangeNotification(from: .read, to: .split), .layoutChanged)
        // The editor stays on screen: only the name is spoken.
        XCTAssertEqual(ChromeAnnouncer.modeChangeNotification(from: .write, to: .split), .announcement)
        XCTAssertEqual(ChromeAnnouncer.modeChangeNotification(from: .split, to: .write), .announcement)
    }

    // MARK: - Floating buttons

    func testFloatingButtonsAreLabelledFullSizeTargets() async throws {
        for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let row = HStack(spacing: DocumentScreen.bottomChromeSpacing) {
                PreviewLinkButton(isLinked: true, profile: .original) {}
                PreviewLinkButton(isLinked: false, profile: .original) {}
                StylingButton(profile: .original) {}
            }
            let host = try await PhoneAccessibilityHost(row, contentSize: size)
            defer { host.tearDown() }
            host.assertElementsInsideWindow()
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            let labels = host.elements().filter(\.isInteractive).map(\.label)
            XCTAssertEqual(labels, [
                PreviewLinkButton.accessibilityTitle(isLinked: true),
                PreviewLinkButton.accessibilityTitle(isLinked: false),
                StylingButton.accessibilityLabel,
            ])
        }
    }

    func testLinkButtonTouchSquareKeepsTheCircleWhereItWas() {
        XCTAssertEqual(PreviewLinkButton.diameter, 38, "the drawn circle is unchanged")
        XCTAssertEqual(PreviewLinkButton.touchSide, 44)
        XCTAssertEqual(PreviewLinkButton.horizontalTouchOutset, 3)
        XCTAssertEqual(DocumentScreen.bottomChromeClearance, MarkdownEditor.chromeMargin + 44 + 8)
    }

    // MARK: - Notices

    func testImageNoticeIsAnnouncedAndStaysLongerUnderVoiceOver() async throws {
        XCTAssertEqual(OpenDocument.noticeDuration(voiceOverRunning: false), .seconds(4))
        XCTAssertEqual(OpenDocument.noticeDuration(voiceOverRunning: true), .seconds(15))

        let document = await preparedDocument(text: "Body.\n")
        _ = try hostScreen(document: document, mode: .write)
        try await Task.sleep(for: .milliseconds(100))
        posted.removeAll()

        document.imageCouldNotBeSaved()
        let message = String(localized: "Can't save images beside this document.")
        _ = try await waitAsync { self.announcements.contains(message) ? true : nil }
        XCTAssertEqual(announcements, [message], "announced once, as it appears")
    }

    func testNoticeFitsTheWindowAtTheLargestTextSize() async throws {
        let document = await preparedDocument(text: "Body.\n")
        let host = try await PhoneAccessibilityHost(
            DocumentScreen(document: document, profileStore: makeProfileStore()),
            contentSize: .accessibilityExtraExtraExtraLarge
        )
        defer { host.tearDown() }
        document.imageCouldNotBeSaved()
        let message = String(localized: "Can't save images beside this document.")
        let notice = try await waitAsync {
            host.window.layoutIfNeeded()
            return host.elements().first { $0.label == message }
        }
        let bounds = host.windowFrameOnScreen.insetBy(dx: -0.5, dy: -0.5)
        XCTAssertTrue(bounds.contains(notice.frame), "\(notice) inside \(bounds)")
        XCTAssertGreaterThan(notice.frame.height, 40, "the notice wraps instead of truncating")
    }

    // MARK: - Read

    func testCopyIsAnnouncedFromThePillAndTheAction() async throws {
        let view = try await renderedReadView("```\nfirst\n```\n")
        let pasteboard = UIPasteboard.withUniqueName()
        view.pasteboardForTesting = pasteboard
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        let pill = try XCTUnwrap(view.overlayButtons.first { $0.kind == .copy })
        pill.sendActions(for: .touchUpInside)
        XCTAssertEqual(pasteboard.string, "first")
        XCTAssertEqual(announcements, [LineformReadView.copiedAnnouncement])
        XCTAssertEqual(pill.largeContentTitle, String(localized: "Copied"))

        posted.removeAll()
        let action = try XCTUnwrap(view.readAccessibilityActions().first)
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertEqual(announcements, [LineformReadView.copiedAnnouncement], "the VoiceOver path says so too")
    }

    func testTaskActionsNameTheTaskStateWithoutTheGlyph() async throws {
        let view = try await renderedReadView("- [ ] water the plants\n- [x] post the letter\n- [X] pay\n")
        let names = view.readAccessibilityActions().map(\.name)
        XCTAssertEqual(names, [
            LineformReadView.taskActionName(isDone: false, lineText: "water the plants"),
            LineformReadView.taskActionName(isDone: true, lineText: "post the letter"),
            LineformReadView.taskActionName(isDone: true, lineText: "pay"),
        ])
        for name in names {
            XCTAssertFalse(name.contains("☐") || name.contains("☑"), name)
        }
        XCTAssertNotEqual(LineformReadView.taskActionName(isDone: false, lineText: "a"),
                          LineformReadView.taskActionName(isDone: true, lineText: "a"))
    }

    func testTaskActionNamesInEnglish() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(LineformReadView.taskActionName(isDone: false, lineText: "water"), "Mark task done: water")
        XCTAssertEqual(LineformReadView.taskActionName(isDone: true, lineText: "water"), "Mark task not done: water")
        XCTAssertEqual(LineformReadView.taskActionName(isDone: false, lineText: ""), "Mark task done")
        XCTAssertEqual(LineformReadView.taskActionName(isDone: true, lineText: ""), "Mark task not done")
    }

    func testHeadingsCarryTheirLevelForTheHeadingsRotor() async throws {
        let text = "# One\n\nBody.\n\n### Three\r\n\n- item\n"
        let view = try await renderedReadView(text)
        let storage = view.textStorage
        var levels: [(String, Int)] = []
        storage.enumerateAttribute(.accessibilityTextHeadingLevel, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let level = value as? Int else { return }
            levels.append(((storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), level))
        }
        XCTAssertEqual(levels.map(\.0), ["One", "Three"])
        XCTAssertEqual(levels.map(\.1), [1, 3])
    }

    func testPillsTakeTouchesInA44PointSquareAndShowLargeContent() async throws {
        let view = try await renderedReadView("```\ncode\n```\n\n![pic](missing.png)\n")
        let copy = try XCTUnwrap(view.overlayButtons.first { $0.kind == .copy })
        let reconnect = try XCTUnwrap(view.overlayButtons.first { $0.kind == .reconnect })
        for pill in [copy, reconnect] {
            XCTAssertLessThan(pill.bounds.height, 44, "drawn at the Mac's size")
            XCTAssertGreaterThanOrEqual(pill.touchBounds.width, 44)
            XCTAssertGreaterThanOrEqual(pill.touchBounds.height, 44)
            let edge = CGPoint(x: pill.bounds.midX, y: pill.bounds.midY - 21)
            XCTAssertTrue(pill.point(inside: edge, with: nil), "a touch just outside the drawn pill reaches it")
            XCTAssertFalse(pill.point(inside: CGPoint(x: pill.bounds.midX, y: pill.bounds.midY - 40), with: nil))
            XCTAssertTrue(pill.showsLargeContentViewer)
            XCTAssertFalse(pill.largeContentTitle?.isEmpty ?? true)
            XCTAssertTrue(pill.interactions.contains { $0 is UILargeContentViewerInteraction })
            // The hit-test reaches the pill through the text view, from just outside it.
            let pointInView = pill.convert(edge, to: view)
            XCTAssertTrue(view.hitTest(pointInView, with: nil) === pill)
        }
    }

    func testReconnectPillFitsItsLabelInEveryLanguage() async throws {
        // The interface's language (Default: English; the `de` configuration: German).
        let view = try await renderedReadView("![pic](missing.png)\n")
        let pill = try XCTUnwrap(view.overlayButtons.first { $0.kind == .reconnect })
        pill.layoutIfNeeded()
        let label = try XCTUnwrap(pill.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(label.text, ReadOverlayButton.reconnectPillLabel)
        XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.intrinsicContentSize.width, "the label is not cut")
        XCTAssertGreaterThanOrEqual(label.frame.minX, 0)
        XCTAssertLessThanOrEqual(label.frame.maxX, pill.bounds.maxX)

        // German's label, whatever the run's language: its pill is wider and still fits it.
        let german = "Erneut verbinden"
        let germanWidth = ReadOverlayButton.reconnectPillWidth(for: german)
        let germanLabel = (german as NSString).size(withAttributes: [.font: ReadOverlayButton.pillLabelFont]).width
        XCTAssertGreaterThanOrEqual(
            germanWidth,
            germanLabel + ReadOverlayButton.reconnectPillGap + ReadOverlayButton.reconnectGlyphSize.width + 24
        )
        XCTAssertGreaterThan(germanWidth, ReadOverlayButton.reconnectPillWidth(for: "Reconnect"))
    }

    // MARK: - First run

    func testWhatToExpectWaitsForTheWriterUnderVoiceOver() throws {
        XCTAssertEqual(FirstRunStage.expect.autoAdvanceDelay(reduceMotion: false), .milliseconds(1800))
        XCTAssertNil(FirstRunStage.expect.autoAdvanceDelay(reduceMotion: false, voiceOverRunning: true))
        XCTAssertNil(FirstRunStage.expect.autoAdvanceDelay(reduceMotion: true, voiceOverRunning: true))
        XCTAssertNil(FirstRunStage.points.autoAdvanceDelay(reduceMotion: false, voiceOverRunning: true))
        let start = ContinuousClock.now
        XCTAssertNil(
            FirstRunTiming.deadline(for: .expect, stageStart: start, lineReadyAt: nil, reduceMotion: false, voiceOverRunning: true),
            "no timer: the writer continues when they have heard it"
        )
        XCTAssertEqual(
            FirstRunTiming.deadline(for: .expect, stageStart: start, lineReadyAt: nil, reduceMotion: false),
            start + .milliseconds(1800)
        )
    }

    // MARK: - Helpers

    private func makeProfileStore() -> ReadingProfileStore {
        let suite = "PhoneChromeAccessibilityTests-\(UUID().uuidString)"
        defaultsSuite = suite
        return ReadingProfileStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private func hostScreen(document: OpenDocument, mode: EditorDisplayMode) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: DocumentScreen(document: document, profileStore: makeProfileStore(), initialMode: mode)
        )
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func preparedDocument(text: String) async -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: ChromeTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        await document.flush()
        return document
    }

    /// A Read view in a portrait window with `text` rendered.
    private func renderedReadView(_ text: String) async throws -> LineformReadView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIViewController()
        window.isHidden = false
        self.window = window
        let view = LineformReadView.make()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        try XCTUnwrap(window.rootViewController?.view).addSubview(view)
        view.apply(text: text, profile: .original, documentDirectory: folder)
        view.layoutIfNeeded()
        return try await waitAsync { view.renderedSourceText == text ? view : nil }
    }

    private func waitAsync<T>(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                              _ value: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window?.layoutIfNeeded()
            if let found = value() { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(value(), "timed out", file: file, line: line)
    }

    private static func keyCommand(input: String, flags: UIKeyModifierFlags, from responder: UIResponder) -> UIKeyCommand? {
        var current: UIResponder? = responder
        while let candidate = current {
            if let command = candidate.keyCommands?.first(where: { $0.input == input && $0.modifierFlags == flags }) {
                return command
            }
            current = candidate.next
        }
        return nil
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

/// No iCloud, ever: every item reads as local.
private struct ChromeTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
