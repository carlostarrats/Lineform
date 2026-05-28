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

        let window = KeyCapableTestWindow(
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

    func testInstructionComposerRendersWindowAttachedNonZeroCursorRects() {
        let composer = IntelligenceInstructionComposer(
            instruction: .constant("Make this warmer."),
            isActionEnabled: true,
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )

        let hostingView = NSHostingView(rootView: composer)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 120)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let eventViews = hostingView.descendants(ofType: IntelligenceInstructionSubmitButtonNSView.self)
        XCTAssertGreaterThanOrEqual(eventViews.count, 1)
        XCTAssertTrue(eventViews.allSatisfy { $0.window === window })
        XCTAssertTrue(eventViews.allSatisfy { $0.bounds.width > 1 && $0.bounds.height > 1 })
    }

    func testInstructionComposerHitTestingStaysAboveTextViewSurface() {
        let root = ZStack(alignment: .bottom) {
            TestTextViewSurface()
                .frame(width: 700, height: 520)

            IntelligenceInstructionComposer(
                instruction: .constant("Make this warmer."),
                isActionEnabled: true,
                onFocusChanged: { _ in },
                submitInstruction: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)
        }
        .frame(width: 700, height: 520)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let eventView = try! XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionSubmitButtonNSView.self).first)
        let eventFrameInWindow = eventView.convert(eventView.bounds, to: nil)
        let windowPoint = NSPoint(x: eventFrameInWindow.midX, y: eventFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)

        XCTAssertNotNil(hostingView.hitTest(hitPoint))
        XCTAssertFalse(hostingView.hitTest(hitPoint) is LineformTextView)
    }

    func testInstructionComposerHitTestingStaysAboveEditorScrollView() {
        let root = ZStack(alignment: .bottom) {
            TestEditorScrollSurface()
                .frame(width: 700, height: 520)

            IntelligenceInstructionComposer(
                instruction: .constant("Make this warmer."),
                isActionEnabled: true,
                onFocusChanged: { _ in },
                submitInstruction: { _ in }
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

        let eventView = try! XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionSubmitButtonNSView.self).first)
        let eventFrameInWindow = eventView.convert(eventView.bounds, to: nil)
        let windowPoint = NSPoint(x: eventFrameInWindow.midX, y: eventFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)
        let hitView = hostingView.hitTest(hitPoint)

        XCTAssertNotNil(hitView)
        XCTAssertFalse(hitView is LineformTextView)
    }

    func testInstructionComposerSendButtonOwnsHitTestingAboveEditorScrollView() {
        let root = ZStack(alignment: .bottom) {
            TestEditorScrollSurface()
                .frame(width: 700, height: 520)

            IntelligenceInstructionComposer(
                instruction: .constant("Make this warmer."),
                isActionEnabled: true,
                onFocusChanged: { _ in },
                submitInstruction: { _ in }
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

        let eventView = try! XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionSubmitButtonNSView.self).first)
        let eventFrameInWindow = eventView.convert(eventView.bounds, to: nil)
        let windowPoint = NSPoint(x: eventFrameInWindow.midX, y: eventFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)
        let hitView = hostingView.hitTest(hitPoint)

        XCTAssertTrue(
            hitView === eventView || hitView?.hasAncestor(eventView) == true,
            "Expected the send button hover surface to own hit testing, got \(String(describing: hitView))."
        )
    }

    func testInstructionComposerUsesNativeTextInputAndSubmitCursorSurface() {
        let composer = IntelligenceInstructionComposer(
            instruction: .constant("Make this warmer."),
            isActionEnabled: true,
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )
        let hostingView = NSHostingView(rootView: composer)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 120)

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

        XCTAssertGreaterThanOrEqual(hostingView.descendants(ofType: IntelligenceInstructionTextView.self).count, 1)
        XCTAssertGreaterThanOrEqual(hostingView.descendants(ofType: IntelligenceInstructionSubmitButtonNSView.self).count, 1)
    }

    func testInstructionComposerUsesDirectTextViewInputNotFieldEditor() throws {
        let composerView = IntelligenceInstructionComposerNSView(
            instruction: "",
            isActionEnabled: false,
            textChanged: { _ in },
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )
        composerView.frame = NSRect(x: 0, y: 0, width: 560, height: 52)
        composerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(composerView.descendants(ofType: NSTextField.self).count, 0)
        XCTAssertEqual(composerView.descendants(ofType: IntelligenceInstructionTextView.self).count, 1)
    }

    func testInstructionComposerInputAreaOwnsHitTestingAboveEditorScrollView() throws {
        let root = ZStack(alignment: .bottom) {
            TestEditorScrollSurface()
                .frame(width: 700, height: 520)

            IntelligenceInstructionComposer(
                instruction: .constant(""),
                isActionEnabled: true,
                onFocusChanged: { _ in },
                submitInstruction: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)
        }
        .frame(width: 700, height: 520)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)

        let textViewFrameInWindow = textView.convert(textView.bounds, to: nil)
        let windowPoint = NSPoint(x: textViewFrameInWindow.midX, y: textViewFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)
        let hitView = hostingView.hitTest(hitPoint)

        XCTAssertTrue(
            hitView === textView || hitView?.hasAncestor(textView) == true,
            "Expected the AI input area to own hit testing, got \(String(describing: hitView))."
        )

        window.makeFirstResponder(textView)
        XCTAssertTrue(window.firstResponder === textView)
    }

    func testInstructionComposerClickingInputFocusesTextViewBeforeTyping() throws {
        var instruction = ""
        var focusStates = [Bool]()
        let composerView = IntelligenceInstructionComposerNSView(
            instruction: "",
            isActionEnabled: false,
            textChanged: { instruction = $0 },
            onFocusChanged: { focusStates.append($0) },
            submitInstruction: { _ in }
        )
        composerView.frame = NSRect(x: 0, y: 0, width: 560, height: 52)

        let window = KeyCapableTestWindow(
            contentRect: composerView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = composerView
        window.makeKeyAndOrderFront(nil)
        composerView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(composerView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === textView)

        let textViewFrameInWindow = textView.convert(textView.bounds, to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: textViewFrameInWindow.midX, y: textViewFrameInWindow.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        textView.mouseDown(with: mouseDown)

        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(focusStates.contains(true))

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: mouseDown.locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(textView.string, "x")
        XCTAssertEqual(instruction, "x")
    }

    func testFullEditorComposerAcceptsTypingAfterSelectingText() throws {
        var document = LineformDocument(text: "Select this sentence for AI.")
        let editor = EditorContainerView(
            document: Binding(
                get: { document },
                set: { document = $0 }
            ),
            initialIntelligenceRailEnabled: true
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 820, height: 620)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()

        let editorTextView = try XCTUnwrap(hostingView.descendants(ofType: LineformTextView.self).first)
        editorTextView.setSelectedRange(NSRange(location: 0, length: 6))
        editorTextView.delegate?.textViewDidChangeSelection?(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorTextView)
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hostingView.layoutSubtreeIfNeeded()

        let inputTextView = try XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        XCTAssertTrue(
            window.firstResponder === inputTextView,
            "Expected the AI input to focus when it appears for a selected range, got \(String(describing: window.firstResponder))."
        )

        let inputFrameInWindow = inputTextView.convert(inputTextView.bounds, to: nil)
        let inputPoint = NSPoint(x: inputFrameInWindow.midX, y: inputFrameInWindow.midY)
        let hitPoint = hostingView.convert(inputPoint, from: nil)
        let hitView = hostingView.hitTest(hitPoint)
        XCTAssertTrue(
            hitView === inputTextView || hitView?.hasAncestor(inputTextView) == true,
            "Expected the full editor AI input point to hit the composer text view, got \(String(describing: hitView))."
        )

        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: inputPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        window.sendEvent(mouseDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(
            window.firstResponder === inputTextView,
            "Expected clicking the AI input in the full editor to focus it, got \(String(describing: window.firstResponder))."
        )

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: inputPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(inputTextView.string, "x")
    }

    func testFullEditorComposerDismissesAfterClearingInputAndCollapsingSelection() throws {
        var document = LineformDocument(text: "Select this sentence for AI.")
        let editor = EditorContainerView(
            document: Binding(
                get: { document },
                set: { document = $0 }
            ),
            initialIntelligenceRailEnabled: true
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 820, height: 620)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()

        let editorTextView = try XCTUnwrap(hostingView.descendants(ofType: LineformTextView.self).first)
        editorTextView.setSelectedRange(NSRange(location: 0, length: 6))
        editorTextView.delegate?.textViewDidChangeSelection?(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorTextView)
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hostingView.layoutSubtreeIfNeeded()

        let inputTextView = try XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        let inputFrameInWindow = inputTextView.convert(inputTextView.bounds, to: nil)
        let inputPoint = NSPoint(x: inputFrameInWindow.midX, y: inputFrameInWindow.midY)

        window.makeFirstResponder(inputTextView)
        try sendKey("a", keyCode: 0, at: inputPoint, in: window)
        try sendKey("b", keyCode: 11, at: inputPoint, in: window)
        try sendKey("c", keyCode: 8, at: inputPoint, in: window)
        XCTAssertEqual(inputTextView.string, "abc")

        inputTextView.setSelectedRange(NSRange(location: 0, length: 3))
        try sendDelete(at: inputPoint, in: window)
        XCTAssertEqual(inputTextView.string, "")

        editorTextView.setSelectedRange(NSRange(location: 15, length: 0))
        editorTextView.delegate?.textViewDidChangeSelection?(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorTextView)
        )
        window.makeFirstResponder(editorTextView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            hostingView.descendants(ofType: IntelligenceInstructionTextView.self).isEmpty,
            "The AI input should disappear once both the instruction and selected text are empty."
        )
    }

    func testFullEditorComposerAcceptsTypingAfterCollapsingSelectionWithExistingInstruction() throws {
        var document = LineformDocument(text: "Select this sentence for AI.")
        let editor = EditorContainerView(
            document: Binding(
                get: { document },
                set: { document = $0 }
            ),
            initialIntelligenceRailEnabled: true
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 820, height: 620)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()

        let editorTextView = try XCTUnwrap(hostingView.descendants(ofType: LineformTextView.self).first)
        editorTextView.setSelectedRange(NSRange(location: 0, length: 6))
        editorTextView.delegate?.textViewDidChangeSelection?(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorTextView)
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hostingView.layoutSubtreeIfNeeded()

        let inputTextView = try XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        let inputFrameInWindow = inputTextView.convert(inputTextView.bounds, to: nil)
        let inputPoint = NSPoint(x: inputFrameInWindow.midX, y: inputFrameInWindow.midY)

        window.makeFirstResponder(inputTextView)
        try sendKey("a", keyCode: 0, at: inputPoint, in: window)
        try sendKey("b", keyCode: 11, at: inputPoint, in: window)
        try sendKey("c", keyCode: 8, at: inputPoint, in: window)
        XCTAssertEqual(inputTextView.string, "abc")

        editorTextView.setSelectedRange(NSRange(location: 15, length: 0))
        editorTextView.delegate?.textViewDidChangeSelection?(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editorTextView)
        )
        window.makeFirstResponder(editorTextView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
        hostingView.layoutSubtreeIfNeeded()

        let liveInputTextView = try XCTUnwrap(
            hostingView.descendants(ofType: IntelligenceInstructionTextView.self).first,
            "The AI input should remain live while it contains an instruction."
        )
        XCTAssertTrue(liveInputTextView === inputTextView)
        XCTAssertTrue(liveInputTextView.window === window)
        let liveInputFrameInWindow = liveInputTextView.convert(liveInputTextView.bounds, to: nil)
        let liveInputPoint = NSPoint(x: liveInputFrameInWindow.midX, y: liveInputFrameInWindow.midY)
        XCTAssertTrue(
            EditorFloatingControlHitTestRegistry.contains(windowPoint: liveInputPoint, in: window),
            "The AI composer should keep its floating hit-test region registered after the editor selection collapses."
        )
        let liveHitPoint = hostingView.convert(liveInputPoint, from: nil)
        let liveHitView = hostingView.hitTest(liveHitPoint)
        XCTAssertNotNil(liveHitView)
        XCTAssertTrue(
            liveHitView === liveInputTextView || liveHitView?.hasAncestor(liveInputTextView) == true,
            "Expected the live AI input point to hit the composer text view, got \(String(describing: liveHitView))."
        )
        XCTAssertFalse(
            liveHitView is LineformTextView,
            "The AI input point should not hit the editor after the selection collapses; got \(String(describing: liveHitView))."
        )

        let inputClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: liveInputPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.sendEvent(inputClick)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(
            window.firstResponder === liveInputTextView,
            "Expected clicking back into the AI input with existing text to restore focus, got \(String(describing: window.firstResponder))."
        )

        try sendKey("z", keyCode: 6, at: liveInputPoint, in: window)
        XCTAssertEqual(liveInputTextView.string, "abcz")
    }

    func testInstructionComposerTextViewAcceptsTypingAboveEditorScrollView() throws {
        var instruction = ""
        let root = ZStack(alignment: .bottom) {
            TestEditorScrollSurface()
                .frame(width: 700, height: 520)

            IntelligenceInstructionComposer(
                instruction: Binding(
                    get: { instruction },
                    set: { instruction = $0 }
                ),
                isActionEnabled: true,
                onFocusChanged: { _ in },
                submitInstruction: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)
        }
        .frame(width: 700, height: 520)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)

        let window = KeyCapableTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(hostingView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        let textViewFrameInWindow = textView.convert(textView.bounds, to: nil)
        let windowPoint = NSPoint(x: textViewFrameInWindow.midX, y: textViewFrameInWindow.midY)
        let hitPoint = hostingView.convert(windowPoint, from: nil)
        let hitView = hostingView.hitTest(hitPoint)

        XCTAssertTrue(
            hitView === textView || hitView?.hasAncestor(textView) == true,
            "Expected the real click point to hit the AI input area, got \(String(describing: hitView))."
        )

        window.makeFirstResponder(textView)
        XCTAssertTrue(
            window.firstResponder === textView,
            "The AI input text view should become first responder before typing, got \(String(describing: window.firstResponder))."
        )

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(textView.string, "x")
        XCTAssertEqual(instruction, "x")
    }

    func testInstructionComposerDirectTextViewAcceptsTypingWithoutFieldEditor() throws {
        var instruction = ""
        let composerView = IntelligenceInstructionComposerNSView(
            instruction: "",
            isActionEnabled: false,
            textChanged: { instruction = $0 },
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )
        composerView.frame = NSRect(x: 0, y: 0, width: 560, height: 52)

        let window = KeyCapableTestWindow(
            contentRect: composerView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = composerView
        window.makeKeyAndOrderFront(nil)
        composerView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(composerView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        window.makeFirstResponder(textView)

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint(x: textView.frame.midX, y: textView.frame.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(textView.string, "x")
        XCTAssertEqual(instruction, "x")

        composerView.update(
            instruction: "",
            isActionEnabled: true,
            textChanged: { instruction = $0 },
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )

        XCTAssertEqual(textView.string, "x")
        XCTAssertEqual(instruction, "x")
    }

    func testInstructionComposerTextViewKeepsNativeClickEditingAfterRefocus() throws {
        var instruction = ""
        let composerView = IntelligenceInstructionComposerNSView(
            instruction: "frozen",
            isActionEnabled: true,
            textChanged: { instruction = $0 },
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )
        composerView.frame = NSRect(x: 0, y: 0, width: 560, height: 52)

        let window = KeyCapableTestWindow(
            contentRect: composerView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = composerView
        window.makeKeyAndOrderFront(nil)
        composerView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(composerView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        textView.string = ""
        instruction = ""
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === textView)

        let textFrame = textView.convert(textView.bounds, to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: textFrame.minX + 3, y: textFrame.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))

        textView.mouseDown(with: mouseDown)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange().location, 0)

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: mouseDown.locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(textView.string, "y")
        XCTAssertEqual(instruction, "y")
    }

    func testInstructionComposerTextViewAllowsNativeDoubleClickSelectionAfterRefocus() throws {
        let composerView = IntelligenceInstructionComposerNSView(
            instruction: "alpha beta",
            isActionEnabled: true,
            textChanged: { _ in },
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )
        composerView.frame = NSRect(x: 0, y: 0, width: 560, height: 52)

        let window = KeyCapableTestWindow(
            contentRect: composerView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = composerView
        window.makeKeyAndOrderFront(nil)
        composerView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let textView = try XCTUnwrap(composerView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === textView)

        let firstGlyphRect = try XCTUnwrap(textView.layoutManager?.boundingRect(
            forGlyphRange: NSRange(location: 1, length: 1),
            in: try XCTUnwrap(textView.textContainer)
        ))
        let doubleClickPointInTextView = NSPoint(
            x: textView.textContainerInset.width + firstGlyphRect.midX,
            y: textView.textContainerInset.height + firstGlyphRect.midY
        )
        let doubleClickPoint = textView.convert(doubleClickPointInTextView, to: nil)
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: doubleClickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 2,
            pressure: 0
        ))

        NSApp.sendEvent(doubleClick)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "alpha")
    }

    func testInstructionComposerKeepsLightThemeColorsInsideDarkWindowAppearance() throws {
        let composerView = IntelligenceInstructionComposerNSView(
            instruction: "",
            isActionEnabled: true,
            textChanged: { _ in },
            onFocusChanged: { _ in },
            submitInstruction: { _ in }
        )
        composerView.appearance = NSAppearance(named: .darkAqua)
        composerView.frame = NSRect(x: 0, y: 0, width: 560, height: 52)

        let window = KeyCapableTestWindow(
            contentRect: composerView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = composerView
        window.makeKeyAndOrderFront(nil)
        composerView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let textView = try XCTUnwrap(composerView.descendants(ofType: IntelligenceInstructionTextView.self).first)
        let textColor = try XCTUnwrap(textView.textColor?.usingColorSpace(.sRGB))
        let lightTextColor = try XCTUnwrap(NSColor.labelColor.usingColorSpace(.sRGB))

        XCTAssertEqual(textColor.redComponent, lightTextColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(textColor.greenComponent, lightTextColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(textColor.blueComponent, lightTextColor.blueComponent, accuracy: 0.01)
    }

    func testTextViewDoesNotForcePointingHandForPassiveFloatingComposerRegion() throws {
        let textView = LineformTextView()
        textView.string = "Selected text sits behind the AI composer."
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
            rect: NSRect(x: 20, y: 20, width: 320, height: 52)
        )
        defer {
            EditorFloatingControlHitTestRegistry.remove(owner: owner)
        }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 80, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        NSCursor.iBeam.set()
        textView.cursorUpdate(with: event)

        XCTAssertEqual(NSCursor.current, .iBeam)
    }

    func testInstructionSubmitButtonShowsHoverAndOwnsPointingCursor() throws {
        var actionCount = 0
        let buttonView = IntelligenceInstructionSubmitButtonNSView(
            isActionEnabled: true,
            performAction: { actionCount += 1 }
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: IntelligenceInstructionComposerPresentation.sendButtonSize,
                height: IntelligenceInstructionComposerPresentation.sendButtonSize
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = buttonView
        buttonView.frame = window.contentView?.bounds ?? NSRect(
            x: 0,
            y: 0,
            width: IntelligenceInstructionComposerPresentation.sendButtonSize,
            height: IntelligenceInstructionComposerPresentation.sendButtonSize
        )
        buttonView.layoutSubtreeIfNeeded()

        XCTAssertEqual(buttonView.intrinsicContentSize.width, IntelligenceInstructionComposerPresentation.sendButtonSize)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.sendButtonUsesFilledAccentBackground)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.sendButtonUsesWhiteSymbol)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: buttonView.bounds.midX, y: buttonView.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))

        XCTAssertTrue(buttonView.hitTest(NSPoint(x: buttonView.bounds.midX, y: buttonView.bounds.midY)) === buttonView)

        buttonView.mouseEntered(with: event)
        XCTAssertTrue(buttonView.isHovering)
        XCTAssertEqual(NSCursor.current, .pointingHand)

        buttonView.mouseDown(with: event)
        XCTAssertEqual(actionCount, 1)

        buttonView.mouseExited(with: event)
        XCTAssertFalse(buttonView.isHovering)
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

    func testTextViewPreservesCurrentCursorInsidePassiveFloatingControlRegion() throws {
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

        XCTAssertEqual(NSCursor.current, .iBeam)
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

    func testDisabledActionRailEventViewDoesNotOwnCursorOrClickAction() throws {
        var hoverStates = [Bool]()
        var actionCount = 0
        let eventView = ActionRailButtonEventNSView(
            isEnabled: false,
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
        let windowPoint = eventView.convert(NSPoint(x: 20, y: 20), to: nil)

        XCTAssertNil(eventView.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertFalse(EditorFloatingControlHitTestRegistry.contains(windowPoint: windowPoint, in: window))

        NSCursor.iBeam.set()
        eventView.mouseEntered(with: event)
        eventView.cursorUpdate(with: event)
        eventView.mouseDown(with: event)

        XCTAssertEqual(NSCursor.current, .iBeam)
        XCTAssertTrue(hoverStates.isEmpty)
        XCTAssertEqual(actionCount, 0)
    }

    private func sendKey(_ character: String, keyCode: UInt16, at point: NSPoint, in window: NSWindow) throws {
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func sendDelete(at point: NSPoint, in window: NSWindow) throws {
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(NSDeleteCharacter)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSDeleteCharacter)!),
            isARepeat: false,
            keyCode: 51
        ))
        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
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

private final class KeyCapableTestWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
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
    func makeNSView(context: Context) -> LineformEditorScrollView {
        let scrollView = LineformEditorScrollView()
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

    func updateNSView(_ nsView: LineformEditorScrollView, context: Context) {
    }
}
