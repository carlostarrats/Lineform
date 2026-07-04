import AppKit
import SwiftUI
import XCTest
@testable import Lineform

/// Hosted-window drawer/inspector motion tests, quarantined into the opt-in
/// `LineformHosted` test plan (run with `-testPlan LineformHosted`).
///
/// These tests build a real `NSWindow` + `NSHostingView` editor inside the unit-test
/// process and sample sub-second animations. That is powerful — it protects real UI
/// motion regressions — but it is also outside what XCTest unit bundles support well:
/// the tests are load-sensitive (they fail spuriously with Xcode open or the machine
/// busy) and SwiftUI/AppKit window lifecycles inside the test host intermittently
/// over-release during autorelease-pool drains, crashing the *test host* (never the
/// app) either per-test (XCTMemoryChecker) or at process exit
/// (`_NSWindowTransformAnimation` dealloc). Two spot-fix attempts (closing the window
/// in teardown; `animationBehavior = .none`) each surfaced a new over-release
/// elsewhere, so the durable fix is placement, not patching: the default test plan
/// skips this class (and `LiveReloadScrollTests`), keeping everyday `xcodebuild test`
/// fast, deterministic, and crash-free, while these tests remain fully runnable on
/// demand — run them on a quiet machine before releases that touch editor motion.
///
/// Do not weaken or delete these tests; see CLAUDE.md ("Verification Commands").
final class EditorDrawerMotionHostedTests: XCTestCase {
    @MainActor
    func testZEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens() throws {
        let harness = try makeEditorDrawerHarness()
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let trackedRange = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        var didOpenOutline = false
        defer {
            if didOpenOutline {
                LineformAppNotification.toggleOutline.post(
                    object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
                )
                runMainLoop(for: 0.45)
            }
            harness.tearDown()
            runMainLoop(for: 0.2)
        }
        let trackedYBefore = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameBefore = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameBefore = textView.convert(textView.bounds, to: nil)
        let scrollOriginBefore = scrollView.contentView.bounds.origin

        LineformAppNotification.toggleOutline.post(
            object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
        )
        didOpenOutline = true
        let maximumAnimatedDelta = try maximumTrackedYDelta(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            baselineY: trackedYBefore,
            duration: 0.45
        )

        let trackedYAfter = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameAfter = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameAfter = textView.convert(textView.bounds, to: nil)
        let scrollOriginAfter = scrollView.contentView.bounds.origin
        XCTAssertEqual(
            trackedYAfter,
            trackedYBefore,
            accuracy: 1.0,
            """
            scrollFrame: \(scrollFrameBefore) -> \(scrollFrameAfter)
            textFrame: \(textFrameBefore) -> \(textFrameAfter)
            scrollOrigin: \(scrollOriginBefore) -> \(scrollOriginAfter)
            """
        )
        XCTAssertLessThanOrEqual(maximumAnimatedDelta, 1.0)
    }

    @MainActor
    func testEditorVisibleTextDoesNotJumpVerticallyWhenReadingInspectorOpens() throws {
        let harness = try makeEditorDrawerHarness()
        defer {
            harness.tearDown()
            runMainLoop(for: 0.2)
        }
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let trackedRange = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let trackedYBefore = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameBefore = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameBefore = textView.convert(textView.bounds, to: nil)
        let scrollOriginBefore = scrollView.contentView.bounds.origin

        LineformAppNotification.showReadingExperience.post(
            object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
        )
        let maximumAnimatedDelta = try maximumTrackedYDelta(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            baselineY: trackedYBefore,
            duration: 0.45
        )

        let trackedYAfter = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameAfter = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameAfter = textView.convert(textView.bounds, to: nil)
        let scrollOriginAfter = scrollView.contentView.bounds.origin
        XCTAssertEqual(
            trackedYAfter,
            trackedYBefore,
            accuracy: 1.0,
            """
            scrollFrame: \(scrollFrameBefore) -> \(scrollFrameAfter)
            textFrame: \(textFrameBefore) -> \(textFrameAfter)
            scrollOrigin: \(scrollOriginBefore) -> \(scrollOriginAfter)
            """
        )
        XCTAssertLessThanOrEqual(maximumAnimatedDelta, 1.0)
    }

