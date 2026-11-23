import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// The App Store review prompt on iPhone: the Mac's policy (`AppReviewPromptStore`) — four
/// sessions with a real file write, spanning a week, a write in this session, at most once per
/// version, the system sheet only (`AppStore.requestReview(in:)`), only after a quiet period and
/// with nothing else on screen. No test asks StoreKit for the sheet: the request is injected.
@MainActor
final class PhoneReviewPromptTests: XCTestCase {
    private var suites: [String] = []
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The policy (the Mac's)

    func testTheKeysAndThresholdsAreTheMacs() {
        XCTAssertEqual(PhoneReviewPromptStore.engagedSessionCountKey, "Lineform.review.engagedSessionCount")
        XCTAssertEqual(PhoneReviewPromptStore.firstEngagedDateKey, "Lineform.review.firstEngagedDate")
        XCTAssertEqual(PhoneReviewPromptStore.lastPromptedVersionKey, "Lineform.review.lastPromptedVersion")
        XCTAssertEqual(PhoneReviewPromptStore.requiredEngagedSessions, 4)
        XCTAssertEqual(PhoneReviewPromptStore.minimumEngagementAge, 7 * 24 * 60 * 60)
        XCTAssertEqual(PhoneReviewPromptStore.presentationDelay, .seconds(4))
    }

    func testManyWritesAreOneSessionAndRestartTheQuietPeriod() throws {
        let defaults = try makeDefaults()
        let store = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9", now: Date.init, forcePrompt: false)
        store.recordSuccessfulWrite()
        store.recordSuccessfulWrite()
        store.recordSuccessfulWrite()
        XCTAssertEqual(defaults.integer(forKey: PhoneReviewPromptStore.engagedSessionCountKey), 1)
        XCTAssertEqual(store.activityRevision, 3)
        XCTAssertFalse(store.isEligible())
    }

    func testFourSessionsAcrossAWeekWithAWriteNowBecomeEligibleOncePerVersion() throws {
        let defaults = try makeDefaults()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for offset in [0.0, 60, 120] {
            let session = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9",
                                                 now: { start.addingTimeInterval(offset) }, forcePrompt: false)
            session.recordSuccessfulWrite()
            XCTAssertFalse(session.isEligible())
        }
        let early = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9",
                                           now: { start.addingTimeInterval(60 * 60) }, forcePrompt: false)
        XCTAssertFalse(early.isEligible(), "no write in this session yet")
        early.recordSuccessfulWrite()
        XCTAssertFalse(early.isEligible(), "four sessions, but not a week yet")

