import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// Spell check in the iPhone editor: `UITextChecker` over the prose of the visible window only
/// (never code, front matter, math or a link destination), drawn underlines that never reach the
/// text storage, edit-menu guesses that replace the word as one undo step, and the Writing Tools
/// protection.
@MainActor
final class SpellCheckTests: XCTestCase {
    private var boundText = ""
    private var coordinator: MarkdownEditor.Coordinator!
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        coordinator = nil
        super.tearDown()
    }

    // MARK: - What is checked

    func testMisspellingInProseIsFound() throws {
        let language = try Self.language()
        XCTAssertEqual(
            SpellCheckPass.misspelledRanges(in: "teh cat", visible: NSRange(location: 0, length: 7),
                                            language: language, checker: UITextChecker()),
            [NSRange(location: 0, length: 3)]
        )

        // Through the editor: found, drawn, and never stored.
        let textView = makeEditor("Ok teh cat")
        XCTAssertTrue(textView.runSpellCheckPass())
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [NSRange(location: 3, length: 3)])
        XCTAssertNotNil(textView.spellingUnderlineLayer().path, "the underline is drawn")
        XCTAssertEqual(textView.spellingUnderlineLayer().lineWidth, 1.5)
        XCTAssertEqual(textView.spellingUnderlineLayer().superlayer, textView.layer)
        let storage = textView.textStorage
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.underlineStyle], "the underline is never stored in the text")
            XCTAssertNil(attributes[.underlineColor])
        }

        // An edit before the word shifts its underline; one that touches the word drops it at once
        // (even one that only abuts it, since it may have changed the word).
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("A ")
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [NSRange(location: 5, length: 3)], "an edit before the word shifts it")
        textView.selectedRange = NSRange(location: 6, length: 0)
        textView.insertText("x")
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [], "an edit on the word drops its underline")
        textView.layoutIfNeeded()
        XCTAssertNil(textView.spellingUnderlineLayer().path, "and the redraw follows in the same frame")
    }

    func testCodeFenceAndInlineCodeAreSkipped() throws {
        let text = "```\nteh fense\n```\n\nUse `teh` here, and teh cat.\n"
        let ranges = SpellCheckPass.misspelledRanges(in: text, visible: NSRange(location: 0, length: (text as NSString).length),
                                                     language: try Self.language(), checker: UITextChecker())
        XCTAssertEqual(ranges, [(text as NSString).range(of: "teh cat")].map { NSRange(location: $0.location, length: 3) },
                       "only the prose misspelling is flagged, not the fence or the inline code")
    }

    func testLinkDestinationSkipped() throws {
        let text = "See [teh docs](/Users/qa/tehx/fiel.md) and ![pic](images/tehpic.png)\n"
        let ranges = SpellCheckPass.misspelledRanges(in: text, visible: NSRange(location: 0, length: (text as NSString).length),
                                                     language: try Self.language(), checker: UITextChecker())
        XCTAssertEqual(ranges, [NSRange(location: 5, length: 3)], "the link text is prose; the destinations are not")
    }

    func testFrontMatterAndMathSkipped() throws {
        let text = "---\ntitle: teh fiel\n---\n\n$$\nteh = qwz\n$$\n\nteh cat\n"
        let ranges = SpellCheckPass.misspelledRanges(in: text, visible: NSRange(location: 0, length: (text as NSString).length),
                                                     language: try Self.language(), checker: UITextChecker())
        XCTAssertEqual(ranges, [NSRange(location: (text as NSString).range(of: "teh cat").location, length: 3)])
    }

    func testNoPassDuringMarkedText() throws {
        _ = try Self.language()
        let textView = makeEditor("teh cat ")
        textView.selectedRange = NSRange(location: 8, length: 0)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(textView.markedTextRange)

        XCTAssertFalse(textView.runSpellCheckPass(), "no pass while an input method is composing")
        textView.scheduleSpellCheck()
        RunLoop.main.run(until: Date().addingTimeInterval(SpellCheckPass.typingDelay + 0.2))
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [], "the scheduled pass skips composition too")

        textView.unmarkText()
        XCTAssertTrue(textView.runSpellCheckPass())
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [NSRange(location: 0, length: 3)])
    }

    func testPassRunsAfterTypingPause() throws {
        _ = try Self.language()
        let textView = makeEditor("A clean line")
        textView.selectedRange = NSRange(location: 12, length: 0)
        textView.insertText(" teh")
        coordinator.textViewDidChange(textView)
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [], "never per keystroke")
        RunLoop.main.run(until: Date().addingTimeInterval(SpellCheckPass.typingDelay + 0.2))
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [NSRange(location: 13, length: 3)], "0.4 s after typing stops")
    }

    // MARK: - Edit menu

    func testGuessReplacesWordAsOneUndo() throws {
        _ = try Self.language()
        let textView = makeEditor("teh cat")
        XCTAssertTrue(textView.runSpellCheckPass())

        let menu = try XCTUnwrap(coordinator.textView(textView, editMenuForTextIn: NSRange(location: 1, length: 0), suggestedActions: []))
        let group = try XCTUnwrap(menu.children.first as? UIMenu)
        let titles = group.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertTrue(titles.contains("the"), "the guesses lead the menu: \(titles)")
        XCTAssertLessThanOrEqual(titles.count, SpellCheckPass.maximumGuesses + 2)
        XCTAssertEqual(Array(titles.suffix(2)), [LineformTextView.learnSpellingTitle, LineformTextView.ignoreSpellingTitle])
        XCTAssertNil(coordinator.textView(textView, editMenuForTextIn: NSRange(location: 5, length: 0), suggestedActions: []),
                     "off a misspelling the system menu is unchanged")

        let undo = try XCTUnwrap(textView.undoManager)
        undo.removeAllActions()
        XCTAssertTrue(textView.applySpellingGuess("the", replacing: NSRange(location: 0, length: 3), word: "teh"))
        XCTAssertEqual(textView.text, "the cat")
        XCTAssertEqual(boundText, "the cat", "the replacement reaches the binding, so autosave sees it")
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [], "the replaced word's underline is gone")

        undo.undo()
        XCTAssertEqual(textView.text, "teh cat", "one undo step restores the word")
        XCTAssertFalse(undo.canUndo)

        XCTAssertFalse(textView.applySpellingGuess("the", replacing: NSRange(location: 4, length: 3), word: "teh"),
                       "a stale range changes nothing")
    }

    func testIgnoreSpellingIsForThisDocument() throws {
        _ = try Self.language()
        let word = "zqxwvteh"
        let textView = makeEditor("\(word) cat")
        XCTAssertTrue(textView.runSpellCheckPass())
        XCTAssertEqual(textView.spellCheck.misspelledRanges.count, 1)
        textView.ignoreSpelling(word)
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [])
        XCTAssertTrue(textView.runSpellCheckPass())
        XCTAssertEqual(textView.spellCheck.misspelledRanges, [], "ignored for the rest of this document")

        let other = makeEditor("\(word) cat")
        XCTAssertTrue(other.runSpellCheckPass())
        XCTAssertEqual(other.spellCheck.misspelledRanges.count, 1, "another document still flags it")
    }

    // MARK: - Configuration and Writing Tools

    func testWritingToolsBehaviorIsNone() {
        let textView = LineformTextView.make(profile: .original)
        XCTAssertEqual(textView.writingToolsBehavior, .none)
        XCTAssertEqual(textView.allowedWritingToolsResultOptions, [.plainText, .list])
        XCTAssertEqual(textView.spellCheckingType, .no, "the system checker is off; the app's pass replaces it")
        XCTAssertEqual(textView.autocorrectionType, .no)
        XCTAssertEqual(textView.smartQuotesType, .no)
        XCTAssertEqual(textView.smartDashesType, .no)
        XCTAssertEqual(textView.smartInsertDeleteType, .no)
    }

    func testWritingToolsIgnoredRangesCoverCode() {
        let text = "---\ntitle: x\n---\n\nProse.\n\n```swift\nlet a = 1\n```\n"
        let textView = makeEditor(text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        let ranges = coordinator.textView(textView, writingToolsIgnoredRangesInEnclosingRange: full).map(\.rangeValue)
        XCTAssertEqual(ranges, MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: full))
        let fence = (text as NSString).range(of: "```swift\nlet a = 1\n```")
        XCTAssertTrue(ranges.contains { NSIntersectionRange($0, fence) == fence }, "the code fence is protected")
        let frontMatter = (text as NSString).range(of: "title: x")
        XCTAssertTrue(ranges.contains { NSIntersectionRange($0, frontMatter) == frontMatter }, "the front matter is protected")
        let prose = (text as NSString).range(of: "Prose.")
        XCTAssertFalse(ranges.contains { NSIntersectionRange($0, prose).length > 0 }, "prose is left to Writing Tools")
    }

    // MARK: - Performance

    /// The iPhone pass must stay scoped. Two ratios, on the Mac's 730 KB corpus with the window at
    /// the END of the document (the worst case: the region walk runs from offset 0 to the window):
    /// against the whole-document Markdown analysis it must never call
    /// (`MarkdownWritingToolsProtection.ignoredRanges`, the Mac gate's baseline), and against the
    /// same pass over the whole document. Both floors are 4×.
    func testSpellPassIsScopedRatio() throws {
        let language = try Self.language()
        let text = Self.largeDocument()
        let ns = text as NSString
        XCTAssertGreaterThan(ns.length, 700 * 1024)
        let lastLine = ns.lineRange(for: NSRange(location: ns.length - 1, length: 0))
        let checker = UITextChecker()

        _ = SpellCheckPass.misspelledRanges(in: text, visible: lastLine, language: language, checker: checker)
        _ = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: lastLine)

        let scoped = Self.bestPerCall(batches: 5, iterations: 10) {
            _ = SpellCheckPass.misspelledRanges(in: text, visible: lastLine, language: language, checker: checker)
        }
        let analysis = Self.bestPerCall(batches: 3, iterations: 3) {
            _ = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: lastLine)
        }
        let wholePass = Self.bestPerCall(batches: 1, iterations: 1) {
            _ = SpellCheckPass.misspelledRanges(in: text, visible: NSRange(location: 0, length: ns.length),
                                                language: language, checker: checker)
        }
        let analysisRatio = analysis / scoped
        let passRatio = wholePass / scoped
        print(String(format: "[perf] iPhone spell pass %.3f ms vs whole-document analysis %.3f ms (%.1f×) and whole-document pass %.1f ms (%.1f×) on %d KB",
                     scoped * 1000, analysis * 1000, analysisRatio, wholePass * 1000, passRatio, ns.length / 1024))
        XCTAssertGreaterThan(analysisRatio, 4, "a whole-document Markdown pass crept into the spell-check path")
        XCTAssertGreaterThan(passRatio, 4, "the spell pass is not scoped to the visible window")
    }

    // MARK: - Helpers

    private static func language() throws -> String {
        try XCTUnwrap(SpellCheckPass.language(primary: "en-US"), "the simulator has an English dictionary")
    }

    /// The Mac's `MarkdownSpellCheckPerformanceTests` corpus, unchanged.
    private static func largeDocument() -> String {
        var parts: [String] = ["---", "title: Large Fixture", "---", ""]
        var index = 0
        var size = 0
        while size < 730 * 1024 {
            index += 1
            let block: [String]
            switch index % 12 {
            case 0: block = ["```swift", "let isRichText = false", "func doThing() {}", "```", ""]
            case 5: block = ["$$", "a = b", "$$", ""]
            case 7: block = ["See [the docs](/Users/qa/notes/file-\(index).md) and `NSTextView`.", ""]
            case 9: block = ["## Section \(index)", ""]
            default: block = ["the quick brown fox jumps over the lazy dog writing calm markdown", ""]
            }
            parts += block
            size += block.reduce(0) { $0 + $1.count + 1 }
        }
        return parts.joined(separator: "\n")
    }

    private static func bestPerCall(batches: Int, iterations: Int, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.infinity
        for _ in 0..<batches {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { body() }
            let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            best = min(best, elapsed / TimeInterval(iterations))
        }
        return best
    }

    private func makeEditor(_ text: String) -> LineformTextView {
        boundText = text
        let binding = Binding<String>(get: { [unowned self] in boundText }, set: { [unowned self] in boundText = $0 })
        let coordinator = MarkdownEditor(text: binding, profile: .original).makeCoordinator()
        self.coordinator = coordinator
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText(text)
        textView.delegate = coordinator
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window?.isHidden = true
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            host.view.addSubview(textView)
            window.isHidden = false
            self.window = window
            textView.becomeFirstResponder()
        }
        textView.layoutIfNeeded()
        textView.undoManager?.removeAllActions()
        return textView
    }
}