    @MainActor
    func testZScrolledEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens() throws {
        try assertScrolledEditorVisibleTextDoesNotJumpVerticallyWhenDrawerOpens(.outline)
    }

    @MainActor
    func testScrolledEditorVisibleTextDoesNotJumpVerticallyWhenReadingInspectorOpens() throws {
        try assertScrolledEditorVisibleTextDoesNotJumpVerticallyWhenDrawerOpens(.readingInspector)
    }

    @MainActor
    func testZReflowingEditorDoesNotScrollUpWhenOutlineDrawerOpens() throws {
        try assertScrolledEditorDoesNotScrollUpWhenDrawerOpens(.outline, text: Self.reflowingDrawerTestDocument)
    }

    @MainActor
    func testReflowingEditorDoesNotScrollUpWhenReadingInspectorOpens() throws {
        try assertScrolledEditorDoesNotScrollUpWhenDrawerOpens(.readingInspector, text: Self.reflowingDrawerTestDocument)
    }

    @MainActor
    func testReadingInspectorOpeningDoesNotSnapTextColumnToFinalPosition() throws {
        let samples = try horizontalTextColumnMotionSamples(whenOpening: .readingInspector)
        let totalDistance = Self.horizontalMotionTotalDistance(samples)
        let distinctIntermediatePositions = Self.distinctIntermediateMotionPositions(samples)

        XCTAssertGreaterThan(totalDistance, 40, "The fixture must exercise visible horizontal text movement.")
        XCTAssertGreaterThanOrEqual(
            distinctIntermediatePositions,
            2,
            "Reading inspector text motion did not expose enough intermediate positions: \(samples)"
        )
    }

