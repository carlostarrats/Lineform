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
}
