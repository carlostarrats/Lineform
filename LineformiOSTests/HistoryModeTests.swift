import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// History mode on screen (D10): Menu ▸ History, Replace With… (the selection row's), the read-only
/// editor with its washes, taps and hardware keys, the card's model, Settings ▸ Clear History,
/// the strings, and the store that is not even made at launch. Real `LineformTextView`s in a
/// window; every store is in memory or in a temporary folder.
@MainActor
final class HistoryModeTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let text = "Alpha beta gamma delta. Epsilon zeta eta theta."
    private let sentence = "Alpha beta gamma delta."
    private var directory: URL!
    private var window: UIWindow?
    private var suites: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Menu ▸ History

    func testHistorySectionHiddenWithoutHistoryAndShownWithIt() throws {
        XCTAssertFalse(MenuSection.visible(hasHistory: false).contains(.history))
        XCTAssertEqual(MenuSection.visible(hasHistory: true), [.files, .outline, .basics, .search, .history, .document, .settings],
                       "after Search, before Document")
        XCTAssertFalse(MenuSection.history.isPage, "choosing it enters History mode; it is never a page")
        XCTAssertTrue(MenuSection.allCases.filter { $0 != .history }.allSatisfy(\.isPage))
        // pinned-en: the Mac's string.
        XCTAssertEqual(MenuSection.history.title, "History")

        // The controller says when: only once a version is kept.
        let (controller, textView) = makeEditor(text)
        XCTAssertFalse(controller.hasHistory)
        XCTAssertFalse(MenuSection.visible(hasHistory: controller.hasHistory).contains(.history))
        try keepReplacement(in: textView, controller: controller, of: sentence, with: "Alpha BETA gamma delta.")
        XCTAssertTrue(controller.hasHistory)
        XCTAssertTrue(MenuSection.visible(hasHistory: controller.hasHistory).contains(.history))
    }

    func testChoosingHistoryForcesWriteAndEntersHistoryMode() throws {
        let (controller, textView) = makeEditor(text)
        try keepReplacement(in: textView, controller: controller, of: sentence, with: "Alpha BETA gamma delta.")
        XCTAssertFalse(controller.isHistoryModeActive)

        var steps: [String] = []
        let entered = HistoryEntry.enterFromMenu(
            history: controller,
            text: { textView.text },
            dismissMenu: { steps.append("dismiss") },
            endAI: { steps.append("endAI") },
            switchToWrite: { steps.append("write") }
        )
        XCTAssertTrue(entered)
        XCTAssertEqual(steps, ["dismiss", "endAI", "write"],
                       "the sheet closes, AI ends, and Write comes up before History mode opens")
        XCTAssertTrue(controller.isHistoryModeActive)
        XCTAssertNil(controller.selectedPassageID, "the overview: the card says to tap a passage")
        XCTAssertFalse(textView.isEditable, "History mode is read-only")
        XCTAssertFalse(HistoryCardModel(controller: controller).hasSelection)
    }

    // MARK: - Replace With…

    func testReplaceWithAddsPassageAndOpensReplacementField() throws {
        let (controller, textView) = makeEditor(text)
        let selection = range(of: sentence, in: text)
        textView.selectedRange = selection

        // The selection row's button (its one entry point; the edit menu carries none).
        XCTAssertTrue(textView.offersReplaceWith(for: selection))
        // pinned-en: the Mac's string.
        XCTAssertEqual(SelectionRowItem.replaceWith.title, "Replace With…")
        XCTAssertTrue(MarkdownEditor.Coordinator.leadingMenuElements(for: textView, range: selection).isEmpty)

        XCTAssertTrue(textView.performReplaceWith(selection))
        XCTAssertTrue(controller.isHistoryModeActive)
        let id = try XCTUnwrap(controller.selectedPassageID, "History opens on the new passage")
        XCTAssertEqual(controller.pendingReplacementFieldID, id)
        var model = HistoryCardModel(controller: controller)
        XCTAssertTrue(model.opensReplacementField, "the card opens Type a replacement at once")
        XCTAssertEqual(model.rows.map(\.text), [sentence], "the selection is kept as the original")
        XCTAssertEqual(model.rows.first?.symbolName, "doc.text")
        XCTAssertTrue(model.rows.first?.isCurrent == true)

        controller.replacementFieldDidOpen()
        model = HistoryCardModel(controller: controller)
        XCTAssertFalse(model.opensReplacementField, "the request is spent")

        // Return in the field: a new current version, in the document at once.
        XCTAssertNotNil(controller.addReplacement("Alpha BETA gamma delta.", text: textView.text, for: id))
        XCTAssertEqual(textView.text, "Alpha BETA gamma delta. Epsilon zeta eta theta.")
        model = HistoryCardModel(controller: controller)
        XCTAssertEqual(model.rows.map(\.symbolName), ["doc.text", "pencil"])
        XCTAssertEqual(model.rows.map(\.isCurrent), [false, true])
    }

    func testReplaceWithNotOfferedForMultiLineOrCodeSelection() {
        let doc = "Intro line.\n\n```\ncode here\n```\n\nLast line."
        // The view holds its controller weakly: keep it alive.
        let (controller, textView) = makeEditor(doc)
        XCTAssertTrue(textView.offersReplaceWith(for: range(of: "Intro line.", in: doc)))
        XCTAssertFalse(textView.offersReplaceWith(for: range(of: "Intro line.\n\n```", in: doc)), "never across lines")
        XCTAssertFalse(textView.offersReplaceWith(for: range(of: "code here", in: doc)), "never inside fenced code")
        XCTAssertFalse(textView.offersReplaceWith(for: NSRange(location: 3, length: 0)), "never on a caret")

        XCTAssertTrue(textView.performReplaceWith(range(of: "Last line.", in: doc)))
        XCTAssertTrue(controller.isHistoryModeActive)
        XCTAssertFalse(textView.offersReplaceWith(for: range(of: "Intro line.", in: doc)), "not in History mode")
    }

    // MARK: - The editor in History mode

    func testTapSelectsInnermostPassage() throws {
        let (controller, textView) = try makeNestedHistory()
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        textView.layoutIfNeeded()
        let word = try XCTUnwrap(controller.located.first { $0.level == .word })
        let outer = try XCTUnwrap(controller.located.first { $0.level == .sentence })

        textView.selectHistoryPassage(at: point(ofCharacterAt: word.range.location + 1, in: textView))
        XCTAssertEqual(controller.selectedPassageID, word.id, "a tap on the word inside the sentence selects the word")

        textView.selectHistoryPassage(at: point(ofCharacterAt: outer.range.location + 1, in: textView))
        XCTAssertEqual(controller.selectedPassageID, outer.id, "outside the word, the sentence")

        let epsilon = (textView.text as NSString).range(of: "Epsilon").location
        textView.selectHistoryPassage(at: point(ofCharacterAt: epsilon + 2, in: textView))
        XCTAssertNil(controller.selectedPassageID, "ordinary text goes back to the overview")
        XCTAssertTrue(controller.isHistoryModeActive, "History stays on")

        XCTAssertEqual(HistoryWashDisplay(passages: controller.located, selectedID: nil)
            .innermostPassage(containing: word.range.location)?.id, word.id)
        XCTAssertTrue(textView.historyTapRecognizer().isEnabled)
    }

    func testEditorIsReadOnlyInHistoryModeAndTypingExits() throws {
        let (controller, textView) = makeEditor(text)
        try keepReplacement(in: textView, controller: controller, of: sentence, with: "Alpha BETA gamma delta.")
        XCTAssertTrue(textView.isEditable)
        XCTAssertFalse(textView.historyTapRecognizer().isEnabled)

        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        XCTAssertFalse(textView.isEditable, "read-only: no keyboard, taps select")
        XCTAssertTrue(textView.isShowingHistoryMode)
        XCTAssertTrue(textView.historyTapRecognizer().isEnabled)
        XCTAssertEqual(textView.contentInset.bottom, LineformTextView.historyCardClearance, "room for the card")

        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        XCTAssertTrue(textView.typeWhileInHistoryMode("!"))
        XCTAssertFalse(controller.isHistoryModeActive, "a typed key leaves History mode")
        XCTAssertTrue(textView.isEditable)
        XCTAssertEqual(textView.contentInset.bottom, 0)
        XCTAssertEqual(textView.text, "Alpha BETA gamma delta. Epsilon zeta eta theta.!", "and then types")
        XCTAssertFalse(textView.typeWhileInHistoryMode("?"), "outside History mode it does nothing")

        // Only text a key would type counts; arrows, Esc and control keys do not.
        XCTAssertEqual(LineformTextView.historyTypedCharacters("a"), "a")
        XCTAssertEqual(LineformTextView.historyTypedCharacters("é"), "é")
        XCTAssertNil(LineformTextView.historyTypedCharacters(UIKeyCommand.inputLeftArrow))
        XCTAssertNil(LineformTextView.historyTypedCharacters(UIKeyCommand.inputEscape))
        XCTAssertNil(LineformTextView.historyTypedCharacters("\r"))
        XCTAssertNil(LineformTextView.historyTypedCharacters("\t"))
        XCTAssertNil(LineformTextView.historyTypedCharacters(""))
    }

    func testWashIsNeverInTextStorage() throws {
        let (controller, textView) = try makeNestedHistory()
        textView.layoutIfNeeded()
        let before = NSAttributedString(attributedString: textView.textStorage)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil
        ) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        textView.layoutIfNeeded()
        let wash = try XCTUnwrap(textView.historyWashView)
        XCTAssertFalse(wash.isHidden)
        XCTAssertEqual(wash.washLayers.count, controller.located.count, "one box per located passage")
        XCTAssertTrue(wash.washLayers.allSatisfy { $0.path != nil && $0.fillColor != nil })
        let overview = wash.washLayers.map(\.fillColor)

        controller.select(controller.located.first { $0.level == .word }?.id)
        textView.layoutIfNeeded()
        XCTAssertNotEqual(wash.washLayers.map(\.fillColor), overview, "the selected passage is drawn stronger")
        let theme = Theme.theme(for: textView.profile)
        XCTAssertTrue(wash.washLayers.contains { $0.fillColor == HistoryPalette.selectedFill(for: theme).cgColor })

        XCTAssertEqual(edits, 0, "no storage edit — attributes included — while History mode draws")
        XCTAssertTrue(textView.textStorage.isEqual(to: before), "the washes are layers, never text attributes")
        XCTAssertTrue(wash.subviews.isEmpty && !wash.isUserInteractionEnabled && wash.accessibilityElementsHidden)
        let textIndex = try XCTUnwrap(textView.subviews.firstIndex { String(describing: type(of: $0)).contains("TextContainer") })
        let washIndex = try XCTUnwrap(textView.subviews.firstIndex(of: wash))
        XCTAssertLessThan(washIndex, textIndex, "the washes sit behind the text")

        controller.exitHistoryMode(text: textView.text)
        textView.layoutIfNeeded()
        XCTAssertTrue(wash.washLayers.isEmpty, "normal writing draws nothing")
        XCTAssertTrue(wash.isHidden)
    }

    func testLevelSwitcherOnlyWithMoreThanOneLevel() throws {
        // One level: no switcher.
        let (single, singleView) = makeEditor(text)
        try keepReplacement(in: singleView, controller: single, of: sentence, with: "Alpha BETA gamma delta.")
        XCTAssertTrue(single.enterHistoryMode(text: singleView.text))
        single.select(single.located.first?.id)
        let one = HistoryCardModel(controller: single)
        XCTAssertTrue(one.hasSelection)
        XCTAssertEqual(one.levels, [.sentence])
        XCTAssertFalse(one.showsLevelSwitcher)

        // A word kept inside a sentence: both levels, and the switcher moves between them.
        let (nested, nestedView) = try makeNestedHistory()
        XCTAssertTrue(nested.enterHistoryMode(text: nestedView.text))
        let word = try XCTUnwrap(nested.located.first { $0.level == .word })
        nested.select(word.id)
        var model = HistoryCardModel(controller: nested)
        XCTAssertEqual(model.levels, [.sentence, .word])
        XCTAssertTrue(model.showsLevelSwitcher)
        XCTAssertEqual(model.currentLevel, .word)
        nested.selectLevel(.sentence)
        model = HistoryCardModel(controller: nested)
        XCTAssertEqual(model.currentLevel, .sentence)

        XCTAssertFalse(HistoryCardModel().showsLevelSwitcher, "nothing selected, nothing to switch")
    }

    func testHardwareArrowsStepAndEscapeExits() throws {
        let (controller, textView) = makeEditor(text)
        try keepReplacement(in: textView, controller: controller, of: sentence, with: "Alpha BETA gamma delta.")
        let inputs = { Set((textView.keyCommands ?? []).filter { $0.modifierFlags.isEmpty }.compactMap(\.input)) }
        XCTAssertFalse(inputs().contains(UIKeyCommand.inputEscape), "no History keys in normal writing")

        XCTAssertTrue(controller.enterHistoryMode(text: textView.text))
        XCTAssertTrue(inputs().isSuperset(of: [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputEscape]))
        controller.select(controller.located.first?.id)
        // pinned-en: the Mac's announcement.
        XCTAssertEqual(HistoryCardModel(controller: controller).announcement, "Sentence, version 2 of 2")

        perform(UIKeyCommand.inputLeftArrow, on: textView)
        XCTAssertEqual(textView.text, text, "← shows the previous version")
        XCTAssertEqual(HistoryCardModel(controller: controller).announcement, "Sentence, version 1 of 2",
                       "VoiceOver hears the new version")
        perform(UIKeyCommand.inputRightArrow, on: textView)
        XCTAssertEqual(textView.text, "Alpha BETA gamma delta. Epsilon zeta eta theta.")

        perform(UIKeyCommand.inputEscape, on: textView)
        XCTAssertTrue(controller.isHistoryModeActive, "Esc first deselects")
        XCTAssertNil(controller.selectedPassageID)
        perform(UIKeyCommand.inputEscape, on: textView)
        XCTAssertFalse(controller.isHistoryModeActive, "then leaves")
        XCTAssertTrue(textView.isEditable)
        XCTAssertFalse(inputs().contains(UIKeyCommand.inputEscape))
    }

    // MARK: - Settings ▸ Clear History

    func testClearHistoryRowClearsStoreAndReloads() throws {
        let store = MemoryHistoryStore()
        let center = NotificationCenter()
        let url = directory.appendingPathComponent("a.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let (controller, textView) = makeEditor(text, store: store, center: center)
        controller.open(url: url, text: text)
        try keepReplacement(in: textView, controller: controller, of: sentence, with: "Alpha BETA gamma delta.")
        XCTAssertFalse(store.load(for: url).isEmpty)
        XCTAssertTrue(controller.enterHistoryMode(text: textView.text), "cleared while History mode is up")

        SettingsSection.clearHistory(store: store, center: center)

        XCTAssertTrue(store.calls.contains("clearAll"))
        XCTAssertTrue(store.load(for: url).isEmpty)
        XCTAssertFalse(controller.hasHistory, "the open document re-read the empty store")
        XCTAssertFalse(controller.isHistoryModeActive)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(store.load(for: url).isEmpty, "leaving History mode did not write the old history back")

        // pinned-en: the Mac's copy, and the row joins the list.
        XCTAssertEqual(SettingsSection.rowTitles, [
            "Automatic Dark Mode", "Show iCloud in Files", "Check spelling while typing", "In-app notifications", "Clear History",
            "Check for Updates…",
        ])
        XCTAssertEqual(SettingsSection.clearHistoryButtonTitle, "Clear…")
        XCTAssertEqual(SettingsSection.clearHistoryConfirmTitle, "Clear all history?")
    }

    // MARK: - Strings

    func testHistoryStringsAreLocalized() throws {
        let keys = [
            "History", "Replace With…", "Type a replacement", "Tap a highlighted passage to see its versions.",
            "Delete from History", "Add", "Done",
            "%@, by you, version %lld of %lld", "%@, by AI, version %lld of %lld",
            "%@, original, version %lld of %lld", "%@, version %lld of %lld",
            "Clear History", "Clear…", "Clear all history?", "Cancel",
            "Removes saved versions for every document. Your files are not changed.",
            "Saved versions for every document will be removed. This can't be undone. Your files are not changed.",
        ]
        // pinned-en: every shown string is one of these keys.
        XCTAssertEqual(HistoryCardModel.title, "History")
        XCTAssertEqual(HistoryCardModel.replacementPlaceholder, "Type a replacement")
        XCTAssertEqual(HistoryCardModel.emptySelectionText, "Tap a highlighted passage to see its versions.")
        XCTAssertEqual(HistoryCardModel.deleteVersionTitle, "Delete from History")
        XCTAssertEqual(HistoryCardModel.addTitle, "Add")
        XCTAssertEqual(HistoryCardModel.doneTitle, "Done")
        XCTAssertEqual(SettingsSection.clearHistoryNote, keys[15])
        XCTAssertEqual(SettingsSection.clearHistoryConfirmMessage, keys[16])
        let row = HistoryCardRow(id: 1, text: "Tea", author: .ai, isCurrent: false)
        XCTAssertEqual(row.accessibilityLabel(position: 2, of: 3), "Tea, by AI, version 2 of 3")

        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LineformiOS/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in keys { XCTAssertNotNil(strings[key], "\(key) missing from the iPhone catalog") }

        let missing = "\u{0}missing"
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "No \(language).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                XCTAssertNotEqual(value, missing, "\(key) missing in \(language)")
                XCTAssertNotEqual(value, key, "\(key) untranslated in \(language)")
            }
        }
    }

    // MARK: - Launch

    /// Building the app's document at launch makes no History store, and the device name is not
    /// read (or made) until a document in the Lineform iCloud folder first uses History.
    func testTheLiveDocumentMakesNoHistoryStoreAtLaunch() throws {
        final class CountingDeviceIDs: HistoryDeviceIDStoring {
            var reads = 0
            var stored: String?
            func readDeviceID() -> HistoryDeviceIDRead {
                reads += 1
                return stored.map { .found($0) } ?? .notFound
            }
            func writeDeviceID(_ id: String) -> Bool { stored = id; return true }
        }
        let suite = "HistoryModeTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let ids = CountingDeviceIDs()
        let store = PhoneHistoryController.makeLiveStore(home: directory, defaults: defaults, deviceIDStorage: ids)

        let document = OpenDocument.live(historyStore: store)
        XCTAssertNotNil(document.history)
        XCTAssertFalse(store.isMade, "nothing History-related runs at launch")
        XCTAssertEqual(ids.reads, 0, "the device name is not touched")

        // First use makes it, once; a document outside the iCloud folder never needs the name.
        let url = directory.appendingPathComponent("first.md")
        XCTAssertTrue(store.load(for: url).isEmpty)
        XCTAssertTrue(store.isMade)
        XCTAssertTrue(store.load(for: url).isEmpty)
        XCTAssertEqual(ids.reads, 0)
        XCTAssertNil(defaults.object(forKey: "LineformHistoryDeviceID.v1"), "never kept in user defaults")
        XCTAssertTrue(PhoneHistoryController.sharedStore is LazyHistoryStore)
    }

    // MARK: - Helpers

    private func makeEditor(
        _ string: String,
        store: PassageHistoryPersisting = MemoryHistoryStore(),
        center: NotificationCenter = NotificationCenter()
    ) -> (PhoneHistoryController, LineformTextView) {
        let date = fixedDate
        let controller = PhoneHistoryController(
            store: store, now: { date }, pruneQueue: DispatchQueue(label: "HistoryModeTests"), notificationCenter: center
        )
        controller.open(url: nil, text: string)
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText(string)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            host.view.addSubview(textView)
            window.isHidden = false
            self.window = window
        }
        controller.attach(textView)
        textView.undoManager?.removeAllActions()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        return (controller, textView)
    }

    /// Replace With… on `needle`, a replacement, and out of History mode: a two-version passage.
    private func keepReplacement(in textView: LineformTextView, controller: PhoneHistoryController,
                                 of needle: String, with replacement: String) throws {
        let found = range(of: needle, in: textView.text)
        XCTAssertTrue(textView.performReplaceWith(found))
        let id = try XCTUnwrap(controller.selectedPassageID)
        XCTAssertNotNil(controller.addReplacement(replacement, text: textView.text, for: id))
        controller.exitHistoryMode(text: textView.text)
        XCTAssertFalse(controller.isHistoryModeActive)
    }

    /// The sentence kept with a replacement, then the word "gamma" inside it kept too.
    private func makeNestedHistory() throws -> (PhoneHistoryController, LineformTextView) {
        let (controller, textView) = makeEditor(text)
        try keepReplacement(in: textView, controller: controller, of: sentence, with: "Alpha BETA gamma delta.")
        try keepReplacement(in: textView, controller: controller, of: "gamma", with: "GAMMA")
        XCTAssertEqual(textView.text, "Alpha BETA GAMMA delta. Epsilon zeta eta theta.")
        return (controller, textView)
    }

    /// The middle of the glyph for `index`, in the text view's content coordinates.
    private func point(ofCharacterAt index: Int, in textView: LineformTextView) -> CGPoint {
        let glyphs = textView.layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let box = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        return CGPoint(x: box.midX + textView.textContainerInset.left, y: box.midY + textView.textContainerInset.top)
    }

    /// Runs the History key command for `input`, as the hardware keyboard would.
    private func perform(_ input: String, on textView: LineformTextView, file: StaticString = #filePath, line: UInt = #line) {
        guard let command = (textView.keyCommands ?? []).first(where: { $0.input == input && $0.modifierFlags.isEmpty }),
              let action = command.action else {
            XCTFail("no key command for \(input)", file: file, line: line)
            return
        }
        textView.perform(action, with: command)
    }

    private func range(of needle: String, in haystack: String) -> NSRange {
        let found = (haystack as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle)")
        return found
    }
}
