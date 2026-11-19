import XCTest
import AppKit
@testable import Lineform
@testable import LineformCore

/// The selection toolbar's pure decisions (`SelectionToolbarPresentation`). Showing, hiding and
/// placement against a live text view were checked by hand in the running app.
final class SelectionToolbarTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
            "\(language).lproj missing from the test host"
        )
    }

    // MARK: - The comment card's action menu

    /// Custom first, then the context menu's AI group with its own rules, flattened.
    func testActionGroupsForSeveralSentences() {
        let groups = SelectionToolbarPresentation.actionGroups(selectedText: "One. Two.", sentenceCount: { 2 })
        XCTAssertEqual(groups, [[.custom], [.trim, .cutInHalf], [.rephrase, .simplify, .moreFormal, .moreCasual],
                                [.proofread], [.markWeakest, .markLong]])
    }

    func testActionGroupsOfferFindOnlyForTwoOrMoreSentences() {
        let groups = SelectionToolbarPresentation.actionGroups(selectedText: "Just one sentence here", sentenceCount: { 1 })
        XCTAssertFalse(groups.joined().contains(.markWeakest))
        XCTAssertFalse(groups.joined().contains(.markLong))
        XCTAssertEqual(groups.first, [.custom])
    }

    func testActionGroupsForOneWord() {
        var counted = false
        let groups = SelectionToolbarPresentation.actionGroups(selectedText: "big", sentenceCount: { counted = true; return 1 })
        XCTAssertEqual(groups, [[.custom], [.anotherWord, .proofread]])
        XCTAssertFalse(counted, "a single word never pays for the sentence split")
    }

    /// Custom IS the note; every other action can go with or without one.
    func testCanSend() {
        XCTAssertFalse(SelectionToolbarPresentation.canSend(action: .custom, note: ""))
        XCTAssertFalse(SelectionToolbarPresentation.canSend(action: .custom, note: "  \n "))
        XCTAssertTrue(SelectionToolbarPresentation.canSend(action: .custom, note: "make it warmer"))
        XCTAssertTrue(SelectionToolbarPresentation.canSend(action: .cutInHalf, note: ""))
        XCTAssertTrue(SelectionToolbarPresentation.canSend(action: .markWeakest, note: "and say why"))
    }

    func testCustomIsNeverOnTheContextMenu() {
        let entries = LineformTextContextMenuPresentation.aiMenuEntries(selectedText: "One. Two.", sentenceCount: { 2 })
        for entry in entries {
            switch entry {
            case .action(let action): XCTAssertNotEqual(action, .custom)
            case .submenu(_, let groups): XCTAssertFalse(groups.joined().contains(.custom))
            }
        }
    }

    /// Out of the context menu's "Find ▸" submenu, the Find actions say what they do.
    func testMenuTitles() {
        XCTAssertEqual(SelectionToolbarPresentation.menuTitle(for: .custom), "Custom")
        XCTAssertEqual(SelectionToolbarPresentation.menuTitle(for: .cutInHalf), "Cut in Half")
        XCTAssertEqual(SelectionToolbarPresentation.menuTitle(for: .markWeakest), "Find Weakest Sentences")
        XCTAssertEqual(SelectionToolbarPresentation.menuTitle(for: .markLong), "Find Long Sentences")
    }

    func testAINames() {
        XCTAssertEqual(SelectionToolbarPresentation.aiName(for: .claude), "Claude")
        XCTAssertEqual(SelectionToolbarPresentation.aiName(for: .other), "Your AI")
        XCTAssertEqual(SelectionToolbarPresentation.commentTitle(aiName: "Claude"), "Ask Claude")
    }

    func testStringsAreLocalized() throws {
        for language in Self.languages {
            let bundle = try bundle(language)
            // The other actions' titles are the context menu's, covered by AIActionPromptTests.
            for action in [AIAction.custom, .markWeakest, .markLong] {
                XCTAssertNotEqual(SelectionToolbarPresentation.menuTitle(for: action, bundle: bundle),
                                  SelectionToolbarPresentation.menuTitle(for: action), "\(language) \(action)")
            }
            XCTAssertNotEqual(SelectionToolbarPresentation.aiName(for: .other, bundle: bundle), "Your AI", language)
            let ask = SelectionToolbarPresentation.commentTitle(aiName: "Claude", bundle: bundle)
            XCTAssertNotEqual(ask, "Ask Claude", language)
            XCTAssertTrue(ask.contains("Claude"), "\(language): \(ask) lost the brand")
        }
    }

    // MARK: - Placement

    private let visible = NSRect(x: 0, y: 100, width: 800, height: 600)
    private let bar = NSSize(width: 300, height: 38)

    func testSitsCentredAboveTheFirstLine() {
        let line = NSRect(x: 200, y: 400, width: 200, height: 20)
        let origin = SelectionToolbarPresentation.origin(barSize: bar, firstLine: line, lastLine: line, visible: visible)
        XCTAssertEqual(origin.x, 150)
        XCTAssertEqual(origin.y, 400 - 8 - 38)
    }

    func testFlipsBelowTheLastLineNearTheTop() {
        let first = NSRect(x: 200, y: 110, width: 200, height: 20)
        let last = NSRect(x: 100, y: 170, width: 100, height: 20)
        let origin = SelectionToolbarPresentation.origin(barSize: bar, firstLine: first, lastLine: last, visible: visible)
        XCTAssertEqual(origin.y, 190 + 8)
    }

    func testStaysInsideTheVisibleRect() {
        let atLeftEdge = NSRect(x: 0, y: 400, width: 20, height: 20)
        XCTAssertEqual(SelectionToolbarPresentation.origin(barSize: bar, firstLine: atLeftEdge, lastLine: atLeftEdge,
                                                           visible: visible).x, 8)
        let atRightEdge = NSRect(x: 780, y: 400, width: 20, height: 20)
        XCTAssertEqual(SelectionToolbarPresentation.origin(barSize: bar, firstLine: atRightEdge, lastLine: atRightEdge,
                                                           visible: visible).x, 800 - 300 - 8)
        // Select All, scrolled to the end: the first line is far above, the last far below.
        let farAbove = NSRect(x: 100, y: -5000, width: 600, height: 20)
        let farBelow = NSRect(x: 100, y: 9000, width: 600, height: 20)
        let pinned = SelectionToolbarPresentation.origin(barSize: bar, firstLine: farAbove, lastLine: farBelow, visible: visible)
        XCTAssertTrue(visible.contains(NSRect(origin: pinned, size: bar)), "\(pinned)")
    }
}