    @MainActor
    private func assertScrolledEditorVisibleTextDoesNotJumpVerticallyWhenDrawerOpens(_ drawer: EditorDrawerKind) throws {
        let harness = try makeEditorDrawerHarness(text: Self.longDrawerTestDocument)
        defer {
            harness.tearDown()
            runMainLoop(for: 0.2)
        }
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let startingOrigin = NSPoint(x: 0, y: 520)
        scrollView.contentView.setBoundsOrigin(startingOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        runMainLoop(for: 0.1)

        let trackedRange = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let trackedCharacter = NSRange(location: trackedRange.location, length: 1)
        let trackedYBefore = try trackedCharacterY(trackedCharacter, in: textView, relativeTo: harness.window)
        let scrollOriginBefore = scrollView.contentView.bounds.origin

        switch drawer {
        case .outline:
            LineformAppNotification.toggleOutline.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        case .readingInspector:
            LineformAppNotification.showReadingExperience.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        }

        let maximumAnimatedTrackedYDelta = try maximumTrackedYDelta(
            trackedCharacter,
            in: textView,
            baselineY: trackedYBefore,
            duration: 0.45
        )
        let trackedYAfter = try trackedCharacterY(trackedCharacter, in: textView, relativeTo: harness.window)
        let scrollOriginAfter = scrollView.contentView.bounds.origin

        XCTAssertEqual(
            trackedYAfter,
            trackedYBefore,
            accuracy: 1.0,
            "scrollOrigin: \(scrollOriginBefore) -> \(scrollOriginAfter)"
        )
        XCTAssertLessThanOrEqual(maximumAnimatedTrackedYDelta, 1.0)
    }

    @MainActor
    private func assertScrolledEditorDoesNotScrollUpWhenDrawerOpens(_ drawer: EditorDrawerKind, text: String) throws {
        let harness = try makeEditorDrawerHarness(text: text)
        defer {
            harness.tearDown()
            runMainLoop(for: 0.2)
        }
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let startingOrigin = NSPoint(x: 0, y: 520)
        scrollView.contentView.setBoundsOrigin(startingOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        runMainLoop(for: 0.1)
        let scrollOriginBefore = scrollView.contentView.bounds.origin.y

        switch drawer {
        case .outline:
            LineformAppNotification.toggleOutline.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        case .readingInspector:
            LineformAppNotification.showReadingExperience.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        }

        let maximumScrollOriginDelta = maximumScrollOriginYDelta(
            in: scrollView,
            baselineY: scrollOriginBefore,
            duration: 0.45
        )
        let scrollOriginAfter = scrollView.contentView.bounds.origin.y

        XCTAssertEqual(scrollOriginAfter, scrollOriginBefore, accuracy: 1.0)
        XCTAssertLessThanOrEqual(maximumScrollOriginDelta, 1.0)
    }

    @MainActor
    private func horizontalTextColumnMotionSamples(
        whenOpening drawer: EditorDrawerKind,
        duration: TimeInterval = 0.45,
        interval: TimeInterval = 0.015
    ) throws -> [CGFloat] {
        let harness = try makeEditorDrawerHarness()
        defer {
            harness.tearDown()
            runMainLoop(for: 0.2)
        }
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        var samples = [try textColumnMinX(in: textView)]

        switch drawer {
        case .outline:
            LineformAppNotification.toggleOutline.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        case .readingInspector:
            LineformAppNotification.showReadingExperience.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        }

        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            samples.append(try textColumnMinX(in: textView))
        }

        return samples
    }

    @MainActor
    private func makeEditorDrawerHarness(
        text: String? = nil,
        profile: ReadingProfile = .original
    ) throws -> EditorDrawerHarness {
        runMainLoop(for: 0.3)
        var document = LineformDocument(
            text: text ?? Self.shortDrawerTestDocument
        )
        let defaultsName = "LineformEditorDrawerHarness-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let readingProfileStore = ReadingProfileStore(defaults: defaults)
        readingProfileStore.apply(profile)
        // Inject a file-browser store on the same isolated defaults suite with no iCloud, so the
        // hosted editor never resolves the user's real workspace bookmark (which would touch
        // ~/Documents and trigger a TCC prompt during headless test runs).
        let fileBrowserStore = OutlineFileBrowserStore(defaults: defaults, iCloudDocumentsURLProvider: { _ in nil })
        // Pin the outline drawer closed at construction so these sub-second motion tests
        // measure the open transition they post below — independent of the app-wide
        // "Show sidebar on launch" default (which is on).
        let settings = LineformSettingsStore(defaults: defaults)
        settings.showSidebarOnLaunch = false
        let editor = EditorContainerView(
            document: Binding(
                get: { document },
                set: { document = $0 }
            ),
            readingProfileStore: readingProfileStore,
            fileBrowserStore: fileBrowserStore,
            settings: settings
        )
        let hostingView = NSHostingView(rootView: AnyView(editor.id(UUID())))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 720)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        runMainLoop(for: 0.3)
        _ = try XCTUnwrap(hostingView.descendants(ofType: LineformTextView.self).first)
        return EditorDrawerHarness(window: window, hostingView: hostingView)
    }

    private static let shortDrawerTestDocument = """
            # Features

            Native macOS document with AppKit and TextKit.

            Real Markdown files that remain portable.

            Write, Read, and Preview modes for drafting.

            Markdown outline navigation from document headings.

            Reading controls for type size, line height, block spacing, margins, column width, themes, focus, and ruler.

            Apple Books-style reader themes, with accessibility adjustments layered on top.

            Native Writing Tools and Apple Intelligence selected-text editing.

            ## Requirements

            - Xcode with macOS SDK support
            - Swift 6
            - Plain UTF-8 Markdown and text file handling
            """

