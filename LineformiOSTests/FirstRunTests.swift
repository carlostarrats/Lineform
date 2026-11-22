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

    func testCopyIsTheSpecWording() {
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
}
