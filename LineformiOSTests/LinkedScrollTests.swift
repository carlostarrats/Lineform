import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// Preview's linked scrolling (the Mac's `SplitScrollSynchronizer`): physical Y copied and clamped
/// at the shorter pane's end, no echo, unlinked panes on their own, re-linking aligning Preview to
/// the editor, and replaced panes ignored. Then the screen: the top/bottom split, the hairline,
/// the 0.12 s preview debounce, and the panes linked through real scrolls.
@MainActor
final class LinkedScrollTests: XCTestCase {
    private var window: UIWindow?
    private var folder: URL!
    private var defaultsSuite: String?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - LinkedScroll

    func testScrollingEditorMovesPreview() {
        let (editor, preview, linked) = panes(editorHeight: 5000, previewHeight: 4000)
        XCTAssertTrue(linked.isLinked, "linked by default")
        scroll(editor, to: 300, linked)
        XCTAssertEqual(preview.contentOffset.y, 300, "the same physical Y")
        scroll(preview, to: 900, linked)
        XCTAssertEqual(editor.contentOffset.y, 900, "and back the other way")
    }

    func testClampsAtShorterPaneEnd() {
        // A long source pane over a short rendered one.
        let (editor, preview, linked) = panes(editorHeight: 5000, previewHeight: 2000)
        scroll(editor, to: 3000, linked)
        XCTAssertEqual(preview.contentOffset.y, 1600, "the preview's end: 2000 − 400")
        scroll(editor, to: 3500, linked)
        XCTAssertEqual(preview.contentOffset.y, 1600, "stays at its end, never jumps back")
        scroll(editor, to: 1000, linked)
        XCTAssertEqual(preview.contentOffset.y, 1000)
        scroll(editor, to: -50, linked)
        XCTAssertEqual(preview.contentOffset.y, 0, "never above the top")

        // And the reverse: a short source pane over a long rendered one.
        let (shortEditor, longPreview, other) = panes(editorHeight: 1000, previewHeight: 6000)
        scroll(longPreview, to: 4000, other)
        XCTAssertEqual(shortEditor.contentOffset.y, 600)

        // Insets count: the range runs from the top inset to the end past the bottom inset.
        let (insetEditor, insetPreview, insetLinked) = panes(editorHeight: 5000, previewHeight: 2000)
        insetPreview.contentInset = UIEdgeInsets(top: 44, left: 0, bottom: 34, right: 0)
        scroll(insetEditor, to: 0, insetLinked)
        XCTAssertEqual(insetPreview.contentOffset.y, -44, "the top is the inset top")
        scroll(insetEditor, to: 4000, insetLinked)
        XCTAssertEqual(insetPreview.contentOffset.y, 2000 + 34 - 400, "the end includes the bottom inset")
    }

    func testNoEchoLoop() {
        let (editor, preview, linked) = panes(editorHeight: 5000, previewHeight: 4000)
        let editorDelegate = ScrollRecorder { linked.editorDidScroll($0) }
        let previewDelegate = ScrollRecorder { linked.previewDidScroll($0) }
        editor.delegate = editorDelegate
        preview.delegate = previewDelegate

        editor.contentOffset = CGPoint(x: 0, y: 700)
        XCTAssertEqual(preview.contentOffset.y, 700)
        XCTAssertEqual(editorDelegate.count, 1, "the preview's reply never moves the editor again")
        XCTAssertEqual(previewDelegate.count, 1, "the preview moved once")

        preview.contentOffset = CGPoint(x: 0, y: 200)
        XCTAssertEqual(editor.contentOffset.y, 200)
        XCTAssertEqual(editorDelegate.count, 2)
        XCTAssertEqual(previewDelegate.count, 2)

        // Where the echo would differ (the preview clamped at its end), it still never comes back:
        // the editor keeps the writer's offset instead of jumping back to the preview's end.
        let (longEditor, shortPreview, clamped) = panes(editorHeight: 5000, previewHeight: 2000)
        let longDelegate = ScrollRecorder { clamped.editorDidScroll($0) }
        let shortDelegate = ScrollRecorder { clamped.previewDidScroll($0) }
        longEditor.delegate = longDelegate
        shortPreview.delegate = shortDelegate
        longEditor.contentOffset = CGPoint(x: 0, y: 3000)
        XCTAssertEqual(shortPreview.contentOffset.y, 1600)
        XCTAssertEqual(longEditor.contentOffset.y, 3000, "no echo pulls the editor back")
        XCTAssertEqual(longDelegate.count, 1)
    }

