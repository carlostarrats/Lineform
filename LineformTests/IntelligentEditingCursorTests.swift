import AppKit
import SwiftUI
import XCTest
@testable import Lineform

@MainActor
final class IntelligentEditingCursorTests: XCTestCase {
    func testCursorRectViewSetsPointingHandOnMouseEnterAndRestoresOnExit() throws {
        var hoverStates = [Bool]()
        let cursorView = CursorRectNSView(cursor: .pointingHand) { hovering in
            hoverStates.append(hovering)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = cursorView
        cursorView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 80, height: 32)
        cursorView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        cursorView.mouseEntered(with: event)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        XCTAssertEqual(hoverStates, [true])

        cursorView.mouseExited(with: event)
        XCTAssertEqual(hoverStates, [true, false])
    }

    func testCursorRectViewReassertsPointingHandWhenTextCursorStealsHover() throws {
        let cursorView = CursorRectNSView(cursor: .pointingHand) { _ in }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = cursorView
        cursorView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 88, height: 52)
        cursorView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        cursorView.mouseEntered(with: event)
        XCTAssertEqual(NSCursor.current, .pointingHand)

        NSCursor.iBeam.set()
        XCTAssertEqual(NSCursor.current, .iBeam)

        cursorView.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, .pointingHand)

        NSCursor.iBeam.set()
        XCTAssertEqual(NSCursor.current, .iBeam)

        cursorView.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, .pointingHand)

        cursorView.mouseExited(with: event)
    }

    func testOptionsPanelRendersWindowAttachedNonZeroCursorRects() {
        var selectedIndex = 0
        let originalText = "The draft need a cleaner sentence."
        let replacementText = "The draft needs a clearer sentence."
        let suggestion = IntelligentEditingSuggestion(
            action: .rewrite,
            selectedRange: NSRange(location: 0, length: (originalText as NSString).length),
            originalText: originalText,
            replacementText: replacementText,
            diff: MarkdownDiff.make(original: originalText, replacement: replacementText)
        )

        let panel = IntelligentEditingOptionsPanel(
            suggestions: [suggestion],
            selectedIndex: Binding(
                get: { selectedIndex },
                set: { selectedIndex = $0 }
            ),
            retry: {},
            accept: {},
            reject: {}
        )

        let hostingView = NSHostingView(rootView: panel)
        hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 360)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let cursorViews = hostingView.descendants(ofType: CursorRectNSView.self)
        XCTAssertGreaterThanOrEqual(cursorViews.count, 3)
        XCTAssertTrue(cursorViews.allSatisfy { $0.window === window })
        XCTAssertTrue(cursorViews.allSatisfy { $0.bounds.width > 1 && $0.bounds.height > 1 })
    }

    func testActionRailRendersWindowAttachedNonZeroCursorRects() {
        let rail = IntelligenceActionRail(
            actions: IntelligentEditingAction.actionRailActions,
            isActionEnabled: true,
            runAction: { _ in }
        )

        let hostingView = NSHostingView(rootView: rail)
        hostingView.frame = NSRect(x: 0, y: 0, width: 430, height: 80)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let eventViews = hostingView.descendants(ofType: ActionRailButtonEventNSView.self)
        XCTAssertEqual(eventViews.count, IntelligentEditingAction.actionRailActions.count)
        XCTAssertTrue(eventViews.allSatisfy { $0.window === window })
        XCTAssertTrue(eventViews.allSatisfy { $0.bounds.width > 1 && $0.bounds.height > 1 })
    }

    func testActionRailHitTestingStaysAboveTextViewSurface() {
        let root = ZStack(alignment: .bottom) {
            TestTextViewSurface()
                .frame(width: 700, height: 520)

            IntelligenceActionRailOverlayHost(
                actions: IntelligentEditingAction.actionRailActions,
                isActionEnabled: true,
                runAction: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)
        }
        .frame(width: 700, height: 520)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let buttonView = try! XCTUnwrap(hostingView.descendants(ofType: ActionRailButtonNSView.self).first)
        let buttonFrameInWindow = buttonView.convert(buttonView.bounds, to: nil)
        let windowPoint = NSPoint(x: buttonFrameInWindow.midX, y: buttonFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)

        XCTAssertTrue(EditorFloatingControlHitTestRegistry.contains(windowPoint: windowPoint, in: window))
        XCTAssertNotNil(hostingView.hitTest(hitPoint))
        XCTAssertFalse(hostingView.hitTest(hitPoint) is LineformTextView)
    }

    func testActionRailHitTestingTargetsButtonAboveEditorScrollView() {
        let root = ZStack(alignment: .bottom) {
            TestEditorScrollSurface()
                .frame(width: 700, height: 520)

            IntelligenceActionRailOverlayHost(
                actions: IntelligentEditingAction.actionRailActions,
                isActionEnabled: true,
                runAction: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)
        }
        .frame(width: 700, height: 520)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let buttonView = try! XCTUnwrap(hostingView.descendants(ofType: ActionRailButtonNSView.self).first)
        let buttonFrameInWindow = buttonView.convert(buttonView.bounds, to: nil)
        let windowPoint = NSPoint(x: buttonFrameInWindow.midX, y: buttonFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)
        let hitView = hostingView.hitTest(hitPoint)

        XCTAssertTrue(EditorFloatingControlHitTestRegistry.contains(windowPoint: windowPoint, in: window))
        XCTAssertTrue(
            hitView === buttonView || hitView?.hasAncestor(buttonView) == true,
            "Expected hit testing over the visible AI button to resolve to the AppKit button view, got \(String(describing: hitView))."
        )
    }

    func testActionRailOverlayUsesDirectAppKitButtonSurface() {
        let overlay = IntelligenceActionRailOverlayNSView(
            actions: IntelligentEditingAction.actionRailActions,
            isActionEnabled: true,
            runAction: { _ in }
        )
        overlay.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = NSWindow(
            contentRect: overlay.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay
        window.makeKeyAndOrderFront(nil)
        overlay.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        overlay.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlay.descendants(ofType: ActionRailButtonNSView.self).count, IntelligentEditingAction.actionRailActions.count)
        XCTAssertTrue(overlay.descendants(ofType: NSHostingView<AnyView>.self).isEmpty)
    }

    func testActionRailButtonViewOwnsHoverCursorAndClickAction() throws {
        var actionCount = 0
        let buttonView = ActionRailButtonNSView(
            action: .proofread,
            isEnabled: true,
            performAction: { actionCount += 1 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = buttonView
        buttonView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 88, height: 52)
        buttonView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))

        XCTAssertTrue(buttonView.hitTest(NSPoint(x: 20, y: 20)) === buttonView)

        buttonView.mouseEntered(with: event)
        XCTAssertEqual(NSCursor.current, .pointingHand)

        buttonView.mouseDown(with: event)
        XCTAssertEqual(actionCount, 1)

        buttonView.mouseExited(with: event)
    }

    func testDisabledActionRailButtonDoesNotOwnHoverCursorOrHitRegion() throws {
        var actionCount = 0
        let buttonView = ActionRailButtonNSView(
            action: .proofread,
            isEnabled: false,
            performAction: { actionCount += 1 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = buttonView
        buttonView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 88, height: 52)
        buttonView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        XCTAssertNil(buttonView.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertFalse(EditorFloatingControlHitTestRegistry.contains(windowPoint: NSPoint(x: 20, y: 20), in: window))

        NSCursor.iBeam.set()
        buttonView.mouseEntered(with: event)
        XCTAssertEqual(NSCursor.current, .iBeam)

        buttonView.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, .iBeam)

        buttonView.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, .iBeam)

        buttonView.mouseDown(with: event)
        XCTAssertEqual(actionCount, 0)
    }

    func testActionRailButtonRemovesHoverTrackingImmediatelyWhenDisabled() throws {
        let buttonView = ActionRailButtonNSView(
            action: .proofread,
            isEnabled: true,
            performAction: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = buttonView
        buttonView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 88, height: 52)
        buttonView.updateTrackingAreas()

        XCTAssertFalse(buttonView.trackingAreas.isEmpty)

        buttonView.isEnabled = false

        XCTAssertTrue(buttonView.trackingAreas.isEmpty)
    }

    func testTextViewDoesNotRestoreIBeamInsideFloatingControlRegion() throws {
        let textView = LineformTextView()
        textView.string = "Selected text sits behind the AI rail."
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)

        let owner = NSObject()
        EditorFloatingControlHitTestRegistry.setRegion(
            owner: owner,
            window: window,
            rect: NSRect(x: 20, y: 20, width: 120, height: 64)
        )
        defer {
            EditorFloatingControlHitTestRegistry.remove(owner: owner)
        }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        NSCursor.pointingHand.set()
        textView.cursorUpdate(with: event)

        XCTAssertEqual(NSCursor.current, .pointingHand)

        NSCursor.iBeam.set()
        textView.mouseMoved(with: event)

        XCTAssertEqual(NSCursor.current, .pointingHand)
    }

    func testActionRailEventViewOwnsHoverCursorAndClickAction() throws {
        var hoverStates = [Bool]()
        var actionCount = 0
        let eventView = ActionRailButtonEventNSView(
            isEnabled: true,
            onHoverChanged: { hoverStates.append($0) },
            performAction: { actionCount += 1 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = eventView
        eventView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 88, height: 52)
        eventView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))

        XCTAssertTrue(eventView.hitTest(NSPoint(x: 20, y: 20)) === eventView)

        eventView.mouseEntered(with: event)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        XCTAssertEqual(hoverStates, [true])

        eventView.mouseDown(with: event)
        XCTAssertEqual(actionCount, 1)

        eventView.mouseExited(with: event)
        XCTAssertEqual(hoverStates, [true, false])
    }
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.descendants(ofType: type)
            if let typedSubview = subview as? T {
                matches.insert(typedSubview, at: 0)
            }
            return matches
        }
    }

    func hasAncestor(_ ancestor: NSView) -> Bool {
        var current = superview
        while let view = current {
            if view === ancestor {
                return true
            }
            current = view.superview
        }
        return false
    }
}

private struct TestTextViewSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> LineformTextView {
        let textView = LineformTextView()
        textView.string = "Select this text, then hover the AI action rail."
        return textView
    }

    func updateNSView(_ nsView: LineformTextView, context: Context) {
    }
}

private struct TestEditorScrollSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = LineformTextView()
        textView.string = "Select this text, then hover the AI action rail."
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
    }
}
