import UIKit
import WebKit
import XCTest
@testable import LineformiOS

/// First run (roadmap step 11): the launch gate, the stage order, the copy and the bundled line
/// animation.
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

    func testStagesRunInOrder() {
        XCTAssertEqual(FirstRunStage.allCases, [.line, .expect, .points, .done])
        XCTAssertEqual(FirstRunStage.line.next, .expect)
        XCTAssertEqual(FirstRunStage.expect.next, .points)
        XCTAssertEqual(FirstRunStage.points.next, .done)
    }

    func testAdvancePastDoneIsIgnored() {
        XCTAssertEqual(FirstRunStage.done.next, .done)
    }

    func testOnlyTimedStagesAdvanceThemselves() {
        for reduceMotion in [false, true] {
            XCTAssertNotNil(FirstRunStage.line.autoAdvanceDelay(reduceMotion: reduceMotion))
            XCTAssertNotNil(FirstRunStage.expect.autoAdvanceDelay(reduceMotion: reduceMotion))
            XCTAssertNil(FirstRunStage.points.autoAdvanceDelay(reduceMotion: reduceMotion))
            XCTAssertNil(FirstRunStage.done.autoAdvanceDelay(reduceMotion: reduceMotion))
        }
    }

    // MARK: - Copy and resources

    func testCopyIsTheSpecWording() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(FirstRunCopy.points, [
            "Free, and everything stays on your device.",
            "Your files stay in iCloud, and sync with Lineform on your Mac if you use it there.",
            "Markdown, styled PDFs, and AI only if you connect your own.",
        ])
        XCTAssertEqual(FirstRunCopy.heading, "What to expect")
        XCTAssertEqual(FirstRunCopy.startWriting, "Start Writing")
    }

    func testIntroResourcesAreBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FirstLaunchIntro"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Lineform", withExtension: "svg", subdirectory: "FirstLaunchIntro/assets"))
    }

    func testCopyIsTranslated() throws {
        try skipUnlessEnglishInterface()
        let keys = [FirstRunCopy.heading] + FirstRunCopy.points + [
            FirstRunCopy.startWriting, "Continue", "Welcome to Lineform", "Simple markdown editing",
        ]
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "'\(key)' is not translated in \(language)")
            }
        }
    }

    func testReduceMotionHoldsTheFinishedLineShorter() throws {
        let normal = try XCTUnwrap(FirstRunStage.line.autoAdvanceDelay(reduceMotion: false))
        let reduced = try XCTUnwrap(FirstRunStage.line.autoAdvanceDelay(reduceMotion: true))
        XCTAssertLessThan(reduced, normal)
    }

    // MARK: - Line timing

    func testLineHoldRunsFromThePagesFirstFrame() throws {
        let start = ContinuousClock.now
        let ready = start + .seconds(1)
        let deadline = try XCTUnwrap(FirstRunTiming.deadline(for: .line, stageStart: start, lineReadyAt: ready, reduceMotion: false))
        XCTAssertEqual(deadline, ready + .milliseconds(2600))
        let reduced = try XCTUnwrap(FirstRunTiming.deadline(for: .line, stageStart: start, lineReadyAt: ready, reduceMotion: true))
        XCTAssertEqual(reduced, ready + .milliseconds(1200))
    }

    func testLineAdvancesAtTheCapWhenThePageNeverPaintsOrPaintsLate() {
        let start = ContinuousClock.now
        XCTAssertEqual(FirstRunTiming.deadline(for: .line, stageStart: start, lineReadyAt: nil, reduceMotion: false), start + .seconds(4))
        XCTAssertEqual(
            FirstRunTiming.deadline(for: .line, stageStart: start, lineReadyAt: start + .seconds(3), reduceMotion: false),
            start + .seconds(4)
        )
    }

    func testOtherStagesTimeFromTheirStart() {
        let start = ContinuousClock.now
        XCTAssertEqual(FirstRunTiming.deadline(for: .expect, stageStart: start, lineReadyAt: nil, reduceMotion: false), start + .milliseconds(1800))
        XCTAssertNil(FirstRunTiming.deadline(for: .points, stageStart: start, lineReadyAt: nil, reduceMotion: false))
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

    // MARK: - Flow

    func testDoubleAdvanceFinishesOnceAndWritesTheFlagOnce() throws {
        let counting = try XCTUnwrap(CountingDefaults(suiteName: suiteName))
        var finishes = 0
        let start = ContinuousClock.now
        let flow = FirstRunFlow(defaults: counting, now: start) { finishes += 1 }
        flow.userAdvance(at: start + .seconds(1))
        flow.userAdvance(at: start + .seconds(2))
        XCTAssertEqual(flow.stage, .points)
        XCTAssertTrue(flow.userAdvance(at: start + .seconds(3)))
        XCTAssertFalse(flow.userAdvance(at: start + .seconds(4)))
        XCTAssertFalse(flow.autoAdvance(from: .done, at: start + .seconds(5)))
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(counting.completedWrites, 1)
        XCTAssertTrue(counting.bool(forKey: FirstRunGate.completedKey))
        XCTAssertTrue(flow.hasFinished)
    }

    func testFlagIsWrittenOnlyOnReachingDone() {
        let start = ContinuousClock.now
        var finishes = 0
        let flow = FirstRunFlow(defaults: defaults, now: start) { finishes += 1 }
        flow.autoAdvance(from: .line, at: start + .seconds(3))
        flow.autoAdvance(from: .expect, at: start + .seconds(5))
        XCTAssertEqual(flow.stage, .points)
        XCTAssertFalse(defaults.bool(forKey: FirstRunGate.completedKey))
        XCTAssertEqual(finishes, 0)
        flow.userAdvance(at: start + .seconds(6))
        XCTAssertEqual(flow.stage, .done)
        XCTAssertTrue(defaults.bool(forKey: FirstRunGate.completedKey))
        XCTAssertEqual(finishes, 1)
    }

    func testTapRightAfterTheTimerDoesNotSkipAStage() {
        let start = ContinuousClock.now
        let flow = FirstRunFlow(defaults: defaults, now: start) {}
        XCTAssertTrue(flow.autoAdvance(from: .line, at: start + .seconds(3)))
        XCTAssertFalse(flow.userAdvance(at: start + .seconds(3) + .milliseconds(50)))
        XCTAssertEqual(flow.stage, .expect, "the heading is not skipped")
        XCTAssertTrue(flow.userAdvance(at: start + .seconds(3) + .milliseconds(200)))
        XCTAssertEqual(flow.stage, .points)
    }

    func testTimerForAStageAlreadyLeftDoesNothing() {
        let start = ContinuousClock.now
        let flow = FirstRunFlow(defaults: defaults, now: start) {}
        flow.userAdvance(at: start + .seconds(1))
        XCTAssertFalse(flow.autoAdvance(from: .line, at: start + .seconds(1)))
        XCTAssertEqual(flow.stage, .expect)
    }

    func testOnlyTheFirstReadySignalOnTheLineCounts() {
        let start = ContinuousClock.now
        let flow = FirstRunFlow(defaults: defaults, now: start) {}
        flow.lineDidBecomeReady(at: start + .seconds(1))
        flow.lineDidBecomeReady(at: start + .seconds(2))
        XCTAssertEqual(flow.lineReadyAt, start + .seconds(1))
        XCTAssertEqual(flow.autoAdvanceDeadline(reduceMotion: false), start + .seconds(1) + .milliseconds(2600))
    }

    // MARK: - Points

    func testEveryPointHasItsOwnSymbol() {
        XCTAssertEqual(FirstRunCopy.pointItems.map(\.text), FirstRunCopy.points)
        XCTAssertEqual(FirstRunCopy.pointItems.count, FirstRunCopy.points.count)
        for point in FirstRunCopy.pointItems {
            XCTAssertNotNil(UIImage(systemName: point.symbol), "'\(point.symbol)' is not an SF Symbol")
        }
    }

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

    func testTaglineInjectionIsEscaped() throws {
        let hostile = "Say \"hi\" \\ it's </script><script>alert(1)</script>\nnext"
        let script = try XCTUnwrap(FirstRunLineView.pageAdjustmentScript(tagline: hostile))
        XCTAssertFalse(script.contains("</script>"), "a closing script tag cannot appear in the injected source")
        let literal = try XCTUnwrap(FirstRunLineView.javaScriptStringLiteral(hostile))
        XCTAssertTrue(script.contains("tagline.textContent = \(literal);"))
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        XCTAssertEqual(decoded, hostile, "the literal reads back as exactly the tagline")
    }

    func testReadyScriptPostsToTheRemovedHandlerName() {
        XCTAssertTrue(FirstRunLineView.readyScript.contains("messageHandlers.\(FirstRunLineView.readyMessageName).postMessage(\"ready\")"))
        XCTAssertTrue(FirstRunLineView.readyScript.contains("requestAnimationFrame"))
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
}

/// Counts writes of the first-run flag.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var completedWrites = 0

    override func set(_ value: Bool, forKey defaultName: String) {
        if defaultName == FirstRunGate.completedKey { completedWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
