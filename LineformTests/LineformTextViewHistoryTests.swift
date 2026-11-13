import XCTest
import AppKit
@testable import Lineform

/// History mode in the text view, without a window (default test plan: no NSWindow).
@MainActor
final class LineformTextViewHistoryTests: XCTestCase {
    private let sample = "Alpha beta gamma. Delta epsilon."

    private func makeTextView() -> LineformTextView {
        let textView = LineformTextView()
        textView.string = sample
        return textView
    }

    private func passage(_ range: NSRange, level: HistoryLevel = .sentence) -> LocatedPassage {
        LocatedPassage(id: UUID(), level: level, range: range, rootID: UUID())
    }

    private func display(_ passages: [LocatedPassage], selected: UUID? = nil, dots: HistoryDots? = nil) -> HistoryModeDisplay {
        HistoryModeDisplay(passages: passages, selectedID: selected, hoveredID: nil, dots: dots)
    }

    private static func contextMenuEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    // MARK: - Context menu

    func testContextMenuOffersAddToHistoryOnlyWhenAllowed() throws {
        defer { LineformTextFormatMenuState.shared.setTextFormat(.markdown) }
        for format in [LineformTextFormat.markdown, .plainText] {
            LineformTextFormatMenuState.shared.setTextFormat(format)
            let textView = makeTextView()
            let selection = NSRange(location: 6, length: 4)
            textView.setSelectedRange(selection)
            var asked: [NSRange] = []
            var commands: [HistoryTextCommand] = []
            textView.historyCommandHandler = { commands.append($0) }

            textView.historyCanAddHandler = { asked.append($0); return true }
            let menu = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent()))
            XCTAssertEqual(menu.identifier, MainMenuIconDecorator.excludedMenuIdentifier)
            let item = try XCTUnwrap(menu.items.first { $0.title == LineformTextContextMenuPresentation.addToHistoryTitle }, "\(format)")
            XCTAssertTrue(item.target === textView)
            XCTAssertEqual(asked, [selection])
            _ = textView.perform(try XCTUnwrap(item.action), with: item)
            XCTAssertEqual(commands, [.add(selection)])

