import Foundation
import SwiftUI

/// Tracks enough local, meaningful use to ask StoreKit for Apple's review prompt.
///
/// There is deliberately no custom "Do you like Lineform?" pre-prompt. Apple's review
/// guidelines require the system prompt, and StoreKit owns its wording, buttons, rating
/// limits, and decision about whether a request is shown at all.
@MainActor
final class AppReviewPromptStore: ObservableObject {
    static let shared = AppReviewPromptStore()

    static let engagedSessionCountKey = "Lineform.review.engagedSessionCount"
    static let firstEngagedDateKey = "Lineform.review.firstEngagedDate"
    static let lastPromptedVersionKey = "Lineform.review.lastPromptedVersion"

    /// Four separate app sessions with a real file write is enough to demonstrate use
    /// without equating launches, browsing, or an untouched document with engagement.
    static let requiredEngagedSessions = 4
    static let minimumEngagementAge: TimeInterval = 7 * 24 * 60 * 60
    static let presentationDelay: Duration = .seconds(4)

    /// Every real write advances this token. The presenting view uses it to restart its
    /// quiet-period delay, so the system sheet never appears while autosaves are active.
    @Published private(set) var activityRevision = 0

    private let defaults: UserDefaults
    private let appVersion: String
    private let now: () -> Date
    private let forcePrompt: Bool
    private var recordedEngagementThisSession = false

    init(
        defaults: UserDefaults = .standard,
        appVersion: String = AppReviewPromptStore.bundleShortVersion(),
        now: @escaping () -> Date = Date.init,
        forcePrompt: Bool = AppReviewPromptStore.debugForcePrompt
    ) {
        self.defaults = defaults
        self.appVersion = appVersion
        self.now = now
        self.forcePrompt = forcePrompt
        #if DEBUG
        if forcePrompt {
            Self.debugLog("eligibility forced for local QA")
        }
        #endif
    }

    nonisolated static func bundleShortVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Development-only inspection seam. Release builds cannot force eligibility.
    nonisolated static var debugForcePrompt: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LINEFORM_FORCE_REVIEW_PROMPT"] == "1"
        #else
        false
        #endif
    }

    #if DEBUG
    nonisolated static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("Lineform review prompt QA: \(message)\n".utf8))
    }
    #endif

    /// Called only after the document system has completed a real source-file write.
    /// Multiple autosaves in one process still count as one engaged session.
    func recordSuccessfulWrite() {
        if !recordedEngagementThisSession {
            recordedEngagementThisSession = true
            let existingCount = max(0, defaults.integer(forKey: Self.engagedSessionCountKey))
            let nextCount = existingCount >= Self.requiredEngagedSessions
                ? Self.requiredEngagedSessions
                : existingCount + 1
            defaults.set(
                nextCount,
                forKey: Self.engagedSessionCountKey
            )
            if defaults.object(forKey: Self.firstEngagedDateKey) as? Date == nil {
                defaults.set(now(), forKey: Self.firstEngagedDateKey)
            }
        }

        activityRevision = activityRevision == Int.max ? 0 : activityRevision + 1
    }

    /// Pure eligibility check. It does not consume the opportunity because the active
    /// window may still be unavailable or obstructed when its quiet-period timer fires.
    func isEligible() -> Bool {
        guard defaults.string(forKey: Self.lastPromptedVersionKey) != appVersion else { return false }
        if forcePrompt { return true }
        guard recordedEngagementThisSession else { return false }
        guard defaults.integer(forKey: Self.engagedSessionCountKey) >= Self.requiredEngagedSessions else {
            return false
        }
        guard let firstDate = defaults.object(forKey: Self.firstEngagedDateKey) as? Date else {
            return false
        }
        return now().timeIntervalSince(firstDate) >= Self.minimumEngagementAge
    }

    /// Atomically rechecks and marks this app version before StoreKit is called. Every
    /// Lineform window observes the shared store; this claim prevents two windows from
    /// requesting the sheet together. StoreKit may still suppress the system prompt.
    func claimPromptIfEligible() -> Bool {
        guard isEligible() else { return false }
        defaults.set(appVersion, forKey: Self.lastPromptedVersionKey)
        return true
    }

    #if DEBUG
    var engagedSessionCountForTesting: Int {
        defaults.integer(forKey: Self.engagedSessionCountKey)
    }
    #endif
}
