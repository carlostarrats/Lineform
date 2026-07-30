import Foundation
import SwiftUI

/// Owns the announcement lifecycle: when to check, what to show, what's been dismissed.
///
/// Mirrors the `LineformSettingsStore` pattern — shared `ObservableObject`,
/// `UserDefaults` keys, injectable defaults and clock for tests.
///
/// Unlike that store this one does NOT need `Published(initialValue:)` backing storage:
/// the only observed property here (`dismissedIDs`) is assigned once inside `init`, and
/// Swift does not run property observers for a property's initializing assignment — so
/// there is no write-back of the value just read. Add a SECOND assignment in `init` and
/// that stops being true.
@MainActor
final class AnnouncementStore: ObservableObject {
    static let shared = AnnouncementStore()

    static let dismissedIDsKey = "Lineform.announcements.dismissedIDs"
    static let lastCheckDateKey = "Lineform.announcements.lastCheckDate"
    /// The last successfully-read feed, in the feed's own wire format. Cached because
    /// the throttle governs the NETWORK CALL, not the card: without it an announcement
    /// the user never dismissed vanishes on the next launch and does not come back until
    /// the check falls due again, up to a day later.
    static let cachedFeedKey = "Lineform.announcements.cachedFeed"

    /// One check per day. The feed changes a few times a year; anything more frequent
    /// is a request the user pays for and never benefits from.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The announcement currently on screen, or nil. The card observes this.
    @Published private(set) var visible: Announcement?

    private let defaults: UserDefaults
    private let fetcher: AnnouncementFetching
    private let appVersion: String
    private let now: () -> Date

    /// Dismissed ids are kept FOREVER and never pruned against the live feed. An id
    /// that has fallen out of the feed costs a few bytes; re-showing an announcement
    /// the user already dismissed — which is what pruning against the feed would
    /// eventually cause — is the one behaviour this feature must never have.
    private var dismissedIDs: Set<String> {
        didSet {
            guard oldValue != dismissedIDs else { return }
            defaults.set(Array(dismissedIDs).sorted(), forKey: Self.dismissedIDsKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        fetcher: AnnouncementFetching = AnnouncementFetcher(),
        appVersion: String = AnnouncementStore.bundleShortVersion(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.appVersion = appVersion
        self.now = now
        self.dismissedIDs = Set(defaults.stringArray(forKey: Self.dismissedIDsKey) ?? [])
        // Restore from the cached feed immediately, so an undismissed announcement is
        // back on screen at launch rather than waiting on a check that may not be due.
        // Re-decoded through `AnnouncementFeed.decode`, so cached bytes face exactly the
        // same validation as freshly-fetched ones — one validator, no second path in.
        self.visible = Self.firstShowable(
            in: (defaults.data(forKey: Self.cachedFeedKey).flatMap(AnnouncementFeed.decode)) ?? [],
            dismissedIDs: dismissedIDs,
            appVersion: appVersion
        )
    }

    /// `nonisolated` so it can serve as a default argument to `init` — a main-actor
    /// static can't be called from the nonisolated context a default argument runs in.
    nonisolated static func bundleShortVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether enough time has passed to check again. A `lastCheck` in the FUTURE
    /// (clock moved backwards, or a restored-from-backup defaults plist) also counts
    /// as due — otherwise a bad clock could suppress checks indefinitely.
    func isCheckDue() -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckDateKey) as? Date else { return true }
        let elapsed = now().timeIntervalSince(last)
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    /// True when this process is a test host rather than a real launch.
    ///
    /// The test host IS the app, so `applicationDidFinishLaunching` runs during every
    /// `xcodebuild test`, which made the suite issue a live request to the production feed
    /// on each run. No test may touch the network, and a CI machine must not call out just
    /// because it ran the tests.
    ///
    /// This is checked at the LAUNCH CALL SITE, never inside `checkIfNeeded` — the store's
    /// own tests drive that method directly with a fake fetcher, and a guard in here would
    /// make every one of them a silent no-op that still passed.
    nonisolated static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Launch entry point. Returns without touching the network when the user has the
    /// setting off or a check isn't due — the toggle gates the REQUEST, not just the
    /// display, so "off" means the app makes no outbound call at all.
    func checkIfNeeded(isEnabled: Bool) async {
        guard isEnabled, isCheckDue() else { return }

        // Stamp BEFORE fetching. A failed check still consumes the day's slot, so a
        // machine that is offline at every launch doesn't retry on a hot loop.
        defaults.set(now(), forKey: Self.lastCheckDateKey)

        // nil means the check LEARNED NOTHING (offline, timeout, unusable payload). It is
        // not a retraction: leave the cache and whatever is on screen exactly as they are.
        // An empty array is a real answer — the publisher is showing nothing — and does
        // clear both.
        guard let announcements = await fetcher.fetch() else { return }

        if let encoded = AnnouncementFeed.encode(announcements) {
            defaults.set(encoded, forKey: Self.cachedFeedKey)
        } else {
            defaults.removeObject(forKey: Self.cachedFeedKey)
        }

        visible = Self.firstShowable(
            in: announcements,
            dismissedIDs: dismissedIDs,
            appVersion: appVersion
        )
    }

    /// The first entry that is neither dismissed nor aimed at a newer build. Feed
    /// order is authoring order, so the file's own ordering decides precedence —
    /// there is deliberately no priority field.
    static func firstShowable(
        in announcements: [Announcement],
        dismissedIDs: Set<String>,
        appVersion: String
    ) -> Announcement? {
        announcements.first { announcement in
            !dismissedIDs.contains(announcement.id) && announcement.appliesTo(appVersion: appVersion)
        }
    }

    /// Dismiss the visible announcement permanently. Idempotent.
    func dismiss(_ announcement: Announcement) {
        dismissedIDs.insert(announcement.id)
        if visible?.id == announcement.id { visible = nil }
    }

    /// Open the announcement's link in the user's browser and dismiss it — acting on
    /// an announcement is a stronger "I've seen this" than closing it, so it should
    /// never come back either.
    func performAction(for announcement: Announcement) {
        if let url = announcement.actionURL {
            NSWorkspace.shared.open(url)
        }
        dismiss(announcement)
    }
}
