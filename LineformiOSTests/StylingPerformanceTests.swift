import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// A Styling sheet slider drag on a 1 MB document: the editor and the Read view restyle at most
/// once per frame, and the restyle never lays out the whole document for the Reading Ruler.
///
/// Timings here are printed, never asserted against a wall clock (other builds share the
/// machine); the assertions are structural counts and `firstUnlaidGlyphIndex()`.
@MainActor
final class StylingPerformanceTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        StylingDrag.end()
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Coalescing

    func testSliderDragAppliesAtMostOncePerRunLoopTurn() {
        let (store, suite) = Self.makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let coalescer = ProfileUpdateCoalescer()
        coalescer.beginDrag()
        for step in 0..<30 {
            coalescer.submit(to: store) { $0.fontSize = 20 + Double(step) }
        }
        XCTAssertEqual(coalescer.appliedCount, 0)
        XCTAssertEqual(store.activeProfile.fontSize, ReadingProfile.original.fontSize)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(coalescer.appliedCount, 1)
        XCTAssertEqual(store.activeProfile.fontSize, 49, "the newest value lands")

        coalescer.submit(to: store) { $0.fontSize = 30 }
        coalescer.endDrag()
        XCTAssertEqual(store.activeProfile.fontSize, 30, "the drag's end lands the pending value at once")
        XCTAssertFalse(StylingDrag.isActive)
    }

    func testSubmitWithoutDragAppliesAtOnce() {
        let (store, suite) = Self.makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let coalescer = ProfileUpdateCoalescer()
        coalescer.submit(to: store) { $0.fontSize = 22 }
        XCTAssertEqual(store.activeProfile.fontSize, 22)
        XCTAssertEqual(coalescer.appliedCount, 1)
    }

    // MARK: - Deferred work during a drag

    /// During a drag a restyle never lays the prefix out for the ruler; the drag's end places it.
    func testDragDefersEditorAssistsLayout() {
        let text = Self.largeDocument()
        let length = (text as NSString).length
        var profile = ReadingProfile.original
        profile.readingRulerEnabled = true
        let editor = makeEditor(text, profile: profile)
        editor.selectedRange = NSRange(location: length - 1, length: 0)
        editor.refreshReadingAssists()
        XCTAssertFalse(editor.readingRulerView?.isHidden ?? true)

        StylingDrag.begin()
        profile.fontSize = 19
        editor.profile = profile
        let glyphs = editor.layoutManager.numberOfGlyphs
        XCTAssertLessThan(editor.layoutManager.firstUnlaidGlyphIndex(), glyphs / 2,
                          "a restyle during a drag must not lay out the prefix up to the caret")
        XCTAssertTrue(editor.readingRulerView?.isHidden ?? true)

        StylingDrag.end()
        XCTAssertFalse(editor.readingRulerView?.isHidden ?? true, "the ruler comes back at the drag's end")
    }

    /// During a drag the Read view keeps the newest profile and renders it once, at the drag's end.
    func testDragDefersReadRender() {
        let text = "# Title\n\nSome text.\n"
        var profile = ReadingProfile.original
        let reader = LineformReadView.make(profile: profile)
        host(reader)
        reader.apply(text: text, profile: profile, documentDirectory: nil)
        XCTAssertEqual(reader.state.renderedProfile, profile)

        StylingDrag.begin()
        profile.fontSize = 24
        reader.apply(text: text, profile: profile, documentDirectory: nil)
        XCTAssertEqual(reader.state.renderedProfile?.fontSize, ReadingProfile.original.fontSize)

        StylingDrag.end()
        XCTAssertEqual(reader.state.renderedProfile, profile)
    }

    // MARK: - Measurement

    /// Prints the cost of one profile change (font size +1) on the 1 MB corpus, phase by phase, in
    /// Write (caret on the last line, Reading Ruler on, page scrolled to the caret) and in Read.
    func testMeasureRestyleCosts() throws {
        let text = Self.largeDocument()
        let length = (text as NSString).length
        XCTAssertGreaterThan(length, 1_000_000)
        var profile = ReadingProfile.original
        profile.readingRulerEnabled = true

        let editor = makeEditor(text, profile: profile)
        editor.selectedRange = NSRange(location: length - 1, length: 0)
        editor.scrollRangeToVisible(editor.selectedRange)
        editor.layoutIfNeeded()
        editor.refreshReadingAssists()

        var base: [TimeInterval] = []
        var tokens: [TimeInterval] = []
        var assists: [TimeInterval] = []
        var whole: [TimeInterval] = []
        var frame: [TimeInterval] = []
        for step in 0..<6 {
            profile.fontSize = step.isMultiple(of: 2) ? 18 : 17
            let scope = editor.currentTokenScope()
            base.append(Self.time { MarkdownTokenStyler.applyBase(to: editor.textStorage, profile: profile) })
            tokens.append(Self.time { MarkdownTokenStyler.applyTokens(to: editor.textStorage, profile: profile, scope: scope) })
            assists.append(Self.time { editor.refreshReadingAssists() })
            editor.layoutIfNeeded()

            profile.fontSize = step.isMultiple(of: 2) ? 19 : 16
            whole.append(Self.time { editor.profile = profile })
            frame.append(Self.time { editor.layoutIfNeeded() })
        }
        print(String(format: "[perf] Write 1 MB, caret at end, ruler on: base %.1f ms, tokens %.1f ms, assists %.1f ms; profile setter %.1f ms + layout %.1f ms (medians of 6)",
                     Self.median(base) * 1000, Self.median(tokens) * 1000, Self.median(assists) * 1000,
                     Self.median(whole) * 1000, Self.median(frame) * 1000))

        var typewriter = profile
        typewriter.typewriterModeEnabled = true
        editor.profile = typewriter
        editor.layoutIfNeeded()
        var typewriterTimes: [TimeInterval] = []
        for step in 0..<4 {
            typewriter.fontSize = step.isMultiple(of: 2) ? 18 : 17
            typewriterTimes.append(Self.time {
                editor.profile = typewriter
                editor.layoutIfNeeded()
            })
        }
        print(String(format: "[perf] Write 1 MB, Typewriter Mode on: profile setter + layout %.1f ms (median of 4)",
                     Self.median(typewriterTimes) * 1000))

        let reader = LineformReadView.make(profile: profile)
        host(reader)
        reader.apply(text: text, profile: profile, documentDirectory: nil)
        reader.layoutIfNeeded()
        var renders: [TimeInterval] = []
        var readLayout: [TimeInterval] = []
        for step in 0..<4 {
            profile.fontSize = step.isMultiple(of: 2) ? 18 : 17
            renders.append(Self.time { reader.apply(text: text, profile: profile, documentDirectory: nil) })
            readLayout.append(Self.time { reader.layoutIfNeeded() })
        }
        print(String(format: "[perf] Read 1 MB: apply %.1f ms + layout %.1f ms (medians of 4)",
                     Self.median(renders) * 1000, Self.median(readLayout) * 1000))

        // The Read apply's parts: the renderer alone, and the pills' geometry (every code block's
        // rect) right after a fresh storage.
        let window = try XCTUnwrap(reader.window)
        var rendererTimes: [TimeInterval] = []
        for step in 0..<3 {
            profile.fontSize = step.isMultiple(of: 2) ? 18 : 17
            rendererTimes.append(Self.time {
                _ = MarkdownPreviewRenderer().render(
                    text, profile: profile, columnWidth: 393,
                    mermaidProvider: reader.state.mermaidProvider, mathProvider: reader.state.mathProvider,
                    diagramLog: reader.state.diagramLog, appVersion: "test", documentDirectory: nil,
                    imageProvider: reader.state.imageProvider,
                    displayMetrics: RenderDisplayMetrics(scale: 3, visibleViewportHeight: window.bounds.height)
                )
            })
        }
        profile.fontSize = 20
        reader.apply(text: text, profile: profile, documentDirectory: nil)
        let pills = Self.time { _ = reader.overlayPills() }
        print(String(format: "[perf] Read 1 MB parts: renderer %.1f ms (median of 3); pills geometry after a render %.1f ms",
                     Self.median(rendererTimes) * 1000, pills * 1000))
    }

    // MARK: - Helpers

    static func makeStore() -> (ReadingProfileStore, String) {
        let suite = "StylingPerformanceTests.\(UUID().uuidString)"
        return (ReadingProfileStore(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    /// About 1 MB of Markdown: front matter, headings, paragraphs, lists, quotes, code and math.
    static func largeDocument() -> String {
        var parts: [String] = ["---", "title: Large Fixture", "---", ""]
        var index = 0
        var size = 0
        while size < 1_024 * 1_024 {
            index += 1
            let block: [String]
            switch index % 12 {
            case 0: block = ["```swift", "let isRichText = false", "func doThing() {}", "```", ""]
            case 3: block = ["- a bullet about calm writing", "- another bullet with *emphasis*", "1. a numbered step", ""]
            case 5: block = ["$$", "a = b", "$$", ""]
            case 7: block = ["See [the docs](/Users/qa/notes/file-\(index).md) and `NSTextView`.", ""]
            case 8: block = ["> A quoted line that runs long enough to wrap on a phone screen at the default size.", ""]
            case 9: block = ["## Section \(index)", ""]
            default: block = ["the quick brown fox jumps over the lazy dog writing calm markdown, and then a little more prose so the paragraph wraps", ""]
            }
            parts += block
            size += block.reduce(0) { $0 + $1.utf16.count + 1 }
        }
        return parts.joined(separator: "\n")
    }

    static func time(_ body: () -> Void) -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func hostWindow() -> UIWindow {
        if let window { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIViewController()
        window.isHidden = false
        self.window = window
        return window
    }

    private func host(_ view: UIView) {
        let window = hostWindow()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController?.view.addSubview(view)
        view.layoutIfNeeded()
    }

    func makeEditor(_ text: String, profile: ReadingProfile) -> LineformTextView {
        let editor = LineformTextView.make(profile: profile)
        host(editor)
        editor.setDocumentText(text)
        editor.layoutIfNeeded()
        return editor
    }
}
