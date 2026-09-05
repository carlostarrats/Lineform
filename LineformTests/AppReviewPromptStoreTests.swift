import XCTest
@testable import Lineform

@MainActor
final class AppReviewPromptStoreTests: XCTestCase {
    func testMultipleWritesCountAsOneEngagedSession() {
        let defaults = freshDefaults("AppReviewOneSession")
        let store = AppReviewPromptStore(
            defaults: defaults,
            appVersion: "1.7",
            now: Date.init,
            forcePrompt: false
        )

        store.recordSuccessfulWrite()
        store.recordSuccessfulWrite()
        store.recordSuccessfulWrite()

        XCTAssertEqual(store.engagedSessionCountForTesting, 1)
        XCTAssertEqual(store.activityRevision, 3, "every write must restart the quiet-period timer")
        XCTAssertFalse(store.isEligible())
    }

    func testCorruptOversizedSessionCountIsSafelyCapped() {
        let defaults = freshDefaults("AppReviewOversizedCount")
        defaults.set(Int.max, forKey: AppReviewPromptStore.engagedSessionCountKey)
        let store = AppReviewPromptStore(
            defaults: defaults,
            appVersion: "1.7",
            now: Date.init,
            forcePrompt: false
        )

        store.recordSuccessfulWrite()

        XCTAssertEqual(store.engagedSessionCountForTesting, AppReviewPromptStore.requiredEngagedSessions)
    }

    func testFourEngagedSessionsAcrossAWeekBecomeEligible() {
        let defaults = freshDefaults("AppReviewEligible")
        let start = Date(timeIntervalSince1970: 1_000_000)

        for offset in [0.0, 60, 120] {
            let session = AppReviewPromptStore(
                defaults: defaults,
                appVersion: "1.7",
                now: { start.addingTimeInterval(offset) },
                forcePrompt: false
            )
            session.recordSuccessfulWrite()
            XCTAssertFalse(session.isEligible())
        }

        let fourthSession = AppReviewPromptStore(
            defaults: defaults,
            appVersion: "1.7",
            now: { start.addingTimeInterval(AppReviewPromptStore.minimumEngagementAge + 1) },
            forcePrompt: false
        )
        fourthSession.recordSuccessfulWrite()

        XCTAssertEqual(fourthSession.engagedSessionCountForTesting, 4)
        XCTAssertTrue(fourthSession.isEligible())
    }

    func testSessionThresholdCannotBypassMinimumAge() {
        let defaults = freshDefaults("AppReviewMinimumAge")
        let start = Date(timeIntervalSince1970: 2_000_000)
        defaults.set(AppReviewPromptStore.requiredEngagedSessions - 1, forKey: AppReviewPromptStore.engagedSessionCountKey)
        defaults.set(start, forKey: AppReviewPromptStore.firstEngagedDateKey)

        let store = AppReviewPromptStore(
            defaults: defaults,
            appVersion: "1.7",
            now: { start.addingTimeInterval(AppReviewPromptStore.minimumEngagementAge - 1) },
            forcePrompt: false
        )
        store.recordSuccessfulWrite()

        XCTAssertEqual(store.engagedSessionCountForTesting, AppReviewPromptStore.requiredEngagedSessions)
        XCTAssertFalse(store.isEligible())
    }

    func testClaimAllowsOnlyOneRequestPerAppVersion() {
        let defaults = eligibleDefaults("AppReviewClaim")
        let store = eligibleStore(defaults: defaults, appVersion: "1.7")
        store.recordSuccessfulWrite()

        XCTAssertTrue(store.claimPromptIfEligible())
        XCTAssertEqual(defaults.string(forKey: AppReviewPromptStore.lastPromptedVersionKey), "1.7")
        XCTAssertFalse(store.isEligible())
        XCTAssertFalse(store.claimPromptIfEligible())
    }

    func testNewAppVersionCanAskAgainAfterARealWrite() {
        let defaults = eligibleDefaults("AppReviewNewVersion")
        defaults.set("1.7", forKey: AppReviewPromptStore.lastPromptedVersionKey)

        let oldVersion = eligibleStore(defaults: defaults, appVersion: "1.7")
        oldVersion.recordSuccessfulWrite()
        XCTAssertFalse(oldVersion.isEligible())

        let newVersion = eligibleStore(defaults: defaults, appVersion: "1.8")
        XCTAssertFalse(newVersion.isEligible(), "a launch alone is not meaningful use")
        newVersion.recordSuccessfulWrite()
        XCTAssertTrue(newVersion.isEligible())
    }

    func testDebugForceBypassesProductionThresholds() {
        let store = AppReviewPromptStore(
            defaults: freshDefaults("AppReviewForce"),
            appVersion: "1.7",
            now: Date.init,
            forcePrompt: true
        )

        XCTAssertTrue(store.isEligible())
        XCTAssertTrue(store.claimPromptIfEligible())
        XCTAssertFalse(store.claimPromptIfEligible(), "the force seam must not create duplicate requests")
    }

    func testForegroundReconsiderationDoesNotCreateEngagement() {
        let store = AppReviewPromptStore(
            defaults: freshDefaults("AppReviewActivation"),
            appVersion: "1.7",
            now: Date.init,
            forcePrompt: false
        )

        store.reconsiderPresentation()

        XCTAssertEqual(store.activityRevision, 0)
        XCTAssertEqual(store.engagedSessionCountForTesting, 0)
    }

    func testPresentationRequiresAnActiveUnobstructedMainWindow() {
        XCTAssertTrue(AppReviewPromptStore.canPresent(
            isApplicationActive: true,
            isMainWindow: true,
            hasAttachedSheet: false,
            hasModalWindow: false,
            hasInAppObstruction: false
        ))

        for blocked in [
            (false, true, false, false, false),
            (true, false, false, false, false),
            (true, true, true, false, false),
            (true, true, false, true, false),
            (true, true, false, false, true)
        ] {
            XCTAssertFalse(AppReviewPromptStore.canPresent(
                isApplicationActive: blocked.0,
                isMainWindow: blocked.1,
                hasAttachedSheet: blocked.2,
                hasModalWindow: blocked.3,
                hasInAppObstruction: blocked.4
            ))
        }
    }

    private func eligibleDefaults(_ label: String) -> UserDefaults {
        let defaults = freshDefaults(label)
        defaults.set(AppReviewPromptStore.requiredEngagedSessions, forKey: AppReviewPromptStore.engagedSessionCountKey)
        defaults.set(
            Date().addingTimeInterval(-AppReviewPromptStore.minimumEngagementAge - 1),
            forKey: AppReviewPromptStore.firstEngagedDateKey
        )
        return defaults
    }

    private func eligibleStore(defaults: UserDefaults, appVersion: String) -> AppReviewPromptStore {
        AppReviewPromptStore(
            defaults: defaults,
            appVersion: appVersion,
            now: Date.init,
            forcePrompt: false
        )
    }

    private func freshDefaults(_ label: String) -> UserDefaults {
        TestDefaults.makeSuite(label)
    }
}