    func testUnlinkedPanesScrollIndependently() {
        let (editor, preview, linked) = panes(editorHeight: 5000, previewHeight: 4000)
        scroll(editor, to: 500, linked)
        linked.toggleLink()
        XCTAssertFalse(linked.isLinked)
        XCTAssertEqual(editor.contentOffset.y, 500, "unlinking moves nothing")
        XCTAssertEqual(preview.contentOffset.y, 500)
        scroll(editor, to: 1500, linked)
        XCTAssertEqual(preview.contentOffset.y, 500)
        scroll(preview, to: 100, linked)
        XCTAssertEqual(editor.contentOffset.y, 1500)
    }

    func testRelinkAlignsPreviewToEditor() {
        let (editor, preview, linked) = panes(editorHeight: 5000, previewHeight: 4000)
        linked.toggleLink()
        scroll(editor, to: 1200, linked)
        scroll(preview, to: 300, linked)
        linked.toggleLink()
        XCTAssertTrue(linked.isLinked)
        XCTAssertEqual(preview.contentOffset.y, 1200, "re-linking brings Preview to the editor")
        XCTAssertEqual(editor.contentOffset.y, 1200, "the editor stays where the writer is")
    }

    func testReplacedPaneIgnored() {
        let (editor, preview, linked) = panes(editorHeight: 5000, previewHeight: 4000)
        let replacement = makeScrollView(contentHeight: 5000)
        linked.connect(editor: replacement)
        scroll(editor, to: 800, linked)
        XCTAssertEqual(preview.contentOffset.y, 0, "a scroll from the replaced editor is ignored")
        scroll(replacement, to: 600, linked)
        XCTAssertEqual(preview.contentOffset.y, 600)

        let newPreview = makeScrollView(contentHeight: 4000)
        linked.connect(preview: newPreview)
        scroll(preview, to: 50, linked)
        XCTAssertEqual(replacement.contentOffset.y, 600, "a scroll from the replaced preview is ignored")
        XCTAssertNotNil(linked.editor)
    }

    // MARK: - The screen

    func testPreviewSplitsPageWithHairline() async throws {
        let document = await preparedDocument(text: Self.longDocument)
        let window = try hostScreen(document: document, mode: .split)
        let editor = try await waitAsync { Self.find(LineformTextView.self, in: window) }
        let reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }
        let editorFrame = editor.convert(editor.bounds, to: window)
        let readerFrame = reader.convert(reader.bounds, to: window)
        XCTAssertEqual(editorFrame.minY, 0)
        XCTAssertEqual(editorFrame.height, (window.bounds.height / 2).rounded(), accuracy: 0.5, "half each")
        XCTAssertEqual(readerFrame.minY, editorFrame.maxY, accuracy: 0.5, "Read right below the editor")
        XCTAssertEqual(readerFrame.maxY, window.bounds.maxY, accuracy: 0.5)
        XCTAssertTrue(editor.keepsCaretVisibleOnResize, "the editor pane keeps the caret in view above the keyboard")
        XCTAssertEqual(PreviewSplit<EmptyView, EmptyView>.editorHeight(forPageHeight: 500, mode: .split), 250)
        XCTAssertEqual(PreviewSplit<EmptyView, EmptyView>.editorHeight(forPageHeight: 500, mode: .write), 500)

        let theme = Theme.theme(for: .original)
        XCTAssertEqual(PreviewSplit<EmptyView, EmptyView>.dividerColor(for: theme),
                       theme.readableInk(theme.textColor.withAlphaComponent(0.15), minimumRatio: 1.5))

        // The link button: the Mac's strings, both ways.
        XCTAssertEqual(PreviewLinkButton.diameter, 38)
        XCTAssertEqual(PreviewLinkButton.accessibilityTitle(isLinked: true), "Unlink split scrolling")
        XCTAssertEqual(PreviewLinkButton.accessibilityTitle(isLinked: false), "Link split scrolling")