    private static let longDrawerTestDocument = (0..<72)
        .map { index in
            """
            ## Section \(index + 1)

            This is a stable paragraph for testing drawer layout in a longer writing session. It has enough words to wrap at ordinary editor widths without being so long that one line dominates the viewport.

            The editor should slide sideways when a drawer opens. The visible text should not jump upward while the outline or reading controls appear.
            """
        }
        .joined(separator: "\n\n")

    private static let reflowingDrawerTestDocument = (0..<48)
        .map { index in
            """
            ## Reflow Section \(index + 1)

            This deliberately long editor line sits above or inside the viewport and will rewrap when a side drawer narrows the writing canvas, which is the case that can make the visible text appear to jump upward during drawer presentation.
            """
        }
        .joined(separator: "\n\n")

    @MainActor
    private func trackedCharacterY(
        _ characterRange: NSRange,
        in textView: LineformTextView,
        relativeTo window: NSWindow
    ) throws -> CGFloat {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return textView.convert(rect, to: nil).midY
    }

    @MainActor
    private func textColumnMinX(in textView: LineformTextView) throws -> CGFloat {
        _ = try XCTUnwrap(textView.window)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let rect = NSRect(
            x: textView.textContainerOrigin.x,
            y: textView.textContainerOrigin.y,
            width: 1,
            height: 1
        )
        return textView.convert(rect, to: nil).minX
    }

    private static func horizontalMotionTotalDistance(_ samples: [CGFloat]) -> CGFloat {
        guard let first = samples.first, let last = samples.last else {
            return 0
        }

        return abs(last - first)
    }

    private static func distinctIntermediateMotionPositions(_ samples: [CGFloat]) -> Int {
        guard
            let first = samples.first,
            let last = samples.last,
            abs(first - last) > 1
        else {
            return 0
        }

        let lowerBound = min(first, last) + 1
        let upperBound = max(first, last) - 1
        return Set(
            samples
                .dropFirst()
                .dropLast()
                .filter { $0 > lowerBound && $0 < upperBound }
                .map { Int($0.rounded()) }
        ).count
    }

    @MainActor
    private func maximumTrackedYDelta(
        _ characterRange: NSRange,
        in textView: LineformTextView,
        baselineY: CGFloat,
        duration: TimeInterval,
        interval: TimeInterval = 0.03
    ) throws -> CGFloat {
        let window = try XCTUnwrap(textView.window)
        var maximumDelta: CGFloat = 0
        let deadline = Date(timeIntervalSinceNow: duration)

        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            let currentY = try trackedCharacterY(characterRange, in: textView, relativeTo: window)
            maximumDelta = max(maximumDelta, abs(currentY - baselineY))
        }

        return maximumDelta
    }

    @MainActor
    private func maximumScrollOriginYDelta(
        in scrollView: NSScrollView,
        baselineY: CGFloat,
        duration: TimeInterval,
        interval: TimeInterval = 0.03
    ) -> CGFloat {
        var maximumDelta: CGFloat = 0
        let deadline = Date(timeIntervalSinceNow: duration)

        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            maximumDelta = max(maximumDelta, abs(scrollView.contentView.bounds.origin.y - baselineY))
        }

        return maximumDelta
    }

    private func runMainLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }
}

@MainActor
private final class EditorDrawerHarness {
    let window: NSWindow
    let hostingView: NSHostingView<AnyView>
    private var didTearDown = false

    init(window: NSWindow, hostingView: NSHostingView<AnyView>) {
        self.window = window
        self.hostingView = hostingView
    }

    func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        window.orderOut(nil)
        window.contentView = nil
    }
}

private enum EditorDrawerKind {
    case outline
    case readingInspector
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        var matches = subviews.compactMap { $0 as? T }
        for subview in subviews {
            matches.append(contentsOf: subview.descendants(ofType: type))
        }
        return matches
    }
}
