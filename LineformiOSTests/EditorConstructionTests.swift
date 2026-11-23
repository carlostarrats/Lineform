import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// UIKit builds `LineformTextView` through the `textViewUsingTextLayoutManager:` factory, and on
/// that path a stored property's default value is never set (a `let spellCheck =
/// SpellCheckPass()` read as nil and crashed). Every piece of editor state therefore has to be
/// right however the view was made. This builds the view through each path the app and UIKit use
/// and reads every one of those properties before anything else touches the view.
@MainActor
final class EditorConstructionTests: XCTestCase {
    func testFactoryPathHasEveryDefault() {
        assertFreshState(LineformTextView(usingTextLayoutManager: false), path: "init(usingTextLayoutManager:)")
    }

    func testFrameInitializerHasEveryDefault() {
        assertFreshState(LineformTextView(frame: .zero, textContainer: nil), path: "init(frame:textContainer:)")
    }

    func testCoderPathHasEveryDefault() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(LineformTextView(usingTextLayoutManager: false), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        let decoded = try XCTUnwrap(
            unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? LineformTextView,
            "the archive decodes as the editor class"
        )
        assertFreshState(decoded, path: "init?(coder:)")
    }

    /// The app's own path: `make(profile:)`, used by `MarkdownEditor.makeUIView`.
    func testMakeAppliesTheProfileAndKeepsTheRestAtDefaults() {
        let textView = LineformTextView.make(profile: .original)
        XCTAssertEqual(textView.profile, .original)
        XCTAssertTrue(textView.hasAppliedProfile, "make applies the profile")
        XCTAssertNil(textView.scrollOffsetBeforeTypewriterMode)
        XCTAssertFalse(textView.isKeyboardAnimating)
        XCTAssertFalse(textView.needsFullHighlight)
        XCTAssertNotNil(textView.lastHighlightedTokenRange, "make runs one full pass")
        XCTAssertTrue(textView.spellCheck.misspelledRanges.isEmpty)
        XCTAssertNil(textView.imageInsertionHost)
        XCTAssertNil(textView.historyController)
        XCTAssertFalse(textView.isApplyingHistoryEdit)
        XCTAssertNotNil(textView.undoManager, "outside History mode, the real undo manager")
    }

    private func assertFreshState(_ textView: LineformTextView, path: String, file: StaticString = #filePath, line: UInt = #line) {
        // Read first, before any setter runs: this is where a missing default shows.
        XCTAssertEqual(textView.profile, .original, "profile, \(path)", file: file, line: line)
        XCTAssertEqual(textView.lastLayoutSize, .zero, "lastLayoutSize, \(path)", file: file, line: line)
        XCTAssertNil(textView.readingRulerView, "readingRulerView, \(path)", file: file, line: line)
        XCTAssertNil(textView.scrollOffsetBeforeTypewriterMode, "scrollOffsetBeforeTypewriterMode, \(path)", file: file, line: line)
        XCTAssertFalse(textView.isKeyboardAnimating, "isKeyboardAnimating, \(path)", file: file, line: line)
        XCTAssertNil(textView.spellingUnderlines, "spellingUnderlines, \(path)", file: file, line: line)
        XCTAssertFalse(textView.needsSpellingUnderlineRedraw, "needsSpellingUnderlineRedraw, \(path)", file: file, line: line)
        XCTAssertNil(textView.lastHighlightedTokenRange, "lastHighlightedTokenRange, \(path)", file: file, line: line)
        XCTAssertFalse(textView.needsFullHighlight, "needsFullHighlight, \(path)", file: file, line: line)
        XCTAssertFalse(textView.hasAppliedProfile, "hasAppliedProfile, \(path)", file: file, line: line)
        XCTAssertTrue(textView.spellCheck.misspelledRanges.isEmpty, "spellCheck, \(path)", file: file, line: line)
        XCTAssertNil(textView.imageInsertionHost, "imageInsertionHost, \(path)", file: file, line: line)
        XCTAssertNil(textView.imagePasteTask, "imagePasteTask, \(path)", file: file, line: line)
        XCTAssertNil(textView.historyController, "historyController, \(path)", file: file, line: line)
        XCTAssertFalse(textView.isApplyingHistoryEdit, "isApplyingHistoryEdit, \(path)", file: file, line: line)
        XCTAssertFalse(textView.state.isReplacingWholeText, "isReplacingWholeText, \(path)", file: file, line: line)
        XCTAssertNil(textView.state.historyStandInUndoManager, "historyStandInUndoManager, \(path)", file: file, line: line)

        // And the state is writable and reads back.
        textView.profile = .original
        XCTAssertTrue(textView.hasAppliedProfile, "the first profile set applies it, \(path)", file: file, line: line)
        textView.isKeyboardAnimating = true
        XCTAssertTrue(textView.isKeyboardAnimating, file: file, line: line)
    }
}
