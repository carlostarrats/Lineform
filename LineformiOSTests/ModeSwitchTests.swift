import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Write / Read / Preview pill and the mode switch: the Mac's metrics and colours, Reduce
/// Motion, the reading position kept across a switch (only the last of several quick switches
/// restores), ⌘E, and undo across modes (a Read edit undoes in Read; Write afterwards starts a new
/// undo history). Every document saves into its own temporary folder.
@MainActor
final class ModeSwitchTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var defaultsSuite: String?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The pill

    func testModeSwitchUsesMacMetrics() throws {
        XCTAssertEqual(ModeSwitch.segmentWidth, 78)
        XCTAssertEqual(ModeSwitch.segmentHeight, 30)
        XCTAssertEqual(ModeSwitch.controlPadding, 3)
        XCTAssertEqual(ModeSwitch.dividerSlotWidth, 3)
        XCTAssertEqual(ModeSwitch.dividerSize, CGSize(width: 1, height: 18))
        XCTAssertEqual(ModeSwitch.dividerOpacity, 0.45)
        XCTAssertEqual(ModeSwitch.labelFontSize, 14)
        XCTAssertEqual(ModeSwitch.strokeWidth, 0.5)
        XCTAssertEqual(ModeSwitch.shadowOpacity, 0.035)
        XCTAssertEqual(ModeSwitch.shadowRadius, 5)
        XCTAssertEqual(ModeSwitch.shadowY, 1)
        XCTAssertEqual(ModeSwitch.pressedFillShare, 0.48)
        XCTAssertEqual(ModeSwitch.liquidSettleDelay, 0.16)

        // Light and dark, the Mac's components.
        XCTAssertEqual(ModeSwitch.backgroundFillComponent, 1.0)
        XCTAssertEqual(ModeSwitch.backgroundFillOpacity, 0.82)
        XCTAssertEqual(ModeSwitch.darkBackgroundFillComponent, 0x1A / 255, accuracy: 0.001, "LineformColors.darkControlBackground")
        XCTAssertEqual(ModeSwitch.darkBackgroundFillOpacity, 0.92)
        XCTAssertEqual(ModeSwitch.strokeOpacity, 0.72)
        XCTAssertEqual(ModeSwitch.darkStrokeOpacity, 0.10)
        XCTAssertEqual(ModeSwitch.selectedFillComponent, 0.86)
        XCTAssertEqual(ModeSwitch.selectedFillAlpha, 0.74)
        XCTAssertEqual(ModeSwitch.darkSelectedFillComponent, 0.20)
        XCTAssertEqual(ModeSwitch.darkSelectedFillAlpha, 0.92)
        XCTAssertEqual(ModeSwitch.textFillComponent, 0.18)
        XCTAssertEqual(ModeSwitch.darkTextFillComponent, 0.92)
        let selected = UIColor(ModeSwitch.selectedFillColor(usesDarkChrome: false))
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        selected.getWhite(&white, alpha: &alpha)
        XCTAssertEqual(white, 0.86, accuracy: 0.01)
        XCTAssertEqual(alpha, 0.74, accuracy: 0.01)

        // Segments sit one segment plus one divider slot apart; the bridge spans both ends.
        XCTAssertEqual(ModeSwitch.segmentOffset(for: .write), 0)
        XCTAssertEqual(ModeSwitch.segmentOffset(for: .read), 81)
        XCTAssertEqual(ModeSwitch.segmentOffset(for: .split), 162)
        XCTAssertEqual(ModeSwitch.pillWidth(bridge: .init(from: .write, to: .split)), 240)
        XCTAssertEqual(ModeSwitch.pillOffset(bridge: .init(from: .split, to: .read), selection: .read), 81)
        XCTAssertEqual(ModeSwitch.pillWidth(bridge: nil), 78)

        // Dividers only between two unselected segments.
        XCTAssertFalse(ModeSwitch.showsDivider(after: 0, selection: .write))
        XCTAssertTrue(ModeSwitch.showsDivider(after: 1, selection: .write))
        XCTAssertFalse(ModeSwitch.showsDivider(after: 0, selection: .read))
        XCTAssertFalse(ModeSwitch.showsDivider(after: 1, selection: .read))

        // The drawn control is exactly that size: 3 × 78 + 2 × 3 + 2 × 3 by 30 + 2 × 3.
        XCTAssertEqual(ModeSwitch.intrinsicSize, CGSize(width: 246, height: 36))
        var mode = EditorDisplayMode.write
        let host = UIHostingController(rootView: ModeSwitch(mode: Binding(get: { mode }, set: { mode = $0 })))
        let size = host.sizeThatFits(in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(size.width, 246, accuracy: 0.5)
        XCTAssertEqual(size.height, 36, accuracy: 0.5)

        // The titles are the package's (the Mac's localized strings).
        XCTAssertEqual(EditorDisplayMode.allCases.map(\.title), ["Write", "Read", "Preview"])
    }

    func testReduceMotionDisablesAnimation() {
        XCTAssertNil(EditorMotionPolicy.animation(ModeSwitch.bridgeAnimation, reduceMotion: true))
        XCTAssertNotNil(EditorMotionPolicy.animation(ModeSwitch.bridgeAnimation, reduceMotion: false))
        XCTAssertEqual(EditorMotionPolicy.effectiveDuration(0.24, reduceMotion: true), 0)
        XCTAssertEqual(EditorMotionPolicy.effectiveDuration(0.24, reduceMotion: false), 0.24)
        XCTAssertFalse(EditorMotionPolicy.usesAnimatedTransitions(reduceMotion: true))
        XCTAssertTrue(EditorMotionPolicy.supportsReduceMotion)
        // Reduce Motion skips the liquid bridge outright.
        XCTAssertNil(ModeSwitch.bridge(from: .write, to: .split, reduceMotion: true))
        XCTAssertEqual(ModeSwitch.bridge(from: .write, to: .split, reduceMotion: false), .init(from: .write, to: .split))
        XCTAssertNil(ModeSwitch.bridge(from: .read, to: .read, reduceMotion: false))
    }

    // MARK: - Position

    func testWriteToReadKeepsTopParagraph() throws {
        let surfaces = try hostSurfaces(text: Self.longDocument)
        let target = Self.paragraphRange(120)
        surfaces.editor.scrollCharacterRangeToTop(NSRange(location: target.location, length: 0))
        let editorTop = try XCTUnwrap(surfaces.editor.topVisibleSourceLocation())
        XCTAssertTrue(NSLocationInRange(editorTop, target), "set-up: paragraph 120 is at the top of Write")

        surfaces.keeper.switchMode(from: .write, to: .read)
        surfaces.bringReaderToFront()
        try spin(until: { self.isInParagraph(120, surfaces.reader.sourceLocationAtTopOfViewport()) })
        XCTAssertTrue(surfaces.reader.isFirstResponder, "Read takes the keyboard focus, for shake and ⌘Z")
    }

    func testReadToWriteKeepsTopParagraph() throws {
        let surfaces = try hostSurfaces(text: Self.longDocument)
        surfaces.bringReaderToFront()
        surfaces.reader.scrollSourceLocationToTop(Self.paragraphRange(150).location)
        try spin(until: { self.isInParagraph(150, surfaces.reader.sourceLocationAtTopOfViewport()) })

        surfaces.keeper.adopt(.read)
        surfaces.keeper.switchMode(from: .read, to: .write)
        surfaces.reader.removeFromSuperview()
        try spin(until: { self.isInParagraph(150, surfaces.editor.topVisibleSourceLocation()) })

        // And back again: Write → Read → Write never drifts by a line.
        let host = try XCTUnwrap(window?.rootViewController?.view)
        host.addSubview(surfaces.reader)
        surfaces.keeper.switchMode(from: .write, to: .read)
        try spin(until: { self.isInParagraph(150, surfaces.reader.sourceLocationAtTopOfViewport()) })
        surfaces.keeper.switchMode(from: .read, to: .write)
        surfaces.reader.removeFromSuperview()
        try spin(until: { self.isInParagraph(150, surfaces.editor.topVisibleSourceLocation()) })
        settle(ticks: 8)
        XCTAssertTrue(isInParagraph(150, surfaces.editor.topVisibleSourceLocation()), "the re-asserts keep it there")
    }

    func testRapidSwitchRestoresOnlyFinalMode() throws {
        let surfaces = try hostSurfaces(text: Self.longDocument)
        surfaces.editor.scrollCharacterRangeToTop(NSRange(location: Self.paragraphRange(80).location, length: 0))
        XCTAssertTrue(isInParagraph(80, surfaces.editor.topVisibleSourceLocation()))
        surfaces.reader.scrollSourceLocationToTop(0)
        let readerOffset = surfaces.reader.contentOffset.y

        // Write → Read → Write → Read → Write inside one tick: only the last restore runs, with the
        // position recorded at the first switch (the Read view never had a frame to read from).
        surfaces.keeper.switchMode(from: .write, to: .read)
        surfaces.keeper.switchMode(from: .read, to: .write)
        surfaces.keeper.switchMode(from: .write, to: .read)
        surfaces.keeper.switchMode(from: .read, to: .write)
        // Moved away before the tick: the restore must bring it back.
        surfaces.editor.setContentOffset(CGPoint(x: 0, y: -surfaces.editor.adjustedContentInset.top), animated: false)
        settle(ticks: 8)

        XCTAssertTrue(isInParagraph(80, surfaces.editor.topVisibleSourceLocation()), "Write restores the first recorded position")
        XCTAssertEqual(surfaces.reader.contentOffset.y, readerOffset, accuracy: 0.5, "no Read restore ran")
        XCTAssertFalse(surfaces.reader.isFirstResponder, "the superseded Read switch took no focus")
        XCTAssertNil(surfaces.keeper.pendingTarget)
    }

    // MARK: - ⌘E

    func testCommandEToggles() async throws {
        XCTAssertEqual(DocumentScreen.toggleWriteReadShortcut.key, KeyEquivalent("e"))
        XCTAssertEqual(DocumentScreen.toggleWriteReadShortcut.modifiers, .command)
        XCTAssertEqual(EditorDisplayMode.write.toggledWriteRead, .read)
        XCTAssertEqual(EditorDisplayMode.read.toggledWriteRead, .write)
        XCTAssertEqual(EditorDisplayMode.split.toggledWriteRead, .write)

        let document = await preparedDocument(text: "# Title\n\nBody.\n")
        let window = try hostScreen(document: document, mode: .write)
        let editor = try await waitAsync { Self.find(LineformTextView.self, in: window) }
        XCTAssertNil(Self.find(LineformReadView.self, in: window))

        // The screen offers ⌘E as a key command on the responder chain, from the editor up, and it
        // works while the editor is typing.
        XCTAssertTrue(editor.becomeFirstResponder())
        let command = try XCTUnwrap(Self.keyCommand(input: "e", flags: .command, from: editor),
                                    "⌘E is on the editor's responder chain")
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: nil, from: command, for: nil))
        let reader = try await waitAsync { Self.find(LineformReadView.self, in: window) }
        _ = try await waitAsync { reader.isFirstResponder ? true : nil }
        XCTAssertFalse(editor.isFirstResponder, "Read takes the focus from the editor")

        let again = try XCTUnwrap(Self.keyCommand(input: "e", flags: .command, from: reader))
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(again.action), to: nil, from: again, for: nil))
        _ = try await waitAsync { Self.find(LineformReadView.self, in: window) == nil ? true : nil }
    }

    // MARK: - Undo across modes

    func testReadEditUndoesInRead() async throws {
        let document = await preparedDocument(text: "- [ ] one\n- [ ] two\n")
        let window = try hostScreen(document: document, mode: .read)
        let reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }
        XCTAssertTrue(reader.undoManager === document.undoManager, "shake and ⌘Z in Read reach the document's undo")
        let range = NSRange(location: 2, length: 3)
        let rect = try XCTUnwrap(reader.checkboxGlyphRect(forSourceRange: range))
        XCTAssertTrue(reader.activateCheckbox(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(document.text, "- [x] one\n- [ ] two\n")
        XCTAssertTrue(document.undoManager.canUndo)
        reader.undoManager?.undo()
        XCTAssertEqual(document.text, "- [ ] one\n- [ ] two\n", "one undo step")
        reader.undoManager?.redo()
        XCTAssertEqual(document.text, "- [x] one\n- [ ] two\n")
    }

    func testWriteAfterReadEditResetsEditorUndo() async throws {
        let document = await preparedDocument(text: "- [ ] one\n")
        // Write's editor with an undo step of its own.
        let editor = LineformTextView.make()
        var bound = document.text
        let representable = MarkdownEditor(
            text: Binding(get: { bound }, set: { bound = $0; document.edit($0) }),
            profile: .original,
            imageHost: nil
        )
        let coordinator = representable.makeCoordinator()
        editor.setDocumentText(document.text)
        editor.delegate = coordinator
        hostAlone(editor)
        editor.selectedRange = NSRange(location: (document.text as NSString).length, length: 0)
        editor.insertText("Typed")
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(document.text, "- [ ] one\nTyped")
        let editorUndo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(editorUndo.canUndo, "set-up: Write has an undo step")

        // A checkbox toggled in Read: the document's undo has it, and Write's text is replaced.
        document.toggleCheckbox(at: NSRange(location: 2, length: 3))
        XCTAssertEqual(document.text, "- [x] one\nTyped")
        bound = document.text
        MarkdownEditor(
            text: Binding(get: { bound }, set: { bound = $0; document.edit($0) }),
            profile: .original,
            imageHost: nil
        ).configure(editor)
        XCTAssertEqual(editor.text, "- [x] one\nTyped")
        XCTAssertFalse(editorUndo.canUndo, "Write starts a new undo history after a Read edit, as after a live reload")
        XCTAssertTrue(document.undoManager.canUndo, "the Read edit stays undoable in Read")
    }

    // MARK: - Helpers

    private static let longDocument: String = (0..<200).map { index in
        "Paragraph \(index): the quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun by the river."
    }.joined(separator: "\n\n")

    private static func paragraphRange(_ index: Int) -> NSRange {
        let text = longDocument as NSString
        let start = text.range(of: "Paragraph \(index):").location
        let end = text.range(of: "river.", range: NSRange(location: start, length: text.length - start)).upperBound
        return NSRange(location: start, length: end - start)
    }

    private func isInParagraph(_ index: Int, _ location: Int?) -> Bool {
        guard let location else { return false }
        return NSLocationInRange(location, Self.paragraphRange(index))
    }

    private struct Surfaces {
        let editor: LineformTextView
        let reader: LineformReadView
        let keeper: ModePositionKeeper

        func bringReaderToFront() {
            reader.superview?.bringSubviewToFront(reader)
        }
    }

    /// The editor and the Read view on one page-sized frame, the Read view under the editor (as
    /// in Write), wired to one position keeper.
    private func hostSurfaces(text: String) throws -> Surfaces {
        let editor = LineformTextView.make()
        editor.setDocumentText(text)
        let reader = LineformReadView.make()
        let window = makeWindow()
        let host = try XCTUnwrap(window.rootViewController?.view)
        for view in [reader, editor] as [UIView] {
            view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
            host.addSubview(view)
        }
        reader.apply(text: text, profile: .original, documentDirectory: nil)
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        keeper.reader = reader
        editor.layoutIfNeeded()
        reader.layoutIfNeeded()
        return Surfaces(editor: editor, reader: reader, keeper: keeper)
    }

    private func hostAlone(_ view: UIView) {
        let window = makeWindow()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        window.rootViewController?.view.addSubview(view)
        view.layoutIfNeeded()
    }

    private func makeWindow() -> UIWindow {
        if let window { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIViewController()
        window.isHidden = false
        self.window = window
        return window
    }

    private func hostScreen(document: OpenDocument, mode: EditorDisplayMode) throws -> UIWindow {
        let suite = "ModeSwitchTests-\(UUID().uuidString)"
        defaultsSuite = suite
        let store = ReadingProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: DocumentScreen(document: document, profileStore: store, initialMode: mode)
        )
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func preparedDocument(text: String) async -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: ModeSwitchTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        await document.flush()
        return document
    }

    /// Runs the main run loop for `ticks` short turns (the restore is deferred a tick, the editor
    /// re-asserts for five).
    private func settle(ticks: Int) {
        for _ in 0..<ticks {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.layoutIfNeeded()
        }
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            settle(ticks: 1)
        }
    }

    /// Waits for `value` in an async test, yielding the main actor (a nested run loop cannot run
    /// main-queue work from inside a main-actor task).
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

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

/// No iCloud, ever: every item reads as local.
private struct ModeSwitchTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
