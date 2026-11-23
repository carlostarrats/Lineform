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
        // The editor's prefix layout (the restore near the end) can land in either leg, depending
        // on when its queued re-asserts run; the round trip is the stable number.
        let roundTrips = zip(toRead, toWrite).map { $0 + $1 }
        print(String(format: "[perf] (e) at the end, editor layout invalidated in Read: Write→Read %.1f ms, Read→Write %.1f ms, round trip %.1f ms (medians of 3); whole-document restyle %.1f ms",
                     StylingPerformanceTests.median(toRead) * 1000, StylingPerformanceTests.median(toWrite) * 1000,
                     StylingPerformanceTests.median(roundTrips) * 1000, wholeRestyle * 1000))
        var topToRead: [TimeInterval] = []
        var topToWrite: [TimeInterval] = []
        let topEditor = makeEditor(text, profile: profile, caretAtEnd: false)
        for _ in 0..<3 {
            let times = modeRoundTrip(editor: topEditor, text: text, profile: profile, atEnd: false)
            topToRead.append(times.toRead)
            topToWrite.append(times.toWrite)
        }
        print(String(format: "[perf] (e) at the top, as an open leaves it: Write→Read %.1f ms, Read→Write %.1f ms (medians of 3)",
                     StylingPerformanceTests.median(topToRead) * 1000, StylingPerformanceTests.median(topToWrite) * 1000))
        topEditor.removeFromSuperview()

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

    // MARK: - Gates

    /// (c) One keystroke at the end (edit, scoped tokens, visible spell pass) against a token
    /// pass over the whole document.
    func testKeystrokeIsScopedRatio() throws {
        let text = Self.corpus
        let editor = makeEditor(text, profile: .original, caretAtEnd: true)
        let language = try XCTUnwrap(SpellCheckPass.language(primary: "en-US"))
        let checker = UITextChecker()
        Self.keystroke(in: editor, language: language, checker: checker)
        let keystroke = Self.bestPerCall(batches: 5, iterations: 5) {
            Self.keystroke(in: editor, language: language, checker: checker)
        }
        let whole = Self.bestPerCall(batches: 2, iterations: 1) {
            MarkdownTokenStyler.applyTokens(to: editor.textStorage, profile: editor.profile,
                                            scope: NSRange(location: 0, length: editor.textStorage.length))
        }
        Self.report("keystroke", scoped: keystroke, whole: whole, wholeName: "whole-document token pass")
        XCTAssertGreaterThan(whole, 0.001, "the whole side must take measurable time, or the ratio means nothing")
        XCTAssertGreaterThan(whole / keystroke, 4, "a keystroke reached a whole-document pass")
    }

    /// (b) An open lays out the first screen, never the document: structurally, and against a
    /// full layout of the text.
    func testOpenDoesNotLayOutWholeDocument() {
        let text = Self.corpus
        let data = MarkdownFileCodec.encode(text)
        let editor = makeEditor(text, profile: .original, caretAtEnd: true)
        Self.open(data, in: editor)
        let layoutManager = editor.layoutManager
        XCTAssertLessThan(layoutManager.firstUnlaidGlyphIndex(), layoutManager.numberOfGlyphs / 2,
                          "an open laid out the document, not its first screen")
        let open = Self.bestPerCall(batches: 3, iterations: 1) { Self.open(data, in: editor) }
        let whole = Self.bestPerCall(batches: 2, iterations: 1) {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: editor.textStorage.length),
                                           actualCharacterRange: nil)
            layoutManager.ensureLayout(for: editor.textContainer)
        }
        Self.report("open 1 MB", scoped: open, whole: whole, wholeName: "full layout")
        XCTAssertGreaterThan(whole, 0.001)
        XCTAssertGreaterThan(whole / open, 2, "an open costs as much as laying out the whole document")
    }

    /// (a) Launch to a typable editor. Ruling (baseline note): an open is lazy (about 14 ms), so
    /// launch measures about 0.85× of it, not 4×; the gate holds launch to at most 2.5× an open,
    /// and to a quarter of a document-scale pass (a whole-document token pass).
    func testLaunchToTypableEditor() throws {
        let text = Self.corpus
        let data = MarkdownFileCodec.encode(text)
        var launches: [TimeInterval] = []
        for _ in 0..<5 {
            var made: LineformTextView?
            launches.append(StylingPerformanceTests.time {
                let editor = LineformTextView.make(profile: .original)
                editor.setDocumentText("")
                host(editor)
                editor.becomeFirstResponder()
                editor.layoutIfNeeded()
                made = editor
            })
            made?.resignFirstResponder()
            made?.removeFromSuperview()
        }
        let launch = launches.min() ?? 0
        let editor = makeEditor(text, profile: .original, caretAtEnd: true)
        let open = Self.bestPerCall(batches: 3, iterations: 1) { Self.open(data, in: editor) }
        let wholeTokens = Self.bestPerCall(batches: 2, iterations: 1) {
            MarkdownTokenStyler.applyTokens(to: editor.textStorage, profile: editor.profile,
                                            scope: NSRange(location: 0, length: editor.textStorage.length))
        }
        Self.report("launch", scoped: launch, whole: open, wholeName: "open 1 MB")
        Self.report("launch", scoped: launch, whole: wholeTokens, wholeName: "whole-document token pass")
        XCTAssertGreaterThan(open, 0.001)
        XCTAssertGreaterThan(open / launch, 0.4, "launching an empty editor costs more than 2.5 opens of 1 MB")
        XCTAssertGreaterThan(wholeTokens / launch, 4, "launching an empty editor does document-scale work")
    }

    /// (d) A repeat apply of unchanged text renders nothing.
    func testReadRepeatApplyIsCheap() {
        let text = Self.corpus
        let reader = LineformReadView.make(profile: .original)
        host(reader)
        let first = StylingPerformanceTests.time {
            reader.apply(text: text, profile: .original, documentDirectory: nil)
            reader.layoutIfNeeded()
        }
        let repeated = Self.bestPerCall(batches: 5, iterations: 5) {
            reader.apply(text: text, profile: .original, documentDirectory: nil)
            reader.layoutIfNeeded()
        }
        Self.report("Read repeat apply", scoped: repeated, whole: first, wholeName: "first render")
        XCTAssertGreaterThan(first, 0.001)
        XCTAssertGreaterThan(first / repeated, 10, "an unchanged apply rendered again")
    }

    /// (e) Read → Write, with the editor as an open leaves it (page at the top, first screen laid
    /// out), against a whole-document restyle. The restore lays out the prefix through its target
    /// and one page, never the rest: the scoped part this guards is largest with the target at
    /// the top. Write → Read's first render is (d)'s cost and is reported, not gated.
    func testModeSwitchBackToWriteIsScoped() {
        let text = Self.corpus
        let editor = makeEditor(text, profile: .original, caretAtEnd: false)
        _ = modeRoundTrip(editor: editor, text: text, profile: .original, atEnd: false)
        var legs: [TimeInterval] = []
        for _ in 0..<3 {
            legs.append(modeRoundTrip(editor: editor, text: text, profile: .original, atEnd: false).toWrite)
        }
        let toWrite = legs.min() ?? 0
        let restyle = Self.bestPerCall(batches: 2, iterations: 1) {
            MarkdownTokenStyler.apply(to: editor.textStorage, profile: editor.profile, tokenScope: nil)
        }
        Self.report("Read → Write", scoped: toWrite, whole: restyle, wholeName: "whole-document restyle")
        XCTAssertGreaterThan(restyle, 0.001)
        XCTAssertGreaterThan(restyle / toWrite, 4, "the switch back to Write laid out past its target")
        XCTAssertLessThan(editor.topVisibleSourceLocation() ?? .max, 2_000, "the restore put the page back at the top")
        XCTAssertLessThan(editor.layoutManager.firstUnlaidGlyphIndex(), editor.layoutManager.numberOfGlyphs / 2)
    }

    /// The scoped restore lands exactly where the old whole-layout restore did: at the top, in the
    /// middle, and at the end (clamped).
    func testScopedRestoreLandsWhereTheWholeLayoutRestoreDid() {
        let text = Self.corpus
        let length = (text as NSString).length
        let editor = makeEditor(text, profile: .original, caretAtEnd: false)
        for target in [0, 120, length / 2, length - 40] {
            editor.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
            editor.scrollCharacterRangeToTop(NSRange(location: target, length: 0))
            let landed = editor.contentOffset.y
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            XCTAssertEqual(landed, Self.wholeLayoutRestoreOffset(editor, target: target), accuracy: 0.5, "target \(target)")
        }
    }

    /// (f) One accept on a ten-change review near the end of 1 MB, against a whole-composition
    /// present.
    func testAIDecisionIsScopedRatio() {
        let text = Self.corpus
        let rig = makeReviewRig(text: text, profile: .original)
        var accepts: [TimeInterval] = []
        for _ in 0..<8 {
            accepts.append(StylingPerformanceTests.time { rig.acceptCurrent() })
        }
        let accept = accepts.min() ?? 0
        let whole = Self.bestPerCall(batches: 3, iterations: 1) {
            AIReviewOverlayTextView.make().present(rig.composition, currentID: rig.session.currentID, profile: rig.profile)
        }
        Self.report("AI accept", scoped: accept, whole: whole, wholeName: "whole-composition present")
        XCTAssertGreaterThan(whole, 0.001)
        XCTAssertGreaterThan(whole / accept, 4, "a review decision restyled or laid out the whole composition")
    }

    /// The incremental present draws attribute for attribute what a whole present draws, through
    /// accepts, a reject, moving and selecting, in two themes.
    func testIncrementalPresentDrawsWhatAWholePresentDraws() {
        let text = String(Self.corpus.prefix(60_000))
        var profile = ReadingProfile.original
        let session = Self.reviewSession(in: text, changes: 6)
        let overlay = AIReviewOverlayTextView.make()
        let rig = ReviewRig(text: text, profile: profile, overlay: overlay, session: session)
        overlay.present(rig.composition, currentID: session.currentID, profile: profile)

        func check(_ step: String) {
            rig.composition = rig.cache.composition(text: text, session: rig.session)
            overlay.present(rig.composition, currentID: rig.session.currentID, profile: profile)
            let whole = AIReviewOverlayTextView.make()
            whole.present(rig.composition, currentID: rig.session.currentID, profile: profile)
            XCTAssertEqual(overlay.textStorage.string, whole.textStorage.string, step)
            XCTAssertTrue(overlay.textStorage.isEqual(to: whole.textStorage), "\(step): drawn differently from a whole present")
        }
        let ids = rig.session.pending.map(\.id)
        rig.session.accept(ids[0]); check("accept the first")
        rig.session.move(by: 1); check("move")
        rig.session.reject(ids[2]); check("reject")
        rig.session.select(ids[4]); check("select")
        rig.session.accept(ids[4]); check("accept the selected")
        profile.themeID = .night
        check("a new theme (whole present)")
        rig.session.accept(ids[1]); check("accept in the new theme")
        rig.session.acceptAllPending(); check("accept all")
    }

    /// Deferred issue 2, by ruling (baseline note): after a full restyle the Reading Ruler and
    /// Typewriter Mode lay out the prefix through the caret, because TextKit 1's estimate for a
    /// line past an unlaid stretch is far off (measured: 335,817 pt estimated vs 1,786,482 pt
    /// exact for the last line of 1 MB). That cost is kept, once per restyle; it must never be
    /// paid again for a caret move or a keystroke, and never during a Styling drag
    /// (`StylingPerformanceTests.testDragDefersEditorAssistsLayout`).
    func testReadingAssistsLayOutThePrefixOncePerRestyle() {
        let text = Self.corpus
        let length = (text as NSString).length
        var profile = ReadingProfile.original
        profile.readingRulerEnabled = true
        let editor = makeEditor(text, profile: profile, caretAtEnd: true)
        profile.fontSize = 19
        let restyle = StylingPerformanceTests.time { editor.profile = profile }
        editor.layoutIfNeeded()
        var step = 0
        let caretMove = Self.bestPerCall(batches: 5, iterations: 4) {
            step += 1
            editor.selectedRange = NSRange(location: length - 1 - (step % 2) * 200, length: 0)
            editor.refreshReadingAssists()
        }
        Self.report("ruler caret move after a restyle", scoped: caretMove, whole: restyle, wholeName: "restyle with the ruler on")
        XCTAssertGreaterThan(restyle, 0.001)
        XCTAssertFalse(editor.readingRulerView?.isHidden ?? true)
        XCTAssertGreaterThan(restyle / caretMove, 10, "the reading assists lay the prefix out again on a caret move")
    }

    /// Deferred issue 3: the pills and the table grid are placed for the page and its
    /// neighbours only, never measured for the whole document.
    func testReadOverlaysDoNotForceWholeLayout() throws {
        let text = Self.corpus + "\n| Column | Other |\n| --- | --- |\n| a | b |\n| c | d |\n"
        let reader = LineformReadView.make(profile: .original)
        host(reader)
        reader.apply(text: text, profile: .original, documentDirectory: nil)
        reader.layoutIfNeeded()
        let layoutManager = reader.layoutManager
        let storageLength = reader.textStorage.length
        var codeBlocks = 0
        reader.textStorage.enumerateAttribute(.codeBlockSourceRange, in: NSRange(location: 0, length: storageLength)) { value, _, _ in
            if value != nil { codeBlocks += 1 }
        }
        XCTAssertGreaterThan(codeBlocks, 100)
        XCTAssertLessThan(reader.overlayButtons.count, 20, "pills were placed for the whole document")
        XCTAssertTrue(reader.tableGridPath(in: reader.overlayWindow()).isEmpty, "the grid measured a table far below the page")

        var overlays: [TimeInterval] = []
        for _ in 0..<3 {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storageLength), actualCharacterRange: nil)
            overlays.append(StylingPerformanceTests.time { reader.layoutOverlays() })
        }
        let whole = Self.bestPerCall(batches: 2, iterations: 1) {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storageLength), actualCharacterRange: nil)
            layoutManager.ensureLayout(for: reader.textContainer)
        }
        let overlay = overlays.min() ?? 0
        Self.report("Read overlays", scoped: overlay, whole: whole, wholeName: "full layout")
        XCTAssertGreaterThan(whole, 0.001)
        XCTAssertGreaterThan(whole / overlay, 4, "placing the pills laid out the whole document")
    }

    /// The windowed pills are the whole set's pills for that stretch: same rects, same numbers.
    /// A scroll past the window places the pills and the grid there.
    func testWindowedOverlaysMatchTheWholeSet() throws {
        let text = Self.corpus + "\n| Column | Other |\n| --- | --- |\n| a | b |\n| c | d |\n"
        let reader = LineformReadView.make(profile: .original)
        host(reader)
        reader.apply(text: text, profile: .original, documentDirectory: nil)
        reader.layoutManager.ensureLayout(for: reader.textContainer)
        reader.layoutIfNeeded()

        func assertMatchesWholeSet(_ place: String) throws {
            _ = try XCTUnwrap(reader.overlayWindow())
            let all = reader.overlayPills()
            let expected = all.filter { pill in
                reader.overlayButtons.contains { NSEqualRanges($0.sourceRange, pill.sourceRange) }
            }
            XCTAssertFalse(expected.isEmpty, place)
            XCTAssertEqual(reader.overlayButtons.count, expected.count, place)
            for (button, pill) in zip(reader.overlayButtons, expected) {
                XCTAssertEqual(button.frame, pill.rect, place)
                XCTAssertEqual(button.codeBlockNumber, pill.codeBlockNumber, place)
            }
        }
        try assertMatchesWholeSet("top")
        XCTAssertTrue(reader.tableGridPath(in: reader.overlayWindow()).isEmpty)

        reader.setContentOffset(CGPoint(x: 0, y: reader.contentSize.height / 2), animated: false)
        reader.layoutIfNeeded()
        try assertMatchesWholeSet("middle")

        let bottom = reader.contentSize.height + reader.adjustedContentInset.bottom - reader.bounds.height
        reader.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        reader.layoutIfNeeded()
        try assertMatchesWholeSet("end")
        let gridAtEnd = try XCTUnwrap(reader.subviews.compactMap { $0 as? ReadTableGridView }.first)
        XCTAssertEqual(gridAtEnd.shapeLayer.path.map { UIBezierPath(cgPath: $0).bounds },
                       reader.tableGridPath().bounds, "the grid at the end is the whole document's grid")
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
    func modeRoundTrip(editor: LineformTextView, text: String, profile: ReadingProfile, atEnd: Bool = true)
        -> (toRead: TimeInterval, toWrite: TimeInterval) {
        let keeper = ModePositionKeeper()
        keeper.editor = editor
        keeper.adopt(.write)
        let length = editor.textStorage.length
        // A previous trip's restore re-asserts for a few ticks; it must not move this trip's page.
        editor.state.persistentScrollTarget = nil
        editor.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        if atEnd {
            editor.selectedRange = NSRange(location: length - 1, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
        } else {
            editor.selectedRange = NSRange(location: 0, length: 0)
            editor.setContentOffset(CGPoint(x: 0, y: -editor.adjustedContentInset.top), animated: false)
        }
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

        // A restyle while in Read (the editor under it restyles too) leaves its layout invalid.
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

    /// The best per-call time over `batches` of `iterations` calls (`testSpellPassIsScopedRatio`).
    static func bestPerCall(batches: Int, iterations: Int, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.infinity
        for _ in 0..<batches {
            let elapsed = StylingPerformanceTests.time {
                for _ in 0..<iterations { body() }
            }
            best = min(best, elapsed / Double(iterations))
        }
        return best
    }

    static func report(_ name: String, scoped: TimeInterval, whole: TimeInterval, wholeName: String) {
        print(String(format: "[perf] gate %@: %.3f ms vs %@ %.1f ms (%.1f×)",
                     name, scoped * 1000, wholeName, whole * 1000, whole / max(scoped, 1e-9)))
    }

    /// Where `scrollCharacterRangeToTop` put `target` when it laid out the whole text first (the
    /// formula before the scoped restore). Needs the whole text laid out.
    static func wholeLayoutRestoreOffset(_ editor: LineformTextView, target: Int) -> CGFloat {
        let layoutManager = editor.layoutManager
        let location = min(max(0, target), editor.textStorage.length - 1)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: editor.textContainer)
        let top = -editor.adjustedContentInset.top
        let targetTop = max(0, rect.minY + editor.textContainerInset.top - LineformTextView.scrollTopMargin)
        let contentHeight = layoutManager.usedRect(for: editor.textContainer).height
            + editor.textContainerInset.top + editor.textContainerInset.bottom
        let maximumY = max(top, contentHeight + editor.adjustedContentInset.bottom - editor.bounds.height)
        return min(max(top, targetTop - editor.adjustedContentInset.top), maximumY)
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
