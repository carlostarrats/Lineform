import LineformCore
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// The iPhone's performance budgets on the 1 MB corpus (`StylingPerformanceTests.largeDocument()`),
/// always at the worst-case position: the caret, the visible window and the AI review's changes at
/// the END of the document. `testMeasureBudgets` prints one `[perf]` line per budget; the absolute
/// numbers are recorded in `docs/notes/iphone-performance-baseline.md`, never asserted (other
/// builds share the machine, and CI is 2–4× slower).
@MainActor
final class PhonePerformanceBudgetTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        StylingDrag.endAll()
        StylingPerformanceTests.spinMainQueue()
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Measurement

    func testMeasureBudgets() throws {
        let text = Self.corpus
        let length = (text as NSString).length
        XCTAssertGreaterThan(length, 1_000_000)
        let profile = ReadingProfile.original

        // (a) Launch to a typable editor.
        var launch: [TimeInterval] = []
        for _ in 0..<5 {
            var editor: LineformTextView?
            launch.append(StylingPerformanceTests.time {
                let made = LineformTextView.make(profile: profile)
                made.setDocumentText("")
                host(made)
                made.becomeFirstResponder()
                made.layoutIfNeeded()
                editor = made
            })
            editor?.resignFirstResponder()
            editor?.removeFromSuperview()
        }
        print(String(format: "[perf] (a) launch to typable editor: %.1f ms (median of 5)",
                     StylingPerformanceTests.median(launch) * 1000))

        // (b) Open 1 MB: decode, replace the text, lay out the first screen. The caret is at the
        // end (the editor held a document of the same length, caret on its last line).
        let data = MarkdownFileCodec.encode(text)
        var open: [TimeInterval] = []
        var unlaidAfterOpen = 0
        var glyphsAfterOpen = 0
        for _ in 0..<3 {
            let editor = makeEditor(text, profile: profile, caretAtEnd: true)
            editor.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
            open.append(StylingPerformanceTests.time { Self.open(data, in: editor) })
            unlaidAfterOpen = editor.layoutManager.firstUnlaidGlyphIndex()
            glyphsAfterOpen = editor.layoutManager.numberOfGlyphs
            editor.removeFromSuperview()
        }
        let layoutEditor = makeEditor(text, profile: profile, caretAtEnd: true)
        let fullLayout = StylingPerformanceTests.time {
            layoutEditor.layoutManager.ensureLayout(for: layoutEditor.textContainer)
        }
        layoutEditor.removeFromSuperview()
        print(String(format: "[perf] (b) open 1 MB: %.1f ms (median of 3); first unlaid glyph %d of %d; full ensureLayout %.1f ms",
                     StylingPerformanceTests.median(open) * 1000, unlaidAfterOpen, glyphsAfterOpen, fullLayout * 1000))

        // (c) One keystroke at the end: the edit, the scoped token pass, the visible spell pass.
        let editor = makeEditor(text, profile: profile, caretAtEnd: true)
        let language = try XCTUnwrap(SpellCheckPass.language(primary: "en-US"))
        let checker = UITextChecker()
        var keystroke: [TimeInterval] = []
        for _ in 0..<10 {
            keystroke.append(StylingPerformanceTests.time { Self.keystroke(in: editor, language: language, checker: checker) })
        }
        let wholeTokens = StylingPerformanceTests.time {
            MarkdownTokenStyler.applyTokens(to: editor.textStorage, profile: profile,
                                            scope: NSRange(location: 0, length: editor.textStorage.length))
        }
        print(String(format: "[perf] (c) keystroke at end (edit + scoped tokens + visible spell): %.2f ms (median of 10); whole-document token pass %.1f ms",
                     StylingPerformanceTests.median(keystroke) * 1000, wholeTokens * 1000))

        // (d) Read render, then a repeat apply of unchanged content.
        var firstRender: [TimeInterval] = []
        var firstApply: [TimeInterval] = []
        var repeatApply: [TimeInterval] = []
        var readUnlaid = 0
        var readGlyphs = 0
        for _ in 0..<3 {
            let reader = LineformReadView.make(profile: profile)
            host(reader)
            var applyOnly: TimeInterval = 0
            firstRender.append(StylingPerformanceTests.time {
                applyOnly = StylingPerformanceTests.time { reader.apply(text: text, profile: profile, documentDirectory: nil) }
                reader.layoutIfNeeded()
            })
            firstApply.append(applyOnly)
            readUnlaid = reader.layoutManager.firstUnlaidGlyphIndex()
            reader.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: reader.textStorage.length), actualCharacterRange: nil)
            let overlays = StylingPerformanceTests.time { reader.layoutOverlays() }
            print(String(format: "[perf] Read overlays (pills + grid) from an invalidated layout, page at top: %.1f ms", overlays * 1000))
            readGlyphs = reader.layoutManager.numberOfGlyphs
            repeatApply.append(StylingPerformanceTests.time {
                reader.apply(text: text, profile: profile, documentDirectory: nil)
                reader.layoutIfNeeded()
            })
            reader.removeFromSuperview()
        }
        print(String(format: "[perf] (d) Read first render %.1f ms (apply %.1f ms + layout), repeat apply %.3f ms (medians of 3); first unlaid glyph %d of %d",
                     StylingPerformanceTests.median(firstRender) * 1000, StylingPerformanceTests.median(firstApply) * 1000,
                     StylingPerformanceTests.median(repeatApply) * 1000, readUnlaid, readGlyphs))

        // (e) Write → Read → Write through `ModePositionKeeper`, from a freshly invalidated editor.
        var toRead: [TimeInterval] = []
        var toWrite: [TimeInterval] = []
        for _ in 0..<3 {
            let times = modeRoundTrip(editor: editor, text: text, profile: profile)
            toRead.append(times.toRead)
            toWrite.append(times.toWrite)
        }
        let wholeRestyle = StylingPerformanceTests.time {
            MarkdownTokenStyler.apply(to: editor.textStorage, profile: profile, tokenScope: nil)
        }
        print(String(format: "[perf] (e) Write→Read %.1f ms, Read→Write %.1f ms (medians of 3); whole-document restyle %.1f ms",
                     StylingPerformanceTests.median(toRead) * 1000, StylingPerformanceTests.median(toWrite) * 1000,
                     wholeRestyle * 1000))
        editor.removeFromSuperview()

        // (f) One AI review decision (accept) on 1 MB, ten changes near the end.
        var decisions: [TimeInterval] = []
        var presents: [TimeInterval] = []
        for _ in 0..<3 {
            let rig = makeReviewRig(text: text, profile: profile)
            decisions.append(StylingPerformanceTests.time { rig.acceptCurrent() })
            let fresh = AIReviewOverlayTextView.make()
            presents.append(StylingPerformanceTests.time {
                fresh.present(rig.composition, currentID: rig.session.currentID, profile: profile)
            })
            rig.overlay.removeFromSuperview()
        }
        print(String(format: "[perf] (f) AI accept (rebuild + present + reveal + layout) %.1f ms; whole-composition present %.1f ms (medians of 3)",
                     StylingPerformanceTests.median(decisions) * 1000, StylingPerformanceTests.median(presents) * 1000))

        // Deferred issue: the reading assists after a full restyle, Reading Ruler on, caret at end.
        var rulerProfile = profile
        rulerProfile.readingRulerEnabled = true
        let rulerEditor = makeEditor(text, profile: rulerProfile, caretAtEnd: true)
        var assists: [TimeInterval] = []
        var assistsUnlaid = 0
        for step in 0..<3 {
            rulerProfile.fontSize = step.isMultiple(of: 2) ? 18 : 17
            assists.append(StylingPerformanceTests.time { rulerEditor.profile = rulerProfile })
            assistsUnlaid = rulerEditor.layoutManager.firstUnlaidGlyphIndex()
            rulerEditor.layoutIfNeeded()
        }
        print(String(format: "[perf] reading assists after a restyle (ruler on, caret at end): profile setter %.1f ms (median of 3); first unlaid glyph %d of %d",
                     StylingPerformanceTests.median(assists) * 1000, assistsUnlaid, rulerEditor.layoutManager.numberOfGlyphs))
        rulerEditor.removeFromSuperview()
    }

    // MARK: - Budget operations (shared with the gates)

    static let corpus = StylingPerformanceTests.largeDocument()

    /// (b): decode the file's bytes, replace the editor's text, lay out the first screen.
    static func open(_ data: Data, in editor: LineformTextView) {
        guard let decoded = MarkdownFileCodec.decode(data) else { return }
        editor.setDocumentText(decoded)
        editor.layoutIfNeeded()
    }

    /// (c): one character typed at the caret, then the token pass for the visible window and the
    /// spell pass over it, as the typing pauses run them.
    static func keystroke(in editor: LineformTextView, language: String, checker: UITextChecker) {
        let caret = editor.selectedRange.location
        editor.textStorage.replaceCharacters(in: NSRange(location: caret, length: 0), with: "a")
        editor.selectedRange = NSRange(location: caret + 1, length: 0)
        let scope = editor.currentTokenScope()
        MarkdownTokenStyler.applyTokens(to: editor.textStorage, profile: editor.profile, scope: scope)
        let visible = editor.visibleCharacterRange() ?? scope
        _ = SpellCheckPass.misspelledRanges(in: editor.textStorage.string, visible: visible, language: language, checker: checker)
    }

    /// (e): Write → Read → Write the way `DocumentScreen` does it, with the editor's layout first
    /// invalidated (as after an open or a restyle). Returns each leg's time.
    func modeRoundTrip(editor: LineformTextView, text: String, profile: ReadingProfile)
        -> (toRead: TimeInterval, toWrite: TimeInterval) {
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        keeper.adopt(.write)
        let length = editor.textStorage.length
        editor.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        editor.selectedRange = NSRange(location: length - 1, length: 0)
        editor.scrollRangeToVisible(editor.selectedRange)
        editor.layoutIfNeeded()

        var reader: LineformReadView?
        let toRead = StylingPerformanceTests.time {
            keeper.switchMode(from: .write, to: .read)
            let made = LineformReadView.make(profile: profile)
            host(made)
            made.apply(text: text, profile: profile, documentDirectory: nil)
            keeper.reader = made
            Self.drainMainQueue()
            made.layoutIfNeeded()
            reader = made
        }
        StylingPerformanceTests.spinMainQueue()

        editor.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        let toWrite = StylingPerformanceTests.time {
            keeper.switchMode(from: .read, to: .write)
            reader?.removeFromSuperview()
            keeper.reader = nil
            Self.drainMainQueue()
            editor.layoutIfNeeded()
        }
        StylingPerformanceTests.spinMainQueue()
        return (toRead, toWrite)
    }

    /// (f): an overlay presenting a ten-change Proofread review near the end of `text`, hosted,
    /// scrolled to its current change.
    @MainActor
    final class ReviewRig {
        let text: String
        let profile: ReadingProfile
        let overlay: AIReviewOverlayTextView
        let cache = AIReviewCompositionCache()
        var session: AIReviewSession
        var composition: AIReviewComposition

        init(text: String, profile: ReadingProfile, overlay: AIReviewOverlayTextView, session: AIReviewSession) {
            self.text = text
            self.profile = profile
            self.overlay = overlay
            self.session = session
            composition = cache.composition(text: text, session: session)
        }

        /// What one accept costs the screen: the session records it, the composition is rebuilt
        /// (`AIReviewCompositionCache`), the overlay presents it, the new current change is
        /// revealed (`AIReviewOverlay.updateUIView`) and the overlay lays out.
        func acceptCurrent() {
            guard let id = session.currentID else { return }
            session.accept(id)
            composition = cache.composition(text: text, session: session)
            overlay.present(composition, currentID: session.currentID, profile: profile)
            overlay.revealCurrentChange(bottomObscured: 0)
            overlay.layoutIfNeeded()
        }
    }

    func makeReviewRig(text: String, profile: ReadingProfile) -> ReviewRig {
        let session = Self.reviewSession(in: text, changes: 10)
        let overlay = AIReviewOverlayTextView.make()
        host(overlay)
        let rig = ReviewRig(text: text, profile: profile, overlay: overlay, session: session)
        overlay.present(rig.composition, currentID: session.currentID, profile: profile)
        overlay.layoutIfNeeded()
        overlay.revealCurrentChange(bottomObscured: 0)
        overlay.layoutIfNeeded()
        return rig
    }

    /// A Proofread session of `changes` one-word corrections ("fox" → "cat") on the last prose
    /// lines of `text`.
    static func reviewSession(in text: String, changes count: Int) -> AIReviewSession {
        let ns = text as NSString
        var changes: [AIChange] = []
        var searchEnd = ns.length
        while changes.count < count {
            let found = ns.range(of: "brown fox", options: .backwards, range: NSRange(location: 0, length: searchEnd))
            guard found.location != NSNotFound else { break }
            let word = NSRange(location: found.location + 6, length: 3)
            changes.append(AIChange(id: changes.count + 1, range: word, original: "fox", replacement: "cat"))
            searchEnd = found.location
        }
        let first = changes.map(\.range.location).min() ?? 0
        let selection = NSRange(location: first, length: ns.length - first)
        return AIReviewSession(action: .proofread, changes: changes, selectionRange: selection,
                               originalSelection: ns.substring(with: selection))
    }

    /// Runs the work queued on the main queue so far (the keeper's next-tick restore).
    static func drainMainQueue() {
        final class Flag { var isSet = false }
        let flag = Flag()
        DispatchQueue.main.async { flag.isSet = true }
        while !flag.isSet { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    // MARK: - Hosting

    private func hostWindow() -> UIWindow {
        if let window { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    func host(_ view: UIView) {
        let window = hostWindow()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController?.view.addSubview(view)
        view.layoutIfNeeded()
    }

    /// An editor showing `text`, laid out, with the caret (and the page) at the end when asked.
    func makeEditor(_ text: String, profile: ReadingProfile, caretAtEnd: Bool) -> LineformTextView {
        let editor = LineformTextView.make(profile: profile)
        host(editor)
        editor.setDocumentText(text)
        if caretAtEnd {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
        }
        editor.layoutIfNeeded()
        return editor
    }
}
