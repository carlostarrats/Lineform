import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Write / Read / Preview pill and the mode switch: the Mac's metrics and colours, Reduce
/// Motion, the reading position kept across a switch (only the last of several quick switches
/// restores), ⌘E, focus, and one undo history in every mode (a Read edit is a ranged edit in the
/// editor, undone by ⌘Z in Write, Read and Preview, in order with the typing around it). Every
/// document saves into its own temporary folder.
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
        try skipUnlessEnglishInterface()
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

    // MARK: - One undo history in every mode

    func testReadTickUndoesWithCommandZInRead() async throws {
        // A scene restored straight into Read: Read takes the focus, so a shake or ⌘Z routes.
        let document = await preparedDocument(text: "- [ ] one\n- [ ] two\n")
        let window = try hostScreen(document: document, mode: .read)
        let reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }
        let editor = try XCTUnwrap(Self.find(LineformTextView.self, in: window))
        _ = try await waitAsync { reader.isFirstResponder ? true : nil }
        XCTAssertTrue(reader.undoManager === editor.undoManager, "Read's undo is the editor's: one history")

        try tick(reader, range: NSRange(location: 2, length: 3))
        XCTAssertEqual(document.text, "- [x] one\n- [ ] two\n")
        XCTAssertEqual(editor.text, document.text, "the tick is an edit in the editor's own storage")

        try pressUndo(from: reader)
        XCTAssertEqual(document.text, "- [ ] one\n- [ ] two\n", "⌘Z undoes the tick, one step")
        try pressUndo(from: reader, redo: true)
        XCTAssertEqual(document.text, "- [x] one\n- [ ] two\n", "⇧⌘Z redoes it")
    }

    func testPreviewTypeThenTickUndoesInOrder() async throws {
        let document = await preparedDocument(text: "- [ ] one\n")
        let window = try hostScreen(document: document, mode: .split)
        let editor = try await waitAsync { Self.find(LineformTextView.self, in: window) }
        let reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }

        // Type in the editor pane.
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        type("Typed", into: editor)
        XCTAssertEqual(document.text, "- [ ] one\nTyped")
        try await Task.sleep(for: .milliseconds(50))

        // Tick the box in the Read pane once it has caught up (the 0.12 s debounce).
        _ = try await waitAsync { reader.renderedSourceText == document.text ? true : nil }
        try tick(reader, range: NSRange(location: 2, length: 3))
        XCTAssertEqual(document.text, "- [x] one\nTyped")
        XCTAssertEqual(editor.text, document.text)
        try await Task.sleep(for: .milliseconds(50))

        // ⌘Z from the Read pane (tapped, so it has the focus): the tick, then the typing.
        XCTAssertTrue(reader.becomeFirstResponder())
        try pressUndo(from: reader)
        XCTAssertEqual(document.text, "- [ ] one\nTyped", "⌘Z undoes the tick")
        try pressUndo(from: reader)
        XCTAssertEqual(document.text, "- [ ] one\n", "⌘Z again undoes the typing")
        XCTAssertEqual(editor.text, document.text)
    }

    func testReadTickThenWriteEditUndoesInOrder() async throws {
        let document = await preparedDocument(text: "- [ ] one\n")
        let window = try hostScreen(document: document, mode: .read)
        var reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }
        let editor = try XCTUnwrap(Self.find(LineformTextView.self, in: window))
        _ = try await waitAsync { reader.isFirstResponder ? true : nil }
        try tick(reader, range: NSRange(location: 2, length: 3))
        XCTAssertEqual(document.text, "- [x] one\n")
        try await Task.sleep(for: .milliseconds(50))

        // ⌘E to Write, type, ⌘E back to Read.
        try pressCommandE(from: reader)
        _ = try await waitAsync { Self.find(LineformReadView.self, in: window) == nil ? true : nil }
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        type("Typed", into: editor)
        XCTAssertEqual(document.text, "- [x] one\nTyped")
        XCTAssertTrue(editor.undoManager?.canUndo ?? false, "Write kept the tick in its history")
        try await Task.sleep(for: .milliseconds(50))
        try pressCommandE(from: editor)
        reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == document.text ? $0 : nil }
        }
        _ = try await waitAsync { reader.isFirstResponder ? true : nil }

        try pressUndo(from: reader)
        XCTAssertEqual(document.text, "- [x] one\n", "the Write edit first")
        try pressUndo(from: reader)
        XCTAssertEqual(document.text, "- [ ] one\n", "then the Read tick")
    }

    func testOutsideReplacementStillClearsEditorUndo() async throws {
        // A live reload (or another file) is a replacement from outside: undo never puts the old
        // text back over it.
        let document = await preparedDocument(text: "one\n")
        let editor = LineformTextView.make()
        var bound = document.text
        let representable = MarkdownEditor(
            text: Binding(get: { bound }, set: { bound = $0; document.edit($0) }),
            profile: .original,
            imageHost: nil,
            readEditDocument: document
        )
        let coordinator = representable.makeCoordinator()
        editor.setDocumentText(document.text)
        editor.delegate = coordinator
        representable.configure(editor)
        hostAlone(editor)
        XCTAssertTrue(document.readEditor === editor)
        editor.selectedRange = NSRange(location: 4, length: 0)
        type("Typed", into: editor)
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)

        bound = "from disk\n"
        representable.configure(editor)
        XCTAssertEqual(editor.text, "from disk\n")
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canUndo)
    }

    // MARK: - Focus

    func testRapidSwitchEndingInWriteRefocusesEditor() throws {
        let surfaces = try hostSurfaces(text: Self.longDocument)
        window?.makeKey()
        XCTAssertTrue(surfaces.editor.becomeFirstResponder())
        surfaces.keeper.switchMode(from: .write, to: .read)
        surfaces.keeper.switchMode(from: .read, to: .write)
        XCTAssertFalse(surfaces.editor.isFirstResponder, "set-up: the Read switch took the focus away")
        settle(ticks: 4)
        XCTAssertTrue(surfaces.editor.isFirstResponder, "back in Write, the editor has its focus again")

        // A Write → Read switch that settles leaves the focus with Read.
        surfaces.keeper.switchMode(from: .write, to: .read)
        surfaces.bringReaderToFront()
        settle(ticks: 4)
        XCTAssertTrue(surfaces.reader.isFirstResponder)
        // A later Read → Write did not start with the editor focused: no keyboard is forced up.
        surfaces.keeper.switchMode(from: .read, to: .write)
        settle(ticks: 4)
        XCTAssertFalse(surfaces.editor.isFirstResponder)
    }

    // MARK: - Pressed states

    func testPressedStatesAnimateWithMotionPolicy() {
        XCTAssertNil(ModeSwitch.pressAnimation(reduceMotion: true), "Reduce Motion: no press animation")
        XCTAssertEqual(ModeSwitch.pressAnimation(reduceMotion: false),
                       Animation.easeInOut(duration: LineformDesign.Motion.hover))
        XCTAssertEqual(LineformDesign.Motion.hover, 0.12)
        // The pressed pill is always drawn; only its opacity changes.
        XCTAssertEqual(ModeSwitch.pressedPillOpacity(isPressed: true, isSelected: false), 1)
        XCTAssertEqual(ModeSwitch.pressedPillOpacity(isPressed: false, isSelected: false), 0)
        XCTAssertEqual(ModeSwitch.pressedPillOpacity(isPressed: true, isSelected: true), 0)
        // The link button's wash and ring: the Mac's values, 0 at rest while unlinked.
        XCTAssertEqual(PreviewLinkButton.washOpacity(isLinked: true, isPressed: false, isDark: false), 0.11)
        XCTAssertEqual(PreviewLinkButton.washOpacity(isLinked: true, isPressed: true, isDark: false), 0.17)
        XCTAssertEqual(PreviewLinkButton.washOpacity(isLinked: true, isPressed: true, isDark: true), 0.28)
        XCTAssertEqual(PreviewLinkButton.washOpacity(isLinked: false, isPressed: true, isDark: false), 0.08)
        XCTAssertEqual(PreviewLinkButton.washOpacity(isLinked: false, isPressed: false, isDark: true), 0)
        XCTAssertEqual(PreviewLinkButton.ringOpacity(isLinked: true, isPressed: true), 0.95)
        XCTAssertEqual(PreviewLinkButton.ringOpacity(isLinked: false, isPressed: true), 0.55)
        XCTAssertEqual(PreviewLinkButton.ringOpacity(isLinked: false, isPressed: false), 0)
    }

    // MARK: - Undo helpers

    /// Types `text` the way the keyboard does, and tells the delegate as UIKit does.
    private func type(_ text: String, into editor: LineformTextView) {
        editor.insertText(text)
        editor.delegate?.textViewDidChange?(editor)
    }

    private func tick(_ reader: LineformReadView, range: NSRange, file: StaticString = #filePath, line: UInt = #line) throws {
        let rect = try XCTUnwrap(reader.checkboxGlyphRect(forSourceRange: range), file: file, line: line)
        XCTAssertTrue(reader.activateCheckbox(at: CGPoint(x: rect.midX, y: rect.midY)), file: file, line: line)
    }

    /// Presses ⌘Z (or ⇧⌘Z) as a hardware keyboard does: the key command found on the first
    /// responder's chain, sent to the first responder.
    private func pressUndo(from responder: UIResponder, redo: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let flags: UIKeyModifierFlags = redo ? [.command, .shift] : .command
        let command = try XCTUnwrap(Self.keyCommand(input: "z", flags: flags, from: responder),
                                    "⌘Z is on the responder chain", file: file, line: line)
        let action = try XCTUnwrap(command.action, file: file, line: line)
        XCTAssertTrue(responder.canPerformAction(action, withSender: command), "there is something to undo", file: file, line: line)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil), file: file, line: line)
    }

    private func pressCommandE(from responder: UIResponder, file: StaticString = #filePath, line: UInt = #line) throws {
        let command = try XCTUnwrap(Self.keyCommand(input: "e", flags: .command, from: responder), file: file, line: line)
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: nil, from: command, for: nil),
                      file: file, line: line)
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