            textView.historyCanAddHandler = { _ in false }
            let refused = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent())).items.map(\.title)
            XCTAssertFalse(refused.contains(LineformTextContextMenuPresentation.addToHistoryTitle))

            asked = []
            textView.historyCanAddHandler = { asked.append($0); return true }
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            let empty = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent())).items.map(\.title)
            XCTAssertFalse(empty.contains(LineformTextContextMenuPresentation.addToHistoryTitle))
            XCTAssertEqual(asked, [], "an empty selection must not run the O(document) check")
        }
    }

    func testContextMenuWithoutHandlerHasNoHistoryItem() throws {
        let textView = makeTextView()
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let titles = try XCTUnwrap(textView.menu(for: Self.contextMenuEvent())).items.map(\.title)
        XCTAssertFalse(titles.contains(LineformTextContextMenuPresentation.addToHistoryTitle))
    }

    // MARK: - Keys

    func testArrowKeysStepVersionsInHistoryMode() {
        let textView = makeTextView()
        let first = passage(NSRange(location: 0, length: 17))
        textView.historyDisplay = display([first], selected: first.id, dots: HistoryDots(count: 3, current: 0))
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        textView.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))

        XCTAssertEqual(commands, [.step(1), .step(-1), .moveSelection(1), .moveSelection(-1)])
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0), "History mode never moves the caret")
    }

    func testArrowKeysMoveCaretInNormalMode() {
        let textView = makeTextView()
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(commands, [])
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testEscapeExitsHistoryMode() {
        let textView = makeTextView()
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 5))])
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(commands, [.exit])
    }

    func testTypingInHistoryModeExitsThenTypes() {
        let textView = makeTextView()
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 5))])
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { command in
            commands.append(command)
            // The controller leaves History mode synchronously.
            if command == .typedWhileInHistoryMode { textView.historyDisplay = nil }
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(commands, [.typedWhileInHistoryMode], "only the first keystroke leaves the mode")
        XCTAssertTrue(textView.string.hasPrefix("abAlpha"))
        XCTAssertNil(textView.historyDisplay)
    }

    /// ⌘Z after a whole-text formatting command leaves the WHOLE document selected. Carried into
    /// History mode, the first keystroke (exit, then type) replaced the entire document.
    func testEnteringHistoryModeCollapsesSelection() {
        let textView = makeTextView()
        let all = NSRange(location: 0, length: (sample as NSString).length)
        textView.setSelectedRange(all)

        textView.historyDisplay = display([passage(NSRange(location: 0, length: 17))])
        XCTAssertEqual(textView.selectedRange().length, 0, "History mode never holds a selection")

        textView.selectAll(nil)
        XCTAssertEqual(textView.selectedRange().length, 0, "and stays collapsed for the whole mode")
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        XCTAssertEqual(textView.selectedRange().length, 0)

        textView.historyDisplay = nil
        textView.setSelectedRange(all)
        XCTAssertEqual(textView.selectedRange(), all, "normal writing selects as usual")
    }

    func testTypingAfterSelectingPassageInsertsAtPassageEnd() {
        let textView = makeTextView()
        textView.selectAll(nil)
        let first = passage(NSRange(location: 0, length: 17))
        let second = passage(NSRange(location: 18, length: 14))
        textView.historyCommandHandler = { command in
            if command == .typedWhileInHistoryMode { textView.historyDisplay = nil }
        }
        textView.historyDisplay = display([first, second])
        textView.historyDisplay = display([first, second], selected: first.id)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 17, length: 0), "the hidden caret sits at the passage end")

        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertNil(textView.historyDisplay)
        XCTAssertEqual(textView.string, "Alpha beta gamma.X Delta epsilon.", "nothing else is replaced")
    }

    /// Defence in depth: even if a selection reached History mode, typing never replaces it.
    func testTypingInHistoryModeNeverReplacesASelection() {
        let textView = makeTextView()
        let all = NSRange(location: 0, length: (sample as NSString).length)
        textView.setSelectedRange(all)
        // Bypass the entry collapse to model a selection that survived anyway.
        textView.historyDisplayStorage = display([passage(NSRange(location: 0, length: 17))])
        textView.historyCommandHandler = { command in
            if command == .typedWhileInHistoryMode { textView.historyDisplay = nil }
        }
        XCTAssertEqual(textView.selectedRange(), all)

        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(textView.string, sample, "a stale selection is never replaced")
        XCTAssertNil(textView.historyDisplay)
    }

    /// Commands that replace a range on their own (formatting, Find & Replace, spelling) leave
    /// History mode AND apply — only a stale selection is refused.
    func testBoldInHistoryModeLeavesModeAndApplies() {
        let textView = makeTextView()
        let first = passage(NSRange(location: 0, length: 17))
        textView.historyCommandHandler = { command in
            if command == .typedWhileInHistoryMode { textView.historyDisplay = nil }
        }
        textView.historyDisplay = display([first], selected: first.id)

        textView.toggleBoldMarkdown(nil)

        XCTAssertNil(textView.historyDisplay)
        XCTAssertNotEqual(textView.string, sample, "the command applied")
        XCTAssertTrue(textView.string.contains("**"))
        XCTAssertTrue(textView.string.hasPrefix("Alpha beta gamma."), "nothing before the caret was replaced")
    }

    func testReplaceInHistoryModeLeavesModeAndApplies() {
        let textView = makeTextView()
        textView.historyCommandHandler = { command in
            if command == .typedWhileInHistoryMode { textView.historyDisplay = nil }
        }
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 17))])
        let replaced = "Alpha beta gamma. Delta EPSILON."

        textView.applyExternalReplacement(MarkdownEdit(text: replaced, selectedRange: NSRange(location: 0, length: 0)))

        XCTAssertNil(textView.historyDisplay)
        XCTAssertEqual(textView.string, replaced)
    }

    func testHistoryModeHidesTheInsertionPoint() {
        let textView = makeTextView()
        XCTAssertFalse(textView.hidesInsertionPointForHistory)
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 5))])
        XCTAssertTrue(textView.hidesInsertionPointForHistory)
        XCTAssertFalse(textView.shouldDrawInsertionPoint)
        textView.historyDisplay = nil
        XCTAssertFalse(textView.hidesInsertionPointForHistory)
    }

    // MARK: - Dot placement (pure)

    /// 17pt SF Pro at 1.5 line height: the dots sit centred in the gap between the descender and
    /// the next line's ascender, at least 2pt from each.
    func testDotsCentreInTheInterLineGap() throws {
        let top = try XCTUnwrap(HistoryDotPlacement.belowTop(
            baselineY: 100, descender: 4, nextLineTopY: 120, diameter: 5))
        XCTAssertEqual(top, 104 + (16 - 5) / 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(top - 104, 2)
        XCTAssertGreaterThanOrEqual(120 - (top + 5), 2)

        let tall = try XCTUnwrap(HistoryDotPlacement.belowTop(
            baselineY: 100, descender: 4, nextLineTopY: 140, diameter: 5))
        XCTAssertEqual(tall, 104 + HistoryDotPlacement.maximumClearanceAbove, accuracy: 0.001,
                       "a paragraph gap never pushes the dots away from their line")
    }

    /// Real layout at the default profile: the dots sit under the first line with at least 2pt
    /// from its descender and from the next line's ascender.
    func testDefaultProfileDotsClearBothLines() throws {
        let textView = LineformTextView()
        textView.applyDefaultTypography()
        // A line separator: a second line in the SAME paragraph (no paragraph spacing).
        textView.string = "Hello world again.\u{2028}Bold lines below."
        let font = try XCTUnwrap(textView.font)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let placement = try XCTUnwrap(textView.historyDotsPlacement(for: NSRange(location: 0, length: 18)))
        XCTAssertTrue(placement.isBelow, "a 1.5 line height has room between the lines")
        var firstLine = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstLine)
        let baseline = textView.textContainerOrigin.y + lineRect.minY + layoutManager.location(forGlyphAt: 0).y
        let nextGlyph = NSMaxRange(firstLine)
        let nextBaseline = textView.textContainerOrigin.y
            + layoutManager.lineFragmentRect(forGlyphAt: nextGlyph, effectiveRange: nil).minY
            + layoutManager.location(forGlyphAt: nextGlyph).y
        XCTAssertGreaterThanOrEqual(placement.origin.y - (baseline - font.descender), 2 - 0.001)
        XCTAssertGreaterThanOrEqual((nextBaseline - font.ascender) - (placement.origin.y + LineformTextView.historyDotDiameter), 2 - 0.001)
    }

    /// Trailing dots only where they cannot cover text: the passage's last glyph must end its
    /// line and the row must fit before the container edge. Otherwise below, best effort.
    func testTrailingDotsNeverOverlapFollowingTextOrTheEdge() {
        XCTAssertEqual(HistoryDotPlacement.choose(belowTop: 104, lastGlyphEndsLine: false, trailingRowMaxX: 50, containerMaxX: 100), .below)
        XCTAssertEqual(HistoryDotPlacement.choose(belowTop: nil, lastGlyphEndsLine: true, trailingRowMaxX: 99, containerMaxX: 100), .trailing)
        XCTAssertEqual(HistoryDotPlacement.choose(belowTop: nil, lastGlyphEndsLine: false, trailingRowMaxX: 50, containerMaxX: 100), .below,
                       "a passage ending mid-line has text after it")
        XCTAssertEqual(HistoryDotPlacement.choose(belowTop: nil, lastGlyphEndsLine: true, trailingRowMaxX: 101, containerMaxX: 100), .below,
                       "never past the container edge")
        // Best-effort below: centred in whatever gap exists, never above the descender.
        XCTAssertEqual(HistoryDotPlacement.bestEffortBelowTop(baselineY: 100, descender: 4, nextLineTopY: 111, diameter: 5), 105, accuracy: 0.001)
        XCTAssertEqual(HistoryDotPlacement.bestEffortBelowTop(baselineY: 100, descender: 4, nextLineTopY: 106, diameter: 5), 104, accuracy: 0.001)
    }

    func testTightLineHeightMovesDotsToTheLineEnd() {
        XCTAssertNil(HistoryDotPlacement.belowTop(baselineY: 100, descender: 4, nextLineTopY: 112.9, diameter: 5),
                     "a gap under dot + 4pt has no room")
        XCTAssertNotNil(HistoryDotPlacement.belowTop(baselineY: 100, descender: 4, nextLineTopY: 113, diameter: 5))
        // Centred on the x-height: baseline 100, x-height 9 → centre 95.5.
        XCTAssertEqual(HistoryDotPlacement.trailingTop(baselineY: 100, xHeight: 9, diameter: 5), 93, accuracy: 0.001)
    }

    func testHistoryEditsAreNotMistakenForTyping() {
        let textView = makeTextView()
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 5))])
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }

        textView.performHistoryEdit {
            let range = NSRange(location: 0, length: 5)
            XCTAssertTrue(textView.shouldChangeText(in: range, replacementString: "Omega"))
            textView.textStorage?.replaceCharacters(in: range, with: "Omega")
            textView.didChangeText()
        }

        XCTAssertEqual(commands, [])
        XCTAssertTrue(textView.string.hasPrefix("Omega beta"))
    }

    func testTypingInNormalModeSendsNothing() {
        let textView = makeTextView()
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commands, [])
    }

    func testAttributeOnlyChangeDoesNotExitHistoryMode() {
        let textView = makeTextView()
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 5))])
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        var reported: [NSRange] = []
        textView.historyUserEditHandler = { range, _ in reported.append(range) }

        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: 0, length: 5), replacementString: nil))

        XCTAssertEqual(commands, [])
        XCTAssertEqual(reported, [], "an attribute change is not a text edit")
        XCTAssertNotNil(textView.historyDisplay)
    }

    func testShiftArrowDoesNothingInHistoryMode() {
        let textView = makeTextView()
        let first = passage(NSRange(location: 0, length: 17))
        textView.historyDisplay = display([first], selected: first.id)
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        for selector in [
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:)),
            #selector(NSResponder.moveWordRight(_:)),
            #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
            #selector(NSResponder.moveToEndOfLine(_:)),
            #selector(NSResponder.moveToBeginningOfDocument(_:)),
            #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)),
            #selector(NSResponder.pageDown(_:)),
        ] {
            textView.doCommand(by: selector)
        }

        XCTAssertEqual(commands, [])
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0), "History mode never moves the caret")
    }

    // MARK: - Reporting user edits

    func testUserTypingIsReportedToEngine() {
        let textView = makeTextView()
        var reported: [(NSRange, String)] = []
        textView.historyUserEditHandler = { reported.append(($0, $1)) }

        textView.setSelectedRange(NSRange(location: 6, length: 4))
        textView.insertText("BETA", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.deleteBackward(nil)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.deleteBackward(nil)

        XCTAssertEqual(reported.map(\.0), [
            NSRange(location: 6, length: 4),
            NSRange(location: 0, length: 0),
            NSRange(location: 0, length: 1),
            NSRange(location: 0, length: 1),
        ])
        XCTAssertEqual(reported.map(\.1), ["BETA", "x", "", ""])
        XCTAssertEqual(textView.string, "lpha BETA gamma. Delta epsilon.")
    }

    func testUndoIsReportedAsAUserEdit() {
        final class Vendor: NSObject, NSTextViewDelegate {
            let manager: UndoManager
            override init() { manager = UndoManager(); super.init() }
            func undoManager(for view: NSTextView) -> UndoManager? { manager }
        }
        let vendor = Vendor()
        let textView = makeTextView()
        textView.delegate = vendor
        var reported: [(NSRange, String)] = []
        textView.historyUserEditHandler = { reported.append(($0, $1)) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        vendor.manager.undo()

        XCTAssertEqual(textView.string, sample)
        XCTAssertEqual(reported.map(\.0), [NSRange(location: 0, length: 0), NSRange(location: 0, length: 1)])
        XCTAssertEqual(reported.map(\.1), ["x", ""])
    }

    func testEngineEditsAreNotReportedTwice() {
        let textView = makeTextView()
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 5))])
        var reported: [NSRange] = []
        textView.historyUserEditHandler = { range, _ in reported.append(range) }
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }

        textView.applyHistoryEdit(HistoryEdit(range: NSRange(location: 0, length: 5), replacement: "Omega"))

        XCTAssertEqual(reported, [], "the engine already moved its live ranges for its own edit")
        XCTAssertEqual(commands, [])
        XCTAssertTrue(textView.string.hasPrefix("Omega beta"))
    }

    /// Formatting and Find & Replace replace the whole text. History must hear the edit as its
    /// minimal changed span — never as one edit across the document (which drops every passage)
    /// and never as "forget everything" (which forces a literal re-find).
    func testWholeTextReplacementReportsItsMinimalSpan() {
        let textView = makeTextView()
        var reported: [(NSRange, String)] = []
        textView.historyUserEditHandler = { reported.append(($0, $1)) }

        textView.applyExternalReplacement(MarkdownEdit(text: "Alpha beta gamma. Delta EPSILON.", selectedRange: NSRange(location: 0, length: 0)))

        XCTAssertEqual(reported.map(\.0), [NSRange(location: 24, length: 7)])
        XCTAssertEqual(reported.map(\.1), ["EPSILON"])
        XCTAssertEqual(textView.string, "Alpha beta gamma. Delta EPSILON.")
    }

    /// NSTextView undoes a whole-text replacement as ONE document-spanning `shouldChangeText`.
    func testUndoOfWholeTextReplacementReportsItsMinimalSpan() {
        final class Vendor: NSObject, NSTextViewDelegate {
            let manager: UndoManager
            override init() { manager = UndoManager(); manager.groupsByEvent = false; super.init() }
            func undoManager(for view: NSTextView) -> UndoManager? { manager }
        }
        let vendor = Vendor()
        let textView = makeTextView()
        textView.delegate = vendor
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        vendor.manager.beginUndoGrouping()
        textView.toggleBoldMarkdown(nil)
        vendor.manager.endUndoGrouping()
        XCTAssertEqual(textView.string, "Alpha **beta** gamma. Delta epsilon.")

        var reported: [(NSRange, String)] = []
        textView.historyUserEditHandler = { reported.append(($0, $1)) }
        vendor.manager.undo()

        XCTAssertEqual(textView.string, sample)
        XCTAssertEqual(reported.count, 1)
        let span = reported.first?.0 ?? NSRange(location: 0, length: 0)
        XCTAssertLessThanOrEqual(span.length, "**beta**".count, "only the changed span, never the whole document")
        XCTAssertGreaterThanOrEqual(span.location, 6)
    }

    /// Reports a whole-text replacement through the text view into a real engine and returns
    /// where the passage is located afterwards (nil when it was dropped).
    private func locateAfterWholeTextReplacement(from text: String, passage target: NSRange,
                                                 to newText: String) throws -> NSRange? {
        let textView = LineformTextView()
        textView.string = text
        var engine = DocumentHistoryEngine(history: DocumentHistory(passages: []), now: Date.init)
        let id = try XCTUnwrap(engine.add(target, author: .you, in: text))
        _ = engine.locateAll(in: text)
        textView.historyUserEditHandler = { engine.applyEdit($0, replacement: $1) }

        textView.applyExternalReplacement(MarkdownEdit(text: newText, selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertEqual(textView.string, newText)
        return engine.locateAll(in: newText).first { $0.id == id }?.range
    }

    /// Deleting one copy of repeated text can sit at several offsets. The prefix-first placement
    /// ({22,11}) would leave the passage on {11,10} — now the ORIGINAL THIRD sentence, identical
    /// text, so verification passed and step rewrote the wrong sentence. Dropped is fine;
    /// retargeted never is.
    func testAmbiguousDeletionInRepeatedTextNeverRetargetsPassage() throws {
        let text = "Keep this. Keep this. Keep this. End."
        let located = try locateAfterWholeTextReplacement(
            from: text, passage: NSRange(location: 11, length: 10), to: String(text.dropFirst(11)))
        if let located {
            XCTAssertEqual(located, NSRange(location: 0, length: 10), "the passage may only stay on its own sentence")
        }
    }

    /// The insertion mirror: a copy inserted in front trims prefix-first to {16,0}, which left the
    /// passage on the newly inserted copy.
    func testAmbiguousInsertionInRepeatedTextNeverRetargetsPassage() throws {
        let located = try locateAfterWholeTextReplacement(
            from: "Go now. Go now. Fin.", passage: NSRange(location: 0, length: 7),
            to: "Go now. Go now. Go now. Fin.")
        if let located {
            XCTAssertEqual(located, NSRange(location: 8, length: 7), "the passage may only stay on its own sentence")
        }
    }

    func testNoOpReplacementReportsNothing() {
        let textView = makeTextView()
        var reported: [NSRange] = []
        textView.historyUserEditHandler = { range, _ in reported.append(range) }
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        textView.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(reported, [])
        XCTAssertEqual(textView.string, sample)
    }

    // MARK: - Drawing state

    func testUnchangedTextRecedesAndPassagesKeepFullInk() throws {
        let textView = makeTextView()
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let changed = passage(NSRange(location: 6, length: 4))
        textView.historyDisplay = display([changed])

        XCTAssertNotNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 7, effectiveRange: nil))
        XCTAssertNotNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 12, effectiveRange: nil))
        let stored = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(
            stored,
            HistoryPalette.recededInk(for: Theme.theme(for: textView.appliedReadingProfile)),
            "receded ink is a temporary attribute, never written to the text storage"
        )
    }

    func testClearingDisplayRemovesTemporaryAttributes() throws {
        let textView = makeTextView()
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        textView.historyDisplay = display([passage(NSRange(location: 6, length: 4))])
        XCTAssertNotNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))

        textView.historyDisplay = nil

        let length = (textView.string as NSString).length
        for index in 0..<length {
            XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil), "index \(index)")
        }
    }

    func testHistoryGapsSubtractPassagesIncludingNestedAndOverlapping() {
        let gaps = LineformTextView.historyGaps(
            in: NSRange(location: 0, length: 20),
            excluding: [NSRange(location: 2, length: 6), NSRange(location: 4, length: 2), NSRange(location: 15, length: 10)]
        )
        XCTAssertEqual(gaps, [NSRange(location: 0, length: 2), NSRange(location: 8, length: 7)])
    }

    func testInnermostPassageWinsAClick() {
        let paragraph = passage(NSRange(location: 0, length: 32), level: .paragraph)
        let sentence = passage(NSRange(location: 0, length: 17), level: .sentence)
        let word = passage(NSRange(location: 6, length: 4), level: .word)
        let model = display([paragraph, sentence, word])
        XCTAssertEqual(model.innermostPassage(containing: 7)?.id, word.id)
        XCTAssertEqual(model.innermostPassage(containing: 2)?.id, sentence.id)
        XCTAssertEqual(model.innermostPassage(containing: 20)?.id, paragraph.id)
        XCTAssertNil(display([word]).innermostPassage(containing: 20))
    }

    func testViewKeepsItsHoverAcrossControllerUpdates() {
        let textView = makeTextView()
        let first = passage(NSRange(location: 0, length: 5))
        let second = passage(NSRange(location: 6, length: 4))
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        textView.historyDisplay = display([first, second])

        textView.setHistoryHoveredID(second.id)
        XCTAssertEqual(textView.historyDisplay?.hoveredID, second.id)
        textView.historyDisplay = display([first, second], selected: first.id)
        XCTAssertEqual(textView.historyDisplay?.hoveredID, second.id)
        textView.historyDisplay = display([first], selected: first.id)
        XCTAssertNil(textView.historyDisplay?.hoveredID, "a hover on a passage that is gone is dropped")
        XCTAssertEqual(commands, [], "hover never calls the handler")
    }

    func testAnnouncementNamesLevelAndVersion() {
        XCTAssertEqual(
            HistoryModeAnnouncement.text(level: .sentence, dots: HistoryDots(count: 4, current: 1)),
            String(localized: "\(HistoryLevel.sentence.title), version \(2) of \(4)")
        )
        XCTAssertEqual(HistoryModeAnnouncement.text(level: .word, dots: nil), HistoryLevel.word.title)
    }
    // MARK: - Accessibility actions (final review I3)

    /// Clicking a passage and the arrow keys are the only ways to work History mode; VoiceOver,
    /// keyboard-only and Switch Control users get the same commands from the actions rotor.
    func testHistoryModeOffersAccessibilityCustomActionsOnlyWhileActive() throws {
        let textView = makeTextView()
        var commands: [HistoryTextCommand] = []
        textView.historyCommandHandler = { commands.append($0) }
        let names = HistoryModeAccessibilityAction.allCases.map(\.name)

        let normal = (textView.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertTrue(Set(normal).isDisjoint(with: names), "normal writing offers no History actions")

        textView.historyDisplay = display([passage(NSRange(location: 0, length: 17))])
        let actions = textView.accessibilityCustomActions() ?? []
        XCTAssertEqual(actions.map(\.name).filter(names.contains), [
            String(localized: "Select Next Passage"),
            String(localized: "Select Previous Passage"),
            String(localized: "Previous Version"),
            String(localized: "Next Version"),
            String(localized: "Exit History"),
        ])
        for action in actions where names.contains(action.name) {
            XCTAssertTrue(try XCTUnwrap(action.handler)())
        }
        XCTAssertEqual(commands, [.moveSelection(1), .moveSelection(-1), .step(-1), .step(1), .exit])

        textView.historyDisplay = nil
        XCTAssertTrue(Set((textView.accessibilityCustomActions() ?? []).map(\.name)).isDisjoint(with: names))
    }
}
