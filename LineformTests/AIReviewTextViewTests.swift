import XCTest
@testable import Lineform

/// The review overlay's text view, without a window (window-hosted checks belong in
/// LineformHosted; the controller does the hands-on pass).
@MainActor
final class AIReviewTextViewTests: XCTestCase {
    private let text = "A very big day.\n\nThe good night."
    private let profile = ReadingProfile.original

    private func composition() -> (AIReviewComposition, AIReviewSession) {
        let ns = text as NSString
        let changes = [
            AIChange(id: 0, range: ns.range(of: "very "), original: "very ", replacement: ""),
            AIChange(id: 1, range: ns.range(of: "big"), original: "big", replacement: "large"),
            AIChange(id: 2, range: ns.range(of: "good"), original: "good", replacement: "fine"),
        ]
        let session = AIReviewSession(action: .trim, changes: changes,
                                      selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        return (AIReviewComposition.build(text: text, session: session), session)
    }

    private func presented(currentID: Int? = 0, hasDecided: Bool = false) -> (AIReviewTextView, AIReviewComposition, [AIReviewCommand]) {
        let view = AIReviewTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        let (composition, _) = composition()
        view.present(composition, currentID: currentID, profile: profile, hasDecided: hasDecided)
        return (view, composition, [])
    }

    func testIsReadOnlyWithNoMenuSpellingOrUndo() throws {
        let (view, _, _) = presented()
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.isSelectable)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        if #available(macOS 15.0, *) {
            XCTAssertEqual(view.writingToolsBehavior, .none)
        }
        XCTAssertTrue(view.acceptsFirstResponder, "the overlay takes the keys during review")
        let manager = try XCTUnwrap(view.undoManager)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        XCTAssertNil(view.menu(for: event))
    }

    func testKeysBecomeReviewCommands() {
        let (view, _, _) = presented()
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commands, [.next, .previous, .acceptCurrent, .end, .typed("x")])
        XCTAssertEqual(view.string, composition().0.string, "typing never lands in the overlay")
    }

    /// Real key events, not only selectors: a non-editable, non-selectable NSTextView still runs
    /// them through key binding (`interpretKeyEvents`) into `doCommand(by:)` / `insertText`.
    func testKeyEventsReachTheCommandPath() throws {
        let (view, _, _) = presented()
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124))
        view.keyDown(with: try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123))
        view.keyDown(with: try key("\r", 36))
        view.keyDown(with: try key("\u{1b}", 53))
        view.keyDown(with: try key("q", 12))
        XCTAssertEqual(commands, [.next, .previous, .acceptCurrent, .end, .typed("q")])
    }

    func testPresentDimsRemovedTextAndDrawsPills() throws {
        let (view, composition, _) = presented(currentID: 1)
        let theme = Theme.theme(for: profile)
        XCTAssertEqual(view.string, composition.string)
        let storage = try XCTUnwrap(view.textStorage)
        let layoutManager = try XCTUnwrap(view.layoutManager)
        for (id, index) in composition.pillIndices {
            let attachment = try XCTUnwrap(storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)
            let cell = try XCTUnwrap(attachment.attachmentCell as? AIReviewPillCell)
            XCTAssertEqual(cell.changeID, id)
            XCTAssertEqual(cell.isCurrent, id == 1)
            XCTAssertEqual(cell.ink, id == 1 ? theme.textColor : HistoryPalette.recededInk(for: theme))
        }
        for (_, range) in composition.removedRanges {
            let ink = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil)
            XCTAssertEqual(ink as? NSColor, HistoryPalette.recededInk(for: theme))
        }
        let replacement = (composition.string as NSString).range(of: "large")
        XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: replacement.location, effectiveRange: nil),
                     "insertions keep the normal ink")
    }

    func testClicksMapToCommands() throws {
        let (view, composition, _) = presented()
        let layoutManager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layoutManager.ensureLayout(for: container)
        let origin = view.textContainerOrigin

        let pill = try XCTUnwrap(composition.pillIndices[1])
        var frame = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: pill, length: 1), actualCharacterRange: nil), in: container)
        frame = frame.offsetBy(dx: origin.x, dy: origin.y)
        let outline = AIReviewPillCell.outlineRect(in: frame)
        XCTAssertEqual(view.command(at: NSPoint(x: outline.minX + 6, y: frame.midY)), .accept(1))
        XCTAssertEqual(view.command(at: NSPoint(x: outline.maxX - 6, y: frame.midY)), .reject(1))

        let removed = try XCTUnwrap(composition.removedRanges[2])
        var word = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: removed, actualCharacterRange: nil), in: container)
        word = word.offsetBy(dx: origin.x, dy: origin.y)
        XCTAssertEqual(view.command(at: NSPoint(x: word.midX, y: word.midY)), .toggleKeep(2))

        let plain = (composition.string as NSString).range(of: "night")
        var plainRect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: plain, actualCharacterRange: nil), in: container)
        plainRect = plainRect.offsetBy(dx: origin.x, dy: origin.y)
        XCTAssertNil(view.command(at: NSPoint(x: plainRect.midX, y: plainRect.midY)))
    }

    func testCustomActionsFollowDecisions() throws {
        let (fresh, _, _) = presented(hasDecided: false)
        let freshNames = (fresh.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertEqual(freshNames, AIReviewTextView.accessibilityActionTitles(hasDecided: false))
        XCTAssertTrue(freshNames.contains("Accept All"))
        XCTAssertTrue(freshNames.contains("Reject All"))
        XCTAssertTrue(freshNames.contains("Keep Removed Text"))

        let (decided, _, _) = presented(hasDecided: true)
        var commands: [AIReviewCommand] = []
        decided.commandHandler = { commands.append($0) }
        let actions = decided.accessibilityCustomActions() ?? []
        XCTAssertTrue(actions.map(\.name).contains("Accept Remaining"))
        XCTAssertTrue(actions.map(\.name).contains("Reject Remaining"))
        for action in actions { _ = action.handler?() }
        XCTAssertEqual(commands, [.accept(0), .reject(0), .toggleKeep(0), .next, .previous,
                                  .acceptRemaining, .rejectRemaining, .end])
    }

    func testKeepIsOfferedOnlyWhenTheCurrentChangeRemovesText() {
        let (view, _, _) = presented(currentID: nil)
        XCTAssertFalse((view.accessibilityCustomActions() ?? []).map(\.name).contains("Accept Change"),
                       "no current change, no per-change actions")
    }

    func testMatchGeometryCopiesTheEditorsLayout() throws {
        let editor = LineformTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        editor.applyTypography(profile)
        editor.string = text
        let overlay = AIReviewTextView.make()
        overlay.matchGeometry(of: editor)
        XCTAssertEqual(overlay.textContainerInset, editor.textContainerInset)
        XCTAssertEqual(overlay.textContainer?.lineFragmentPadding, editor.textContainer?.lineFragmentPadding)
        XCTAssertEqual(overlay.textContainer?.containerSize.width, editor.textContainer?.containerSize.width)
        XCTAssertEqual(overlay.frame.width, editor.frame.width)
        XCTAssertEqual(overlay.backgroundColor, editor.backgroundColor)
        XCTAssertEqual(overlay.defaultParagraphStyle, editor.defaultParagraphStyle)
    }
}
