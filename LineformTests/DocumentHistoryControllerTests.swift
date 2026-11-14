import XCTest
import AppKit
@testable import Lineform

/// The editor's History controller, without a window (default test plan: no NSWindow). The
/// integration tests attach a bare `LineformTextView`, which is what production edits go through.
@MainActor
final class DocumentHistoryControllerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let text = "Alpha beta gamma delta. Epsilon zeta eta theta."
    private let sentence = "Alpha beta gamma delta."
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentHistoryControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeController(store: PassageHistoryPersisting = NullPassageHistoryStore()) -> DocumentHistoryController {
        let date = fixedDate
        return DocumentHistoryController(store: store, now: { date })
    }

    private func range(of needle: String, in haystack: String) -> NSRange {
        let found = (haystack as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle)")
        return found
    }

    private func apply(_ edit: HistoryEdit?, to string: String) -> String {
        guard let edit else { return string }
        return (string as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// A user edit: applied to `string` and reported, as the text view does.
    private func type(_ controller: DocumentHistoryController, _ old: String, with new: String, in string: String) -> String {
        let r = range(of: old, in: string)
        controller.noteUserEdit(r, replacement: new)
        return (string as NSString).replacingCharacters(in: r, with: new)
    }

    /// `sentence` with two distinct versions, the second current: the user edit "beta" → "BETA"
    /// recorded as an accepted change (Add to History alone now stores one version, which typing
    /// edits in place).
    private func controllerWithEditedPassage(store: PassageHistoryPersisting = NullPassageHistoryStore(),
                                             url: URL? = nil) -> (DocumentHistoryController, String) {
        let controller = makeController(store: store)
        controller.open(url: url, text: text)
        let edited = type(controller, "beta", with: "BETA", in: text)
        let accepted = "Alpha BETA gamma delta."
        controller.recordAccepted(range: range(of: accepted, in: edited), original: sentence, accepted: accepted, text: edited)
        return (controller, edited)
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private final class UndoManagerVendor: NSObject, NSTextViewDelegate {
        let manager: UndoManager
        override init() { manager = UndoManager(); super.init() }
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private func makeTextView(_ string: String) -> LineformTextView {
        let textView = LineformTextView()
        textView.string = string
        return textView
    }

    // MARK: - Undo collapse (pure)

    func testCollapsedExitEditUndoesToEntryText() throws {
        let entry = "One two three. Four five six."
        let exit = "One TWO three. Four five six seven."
        let edit = try XCTUnwrap(HistoryUndoCollapse.minimalEdit(from: entry, to: exit))
        XCTAssertEqual(apply(edit, to: entry), exit)
        let inverse = HistoryEdit(
            range: NSRange(location: edit.range.location, length: (edit.replacement as NSString).length),
            replacement: (entry as NSString).substring(with: edit.range)
        )
        XCTAssertEqual(apply(inverse, to: exit), entry)
        XCTAssertEqual(edit.range.location, 4, "the shared prefix is not rewritten")
    }

    func testExitEditPreservesCRLFAndBOM() throws {
        let entry = "\u{FEFF}Alpha\r\nbeta\r\ngamma\r\n"
        let exit = "\u{FEFF}Alpha\r\nBETA\r\ngamma\r\n"
        let edit = try XCTUnwrap(HistoryUndoCollapse.minimalEdit(from: entry, to: exit))
        XCTAssertEqual(apply(edit, to: entry), exit)
        XCTAssertEqual(edit.range, NSRange(location: 8, length: 4), "BOM and CRLFs stay outside the edit")
        XCTAssertEqual(edit.replacement, "BETA")

        // A change next to a CRLF never splits the pair, and a change next to an emoji never
        // splits its surrogates or a combining mark.
        let crlf = try XCTUnwrap(HistoryUndoCollapse.minimalEdit(from: "a\r\nb", to: "a\nb"))
        XCTAssertEqual(apply(crlf, to: "a\r\nb"), "a\nb")
        XCTAssertEqual(crlf.range, NSRange(location: 1, length: 2))
        let emoji = try XCTUnwrap(HistoryUndoCollapse.minimalEdit(from: "x👍🏽y", to: "x👍🏿y"))
        XCTAssertEqual(apply(emoji, to: "x👍🏽y"), "x👍🏿y")
        XCTAssertEqual(emoji.range, NSRange(location: 1, length: 4))
        let accent = try XCTUnwrap(HistoryUndoCollapse.minimalEdit(from: "cafe", to: "cafe\u{301}"))
        XCTAssertEqual(apply(accent, to: "cafe"), "cafe\u{301}")
        XCTAssertEqual(accent.range.location, 3, "the combining mark takes its base letter with it")
    }

    func testMinimalEditIsNilWhenUnchanged() {
        XCTAssertNil(HistoryUndoCollapse.minimalEdit(from: "same\r\n", to: "same\r\n"))
        XCTAssertNil(HistoryUndoCollapse.minimalEdit(from: "", to: ""))
        XCTAssertEqual(HistoryUndoCollapse.minimalEdit(from: "", to: "new"),
                       HistoryEdit(range: NSRange(location: 0, length: 0), replacement: "new"))
    }

    /// Repeated text lets a change sit at several offsets: the union of the prefix-first and
    /// suffix-first placements is reported, and the result text is unchanged. One placement
    /// (ordinary edits) reports exactly the minimal edit.
    func testUnambiguousEditReportsUnionOfAmbiguousPlacements() throws {
        let entry = "Keep this. Keep this. Keep this. End."
        let exit = String(entry.dropFirst(11))
        let union = try XCTUnwrap(HistoryUndoCollapse.unambiguousEdit(from: entry, to: exit))
        XCTAssertEqual(union.range, NSRange(location: 0, length: 33))
        XCTAssertEqual(apply(union, to: entry), exit)

        let inserted = try XCTUnwrap(HistoryUndoCollapse.unambiguousEdit(from: "hello", to: "helllo"))
        XCTAssertEqual(inserted.range, NSRange(location: 2, length: 2))
        XCTAssertEqual(apply(inserted, to: "hello"), "helllo")

        let plainEntry = "One two three. Four five six."
        let plainExit = "One TWO three. Four five six seven."
        XCTAssertEqual(HistoryUndoCollapse.unambiguousEdit(from: plainEntry, to: plainExit),
                       HistoryUndoCollapse.minimalEdit(from: plainEntry, to: plainExit))
        XCTAssertEqual(HistoryUndoCollapse.unambiguousEdit(from: "", to: "x"),
                       HistoryEdit(range: NSRange(location: 0, length: 0), replacement: "x"))
        XCTAssertNil(HistoryUndoCollapse.unambiguousEdit(from: "same", to: "same"))
        let crlf = try XCTUnwrap(HistoryUndoCollapse.unambiguousEdit(from: "a\r\nb", to: "a\nb"))
        XCTAssertEqual(apply(crlf, to: "a\r\nb"), "a\nb")
    }

    // MARK: - Add stores only the original; replacements; discard on exit (1.8 QA follow-ups)

    func testAddReturnsThePassageAndRequestsShowingHistory() throws {
        let controller = makeController()
        controller.open(url: nil, text: text)
        var requested: [UUID] = []
        controller.onRequestShowHistory = { requested.append($0) }
        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertEqual(requested, [id])
        XCTAssertTrue(controller.hasHistory)

        XCTAssertTrue(controller.showPassage(id, text: text))
        XCTAssertTrue(controller.isHistoryModeActive)
        XCTAssertEqual(controller.display?.selectedID, id)
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), [sentence], "listed once, not twice")
        XCTAssertNil(controller.display?.counter, "one version: no 1/1")

        // Adding the same passage again adds nothing, but still asks to show it.
        XCTAssertEqual(controller.add(range(of: sentence, in: text), text: text), id)
        XCTAssertEqual(requested, [id, id])
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), [sentence])

        // The text view's Add command goes through the same path.
        _ = controller.handle(.add(range(of: "Epsilon zeta eta theta.", in: text)), text: text)
        XCTAssertEqual(requested.count, 3)
        XCTAssertEqual(controller.display?.selectedID, requested.last, "in History mode the new passage is focused")
    }

    /// Add to History asks the editor to show History focused on THAT passage.
    func testAddRequestsShowingHistoryForThePassage() throws {
        let controller = makeController()
        controller.open(url: nil, text: text)
        var requested: [UUID] = []
        controller.onRequestShowHistory = { requested.append($0) }
        let second = try XCTUnwrap(controller.add(range(of: "Epsilon zeta eta theta.", in: text), text: text))
        XCTAssertEqual(requested, [second])
        XCTAssertTrue(controller.showPassage(second, text: text))
        XCTAssertEqual(controller.display?.selectedID, second)
    }

    /// AI actions are offered on every selection in normal writing — before 2026-11-13 a word
    /// passage refused them on itself and inside itself (`isInsideWordPassage`), which is what hid
    /// the AI items on "some words" of a line already rewritten. Only History mode refuses them.
    func testAIIsOfferedOnAnySelectionOutsideHistoryMode() throws {
        let doc = "Intro.\n\nThe quick brown fox jumps over it.\n\nOutro."
        let controller = DocumentHistoryController(store: NullPassageHistoryStore())
        controller.open(url: nil, text: doc)
        _ = try XCTUnwrap(controller.recordAccepted(range: range(of: "The quick brown fox jumps over it.", in: doc),
                                                    original: "The fast brown fox jumps over it.",
                                                    accepted: "The quick brown fox jumps over it.", text: doc))
        _ = try XCTUnwrap(controller.recordAccepted(range: range(of: "quick brown", in: doc), original: "fast brown",
                                                    accepted: "quick brown", text: doc))
        let selections = [
            ("a word inside a sentence passage", range(of: "jumps", in: doc)),
            ("a word passage itself", range(of: "quick brown", in: doc)),
            ("part of a word passage", range(of: "brown", in: doc)),
            ("partly overlapping a passage", range(of: "brown fox", in: doc)),
            ("containing passages", range(of: "Intro.\n\nThe quick brown fox jumps over it.", in: doc)),
        ]
        for (name, selection) in selections {
            XCTAssertTrue(controller.allowsAIAction(on: selection), name)
        }
        XCTAssertEqual(controller.aiActionRange(for: range(of: "brown fox", in: doc)), range(of: "quick brown fox", in: doc))
        XCTAssertTrue(controller.enterHistoryMode(text: doc))
        XCTAssertFalse(controller.allowsAIAction(on: range(of: "jumps", in: doc)), "History mode never overlaps AI")
    }

    /// Replace With…: the passage is shown with its alternative field already asked for; the
    /// request is spent when the field opens, and never carried into a later History entry.
    func testAddAlternativeAsksForTheField() throws {
        let controller = DocumentHistoryController(store: NullPassageHistoryStore())
        controller.open(url: nil, text: text)
        var requested: [UUID] = []
        controller.onRequestShowHistory = { requested.append($0) }
        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertEqual(requested, [id])
        XCTAssertTrue(controller.showPassage(id, text: text))
        XCTAssertEqual(controller.sidebarModel.selectedPassageID, id)
        XCTAssertTrue(controller.sidebarModel.opensAlternativeField)
        controller.alternativeFieldDidOpen()
        XCTAssertFalse(controller.sidebarModel.opensAlternativeField)
        XCTAssertNil(controller.pendingAlternativeFieldID)

        // Left without opening it: the next entry does not reopen it.
        let other = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertNotNil(controller.pendingAlternativeFieldID)
        controller.exitHistoryMode()
        XCTAssertNil(controller.pendingAlternativeFieldID)
        _ = other
    }

    /// Deselect returns to the overview: History stays on, nothing selected; with nothing
    /// selected it does nothing (Esc then leaves History, from the text view).
    func testDeselectReturnsToTheOverview() throws {
        let controller = DocumentHistoryController(store: NullPassageHistoryStore())
        controller.open(url: nil, text: text)
        let accepted = "Alpha BETA gamma delta."
        let doc = (text as NSString).replacingOccurrences(of: sentence, with: accepted)
        controller.open(url: nil, text: doc, documentID: UUID())
        let id = try XCTUnwrap(controller.recordAccepted(range: range(of: accepted, in: doc), original: sentence,
                                                         accepted: accepted, text: doc))
        XCTAssertTrue(controller.showPassage(id, text: doc))
        XCTAssertEqual(controller.display?.selectedID, id)
        XCTAssertNil(controller.handle(.deselect, text: doc))
        XCTAssertTrue(controller.isHistoryModeActive)
        XCTAssertNil(controller.display?.selectedID)
        XCTAssertFalse(controller.sidebarModel.hasSelection)
        XCTAssertNil(controller.handle(.deselect, text: doc))
        XCTAssertTrue(controller.isHistoryModeActive, "nothing selected: deselect does nothing")
    }

    /// Replace With… on fresh text: one version, so no "1/1" counter until a replacement lands.
    func testOneVersionPassageShowsNoCounter() throws {
        let controller = DocumentHistoryController(store: NullPassageHistoryStore())
        controller.open(url: nil, text: text)
        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertTrue(controller.showPassage(id, text: text))
        XCTAssertEqual(controller.display?.selectedID, id)
        XCTAssertNil(controller.display?.counter)
        XCTAssertNotNil(controller.addReplacement("Alpha beta gamma.", for: id))
        XCTAssertEqual(controller.display?.counter, HistoryCounter(count: 2, current: 1))
    }

    /// Replace With… is honest about its one-line field: offered within one line of prose (a
    /// word, a sentence, a list item's text), absent across paragraphs or blocks and on code,
    /// front matter or math.
    func testReplaceWithIsOfferedOnlyWhereOneLineCanReplace() {
        let doc = "---\ntitle: x\n---\n\nFirst paragraph here. Second sentence.\n\n- A list item\n> A quote\n\n```\nlet x = 1\n```\n"
        let controller = DocumentHistoryController(store: NullPassageHistoryStore())
        controller.open(url: nil, text: doc)
        XCTAssertTrue(controller.canAdd(range(of: "Second sentence.", in: doc), text: doc))
        XCTAssertTrue(controller.canAdd(range(of: "First paragraph here. Second sentence.", in: doc), text: doc))
        XCTAssertTrue(controller.canAdd(range(of: "list item", in: doc), text: doc))
        XCTAssertFalse(controller.canAdd(range(of: "Second sentence.\n\n- A list item\n> A quote\n\n```\nlet x = 1", in: doc), text: doc),
                       "several paragraphs and blocks")
        XCTAssertFalse(controller.canAdd(range(of: "let x = 1", in: doc), text: doc), "fenced code")
        XCTAssertFalse(controller.canAdd(range(of: "title: x", in: doc), text: doc), "front matter")
    }

    /// A passage that is not in the text is checked BEFORE History mode starts: nothing is
    /// entered (no wash, no sidebar on an inert History tab).
    func testShowPassageForAMissingPassageDoesNotEnterHistoryMode() throws {
        let (controller, edited) = controllerWithEditedPassage()
        XCTAssertFalse(controller.showPassage(UUID(), text: edited))
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertNil(controller.display)
    }

    /// The show-History hook is cleared only by the view that set it: a hierarchy rebuild can run
    /// the new view's onAppear before the old one's onDisappear.
    func testShowHistoryHandlerIsClearedOnlyByItsOwner() {
        let controller = makeController()
        let old = UUID()
        let new = UUID()
        controller.setShowHistoryHandler(owner: old) { _ in }
        controller.setShowHistoryHandler(owner: new) { _ in }
        controller.clearShowHistoryHandler(owner: old)
        XCTAssertNotNil(controller.onRequestShowHistory, "a stale owner does not clear the live hook")
        controller.clearShowHistoryHandler(owner: new)
        XCTAssertNil(controller.onRequestShowHistory, "the owner's disappear breaks the view ↔ controller cycle")
    }

    func testExitDiscardsPassagesWithNoReplacement() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let controller = makeController(store: store)
        controller.open(url: a, text: text)
        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertTrue(controller.showPassage(id, text: text))
        XCTAssertNil(controller.exitHistoryMode(), "nothing changed in the document")
        XCTAssertFalse(controller.hasHistory, "nothing was added, so nothing is kept")
        XCTAssertTrue(store.load(for: a).isEmpty)
    }

    func testAddReplacementInHistoryModeKeepsThePassage() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let controller = makeController(store: store)
        controller.open(url: a, text: text)
        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertTrue(controller.showPassage(id, text: text))

        XCTAssertNil(controller.addReplacement("   ", for: id), "empty adds nothing")
        XCTAssertNil(controller.addReplacement(sentence, for: id), "unchanged adds nothing")
        let edit = try XCTUnwrap(controller.addReplacement("Alpha BETA gamma delta.", for: id))
        let replaced = apply(edit, to: text)
        XCTAssertEqual(replaced, "Alpha BETA gamma delta. Epsilon zeta eta theta.")
        XCTAssertTrue(controller.isHistoryModeActive, "adding a replacement does not leave History")
        XCTAssertEqual(controller.display?.selectedID, id)
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), [sentence, "Alpha BETA gamma delta."])
        XCTAssertEqual(controller.sidebarModel.versions.map(\.isCurrent), [false, true])

        let collapse = controller.exitHistoryMode()
        XCTAssertEqual(apply(collapse, to: text), replaced, "the session collapses from entry to exit text")
        XCTAssertTrue(controller.hasHistory)
        XCTAssertEqual(store.load(for: a).passages.first?.versions.map(\.text), [sentence, "Alpha BETA gamma delta."])
    }

    func testAddReplacementNeedsHistoryModeAndASelection() throws {
        let controller = makeController()
        controller.open(url: nil, text: text)
        let id = try XCTUnwrap(controller.add(range(of: sentence, in: text), text: text))
        XCTAssertNil(controller.addReplacement("Other words here.", for: id), "outside History mode")
        XCTAssertTrue(controller.enterHistoryMode(text: text))
        XCTAssertNil(controller.addReplacement("Other words here.", for: id), "no passage selected")
    }

    /// The field is opened for one passage. If the selection moved meanwhile (a level button, a
    /// click in the text) the text is NOT put on the passage selected now — a sentence-sized
    /// replacement must never land on the whole paragraph.
    func testAddReplacementRefusesWhenTheSelectionChangedSinceTheFieldOpened() throws {
        let doc = "First one here. Second one there.\n\nOther paragraph."
        let controller = makeController()
        controller.open(url: nil, text: doc)
        let paragraph = try XCTUnwrap(controller.add(range(of: "First one here. Second one there.", in: doc), text: doc))
        XCTAssertTrue(controller.showPassage(paragraph, text: doc))
        let sentenceID = try XCTUnwrap(controller.add(range(of: "First one here.", in: doc), text: doc))
        XCTAssertEqual(controller.sidebarModel.selectedPassageID, sentenceID, "the sidebar model names the passage")

        // The field opened on the sentence; then "Paragraph" was clicked.
        controller.selectLevel(.paragraph)
        XCTAssertEqual(controller.sidebarModel.selectedPassageID, paragraph)
        XCTAssertNil(controller.addReplacement("Sentence text.", for: sentenceID))
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), ["First one here. Second one there."])
        XCTAssertNotNil(controller.addReplacement("Whole new paragraph.", for: paragraph))
    }

    func testExitKeepsAIRecordedPassages() throws {
        let controller = makeController()
        let accepted = "Alpha BETA gamma delta."
        let doc = (text as NSString).replacingOccurrences(of: sentence, with: accepted)
        controller.open(url: nil, text: doc)
        controller.recordAccepted(range: range(of: accepted, in: doc), original: sentence, accepted: accepted, text: doc)
        XCTAssertTrue(controller.enterHistoryMode(text: doc))
        _ = controller.exitHistoryMode()
        XCTAssertTrue(controller.hasHistory, "an accepted AI change is two versions: it stays")
    }

    /// 1.8.0 stored every Add twice; that history collapses to one version on load and, being
    /// unrevised, is discarded there — the document opens with no history.
    func testLegacyDuplicateAddIsDiscardedOnLoad() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let context = PassageHistoryText.context(around: range(of: sentence, in: text), in: text)
        store.save(DocumentHistory(passages: [HistoryPassage(
            id: UUID(), level: .sentence,
            versions: [HistoryVersion(text: sentence, author: .you, createdAt: fixedDate),
                       HistoryVersion(text: sentence, author: .you, createdAt: fixedDate)],
            currentIndex: 1, parentID: nil, parentVersionIndex: nil,
            contextBefore: context.before, contextAfter: context.after, lastTouched: fixedDate)]), for: a)
        let controller = makeController(store: store)
        controller.open(url: a, text: text)
        XCTAssertFalse(controller.hasHistory)
        XCTAssertFalse(controller.enterHistoryMode(text: text))
        XCTAssertTrue(store.load(for: a).isEmpty)
    }

    /// A passage added while History mode is on, then given a replacement: one ⌘Z after leaving
    /// restores the entry text AND makes the original current again, so the passage survives.
    func testReplacementOnPassageAddedInHistoryModeUndoesAsOneStep() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let vendor = UndoManagerVendor()
        let textView = makeTextView(edited)
        textView.delegate = vendor
        controller.attach(textView)
        XCTAssertTrue(controller.enterHistoryMode(text: textView.string))

        let other = "Epsilon zeta eta theta."
        let id = try XCTUnwrap(controller.add(range(of: other, in: textView.string), text: textView.string))
        XCTAssertEqual(controller.display?.selectedID, id)
        _ = try XCTUnwrap(controller.addReplacement("Epsilon ZETA eta theta.", for: id))
        XCTAssertEqual(textView.string, "Alpha BETA gamma delta. Epsilon ZETA eta theta.")
        XCTAssertFalse(vendor.manager.canUndo, "a replacement is not undoable on its own")

        _ = controller.handle(.exit, text: textView.string)
        XCTAssertTrue(vendor.manager.canUndo)
        vendor.manager.undo()
        XCTAssertEqual(textView.string, edited, "one ⌘Z restores the entry text")
        XCTAssertEqual(try versionTexts(controller, at: other, in: textView.string), [other, "Epsilon ZETA eta theta."],
                       "the passage keeps both versions after the undo")
    }

    // MARK: - Mode

    func testEnteringHistoryModeRequiresHistory() {
        let controller = makeController()
        controller.open(url: nil, text: text)
        XCTAssertFalse(controller.hasHistory)
        controller.enterHistoryMode(text: text)
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertNil(controller.display)
    }

    func testEnteringShowsPassagesWithNothingSelected() throws {
        let (controller, edited) = controllerWithEditedPassage()
        XCTAssertTrue(controller.hasHistory)
        controller.enterHistoryMode(text: edited)
        XCTAssertTrue(controller.isHistoryModeActive)
        let display = try XCTUnwrap(controller.display)
        XCTAssertEqual(display.passages.map(\.range), [range(of: "Alpha BETA gamma delta.", in: edited)])
        XCTAssertNil(display.selectedID)
        XCTAssertFalse(controller.sidebarModel.hasSelection)
    }

    func testSelectStepAndSidebarModel() throws {
        let (controller, edited) = controllerWithEditedPassage()
        controller.enterHistoryMode(text: edited)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        XCTAssertNil(controller.handle(.select(id), text: edited))
        XCTAssertEqual(controller.display?.selectedID, id)
        XCTAssertEqual(controller.display?.counter, HistoryCounter(count: 2, current: 1))
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), ["Alpha beta gamma delta.", "Alpha BETA gamma delta."])
        XCTAssertEqual(controller.sidebarModel.versions.map(\.isCurrent), [false, true])
        XCTAssertEqual(controller.sidebarModel.currentLevel, .sentence)
        XCTAssertEqual(controller.sidebarModel.levels, [.sentence])

        let edit = try XCTUnwrap(controller.handle(.step(-1), text: edited))
        let stepped = apply(edit, to: edited)
        XCTAssertEqual(stepped, text)
        XCTAssertEqual(controller.display?.counter, HistoryCounter(count: 2, current: 0))
        XCTAssertEqual(controller.sidebarModel.versions.map(\.isCurrent), [true, false])

        let back = try XCTUnwrap(controller.selectVersion(1, text: stepped))
        XCTAssertEqual(apply(back, to: stepped), edited)
    }

    func testMoveSelectionWalksPassagesInOrder() throws {
        let controller = makeController()
        controller.open(url: nil, text: text)
        _ = controller.handle(.add(range(of: sentence, in: text)), text: text)
        _ = controller.handle(.add(range(of: "Epsilon zeta eta theta.", in: text)), text: text)
        controller.enterHistoryMode(text: text)
        let ids = try XCTUnwrap(controller.display?.passages.map(\.id))
        XCTAssertEqual(ids.count, 2)
        _ = controller.handle(.moveSelection(1), text: text)
        XCTAssertEqual(controller.display?.selectedID, ids[0])
        _ = controller.handle(.moveSelection(1), text: text)
        XCTAssertEqual(controller.display?.selectedID, ids[1])
        _ = controller.handle(.moveSelection(1), text: text)
        XCTAssertEqual(controller.display?.selectedID, ids[1], "stops at the last passage")
        _ = controller.handle(.moveSelection(-1), text: text)
        XCTAssertEqual(controller.display?.selectedID, ids[0])
    }

    func testDeletingLastVersionLeavesHistoryMode() throws {
        let (controller, edited) = controllerWithEditedPassage()
        controller.enterHistoryMode(text: edited)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: edited)
        // Deleting a non-current version leaves one: the passage loses its history record.
        XCTAssertNil(controller.deleteVersion(0, text: edited))
        XCTAssertFalse(controller.hasHistory)
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertNil(controller.display)
    }

    func testTypingCommandExitsHistoryMode() throws {
        let (controller, edited) = controllerWithEditedPassage()
        controller.enterHistoryMode(text: edited)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: edited)
        let stepped = apply(controller.handle(.step(-1), text: edited), to: edited)

        let collapse = controller.handle(.typedWhileInHistoryMode, text: stepped)
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertNil(controller.display)
        XCTAssertEqual(apply(collapse, to: edited), stepped, "the collapse goes from entry text to exit text")
        XCTAssertTrue(controller.hasHistory)
    }

    func testEscapeWithNoStepsExitsWithNoEdit() throws {
        let (controller, edited) = controllerWithEditedPassage()
        controller.enterHistoryMode(text: edited)
        XCTAssertNil(controller.handle(.exit, text: edited))
        XCTAssertFalse(controller.isHistoryModeActive)
    }

    func testSwitchingToReadModeExitsHistoryMode() {
        let (controller, edited) = controllerWithEditedPassage()
        controller.enterHistoryMode(text: edited)
        controller.displayModeDidChange(to: .write)
        XCTAssertTrue(controller.isHistoryModeActive, "Write is where History mode runs")
        controller.displayModeDidChange(to: .read)
        XCTAssertFalse(controller.isHistoryModeActive)
        controller.enterHistoryMode(text: edited)
        controller.displayModeDidChange(to: .split)
        XCTAssertFalse(controller.isHistoryModeActive)
    }

    func testReloadExitsWithoutCollapseAndRelocates() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let textView = makeTextView(edited)
        controller.attach(textView)
        controller.enterHistoryMode(text: edited)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        let stepped = textView.string

        let disk = "Intro. " + stepped
        controller.documentReloaded(text: disk)
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertNil(textView.historyDisplay)
        XCTAssertEqual(textView.string, stepped, "reload replaces the text; the controller writes nothing")
        XCTAssertTrue(controller.hasHistory, "the passage is re-found literally in the reloaded text")
        controller.enterHistoryMode(text: disk)
        XCTAssertEqual(controller.display?.passages.first?.range, range(of: sentence, in: disk))
    }

    func testSwitchingDocumentsResetsState() throws {
        let (controller, edited) = controllerWithEditedPassage()
        controller.enterHistoryMode(text: edited)
        controller.close(text: edited)
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertFalse(controller.hasHistory)
        controller.open(url: nil, text: "Other document.")
        XCTAssertFalse(controller.hasHistory)
    }

    // MARK: - Store

    func testFileMovedKeepsHistory() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: a)
        XCTAssertTrue(controller.hasHistory)

        let b = directory.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: a, to: b)
        controller.fileMoved(from: a, to: b)
        XCTAssertEqual(controller.url.map(FileIdentity.key(for:)), FileIdentity.key(for: b))

        let reopened = makeController(store: store)
        reopened.open(url: b, text: edited)
        XCTAssertTrue(reopened.hasHistory)
        let stale = makeController(store: store)
        stale.open(url: a, text: edited)
        XCTAssertFalse(stale.hasHistory)
    }

    func testTypedChangesPersistWhenTheDocumentSaves() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: a)
        let typedMore = type(controller, "gamma", with: "GAMMA", in: edited)
        controller.documentSaved(text: typedMore)

        let reopened = makeController(store: store)
        reopened.open(url: a, text: typedMore)
        XCTAssertTrue(reopened.hasHistory, "the current version follows what was typed into it")
    }

    func testNothingStoredUntilAVersionIsKept() throws {
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let store = FilePassageHistoryStore(directory: storeDirectory)
        let a = try makeFile("a.md", contents: text)
        let controller = makeController(store: store)
        controller.open(url: a, text: text)
        controller.enterHistoryMode(text: text)
        _ = controller.exitHistoryMode()
        controller.documentSaved(text: text)
        controller.close(text: text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.path),
                       "no directory, no index: nothing is written for a document without history")

        let kept = makeController(store: store)
        kept.open(url: a, text: text)
        _ = kept.handle(.add(range(of: sentence, in: text)), text: text)
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)) ?? []).isEmpty)
    }

    func testUntitledHistoryIsStoredOnceTheDocumentGetsAFile() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let (controller, edited) = controllerWithEditedPassage(store: store, url: nil)
        let a = try makeFile("a.md", contents: edited)
        controller.documentGotFile(a, text: edited)
        let reopened = makeController(store: store)
        reopened.open(url: a, text: edited)
        XCTAssertTrue(reopened.hasHistory)
    }

    // MARK: - With the text view

    func testOneUndoAfterLeavingRestoresTheEntryText() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let vendor = UndoManagerVendor()
        let textView = makeTextView(edited)
        textView.delegate = vendor
        controller.attach(textView)

        controller.enterHistoryMode(text: textView.string)
        XCTAssertNotNil(textView.historyDisplay)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        XCTAssertEqual(textView.string, text, "a step updates the document immediately")
        XCTAssertFalse(vendor.manager.canUndo, "steps are not undoable one by one")
        XCTAssertTrue(controller.isHistoryModeActive, "the controller's own edit is not typing")

        _ = controller.handle(.exit, text: textView.string)
        XCTAssertNil(textView.historyDisplay)
        XCTAssertEqual(textView.string, text, "the text showing when you leave is the document text")
        XCTAssertTrue(vendor.manager.canUndo)
        vendor.manager.undo()
        XCTAssertEqual(textView.string, edited, "one ⌘Z restores the entry text")
        XCTAssertFalse(vendor.manager.canUndo)
    }

    func testTypingInHistoryModeLeavesAndTypesInTheTextView() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let vendor = UndoManagerVendor()
        let textView = makeTextView(edited)
        textView.delegate = vendor
        controller.attach(textView)
        controller.enterHistoryMode(text: textView.string)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertEqual(textView.string, text + "!")
        XCTAssertTrue(controller.hasHistory, "typing after the passage keeps its history")
    }

    func testUserEditsFromTheTextViewMoveLivePassages() throws {
        let controller = makeController()
        let textView = makeTextView(text)
        controller.attach(textView)
        controller.open(url: nil, text: text)
        _ = controller.handle(.add(range(of: sentence, in: text)), text: text)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("Intro. ", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.enterHistoryMode(text: textView.string)
        XCTAssertEqual(controller.display?.passages.first?.range, range(of: sentence, in: textView.string))
    }

    // MARK: - QA script, headless

    /// The level switcher lists every level of the nested group, whichever member is selected,
    /// and clicking a level moves the selection up or down.
    func testLevelSwitcherListsTheWholeNestedGroup() throws {
        let doc = "The first sentence sits here quietly. The second sentence has a bold word inside it.\n\nA lone sentence with a single word worth keeping. Nothing else here changes.\n\nJust one lone sentence stands alone here. Another sentence follows it."
        let paragraph = "The first sentence sits here quietly. The second sentence has a bold word inside it."
        let controller = makeController()
        controller.open(url: nil, text: doc)
        _ = controller.handle(.add(range(of: paragraph, in: doc)), text: doc)
        _ = controller.handle(.add(range(of: "The second sentence has a bold word inside it.", in: doc)), text: doc)
        _ = controller.handle(.add(range(of: "bold", in: doc)), text: doc)
        _ = controller.handle(.add(range(of: "A lone sentence with a single word worth keeping.", in: doc)), text: doc)
        _ = controller.handle(.add(range(of: "single", in: doc)), text: doc)
        _ = controller.handle(.add(range(of: "Just one lone sentence stands alone here.", in: doc)), text: doc)

        controller.enterHistoryMode(text: doc)
        let passages = try XCTUnwrap(controller.display?.passages)
        XCTAssertEqual(passages.count, 6)
        func select(_ needle: String) throws {
            let r = range(of: needle, in: doc)
            let id = try XCTUnwrap(passages.first { $0.range == r }?.id, needle)
            _ = controller.handle(.select(id), text: doc)
        }

        try select("bold")
        XCTAssertEqual(controller.sidebarModel.levels, [.paragraph, .sentence, .word])
        XCTAssertEqual(controller.sidebarModel.currentLevel, .word)
        controller.selectLevel(.paragraph)
        XCTAssertEqual(controller.sidebarModel.currentLevel, .paragraph)
        controller.selectLevel(.sentence)
        XCTAssertEqual(controller.sidebarModel.currentLevel, .sentence)
        XCTAssertEqual(controller.display?.selectedPassage?.range, range(of: "The second sentence has a bold word inside it.", in: doc))

        try select("single")
        XCTAssertEqual(controller.sidebarModel.levels, [.sentence, .word])
        try select("Just one lone sentence stands alone here.")
        XCTAssertEqual(controller.sidebarModel.levels, [.sentence])
        XCTAssertFalse(HistorySidebarPresentation.showsLevelSwitcher(controller.sidebarModel.levels))
    }

    func testCRLFDocumentStepsExitsAndUndoes() throws {
        let doc = "# CRLF\r\n\r\nLine endings are Windows style in this short file.\r\n"
        let sentenceCRLF = "Line endings are Windows style in this short file."
        let controller = makeController()
        let vendor = UndoManagerVendor()
        let textView = makeTextView(doc)
        textView.delegate = vendor
        controller.attach(textView)
        controller.open(url: nil, text: doc)
        // A frozen original plus a current copy (see `attachedEditedPassage`); typing edits the copy.
        controller.recordAccepted(range: range(of: sentenceCRLF, in: doc), original: sentenceCRLF,
                                  accepted: sentenceCRLF, text: doc)
        textView.setSelectedRange(range(of: "Windows", in: doc))
        textView.insertText("DOS", replacementRange: NSRange(location: NSNotFound, length: 0))
        let edited = textView.string
        vendor.manager.removeAllActions()

        controller.enterHistoryMode(text: edited)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        _ = controller.handle(.step(1), text: textView.string)
        XCTAssertEqual(textView.string, doc)
        _ = controller.handle(.exit, text: textView.string)
        XCTAssertEqual(textView.string, doc)
        XCTAssertEqual(textView.string.components(separatedBy: "\r\n").count, 4, "every CRLF survives")
        vendor.manager.undo()
        XCTAssertEqual(textView.string, edited)
    }

    func testUndoIsUnavailableInHistoryModeAndCollapsesOnExit() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let coordinator = Coordinator(text: .constant(""), textFormat: .constant(.markdown), plainTextConversion: .constant(nil))
        coordinator.currentTabID = UUID()
        let textView = makeTextView(text)
        textView.delegate = coordinator
        let real = try XCTUnwrap(coordinator.undoManager(for: textView))
        // A pre-session edit, in entry coordinates, sits on the real stack.
        textView.setSelectedRange(range(of: "beta", in: text))
        textView.insertText("BETA", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(textView.string, edited)
        // The run loop would close this event's undo group; there is none here.
        if real.groupingLevel > 0 { real.endUndoGrouping() }
        XCTAssertTrue(real.canUndo)
        controller.attach(textView)

        controller.enterHistoryMode(text: textView.string)
        let standIn = try XCTUnwrap(coordinator.undoManager(for: textView))
        XCTAssertFalse(standIn === real)
        XCTAssertFalse(standIn.canUndo, "⌘Z is unavailable while History mode shows other versions")
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        XCTAssertFalse(standIn.canUndo)

        real.beginUndoGrouping()  // the Esc key's event group
        _ = controller.handle(.exit, text: textView.string)
        real.endUndoGrouping()
        XCTAssertTrue(coordinator.undoManager(for: textView) === real)
        real.undo()
        XCTAssertEqual(textView.string, edited, "the session is one step")
        real.undo()
        XCTAssertEqual(textView.string, text, "and the pre-session edit is still undoable")
    }

    func testUndoAfterLeavingKeepsEveryVersionsText() throws {
        let (controller, edited) = controllerWithEditedPassage()
        let vendor = UndoManagerVendor()
        let textView = makeTextView(edited)
        textView.delegate = vendor
        controller.attach(textView)
        controller.enterHistoryMode(text: textView.string)
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        _ = controller.handle(.exit, text: textView.string)

        vendor.manager.undo()
        XCTAssertEqual(textView.string, edited)
        controller.enterHistoryMode(text: textView.string)
        _ = controller.handle(.select(try XCTUnwrap(controller.display?.passages.first?.id)), text: textView.string)
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), ["Alpha beta gamma delta.", "Alpha BETA gamma delta."],
                       "undo must not write the restored text over the version that was current at exit")
        XCTAssertEqual(controller.sidebarModel.versions.map(\.isCurrent), [false, true])
        _ = controller.handle(.exit, text: textView.string)

        vendor.manager.redo()
        XCTAssertEqual(textView.string, text)
        controller.enterHistoryMode(text: textView.string)
        _ = controller.handle(.select(try XCTUnwrap(controller.display?.passages.first?.id)), text: textView.string)
        XCTAssertEqual(controller.sidebarModel.versions.map(\.text), ["Alpha beta gamma delta.", "Alpha BETA gamma delta."])
        XCTAssertEqual(controller.sidebarModel.versions.map(\.isCurrent), [true, false])
    }

    // MARK: - Review fixes

    func testEnteringReportsWhetherHistoryModeStarted() {
        let controller = makeController()
        controller.open(url: nil, text: text)
        XCTAssertFalse(controller.enterHistoryMode(text: text))
        let (withHistory, edited) = controllerWithEditedPassage()
        XCTAssertTrue(withHistory.enterHistoryMode(text: edited))
    }

    func testDeclinedHistoryTabReturnsToThePreviousTab() {
        XCTAssertEqual(OutlineSidebarTab.tabAfterSelecting(.history, accepted: false, previous: .files), .files)
        XCTAssertEqual(OutlineSidebarTab.tabAfterSelecting(.history, accepted: false, previous: nil), .outline)
        XCTAssertEqual(OutlineSidebarTab.tabAfterSelecting(.history, accepted: true, previous: .files), .history)
        XCTAssertEqual(OutlineSidebarTab.tabAfterSelecting(.files, accepted: true, previous: nil), .files)
    }

    /// Read-mode checkbox toggles and image reconnects write the binding, not the text view.
    func testUnreportedBindingWriteIsReFoundAfterInvalidation() throws {
        let doc = "- [ ] task\n\n" + text
        let controller = makeController()
        controller.open(url: nil, text: doc)
        _ = controller.handle(.add(range(of: sentence, in: doc)), text: doc)
        let toggled = "- [x] task done\n\n" + text
        controller.noteWholeTextReplacement()
        XCTAssertTrue(controller.enterHistoryMode(text: toggled))
        XCTAssertEqual(controller.display?.passages.first?.range, range(of: sentence, in: toggled))
    }

    func testDirectoryMoveFollowsTheOpenFile() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let (controller, edited) = controllerWithEditedPassage(store: store, url: file)

        let renamed = directory.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        controller.directoryMoved(from: folder, to: renamed)
        let moved = renamed.appendingPathComponent("a.md")
        XCTAssertEqual(controller.url.map(FileIdentity.key(for:)), FileIdentity.key(for: moved))
        let reopened = makeController(store: store)
        reopened.open(url: moved, text: edited)
        XCTAssertTrue(reopened.hasHistory)
    }
    // MARK: - Final review fixes

    private func grouped(_ manager: UndoManager, _ body: () -> Void) {
        manager.beginUndoGrouping()
        body()
        manager.endUndoGrouping()
    }

    /// A text view on its own undo stack, explicit groups (no run loop to close them), with each
    /// passage (default `sentence`) holding its text twice — a frozen version plus a current copy —
    /// so the caller's typing gives it a second, distinct version. Add to History now stores only
    /// the original, so the copy is recorded as an accepted change of identical text (the engine
    /// keeps an accepted version even when it equals the one before it).
    private func attachedEditedPassage(store: PassageHistoryPersisting, url: URL?, doc: String? = nil,
                                       passages: [String]? = nil) -> (DocumentHistoryController, LineformTextView, UndoManager) {
        let doc = doc ?? text
        let controller = makeController(store: store)
        let vendor = UndoManagerVendor()
        vendor.manager.groupsByEvent = false
        let textView = makeTextView(doc)
        textView.delegate = vendor
        objc_setAssociatedObject(textView, "vendor", vendor, .OBJC_ASSOCIATION_RETAIN)
        controller.attach(textView)
        controller.open(url: url, text: doc)
        for needle in passages ?? [sentence] {
            controller.recordAccepted(range: range(of: needle, in: textView.string), original: needle,
                                      accepted: needle, text: textView.string)
        }
        return (controller, textView, vendor.manager)
    }

    private func typeInView(_ textView: LineformTextView, _ manager: UndoManager, replacing old: String, with new: String) {
        textView.setSelectedRange(range(of: old, in: textView.string))
        grouped(manager) { textView.insertText(new, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        textView.breakUndoCoalescing()
    }

    private func versionTexts(_ controller: DocumentHistoryController, at needle: String, in string: String) throws -> [String] {
        XCTAssertTrue(controller.enterHistoryMode(text: string), "History mode needs a passage")
        let r = range(of: needle, in: string)
        let id = try XCTUnwrap(controller.display?.passages.first { $0.range == r }?.id, needle)
        _ = controller.handle(.select(id), text: string)
        let texts = controller.sidebarModel.versions.map(\.text)
        _ = controller.handle(.exit, text: string)
        return texts
    }

    /// The focused passage's counter reserves layout space through storage ATTRIBUTES only:
    /// enter → focus → exit leaves the text, the file, the dirty state (no text-change
    /// notifications reach the document binding) and the undo stack exactly as they were.
    func testEnterFocusExitNeverChangesTheDocument() throws {
        final class Delegate: NSObject, NSTextViewDelegate {
            let manager: UndoManager
            var textChanges = 0
            override init() { manager = UndoManager(); manager.groupsByEvent = false; super.init() }
            func undoManager(for view: NSTextView) -> UndoManager? { manager }
            func textDidChange(_ notification: Notification) { textChanges += 1 }
        }
        let a = try makeFile("a.md", contents: text)
        let bytes = try Data(contentsOf: a)
        let controller = makeController(store: NullPassageHistoryStore())
        let delegate = Delegate()
        let textView = makeTextView(text)
        textView.delegate = delegate
        controller.attach(textView)
        controller.open(url: a, text: text)
        // Two versions, so focusing it shows (and reserves room for) a counter: a one-version
        // passage shows none (2026-11-14).
        controller.recordAccepted(range: range(of: sentence, in: textView.string), original: "Alpha beta.",
                                  accepted: sentence, text: textView.string)
        textView.setSelectedRange(range(of: "beta", in: textView.string))
        delegate.manager.beginUndoGrouping()
        textView.insertText("BETA", replacementRange: NSRange(location: NSNotFound, length: 0))
        delegate.manager.endUndoGrouping()
        delegate.manager.removeAllActions()
        delegate.textChanges = 0
        let string = textView.string
        let storage = try XCTUnwrap(textView.textStorage)
        let kerns = (0..<storage.length).map { storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber }

        XCTAssertTrue(controller.enterHistoryMode(text: textView.string))
        let id = try XCTUnwrap(controller.display?.passages.first?.id)
        _ = controller.handle(.select(id), text: textView.string)
        XCTAssertNotNil(controller.display?.counter)
        XCTAssertFalse(HistoryCounterSpacing.spacedCharacters(in: storage).isEmpty, "focus reserved the counter's room")
        _ = controller.handle(.exit, text: textView.string)

        XCTAssertEqual(textView.string, string)
        XCTAssertEqual(try Data(contentsOf: a), bytes)
        XCTAssertEqual(delegate.textChanges, 0, "no text change reached the document")
        XCTAssertFalse(delegate.manager.canUndo, "History mode registered no undo")
        XCTAssertTrue(HistoryCounterSpacing.spacedCharacters(in: storage).isEmpty)
        XCTAssertEqual((0..<storage.length).map { storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber }, kerns,
                       "the reserved space is removed exactly")
    }

    /// A session that deleted a version registers no version undo, so live ranges survive into
    /// the exit's ⌘Z. The collapse here (entry → exit) removes one of three identical sentences;
    /// placed prefix-first ({22,11}), its undo is an insert at {22,0} that left C on {11,10} —
    /// the identical SECOND sentence (true C is {22,10}). Dropped is fine; retargeted never is.
    func testExitAfterDeletingVersionThenUndoNeverRetargetsPassage() throws {
        let doc = "Keep this. Keep that. End here now."
        let (controller, textView, manager) = attachedEditedPassage(
            store: NullPassageHistoryStore(), url: nil, doc: doc,
            passages: ["Keep this.", "Keep that.", "End here now."])
        typeInView(textView, manager, replacing: "that", with: "this")
        textView.setSelectedRange(NSRange(location: 0, length: 10))
        grouped(manager) { textView.insertText("Keep this. Keep this.", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        textView.breakUndoCoalescing()
        typeInView(textView, manager, replacing: "now", with: "soon")
        let entry = textView.string
        XCTAssertEqual(entry, "Keep this. Keep this. Keep this. End here soon.")

        XCTAssertTrue(controller.enterHistoryMode(text: entry))
        let passages = try XCTUnwrap(controller.display?.passages)
        let b = try XCTUnwrap(passages.first { $0.range == NSRange(location: 0, length: 21) }?.id, "B")
        let c = try XCTUnwrap(passages.first { $0.range == NSRange(location: 22, length: 10) }?.id, "C")
        let d = try XCTUnwrap(passages.first { $0.range == NSRange(location: 33, length: 14) }?.id, "D")
        _ = controller.handle(.select(d), text: textView.string)
        _ = controller.deleteVersion(0, text: textView.string)
        _ = controller.handle(.select(b), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        XCTAssertEqual(textView.string, "Keep this. Keep this. End here soon.")
        grouped(manager) { _ = controller.handle(.exit, text: textView.string) }

        manager.undo()
        XCTAssertEqual(textView.string, entry)
        if controller.enterHistoryMode(text: textView.string),
           let located = controller.display?.passages.first(where: { $0.id == c }) {
            XCTAssertEqual(located.range, NSRange(location: 22, length: 10), "C may only stay on its own sentence")
        }
    }

    /// C1: ⌘B, then a save (persist re-locates), then ⌘Z. NSTextView undoes the formatting as one
    /// document-spanning edit; reported as such it straddled every passage and dropped them all.
    func testFormattingThenSaveThenUndoKeepsUnrelatedPassages() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let (controller, textView, manager) = attachedEditedPassage(store: store, url: a)
        typeInView(textView, manager, replacing: "beta", with: "BETA")

        textView.setSelectedRange(range(of: "theta", in: textView.string))
        grouped(manager) { textView.toggleBoldMarkdown(nil) }
        XCTAssertTrue(textView.string.contains("**theta**"))
        controller.documentSaved(text: textView.string)
        manager.undo()
        XCTAssertFalse(textView.string.contains("**"))
        controller.documentSaved(text: textView.string)

        XCTAssertTrue(controller.hasHistory, "undoing formatting elsewhere must not drop the passage")
        XCTAssertEqual(try versionTexts(controller, at: "Alpha BETA gamma delta.", in: textView.string),
                       ["Alpha beta gamma delta.", "Alpha BETA gamma delta."])
    }

    /// C1: Find & Replace (one Replace) → save → undo.
    func testFindReplaceThenSaveThenUndoKeepsUnrelatedPassages() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let (controller, textView, manager) = attachedEditedPassage(store: store, url: a)
        typeInView(textView, manager, replacing: "beta", with: "BETA")

        let replaced = textView.string.replacingOccurrences(of: "zeta", with: "ZETA")
        grouped(manager) {
            textView.applyExternalReplacement(MarkdownEdit(text: replaced, selectedRange: range(of: "ZETA", in: replaced)))
        }
        controller.documentSaved(text: textView.string)
        manager.undo()
        XCTAssertTrue(textView.string.contains("zeta"))
        controller.documentSaved(text: textView.string)

        XCTAssertTrue(controller.hasHistory)
        XCTAssertEqual(try versionTexts(controller, at: "Alpha BETA gamma delta.", in: textView.string),
                       ["Alpha beta gamma delta.", "Alpha BETA gamma delta."])
    }

    /// C1: leave History mode having stepped two passages (the collapse spans both), undo, save,
    /// redo. Redo replayed the text before the versions; the collapse straddled both passages.
    func testExitUndoSaveRedoKeepsHistoryAndTheExitVersions() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let second = "Epsilon zeta eta theta."
        let (controller, textView, manager) = attachedEditedPassage(store: store, url: a, passages: [sentence, second])
        typeInView(textView, manager, replacing: "beta", with: "BETA")
        typeInView(textView, manager, replacing: "zeta", with: "ZETA")
        let edited = textView.string

        XCTAssertTrue(controller.enterHistoryMode(text: textView.string))
        _ = controller.handle(.moveSelection(1), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        _ = controller.handle(.moveSelection(1), text: textView.string)
        _ = controller.handle(.step(-1), text: textView.string)
        XCTAssertEqual(textView.string, text)
        grouped(manager) { _ = controller.handle(.exit, text: textView.string) }

        manager.undo()
        XCTAssertEqual(textView.string, edited)
        controller.documentSaved(text: textView.string)
        manager.redo()
        XCTAssertEqual(textView.string, text)
        controller.documentSaved(text: textView.string)

        XCTAssertTrue(controller.hasHistory, "redo must not drop the passages the collapse spans")
        XCTAssertTrue(controller.enterHistoryMode(text: textView.string))
        XCTAssertEqual(controller.display?.passages.count, 2)
        for needle in [sentence, second] {
            let r = range(of: needle, in: textView.string)
            let id = try XCTUnwrap(controller.display?.passages.first { $0.range == r }?.id, needle)
            _ = controller.handle(.select(id), text: textView.string)
            XCTAssertEqual(controller.sidebarModel.versions.map(\.isCurrent), [true, false],
                           "the version current at exit is current again after redo")
        }
    }

    /// I2: quitting persists what was typed into a passage since the last save.
    func testWillTerminatePersistsTypedPassageText() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let center = NotificationCenter()
        let controller = DocumentHistoryController(store: store, now: { [fixedDate] in fixedDate }, notificationCenter: center)
        let textView = makeTextView(text)
        controller.attach(textView)
        controller.open(url: a, text: text)
        // A frozen original plus a current copy (see `attachedEditedPassage`): a one-version
        // passage is discarded on load, so the stored passage needs a second version.
        controller.recordAccepted(range: range(of: sentence, in: text), original: sentence, accepted: sentence, text: text)
        textView.setSelectedRange(range(of: "beta", in: textView.string))
        textView.insertText("BETA", replacementRange: NSRange(location: NSNotFound, length: 0))

        center.post(name: NSApplication.willTerminateNotification, object: NSApp)

        let reopened = makeController(store: store)
        reopened.open(url: a, text: textView.string)
        XCTAssertTrue(reopened.hasHistory, "the typed current version reached the store before quit")
    }

    /// I1: pruning walks every stored document's bookmark (network volumes, unplugged drives);
    /// it runs off the main thread and opening a document never waits for it.
    func testPruneRunsOffTheMainThreadAndOpenDoesNotWait() throws {
        final class SlowPruneStore: PassageHistoryPersisting {
            let started = XCTestExpectation(description: "prune ran")
            let release = DispatchSemaphore(value: 0)
            var prunedOnMain: Bool?
            func load(for url: URL) -> DocumentHistory { DocumentHistory(passages: []) }
            func save(_ history: DocumentHistory, for url: URL) {}
            func retarget(from old: URL, to new: URL) {}
            func retargetDirectory(from oldDir: URL, to newDir: URL) {}
            func prune(now: Date) {
                prunedOnMain = Thread.isMainThread
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            func clearAll() {}
        }
        let store = SlowPruneStore()
        let controller = makeController(store: store)
        let opened = Date()
        controller.open(url: directory.appendingPathComponent("a.md"), text: text)
        XCTAssertLessThan(Date().timeIntervalSince(opened), 1, "open must not wait for prune")
        store.release.signal()
        wait(for: [store.started], timeout: 5)
        XCTAssertEqual(store.prunedOnMain, false)
    }
    /// Prune is asynchronous now, so a document opened before it gets there applies the 30-day
    /// rule itself — otherwise its next save writes the stale passages back.
    func testOpenDropsPassagesUntouchedFor30Days() throws {
        let store = FilePassageHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md", contents: text)
        let old = fixedDate.addingTimeInterval(-FilePassageHistoryStore.staleInterval - 60)
        let staleHistory = DocumentHistory(passages: [HistoryPassage(
            id: UUID(), level: .sentence,
            versions: [HistoryVersion(text: "Alpha earlier words.", author: .you, createdAt: old),
                       HistoryVersion(text: sentence, author: .you, createdAt: old)],
            currentIndex: 1, parentID: nil, parentVersionIndex: nil,
            contextBefore: "", contextAfter: " Epsilon zeta eta theta.", lastTouched: old)])
        store.save(staleHistory, for: a)

        let controller = makeController(store: store)
        controller.open(url: a, text: text)
        XCTAssertFalse(controller.hasHistory, "a passage untouched for 30 days is gone at open")
    }
}