        // Linked through the real views: scrolling the editor moves the Read pane. Laid out first,
        // as a finger scroll lays out on the way (UIKit otherwise grows contentSize mid-set and puts
        // the old offset back).
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        editor.layoutIfNeeded()
        editor.setContentOffset(CGPoint(x: 0, y: 900 - editor.adjustedContentInset.top), animated: false)
        let distance = reader.contentOffset.y + reader.adjustedContentInset.top
        XCTAssertEqual(distance, 900, accuracy: 0.5)
    }

    func testPreviewTextFollowsEditsAfterDebounce() async throws {
        let document = await preparedDocument(text: "# One\n")
        let window = try hostScreen(document: document, mode: .split)
        let reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }
        XCTAssertEqual(reader.renderedSourceText, "# One\n")
        document.edit("# One\n\nTwo\n")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(reader.renderedSourceText, "# One\n", "Preview waits 0.12 s after an edit")
        _ = try await waitAsync { reader.renderedSourceText == "# One\n\nTwo\n" ? true : nil }
        XCTAssertEqual(LineformReadView.previewTextDelay, 0.12)
    }

    func testLayoutOffsetChangesInReadPaneDoNotDriveEditor() throws {
        let (editor, reader, linked) = try hostedReadPane(text: Self.longDocument)
        editor.setContentOffset(CGPoint(x: 0, y: 600 - editor.adjustedContentInset.top), animated: false)
        let editorY = editor.contentOffset.y

        // An offset UIKit or layout sets (no finger on the page, no restore): the editor stays.
        reader.contentOffset = CGPoint(x: 0, y: reader.contentOffset.y + 250)
        XCTAssertFalse(reader.forwardsScrollToLink)
        XCTAssertEqual(editor.contentOffset.y, editorY, accuracy: 0.5, "a layout-driven change never moves the editor")

        // An explicit restore does drive it.
        reader.scrollSourceLocationToTop((Self.longDocument as NSString).range(of: "Paragraph 90:").location)
        let readerDistance = reader.contentOffset.y + reader.adjustedContentInset.top
        let editorDistance = editor.contentOffset.y + editor.adjustedContentInset.top
        XCTAssertGreaterThan(readerDistance, 1000)
        XCTAssertEqual(editorDistance, LinkedScroll.linkedOffsetY(from: reader, to: editor) + editor.adjustedContentInset.top,
                       accuracy: 0.5, "the restore is followed")
        XCTAssertNotEqual(editor.contentOffset.y, editorY, accuracy: 1)
        _ = linked
    }

    func testEnteringPreviewAlignsReadPaneAfterFirstRender() throws {
        let (editor, reader, _) = try hostedReadPane(text: Self.longDocument, scrollEditorTo: 1400)
        // The pane was made after the editor had scrolled: the first render lines it up once.
        settle(ticks: 3)
        let editorDistance = editor.contentOffset.y + editor.adjustedContentInset.top
        let readerDistance = reader.contentOffset.y + reader.adjustedContentInset.top
        XCTAssertEqual(editorDistance, 1400, accuracy: 0.5)
        XCTAssertEqual(readerDistance, 1400, accuracy: 0.5, "Preview took the editor's place after its first render")

        // Unlinked, a new pane stays where it is.
        let (_, unlinkedReader, _) = try hostedReadPane(text: Self.longDocument, scrollEditorTo: 1400, linked: false)
        settle(ticks: 3)
        XCTAssertEqual(unlinkedReader.contentOffset.y + unlinkedReader.adjustedContentInset.top, 0, accuracy: 0.5)
    }

    func testReadPaneScrollsClearOfBottomButtons() async throws {
        let text = Self.longDocument + "\n\n![a missing picture](gone.png)"
        let document = await preparedDocument(text: text)
        let window = try hostScreen(document: document, mode: .split)
        let reader = try await waitAsync {
            Self.find(LineformReadView.self, in: window).flatMap { $0.renderedSourceText == nil ? nil : $0 }
        }
        XCTAssertEqual(DocumentScreen.bottomChromeClearance, MarkdownEditor.chromeMargin + 38 + 8)
        XCTAssertEqual(reader.contentInset.bottom, DocumentScreen.bottomChromeClearance, "Preview's lower pane")

        // At the end of the page.
        reader.layoutManager.ensureLayout(for: reader.textContainer)
        reader.layoutIfNeeded()
        let maximumY = reader.contentSize.height + reader.adjustedContentInset.bottom - reader.bounds.height
        reader.contentOffset = CGPoint(x: 0, y: maximumY)
        reader.layoutIfNeeded()
        let storage = reader.textStorage
        let lastGlyph = reader.layoutManager.glyphRange(forCharacterRange: NSRange(location: storage.length - 1, length: 1), actualCharacterRange: nil)
        let lastLine = reader.layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph.location, effectiveRange: nil)
            .offsetBy(dx: reader.textContainerInset.left, dy: reader.textContainerInset.top)
        let pill = try XCTUnwrap(reader.overlayButtons.first { $0.kind == .reconnect })
        let lastLineInWindow = reader.convert(lastLine, to: window)
        let pillInWindow = pill.convert(pill.bounds, to: window)

        // The floating buttons: the Menu button and, left of it, the link button, chromeMargin
        // above the safe area's bottom.
        let buttonsBottom = window.bounds.height - window.safeAreaInsets.bottom - MarkdownEditor.chromeMargin
        let menu = Self.accessibilityFrame(label: "Files", in: window)
            ?? CGRect(x: window.bounds.width - MarkdownEditor.chromeMargin - MenuButton.diameter,
                      y: buttonsBottom - MenuButton.diameter, width: MenuButton.diameter, height: MenuButton.diameter)
        let link = Self.accessibilityFrame(label: PreviewLinkButton.accessibilityTitle(isLinked: true), in: window)
            ?? CGRect(x: menu.minX - DocumentScreen.bottomChromeSpacing - PreviewLinkButton.diameter,
                      y: menu.midY - PreviewLinkButton.diameter / 2,
                      width: PreviewLinkButton.diameter, height: PreviewLinkButton.diameter)
        for button in [menu, link] {
            XCTAssertLessThanOrEqual(lastLineInWindow.maxY, button.minY, "the last line is above \(button)")
            XCTAssertLessThanOrEqual(pillInWindow.maxY, button.minY, "the pill is above \(button)")
        }
    }

    // MARK: - Helpers

    /// An editor and a Read pane wired to one `LinkedScroll` the way the screen wires Preview: the
    /// Read pane made (and so first rendered) after the editor was scrolled to `scrollEditorTo`.
    private func hostedReadPane(
        text: String,
        scrollEditorTo editorDistance: CGFloat = 0,
        linked: Bool = true
    ) throws -> (LineformTextView, LineformReadView, LinkedScroll) {
        let window = self.window ?? {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UIViewController()
            window.isHidden = false
            self.window = window
            return window
        }()
        let host = try XCTUnwrap(window.rootViewController?.view)
        let link = LinkedScroll()
        links.append(link) // The screen holds its LinkedScroll in @State; the panes hold it weakly.
        if !linked { link.toggleLink() }
        let editor = LineformTextView.make()
        editor.setDocumentText(text)
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 426)
        host.addSubview(editor)
        link.connect(editor: editor)
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        editor.layoutIfNeeded()
        editor.setContentOffset(CGPoint(x: 0, y: editorDistance - editor.adjustedContentInset.top), animated: false)

        let reader = LineformReadView.make()
        reader.frame = CGRect(x: 0, y: 426, width: 393, height: 426)
        ReadViewRepresentable(text: text, profile: .original, documentDirectory: nil, linkedScroll: link).configure(reader)
        // The editor reports no scrolls here, so only the Read pane's own path can line it up.
        host.addSubview(reader)
        reader.layoutIfNeeded()
        return (editor, reader, link)
    }

    private var links: [LinkedScroll] = []

    private func settle(ticks: Int) {
        for _ in 0..<ticks {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.layoutIfNeeded()
        }
    }

    /// The frame of the accessibility element labelled `label` (a SwiftUI button), if VoiceOver's
    /// tree exposes it.
    private static func accessibilityFrame(label: String, in root: NSObject, depth: Int = 0) -> CGRect? {
        guard depth < 40 else { return nil }
        if root.accessibilityLabel == label, !(root is UIWindow) { return root.accessibilityFrame }
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
            if let frame = accessibilityFrame(label: label, in: child, depth: depth + 1) { return frame }
        }
        return nil
    }

    private static let longDocument: String = (0..<200).map { index in
        "Paragraph \(index): the quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun by the river."
    }.joined(separator: "\n\n")

    private func panes(editorHeight: CGFloat, previewHeight: CGFloat) -> (UIScrollView, UIScrollView, LinkedScroll) {
        let editor = makeScrollView(contentHeight: editorHeight)
        let preview = makeScrollView(contentHeight: previewHeight)
        let linked = LinkedScroll()
        linked.connect(editor: editor)
        linked.connect(preview: preview)
        return (editor, preview, linked)
    }

    private func makeScrollView(contentHeight: CGFloat) -> UIScrollView {
        let view = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        view.contentInsetAdjustmentBehavior = .never
        view.contentSize = CGSize(width: 390, height: contentHeight)
        return view
    }

    /// Sets `view`'s offset (as a scroll would) and reports it, as the pane's delegate does.
    private func scroll(_ view: UIScrollView, to y: CGFloat, _ linked: LinkedScroll) {
        view.contentOffset = CGPoint(x: 0, y: y)
        linked.editorDidScroll(view)
        linked.previewDidScroll(view)
    }

    private func hostScreen(document: OpenDocument, mode: EditorDisplayMode) throws -> UIWindow {
        let suite = "LinkedScrollTests-\(UUID().uuidString)"
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
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: LinkedScrollTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        await document.flush()
        return document
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

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

/// Counts scroll reports and forwards each one.
private final class ScrollRecorder: NSObject, UITextViewDelegate {
    private let forward: (UIScrollView) -> Void
    private(set) var count = 0

    init(_ forward: @escaping (UIScrollView) -> Void) {
        self.forward = forward
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        count += 1
        forward(scrollView)
    }
}

/// No iCloud, ever: every item reads as local.
private struct LinkedScrollTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
