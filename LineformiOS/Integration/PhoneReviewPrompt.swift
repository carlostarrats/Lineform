import Combine
import Foundation

/// When Lineform asks StoreKit for the App Store review sheet on iPhone: the Mac's
/// `AppReviewPromptStore` policy, under the Mac's keys (per device).
///
/// There is no custom "Do you like Lineform?" pre-prompt: App Review guideline 5.6.1 requires the
/// system sheet, and StoreKit owns its wording, buttons, limits and whether it shows at all.
/// What counts as use is a SUCCESSFUL SOURCE-FILE WRITE (`OpenDocument.onConfirmedWrite`):
/// launches, reading, browsing and edits that never reached disk do not. Eligible after four
/// sessions with such a write, spanning at least seven days, and another write in this session;
/// asked at most once per marketing version, claimed just before the request. The screen asks only
/// after writes have been quiet for `presentationDelay`, while the scene is active and nothing of
/// Lineform's is on screen over the page.
@MainActor
final class PhoneReviewPromptStore: ObservableObject {
    /// The app's store. Inert in the test host (`recordsEngagement` false): the test host is the
    /// app, and test runs writing documents must never add up to a review request.
    static let shared = PhoneReviewPromptStore(recordsEngagement: !LineformiOSApp.isRunningUnderTests)

    static let engagedSessionCountKey = "Lineform.review.engagedSessionCount"
    static let firstEngagedDateKey = "Lineform.review.firstEngagedDate"
    static let lastPromptedVersionKey = "Lineform.review.lastPromptedVersion"

    static let requiredEngagedSessions = 4
    static let minimumEngagementAge: TimeInterval = 7 * 24 * 60 * 60
    static let presentationDelay: Duration = .seconds(4)

    /// Every real write advances this token; the screen restarts its quiet-period task on it.
    @Published private(set) var activityRevision = 0

    /// False only for the app's store in the test host: nothing is recorded or asked.
    let recordsEngagement: Bool
    private let defaults: UserDefaults
    private let appVersion: String
    private let now: () -> Date
    private let forcePrompt: Bool
    private var recordedEngagementThisSession = false

    init(
        defaults: UserDefaults = .standard,
        appVersion: String = PhoneUpdateCommand.bundleShortVersion(),
        now: @escaping () -> Date = Date.init,
        forcePrompt: Bool = PhoneReviewPromptStore.debugForcePrompt,
        recordsEngagement: Bool = true
    ) {
        self.defaults = defaults
        self.appVersion = appVersion
        self.now = now
        self.forcePrompt = forcePrompt
        self.recordsEngagement = recordsEngagement
    }

    /// Development-only seam (`LINEFORM_FORCE_REVIEW_PROMPT=1`, the Mac's). Release builds
    /// cannot force eligibility.
    nonisolated static var debugForcePrompt: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LINEFORM_FORCE_REVIEW_PROMPT"] == "1"
        #else
        false
        #endif
    }

    /// Whether the sheet may be requested now: the scene is in the foreground, nothing is
    /// presented over the page, and nothing of Lineform's (a card, the selection row, History, a
    /// notice) is in the way.
    nonisolated static func canPresent(isSceneActive: Bool, hasPresentedController: Bool, hasInAppObstruction: Bool) -> Bool {
        isSceneActive && !hasPresentedController && !hasInAppObstruction
    }

    /// Called only after a source-file write reached disk. Many writes in one process are one
    /// engaged session; each one restarts the quiet period.
    func recordSuccessfulWrite() {
        guard recordsEngagement else { return }
        if !recordedEngagementThisSession {
            recordedEngagementThisSession = true
            let existing = max(0, defaults.integer(forKey: Self.engagedSessionCountKey))
            let next = existing >= Self.requiredEngagedSessions ? Self.requiredEngagedSessions : existing + 1
            defaults.set(next, forKey: Self.engagedSessionCountKey)
            if defaults.object(forKey: Self.firstEngagedDateKey) as? Date == nil {
                defaults.set(now(), forKey: Self.firstEngagedDateKey)
            }
        }
        activityRevision = activityRevision == Int.max ? 0 : activityRevision + 1
    }

    /// Back in the foreground: schedule again if eligible. Never counts as use.
    func reconsiderPresentation() {
        guard isEligible() else { return }
        activityRevision = activityRevision == Int.max ? 0 : activityRevision + 1
    }

    /// Pure eligibility; consumes nothing.
    func isEligible() -> Bool {
        guard recordsEngagement else { return false }
        guard defaults.string(forKey: Self.lastPromptedVersionKey) != appVersion else { return false }
        if forcePrompt { return true }
        guard recordedEngagementThisSession else { return false }
        guard defaults.integer(forKey: Self.engagedSessionCountKey) >= Self.requiredEngagedSessions else { return false }
        guard let first = defaults.object(forKey: Self.firstEngagedDateKey) as? Date else { return false }
        return now().timeIntervalSince(first) >= Self.minimumEngagementAge
    }

    /// Rechecks and marks this version immediately before StoreKit is called.
    func claimPromptIfEligible() -> Bool {
        guard isEligible() else { return false }
        defaults.set(appVersion, forKey: Self.lastPromptedVersionKey)
        return true
    }

    /// Waits out the quiet period, then asks once if still eligible and nothing is in the way.
    /// A new write cancels the task (the screen's `.task(id: activityRevision)`), so the sheet
    /// never comes up while autosaves are running. `request` is `AppStore.requestReview(in:)` in
    /// the app; tests inject it.
    func requestAfterQuietPeriod(
        delay: Duration = PhoneReviewPromptStore.presentationDelay,
        canPresent: () -> Bool,
        request: () -> Void
    ) async {
        guard isEligible() else { return }
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        guard !Task.isCancelled, canPresent() else { return }
        guard claimPromptIfEligible() else { return }
        request()
    }
}
