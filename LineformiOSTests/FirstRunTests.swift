import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import LineformiOS

/// First run (roadmap step 11, redesigned 2026-11-24): the launch gate, the stage order (nothing
/// advances by itself), the copy and the bundled wordmark animation.
@MainActor
final class FirstRunTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FirstRunTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Gate

    func testFreshDeviceShowsFirstRun() {
        XCTAssertTrue(FirstRunGate.shouldShowAtLaunch(defaults: defaults, environment: [:]))
    }

    func testCompletedDeviceSkipsFirstRun() {
        FirstRunGate.markCompleted(defaults: defaults)
        XCTAssertFalse(FirstRunGate.shouldShowAtLaunch(defaults: defaults, environment: [:]))
        XCTAssertTrue(defaults.bool(forKey: "LineformiOSFirstRunCompleted.v1"))
    }

    func testEnvironmentForcesFirstRun() {
        FirstRunGate.markCompleted(defaults: defaults)
        XCTAssertTrue(FirstRunGate.shouldShowAtLaunch(defaults: defaults, environment: ["LINEFORM_SHOW_FIRST_RUN": "1"]))
    }

    func testRestoredSceneWinsOverFirstRun() {
        XCTAssertFalse(FirstRunGate.shouldPresent(launchWantsFirstRun: true, restoredBookmark: "abc=", restoredPath: ""))
        XCTAssertFalse(FirstRunGate.shouldPresent(launchWantsFirstRun: true, restoredBookmark: "", restoredPath: "/x.md"))
        XCTAssertTrue(FirstRunGate.shouldPresent(launchWantsFirstRun: true, restoredBookmark: "", restoredPath: ""))
        XCTAssertFalse(FirstRunGate.shouldPresent(launchWantsFirstRun: false, restoredBookmark: "", restoredPath: ""))
    }

    // MARK: - Stages

    func testStagesRunInOrderWithNoWhatToExpect() {
        XCTAssertEqual(FirstRunStage.allCases, [.welcome, .points, .done])
        XCTAssertEqual(FirstRunStage.welcome.next, .points)
        XCTAssertEqual(FirstRunStage.points.next, .done)
        XCTAssertEqual(FirstRunStage.done.next, .done)
    }

    func testTimingPacesTheScreenAsApproved() {
        XCTAssertEqual(FirstRunTiming.writeSeconds, 3.5)
        XCTAssertEqual(FirstRunTiming.shrinkSeconds, 0.9)
        let delays = (0..<FirstRunCopy.pointItems.count).map(FirstRunTiming.pointDelay)
        XCTAssertEqual(delays, delays.sorted(), "the points arrive one after another")
        XCTAssertEqual(Set(delays).count, delays.count)
        XCTAssertGreaterThan(
            FirstRunTiming.startWritingDelay(pointCount: delays.count), delays.last ?? 0,
            "Start Writing comes last"
        )
    }

    // MARK: - Flow

    func testNothingAdvancesWithoutATap() {
        var finishes = 0
        let flow = FirstRunFlow(defaults: defaults) { finishes += 1 }
        XCTAssertEqual(flow.stage, .welcome)
        XCTAssertFalse(flow.isWordmarkWritten)
        flow.wordmarkDidFinishWriting()
        XCTAssertTrue(flow.isWordmarkWritten, "the written wordmark only reveals Get Started")
        XCTAssertEqual(flow.stage, .welcome, "the page finishing writing does not move on")
        XCTAssertEqual(finishes, 0)
    }

    func testEachButtonAdvancesOnlyFromItsOwnStage() {
        let flow = FirstRunFlow(defaults: defaults) {}
        XCTAssertFalse(flow.advance(from: .points), "Start Writing does nothing on the welcome")
        XCTAssertEqual(flow.stage, .welcome)
        XCTAssertTrue(flow.advance(from: .welcome))
        XCTAssertEqual(flow.stage, .points)
        XCTAssertFalse(flow.advance(from: .welcome), "a second Get Started never skips the points")
        XCTAssertEqual(flow.stage, .points)
    }

    func testFlagIsWrittenOnlyOnStartWriting() {
        var finishes = 0
        let flow = FirstRunFlow(defaults: defaults) { finishes += 1 }
        flow.wordmarkDidFinishWriting()
        flow.advance(from: .welcome)
        XCTAssertFalse(defaults.bool(forKey: FirstRunGate.completedKey))
        XCTAssertEqual(finishes, 0)
        XCTAssertTrue(flow.advance(from: .points))
        XCTAssertEqual(flow.stage, .done)
        XCTAssertTrue(defaults.bool(forKey: FirstRunGate.completedKey))
        XCTAssertEqual(finishes, 1)
    }

    func testDoubleStartWritingFinishesOnceAndWritesTheFlagOnce() throws {
        let counting = try XCTUnwrap(CountingDefaults(suiteName: suiteName))
        var finishes = 0
        let flow = FirstRunFlow(defaults: counting) { finishes += 1 }
        flow.advance(from: .welcome)
        XCTAssertTrue(flow.advance(from: .points))
        XCTAssertFalse(flow.advance(from: .points))
        XCTAssertFalse(flow.advance(from: .done))
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(counting.completedWrites, 1)
        XCTAssertTrue(counting.bool(forKey: FirstRunGate.completedKey))
        XCTAssertTrue(flow.hasFinished)
    }

    func testLateWrittenSignalAfterGetStartedIsIgnored() {
        let flow = FirstRunFlow(defaults: defaults) {}
        flow.advance(from: .welcome)
        flow.wordmarkDidFinishWriting()
        XCTAssertFalse(flow.isWordmarkWritten)
        XCTAssertEqual(flow.stage, .points)
    }

    // MARK: - Copy and resources

    func testCopyIsTheApprovedWording() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(FirstRunCopy.pointItems.map(\.title), [
            "Free and private", "Real files, in iCloud", "More than text", "Made to be read",
        ])
        XCTAssertEqual(FirstRunCopy.pointItems.map(\.text), [
            "No account, nothing to sign up for. Your writing stays with you.",
            "Plain Markdown files that sync with Lineform for Mac and open anywhere.",
            "Images, tables, math and diagrams. Export styled PDFs in a tap.",
            "Reading themes, accessible fonts and read aloud. AI only if you connect your own.",
        ])
        XCTAssertEqual(FirstRunCopy.tagline, "Simple markdown editing")
        XCTAssertEqual(FirstRunCopy.getStarted, "Get Started")
        XCTAssertEqual(FirstRunCopy.startWriting, "Start Writing")
        XCTAssertEqual(FirstRunCopy.allStrings.count, 3 + 2 * FirstRunCopy.pointItems.count)
    }

    func testIntroResourcesAreBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FirstLaunchIntro"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Lineform", withExtension: "svg", subdirectory: "FirstLaunchIntro/assets"))
    }

    func testCopyIsTranslated() throws {
        try skipUnlessEnglishInterface()
        let keys = FirstRunCopy.allStrings + ["Welcome to Lineform"]
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "'\(key)' is not translated in \(language)")
            }
        }
    }

    func testEveryPointHasItsOwnSymbol() {
        XCTAssertEqual(FirstRunCopy.pointItems.count, 4)
        for point in FirstRunCopy.pointItems {
            XCTAssertNotNil(UIImage(systemName: point.symbol), "'\(point.symbol)' is not an SF Symbol")
            XCTAssertFalse(point.title.isEmpty)
            XCTAssertFalse(point.text.isEmpty)
        }
        XCTAssertNotNil(UIImage(systemName: "arrow.right"), "Get Started's arrow")
    }

    // MARK: - Layout

    // MARK: - Web view

    func testNavigationAllowsOnlyFiles() {
        typealias Coordinator = FirstRunLineView.Coordinator
        XCTAssertTrue(Coordinator.allows(URL(fileURLWithPath: "/tmp/index.html")))
        XCTAssertFalse(Coordinator.allows(URL(string: "https://lineform.app")))
        XCTAssertFalse(Coordinator.allows(URL(string: "http://example.com")))
        XCTAssertFalse(Coordinator.allows(URL(string: "about:blank")))
        XCTAssertFalse(Coordinator.allows(URL(string: "data:text/html,hi")))
        XCTAssertFalse(Coordinator.allows(nil))
    }

    func testLocalOnlyContentRulesCompile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FirstRunRules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let rules = try await store.compileContentRuleList(
            forIdentifier: FirstRunLineView.contentRuleListIdentifier,
            encodedContentRuleList: FirstRunLineView.localOnlyContentRules
        )
        XCTAssertNotNil(rules)
    }

    func testPageAdjustmentSlowsTheWriteAndPostsWrittenOnce() {
        let script = FirstRunLineView.pageAdjustmentScript
        XCTAssertTrue(script.contains("setControl('writeTime', 6, 3.5)"), "the write-on takes 3.5 s")
        XCTAssertTrue(script.contains("messageHandlers.\(FirstRunLineView.messageName).postMessage('written')"))
        XCTAssertTrue(script.contains("window.lineformQuiet"))
        XCTAssertTrue(FirstRunLineView.quietScript.contains("lineformQuiet"))
        // The page's own controls are hidden; the overlay draws the native tagline and buttons.
        XCTAssertTrue(script.contains(".intro-tagline, .start-button, .tuning-panel { display: none !important; }"))
        XCTAssertFalse(script.contains("http"), "the adjustment loads nothing")
    }

    /// The Mac's intro keeps its own timing and knows nothing of first run: the iPhone's changes
    /// are the injected script plus `lineformIntroColorBoost`, which the intro treats as 1 when
    /// absent (the Mac never sets it).
    func testMacIntroKeepsItsOwnBehaviour() throws {
        let folder = try XCTUnwrap(Bundle.main.url(forResource: "FirstLaunchIntro", withExtension: nil))
        let script = try String(contentsOf: folder.appendingPathComponent("intro.js"), encoding: .utf8)
        let html = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("id=\"writeTime\" type=\"range\" min=\"0.25\" max=\"1.6\" value=\"1\""), "the Mac writes in 1 s")
        XCTAssertFalse(script.contains("lineformFirstRun"))
        XCTAssertTrue(script.contains("Number(window.lineformIntroColorBoost) || 1"), "no boost unless the iPhone sets it")
    }

    // MARK: - Launch

    func testHostedLaunchNeverShowsFirstRun() {
        XCTAssertTrue(LineformiOSApp.isRunningUnderTests)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertFalse(windows.contains { Self.containsWebView($0) }, "the test host shows no first run")
    }

    private static func containsWebView(_ view: UIView) -> Bool {
        view is WKWebView || view.subviews.contains { containsWebView($0) }
    }

    // MARK: - Presentation latch

    func testRestoredSceneEndsFirstRunForGood() {
        var presentation = FirstRunPresentation(launchWantsFirstRun: true)
        XCTAssertTrue(presentation.restored(bookmark: "abc=", path: ""))
        XCTAssertFalse(presentation.isShowing)
        XCTAssertFalse(presentation.restored(bookmark: "", path: ""), "a later empty bookmark does not bring it back")
        XCTAssertFalse(presentation.isShowing)
    }

    func testOpenedDocumentEndsFirstRunForGood() {
        var presentation = FirstRunPresentation(launchWantsFirstRun: true)
        XCTAssertFalse(presentation.restored(bookmark: "", path: ""))
        XCTAssertTrue(presentation.isShowing)
        XCTAssertTrue(presentation.documentOpened())
        XCTAssertFalse(presentation.documentOpened(), "ends once")
        XCTAssertFalse(presentation.restored(bookmark: "", path: ""), "New Document's empty bookmark does not re-arm it")
        XCTAssertFalse(presentation.isShowing)
    }

    func testLaunchThatDoesNotWantFirstRunNeverShowsIt() {
        var presentation = FirstRunPresentation(launchWantsFirstRun: false)
        XCTAssertFalse(presentation.restored(bookmark: "", path: ""))
        XCTAssertFalse(presentation.documentOpened())
        XCTAssertFalse(presentation.isShowing)
    }

    func testFinishingEndsFirstRun() {
        var presentation = FirstRunPresentation(launchWantsFirstRun: true)
        presentation.finished()
        XCTAssertFalse(presentation.isShowing)
        XCTAssertFalse(presentation.restored(bookmark: "", path: ""))
        XCTAssertFalse(presentation.isShowing)
    }
}

/// Counts writes of the first-run flag.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var completedWrites = 0

    override func set(_ value: Bool, forKey defaultName: String) {
        if defaultName == FirstRunGate.completedKey { completedWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
