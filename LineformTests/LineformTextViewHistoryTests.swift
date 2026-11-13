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

    private func display(_ passages: [LocatedPassage], selected: UUID? = nil, counter: HistoryCounter? = nil) -> HistoryModeDisplay {
        HistoryModeDisplay(passages: passages, selectedID: selected, hoveredID: nil, counter: counter)
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
        textView.historyDisplay = display([first], selected: first.id, counter: HistoryCounter(count: 3, current: 0))
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

    // MARK: - Counter

    func testCounterTextIsCurrentOverTotal() {
        XCTAssertEqual(HistoryCounter(count: 3, current: 1).text, "2/3")
        XCTAssertEqual(HistoryCounter(count: 12, current: 9).text, "10/12")
    }

    /// The counter starts `leadingGap` after the last glyph and ends `trailingGap` before the
    /// reserved space runs out, so it can never reach the next glyph.
    func testCounterFitsInsideItsReservedSpace() {
        for text in ["1/2", "10/12", "99/99"] {
            let x = HistoryCounterLayout.originX(afterGlyphEndingAt: 100)
            XCTAssertEqual(x, 100 + HistoryCounterLayout.leadingGap)
            XCTAssertLessThanOrEqual(x + HistoryCounterLayout.width(of: text),
                                     100 + HistoryCounterLayout.reservedWidth(for: text) - HistoryCounterLayout.trailingGap)
        }
        // Cap-aligned: the counter's cap top sits at the text's cap top.
        let top = HistoryCounterLayout.top(baselineY: 100, textCapHeight: 12)
        let font = HistoryCounterLayout.font
        XCTAssertEqual(top + font.ascender - font.capHeight, 100 - 12, accuracy: 0.001)
    }

    private func laidOutTextView(_ text: String) throws -> LineformTextView {
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        textView.applyDefaultTypography()
        textView.string = text
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        return textView
    }

    private func kern(_ textView: LineformTextView, at index: Int) -> NSNumber? {
        textView.textStorage?.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber
    }

    /// Entering History mode shows no counters and reserves no space: nothing reflows.
    func testEnteringHistoryModeShowsNoCounterAndReflowsNothing() throws {
        let textView = try laidOutTextView(sample)
        let before = (0..<(sample as NSString).length).map { kern(textView, at: $0) }
        textView.historyDisplay = display([passage(NSRange(location: 0, length: 17)), passage(NSRange(location: 18, length: 14))])
        let after = (0..<(sample as NSString).length).map { kern(textView, at: $0) }
        XCTAssertEqual(before, after)
        XCTAssertTrue(HistoryCounterSpacing.spacedCharacters(in: try XCTUnwrap(textView.textStorage)).isEmpty)
    }

    /// Only the focused passage reserves counter space, and moving focus moves it.
    func testCounterAppearsOnlyForTheFocusedPassage() throws {
        let textView = try laidOutTextView(sample)
        let storage = try XCTUnwrap(textView.textStorage)
        let first = passage(NSRange(location: 0, length: 17))
        let second = passage(NSRange(location: 18, length: 14))
        textView.historyDisplay = display([first, second])
        textView.historyDisplay = display([first, second], selected: first.id, counter: HistoryCounter(count: 3, current: 1))
        XCTAssertEqual(HistoryCounterSpacing.spacedCharacters(in: storage), [16], "after the first passage's last glyph only")
        textView.historyDisplay = display([first, second], selected: second.id, counter: HistoryCounter(count: 2, current: 0))
        XCTAssertEqual(HistoryCounterSpacing.spacedCharacters(in: storage), [31])
        textView.historyDisplay = nil
        XCTAssertTrue(HistoryCounterSpacing.spacedCharacters(in: storage).isEmpty)
    }

    /// The highlighter resets attributes with `setAttributes`; the counter's room is re-reserved
    /// after every pass while focused, and never after History mode ends.
    func testHighlighterPassKeepsTheCounterRoomOnlyWhileFocused() throws {
        let textView = try laidOutTextView(sample)
        let storage = try XCTUnwrap(textView.textStorage)
        let first = passage(NSRange(location: 0, length: 17))
        textView.historyDisplay = display([first])
        textView.historyDisplay = display([first], selected: first.id, counter: HistoryCounter(count: 2, current: 0))
        textView.refreshMarkdownHighlighting()
        XCTAssertEqual(HistoryCounterSpacing.spacedCharacters(in: storage), [16])
        textView.historyDisplay = nil
        textView.refreshMarkdownHighlighting()
        XCTAssertTrue(HistoryCounterSpacing.spacedCharacters(in: storage).isEmpty)
    }

    /// A focused word at a line's end whose reserved counter room WRAPS it: every highlighter
    /// pass (scroll-settle included) wipes and re-reserves the room. Re-reserving restores the
    /// layout already on screen, so it must not re-anchor — anchoring there captured the unkerned
    /// layout and scrolled one line further on every pass.
    func testRepeatedHighlighterPassesNeverScrollAFocusedLineEndPassage() throws {
        let line = "Alpha beta gamma delta"
        let text = Array(repeating: line, count: 60).joined(separator: "\n")
        let target = (text as NSString).range(of: "delta", options: [], range: NSRange(location: 30 * 23, length: 23))
        XCTAssertNotEqual(target.location, NSNotFound)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let textView = LineformTextView()
        scrollView.documentView = textView
        textView.applyDefaultTypography()
        textView.string = text
        textView.refreshMarkdownHighlighting()  // measure the layout the highlighter produces
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        func lineStartsAtTarget() -> Bool {
            layoutManager.ensureLayout(for: container)
            var lineGlyphs = NSRange(location: 0, length: 0)
            layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: target.location), effectiveRange: &lineGlyphs)
            return layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil).location == target.location
        }
        // The view sizes its own text container from its frame: find the narrowest frame that
        // still keeps "delta" on its line, so the reserved room wraps it.
        var width: CGFloat = 700
        func fits(_ w: CGFloat) -> Bool {
            textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            return !lineStartsAtTarget()
        }
        while width > 100, fits(width - 1) { width -= 1 }
        XCTAssertTrue(fits(width))
        let word = passage(target, level: .word)
        textView.historyDisplay = display([word])
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.historyDisplay = display([word], selected: word.id, counter: HistoryCounter(count: 3, current: 1))
        layoutManager.ensureLayout(for: container)
        XCTAssertTrue(lineStartsAtTarget(), "the reserved room wrapped the word (the case under test)")
        let origin = scrollView.contentView.bounds.origin.y

        for _ in 0..<3 {
            textView.refreshMarkdownHighlighting()
            layoutManager.ensureLayout(for: container)
        }
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, origin, accuracy: 0.5, "highlighter passes never scroll")
        XCTAssertEqual(HistoryCounterSpacing.spacedCharacters(in: try XCTUnwrap(textView.textStorage)), [NSMaxRange(target) - 1])
    }

    /// A word passage mid-line, followed by text on the same line: the counter ends before the
    /// next glyph starts, and the passage's first line does not move.
    func testCounterNeverOverlapsFollowingText() throws {
        let textView = try laidOutTextView(sample)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let word = passage(NSRange(location: 6, length: 4), level: .word)  // "beta"
        let lineY = layoutManager.lineFragmentRect(forGlyphAt: 6, effectiveRange: nil).minY
        let counter = HistoryCounter(count: 3, current: 1)
        textView.historyDisplay = display([word])
        textView.historyDisplay = display([word], selected: word.id, counter: counter)
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let frame = try XCTUnwrap(textView.historyCounterFrame(for: word.range, counter: counter))
        let nextGlyph = layoutManager.glyphIndexForCharacter(at: 11)  // "gamma"
        let nextRect = layoutManager.lineFragmentRect(forGlyphAt: nextGlyph, effectiveRange: nil)
        XCTAssertEqual(nextRect.minY, lineY, "still on the same line")
        let nextX = textView.textContainerOrigin.x + nextRect.minX + layoutManager.location(forGlyphAt: nextGlyph).x
        XCTAssertLessThanOrEqual(frame.maxX, nextX, "the counter never reaches the following text")
        let endOfBeta = textView.textContainerOrigin.x
            + layoutManager.boundingRect(forGlyphRange: NSRange(location: layoutManager.glyphIndexForCharacter(at: 9), length: 1),
                                         in: try XCTUnwrap(textView.textContainer)).minX
        XCTAssertGreaterThan(frame.minX, endOfBeta, "after the passage's last glyph")
        XCTAssertEqual(layoutManager.lineFragmentRect(forGlyphAt: 6, effectiveRange: nil).minY, lineY,
                       "the focused passage's first line stays put")
    }

    /// Focus: the focused passage full ink, others at the focus-other ink (hovered: receded),
    /// unchanged text deep receded. Unfocused: unchanged receded, passages full ink.
    func testFocusInks() throws {
        let textView = makeTextView()
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let theme = Theme.theme(for: textView.appliedReadingProfile)
        func ink(_ index: Int) -> NSColor? {
            layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
        }
        let first = passage(NSRange(location: 0, length: 5))
        let second = passage(NSRange(location: 6, length: 4))
        textView.historyDisplay = display([first, second])
        XCTAssertEqual(ink(12), HistoryPalette.recededInk(for: theme))
        XCTAssertNil(ink(0))
        XCTAssertNil(ink(7))

        textView.historyDisplay = display([first, second], selected: first.id, counter: HistoryCounter(count: 2, current: 1))
        XCTAssertNil(ink(0), "the focused passage keeps the full ink")
        XCTAssertEqual(ink(7), HistoryPalette.focusOtherInk(for: theme))
        XCTAssertEqual(ink(12), HistoryPalette.deepRecededInk(for: theme))

        textView.setHistoryHoveredID(second.id)
        XCTAssertEqual(ink(7), HistoryPalette.recededInk(for: theme), "a hovered passage reads as clickable")
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
            HistoryModeAnnouncement.text(level: .sentence, counter: HistoryCounter(count: 4, current: 1)),
            String(localized: "\(HistoryLevel.sentence.title), version \(2) of \(4)")
        )
        XCTAssertEqual(HistoryModeAnnouncement.text(level: .word, counter: nil), HistoryLevel.word.title)
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
