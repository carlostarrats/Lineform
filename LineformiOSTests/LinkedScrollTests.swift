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

    // MARK: - Helpers

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
private final class ScrollRecorder: NSObject, UIScrollViewDelegate {
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