        let fourth = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9",
                                            now: { start.addingTimeInterval(PhoneReviewPromptStore.minimumEngagementAge + 1) },
                                            forcePrompt: false)
        fourth.recordSuccessfulWrite()
        XCTAssertTrue(fourth.isEligible())
        XCTAssertTrue(fourth.claimPromptIfEligible())
        XCTAssertFalse(fourth.claimPromptIfEligible(), "at most once per version")
        XCTAssertEqual(defaults.string(forKey: PhoneReviewPromptStore.lastPromptedVersionKey), "1.9")

        let nextVersion = PhoneReviewPromptStore(defaults: defaults, appVersion: "2.0",
                                                 now: { start.addingTimeInterval(PhoneReviewPromptStore.minimumEngagementAge * 2) },
                                                 forcePrompt: false)
        nextVersion.recordSuccessfulWrite()
        XCTAssertTrue(nextVersion.isEligible())
    }

    func testACorruptCountIsCapped() throws {
        let defaults = try makeDefaults()
        defaults.set(Int.max, forKey: PhoneReviewPromptStore.engagedSessionCountKey)
        let store = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9", now: Date.init, forcePrompt: false)
        store.recordSuccessfulWrite()
        XCTAssertEqual(defaults.integer(forKey: PhoneReviewPromptStore.engagedSessionCountKey), PhoneReviewPromptStore.requiredEngagedSessions)
    }

    /// Returning to the foreground schedules again only when eligible, and never counts as use.
    func testReturningToTheForegroundNeverCountsAsUse() throws {
        let defaults = try makeDefaults()
        let store = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9", now: Date.init, forcePrompt: false)
        store.reconsiderPresentation()
        XCTAssertEqual(store.activityRevision, 0)
        XCTAssertEqual(defaults.integer(forKey: PhoneReviewPromptStore.engagedSessionCountKey), 0)
    }

    /// The test host is the app: the app's shared store records nothing there, so test runs never
    /// add up to a review request.
    func testTheSharedStoreIsInertUnderTests() {
        XCTAssertFalse(PhoneReviewPromptStore.shared.recordsEngagement)
        let before = PhoneReviewPromptStore.shared.activityRevision
        PhoneReviewPromptStore.shared.recordSuccessfulWrite()
        XCTAssertEqual(PhoneReviewPromptStore.shared.activityRevision, before)
        XCTAssertFalse(PhoneReviewPromptStore.shared.isEligible())
    }

    // MARK: Asking

    func testAsksAfterTheQuietPeriodOnlyWhenNothingIsInTheWay() async throws {
        let defaults = try makeDefaults()
        let store = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9", now: Date.init, forcePrompt: true)
        var requests = 0
        await store.requestAfterQuietPeriod(delay: .zero, canPresent: { false }, request: { requests += 1 })
        XCTAssertEqual(requests, 0, "something on screen: no request, and the version is not used up")
        XCTAssertNil(defaults.string(forKey: PhoneReviewPromptStore.lastPromptedVersionKey))

        await store.requestAfterQuietPeriod(delay: .zero, canPresent: { true }, request: { requests += 1 })
        XCTAssertEqual(requests, 1)
        await store.requestAfterQuietPeriod(delay: .zero, canPresent: { true }, request: { requests += 1 })
        XCTAssertEqual(requests, 1, "once per version")
    }

    func testANewWriteDuringTheQuietPeriodCancelsTheRequest() async throws {
        let defaults = try makeDefaults()
        let store = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9", now: Date.init, forcePrompt: true)
        var requests = 0
        let task = Task { await store.requestAfterQuietPeriod(delay: .seconds(2), canPresent: { true }, request: { requests += 1 }) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        XCTAssertEqual(requests, 0)
    }

    func testNotEligibleNeverAsks() async throws {
        let defaults = try makeDefaults()
        let store = PhoneReviewPromptStore(defaults: defaults, appVersion: "1.9", now: Date.init, forcePrompt: false)
        var requests = 0
        await store.requestAfterQuietPeriod(delay: .zero, canPresent: { true }, request: { requests += 1 })
        XCTAssertEqual(requests, 0)
    }

    func testCanPresentOnlyWhenActiveAndUnobstructed() {
        XCTAssertTrue(PhoneReviewPromptStore.canPresent(isSceneActive: true, hasPresentedController: false, hasInAppObstruction: false))
        XCTAssertFalse(PhoneReviewPromptStore.canPresent(isSceneActive: false, hasPresentedController: false, hasInAppObstruction: false))
        XCTAssertFalse(PhoneReviewPromptStore.canPresent(isSceneActive: true, hasPresentedController: true, hasInAppObstruction: false))
        XCTAssertFalse(PhoneReviewPromptStore.canPresent(isSceneActive: true, hasPresentedController: false, hasInAppObstruction: true))
    }

    // MARK: What counts as use: a write that reached disk

    func testOnlyARealWriteCounts() async throws {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder })
        await document.prepare()
        var writes = 0
        document.onConfirmedWrite = { writes += 1 }

        await document.flush()
        XCTAssertEqual(writes, 0, "nothing to save is not use")
        document.edit("   \n")
        await document.flush()
        XCTAssertEqual(writes, 0, "a blank document makes no file")

        document.edit("Title\n")
        await document.flush()
        XCTAssertEqual(writes, 1, "the first save creates the file")
        document.edit("Title\nMore")
        await document.flush()
        XCTAssertEqual(writes, 2, "an ordinary save")
        document.edit("Renamed\nMore")
        await document.flush()
        XCTAssertEqual(writes, 3, "a first-line rename and its write")
    }

    func testAFailedWriteDoesNotCount() async throws {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, writer: FailingWriter())
        await document.prepare()
        var writes = 0
        document.onConfirmedWrite = { writes += 1 }
        document.edit("Title\n")
        let saved = await document.flush()
        XCTAssertFalse(saved)
        XCTAssertEqual(writes, 0)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "review-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
}
