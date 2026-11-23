import Combine
import LineformCore
import SwiftUI
import UIKit

/// The announcement lifecycle on iPhone: when to check, what to show, what has been dismissed.
/// The Mac's `AnnouncementStore` without AppKit (its link opener is injected), on the package's
/// `AnnouncementFeed` and `AnnouncementFetcher`, under the Mac's `UserDefaults` keys (per device).
///
/// The rules are the Mac's, each for the same reason (`app-integration.md`, In-app announcements):
/// - The setting gates the REQUEST: `checkIfNeeded(isEnabled:)` returns before the fetcher is
///   touched, so "off" means no outbound call at all. Turning it off also takes the card away
///   (`settingChanged(isEnabled:)`), and `init` restores no card while it is off.
/// - At most one check a day; a failed check still stamps the day, so an offline phone never
///   retries on a hot loop. The throttle governs the NETWORK CALL only: `visible` is restored
///   from the cached feed in `init`.
/// - nil from the fetcher (learned nothing) leaves the card and the cache alone; [] (the
///   publisher shows nothing) retracts both.
/// - Dismissed ids are kept forever and never pruned against the live feed.
///
/// `dismissedIDs` is assigned once in `init` (Swift runs no observer for that), so reading the
/// stored value never writes it back.
@MainActor
final class PhoneAnnouncementStore: ObservableObject {
    static let shared = PhoneAnnouncementStore()

    /// The Mac's keys, byte for byte. Each device keeps its own (`UserDefaults.standard`).
    static let dismissedIDsKey = "Lineform.announcements.dismissedIDs"
    static let lastCheckDateKey = "Lineform.announcements.lastCheckDate"
    static let cachedFeedKey = "Lineform.announcements.cachedFeed"

    /// One check per day, as on the Mac.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The announcement on screen, or nil. The card observes this.
    @Published private(set) var visible: Announcement?

    private let defaults: UserDefaults
    private let fetcher: AnnouncementFetching
    private let appVersion: String
    private let now: () -> Date
    private let open: @MainActor (URL) -> Void
    private weak var followedSettings: AppSettings?
    private var settingSubscription: AnyCancellable?

    private var dismissedIDs: Set<String> {
        didSet {
            guard oldValue != dismissedIDs else { return }
            defaults.set(Array(dismissedIDs).sorted(), forKey: Self.dismissedIDsKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        fetcher: AnnouncementFetching = AnnouncementFetcher(),
        appVersion: String = PhoneUpdateCommand.bundleShortVersion(),
        now: @escaping () -> Date = Date.init,
        open: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.appVersion = appVersion
        self.now = now
        self.open = open
        self.dismissedIDs = Set(defaults.stringArray(forKey: Self.dismissedIDsKey) ?? [])
        // The cached feed, through the same validator as a fetched one; nothing while the setting
        // is off, so a writer who turned announcements off never sees one come back at launch.
        let enabled = LineformSettingKeys.bool(
            LineformSettingKeys.checksForAnnouncements,
            default: LineformSettingKeys.Defaults.checksForAnnouncements,
            in: defaults
        )
        self.visible = enabled
            ? Self.firstShowable(
                in: defaults.data(forKey: Self.cachedFeedKey).flatMap(AnnouncementFeed.decode) ?? [],
                dismissedIDs: dismissedIDs,
                appVersion: appVersion
            )
            : nil
    }

    /// Whether a scene-phase change starts a check: becoming active, never in the test host. The
    /// test host IS the app, so a check wired here would make every test run call the production
    /// feed. Checked at the CALL SITE (`LineformiOSApp`), never inside `checkIfNeeded`, whose own
    /// tests drive it with a spy fetcher.
    nonisolated static func checksOnSceneChange(to phase: ScenePhase, isRunningUnderTests: Bool) -> Bool {
        phase == .active && !isRunningUnderTests
    }

    /// Whether enough time has passed to check again. A last check in the future (the clock went
    /// backwards) counts as due, so a bad clock never suppresses checks.
    func isCheckDue() -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckDateKey) as? Date else { return true }
        let elapsed = now().timeIntervalSince(last)
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    /// Returns without touching the network when the setting is off or a check is not due.
    func checkIfNeeded(isEnabled: Bool) async {
        guard isEnabled, isCheckDue() else { return }

        // Stamp BEFORE fetching: a failed check still uses the day's slot.
        defaults.set(now(), forKey: Self.lastCheckDateKey)

        // nil: the check learned nothing. Not a retraction; leave the cache and the card.
        guard let announcements = await fetcher.fetch() else { return }

        if let encoded = AnnouncementFeed.encode(announcements) {
            defaults.set(encoded, forKey: Self.cachedFeedKey)
        } else {
            defaults.removeObject(forKey: Self.cachedFeedKey)
        }
        visible = Self.firstShowable(in: announcements, dismissedIDs: dismissedIDs, appVersion: appVersion)
    }

    /// Follows the In-app notifications switch: its value now, then every change, goes to
    /// `settingChanged` (so a switch turned off before the screen first appeared is honoured too).
    /// One subscription; following the same settings again keeps it.
    func follow(_ settings: AppSettings) {
        guard followedSettings !== settings else { return }
        followedSettings = settings
        settingSubscription = settings.$checksForAnnouncements
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated { self?.settingChanged(isEnabled: isEnabled) }
            }
    }

    /// The In-app notifications switch changed. Off takes the card away now (the cache stays, so
    /// turning it back on lets a current announcement return at the next launch). On does nothing
    /// until the next check.
    func settingChanged(isEnabled: Bool) {
        if !isEnabled { visible = nil }
    }

    /// The first entry neither dismissed nor aimed at a newer build. Feed order decides.
    static func firstShowable(in announcements: [Announcement], dismissedIDs: Set<String>, appVersion: String) -> Announcement? {
        announcements.first { !dismissedIDs.contains($0.id) && $0.appliesTo(appVersion: appVersion) }
    }

    /// Dismiss the announcement for good. Idempotent.
    func dismiss(_ announcement: Announcement) {
        dismissedIDs.insert(announcement.id)
        if visible?.id == announcement.id { visible = nil }
    }

    /// Opens the announcement's link (in Safari) and dismisses it: acting on it is a stronger
    /// "I've seen this" than closing it.
    func performAction(for announcement: Announcement) {
        if let url = announcement.actionURL {
            open(url)
        }
        dismiss(announcement)
    }
}
