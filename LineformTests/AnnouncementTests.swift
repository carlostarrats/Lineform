import XCTest
@testable import Lineform

/// Feed validation, version comparison, and store lifecycle.
///
/// No test here touches the network: `AnnouncementFetching` is faked throughout. The
/// fake models the SHIPPING contract — `fetch()` returns [] for every failure and never
/// throws — so a test can't certify behaviour the real fetcher doesn't have.
final class AnnouncementFeedTests: XCTestCase {

    private func feedJSON(_ entries: String, version: Int = 1) -> Data {
        Data("""
        { "version": \(version), "announcements": [\(entries)] }
        """.utf8)
    }

    private let validEntry = """
    {
      "id": "ios-app-1",
      "title": "Lineform for iPhone and iPad",
      "body": "Now on the App Store.",
      "actionLabel": "Learn more",
      "actionURL": "https://example.com/ios",
      "minAppVersion": "1.5.0"
    }
    """

    // MARK: - Decoding

    func testDecodesValidEntry() {
        let announcements = AnnouncementFeed.decode(feedJSON(validEntry))
        XCTAssertEqual(announcements.count, 1)
        let first = announcements[0]
        XCTAssertEqual(first.id, "ios-app-1")
        XCTAssertEqual(first.title, "Lineform for iPhone and iPad")
        XCTAssertEqual(first.body, "Now on the App Store.")
        XCTAssertEqual(first.actionLabel, "Learn more")
        XCTAssertEqual(first.actionURL, URL(string: "https://example.com/ios"))
        XCTAssertEqual(first.minAppVersion, "1.5.0")
    }

    func testDecodesEntryWithoutOptionalFields() {
        let entry = """
        { "id": "a", "title": "T", "body": "B" }
        """
        let announcements = AnnouncementFeed.decode(feedJSON(entry))
        XCTAssertEqual(announcements.count, 1)
        XCTAssertNil(announcements[0].actionLabel)
        XCTAssertNil(announcements[0].actionURL)
        XCTAssertNil(announcements[0].minAppVersion)
    }

    func testMalformedJSONYieldsNothing() {
        XCTAssertTrue(AnnouncementFeed.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(AnnouncementFeed.decode(Data()).isEmpty)
    }

    func testUnsupportedFeedVersionYieldsNothing() {
        XCTAssertTrue(AnnouncementFeed.decode(feedJSON(validEntry, version: 2)).isEmpty)
        XCTAssertTrue(AnnouncementFeed.decode(feedJSON(validEntry, version: 0)).isEmpty)
    }

    /// The size ceiling is enforced on the decoded bytes as well as at the network
    /// layer, so a fetcher change can never quietly remove the only bound.
    func testOversizedPayloadYieldsNothing() {
        let padding = String(repeating: "a", count: AnnouncementFeed.maximumPayloadBytes)
        let oversized = Data("""
        { "version": 1, "announcements": [], "junk": "\(padding)" }
        """.utf8)
        XCTAssertGreaterThan(oversized.count, AnnouncementFeed.maximumPayloadBytes)
        XCTAssertTrue(AnnouncementFeed.decode(oversized).isEmpty)
    }

    func testEntryCountIsCapped() {
        let many = (0..<(AnnouncementFeed.maximumEntryCount + 10))
            .map { #"{ "id": "id\#($0)", "title": "T", "body": "B" }"# }
            .joined(separator: ",")
        XCTAssertEqual(
            AnnouncementFeed.decode(feedJSON(many)).count,
            AnnouncementFeed.maximumEntryCount
        )
    }

    /// One bad entry must not discard the good ones around it — a single typo in the
    /// feed should not silently kill the whole channel.
    func testInvalidEntryIsSkippedWithoutDiscardingValidOnes() {
        let entries = """
        { "id": "good-1", "title": "T", "body": "B" },
        { "id": "", "title": "T", "body": "B" },
        { "id": "good-2", "title": "T", "body": "B" }
        """
        XCTAssertEqual(
            AnnouncementFeed.decode(feedJSON(entries)).map(\.id),
            ["good-1", "good-2"]
        )
    }

    // MARK: - Field validation

    func testEmptyAndWhitespaceOnlyFieldsAreRejected() {
        XCTAssertNil(AnnouncementFeed.sanitized("", maximumLength: 10))
        XCTAssertNil(AnnouncementFeed.sanitized("   ", maximumLength: 10))
        XCTAssertNil(AnnouncementFeed.sanitized("\n\t", maximumLength: 10))
    }

    func testOverLengthFieldIsRejectedNotTruncated() {
        XCTAssertNil(AnnouncementFeed.sanitized(String(repeating: "a", count: 11), maximumLength: 10))
        XCTAssertEqual(AnnouncementFeed.sanitized("  hello  ", maximumLength: 10), "hello")
    }

    /// Control characters are REJECTED rather than stripped: silently altering remote
    /// text renders something nobody reviewed.
    func testControlCharactersAreRejected() {
        XCTAssertNil(AnnouncementFeed.sanitized("hel\u{0}lo", maximumLength: 20))
        XCTAssertNil(AnnouncementFeed.sanitized("line\nbreak", maximumLength: 20))
        XCTAssertNil(AnnouncementFeed.sanitized("bell\u{7}", maximumLength: 20))
    }

    /// Length is measured in Characters, so an emoji counts as one — the same rule the
    /// table reformatter learned the hard way about UTF-16 measurement.
    func testLengthIsMeasuredInCharactersNotUTF16() {
        XCTAssertEqual(AnnouncementFeed.sanitized("👍🏽👍🏽", maximumLength: 2), "👍🏽👍🏽")
        XCTAssertNil(AnnouncementFeed.sanitized("👍🏽👍🏽👍🏽", maximumLength: 2))
    }

    // MARK: - URL validation

    func testOnlyHTTPSURLsAreAccepted() {
        XCTAssertNotNil(AnnouncementFeed.validatedURL("https://example.com/x"))
        XCTAssertNil(AnnouncementFeed.validatedURL("http://example.com/x"))
        XCTAssertNil(AnnouncementFeed.validatedURL("javascript:alert(1)"))
        XCTAssertNil(AnnouncementFeed.validatedURL("data:text/html,<script>"))
        XCTAssertNil(AnnouncementFeed.validatedURL("file:///etc/passwd"))
        XCTAssertNil(AnnouncementFeed.validatedURL("//example.com/x"))
        XCTAssertNil(AnnouncementFeed.validatedURL("example.com"))
    }

    func testURLSchemeComparisonIsCaseInsensitive() {
        XCTAssertNotNil(AnnouncementFeed.validatedURL("HTTPS://example.com/x"))
    }

    func testEntryWithRejectedURLIsDropped() {
        let entry = """
        { "id": "a", "title": "T", "body": "B",
          "actionLabel": "Go", "actionURL": "javascript:alert(1)" }
        """
        XCTAssertTrue(AnnouncementFeed.decode(feedJSON(entry)).isEmpty)
    }

    /// A label without a destination is dead UI; a destination without a label is
    /// unreachable. Either half alone is an authoring mistake, so the entry is skipped.
    func testHalfSuppliedActionPairIsRejected() {
        let labelOnly = """
        { "id": "a", "title": "T", "body": "B", "actionLabel": "Go" }
        """
        let urlOnly = """
        { "id": "b", "title": "T", "body": "B", "actionURL": "https://example.com" }
        """
        XCTAssertTrue(AnnouncementFeed.decode(feedJSON(labelOnly)).isEmpty)
        XCTAssertTrue(AnnouncementFeed.decode(feedJSON(urlOnly)).isEmpty)
    }

    // MARK: - Version comparison

    /// The bug a lexicographic compare would produce: 1.10 must sort ABOVE 1.9.
    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertEqual(AnnouncementFeed.compareVersions("1.10.0", "1.9.0"), .orderedDescending)
        XCTAssertEqual(AnnouncementFeed.compareVersions("1.9.0", "1.10.0"), .orderedAscending)
        XCTAssertEqual(AnnouncementFeed.compareVersions("2.0", "10.0"), .orderedAscending)
    }

    func testMissingTrailingComponentsReadAsZero() {
        XCTAssertEqual(AnnouncementFeed.compareVersions("1.5", "1.5.0"), .orderedSame)
        XCTAssertEqual(AnnouncementFeed.compareVersions("1", "1.0.0"), .orderedSame)
        XCTAssertEqual(AnnouncementFeed.compareVersions("1.5.1", "1.5"), .orderedDescending)
    }

    func testNonNumericVersionIsRejectedNotCoerced() {
        XCTAssertNil(AnnouncementFeed.validatedVersion("1.5.0-beta"))
        XCTAssertNil(AnnouncementFeed.validatedVersion("v1.5"))
        XCTAssertNil(AnnouncementFeed.validatedVersion(""))
        XCTAssertNil(AnnouncementFeed.validatedVersion("1..5"))
        XCTAssertNil(AnnouncementFeed.validatedVersion("1.5.0.0.0"))
        XCTAssertNotNil(AnnouncementFeed.validatedVersion("1.5.0"))
        XCTAssertNotNil(AnnouncementFeed.validatedVersion("1"))
    }

    /// Bounded before any Int conversion — the generalized ordered-list `Int.max` rule.
    func testAbsurdlyLongVersionComponentIsRejected() {
        XCTAssertNil(AnnouncementFeed.validatedVersion("9999999999"))
        XCTAssertNil(AnnouncementFeed.validatedVersion("1.99999999999999999999"))
    }

    func testEntryWithRejectedVersionIsDropped() {
        let entry = """
        { "id": "a", "title": "T", "body": "B", "minAppVersion": "not-a-version" }
        """
        XCTAssertTrue(AnnouncementFeed.decode(feedJSON(entry)).isEmpty)
    }

    func testAppliesToRespectsMinimumVersion() {
        let announcement = Announcement(
            id: "a", title: "T", body: "B",
            actionLabel: nil, actionURL: nil, minAppVersion: "1.5.0"
        )
        XCTAssertFalse(announcement.appliesTo(appVersion: "1.4.9"))
        XCTAssertTrue(announcement.appliesTo(appVersion: "1.5.0"))
        XCTAssertTrue(announcement.appliesTo(appVersion: "1.6.0"))
        XCTAssertTrue(announcement.appliesTo(appVersion: "1.10.0"))
    }

    func testAppliesToIsUnboundedWithoutMinimumVersion() {
        let announcement = Announcement(
            id: "a", title: "T", body: "B",
            actionLabel: nil, actionURL: nil, minAppVersion: nil
        )
        XCTAssertTrue(announcement.appliesTo(appVersion: "0"))
        XCTAssertTrue(announcement.appliesTo(appVersion: "99.0.0"))
    }
}

/// Records whether it was asked, so a test can assert the setting gates the REQUEST
/// and not merely the display.
private actor FakeAnnouncementFetcher: AnnouncementFetching {
    private let announcements: [Announcement]
    private(set) var fetchCount = 0

    init(_ announcements: [Announcement]) {
        self.announcements = announcements
    }

    func fetch() async -> [Announcement] {
        fetchCount += 1
        return announcements
    }

    func recordedFetchCount() async -> Int { fetchCount }
}

@MainActor
final class AnnouncementStoreTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func announcement(_ id: String, minAppVersion: String? = nil) -> Announcement {
        Announcement(
            id: id, title: "T", body: "B",
            actionLabel: nil, actionURL: nil, minAppVersion: minAppVersion
        )
    }

    // MARK: - Selection

    func testShowsFirstUndismissedApplicableAnnouncement() {
        let result = AnnouncementStore.firstShowable(
            in: [announcement("a"), announcement("b")],
            dismissedIDs: ["a"],
            appVersion: "1.5.0"
        )
        XCTAssertEqual(result?.id, "b")
    }

    func testSkipsAnnouncementsAimedAtNewerBuilds() {
        let result = AnnouncementStore.firstShowable(
            in: [announcement("future", minAppVersion: "2.0.0"), announcement("now")],
            dismissedIDs: [],
            appVersion: "1.5.0"
        )
        XCTAssertEqual(result?.id, "now")
    }

    func testNothingShowableYieldsNil() {
        XCTAssertNil(AnnouncementStore.firstShowable(
            in: [announcement("a")],
            dismissedIDs: ["a"],
            appVersion: "1.5.0"
        ))
        XCTAssertNil(AnnouncementStore.firstShowable(in: [], dismissedIDs: [], appVersion: "1.5.0"))
    }

    // MARK: - Dismissal

    func testDismissalPersistsAcrossStoreInstances() async {
        let defaults = freshDefaults("AnnouncementDismissPersist")
        let fetcher = FakeAnnouncementFetcher([announcement("a")])

        let store = AnnouncementStore(
            defaults: defaults, fetcher: fetcher, appVersion: "1.5.0", now: { Date() }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "a")

        store.dismiss(store.visible!)
        XCTAssertNil(store.visible)

        // A fresh store, a due check, the same feed — the dismissed entry stays gone.
        defaults.removeObject(forKey: AnnouncementStore.lastCheckDateKey)
        let restored = AnnouncementStore(
            defaults: defaults, fetcher: fetcher, appVersion: "1.5.0", now: { Date() }
        )
        await restored.checkIfNeeded(isEnabled: true)
        XCTAssertNil(restored.visible)
    }

    func testDismissIsIdempotent() async {
        let store = AnnouncementStore(
            defaults: freshDefaults("AnnouncementDismissIdempotent"),
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { Date() }
        )
        await store.checkIfNeeded(isEnabled: true)
        let shown = store.visible!
        store.dismiss(shown)
        store.dismiss(shown)
        XCTAssertNil(store.visible)
    }

    // MARK: - Throttle

    func testCheckIsDueOnFirstRun() {
        let store = AnnouncementStore(
            defaults: freshDefaults("AnnouncementFirstRun"),
            fetcher: FakeAnnouncementFetcher([]),
            appVersion: "1.5.0",
            now: { Date() }
        )
        XCTAssertTrue(store.isCheckDue())
    }

    func testCheckIsNotDueWithinTheInterval() async {
        let defaults = freshDefaults("AnnouncementThrottle")
        let start = Date()
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([]),
            appVersion: "1.5.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertFalse(store.isCheckDue())
    }

    func testCheckIsDueAgainAfterTheInterval() async {
        let defaults = freshDefaults("AnnouncementThrottleElapsed")
        let start = Date()
        var clock = start
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([]),
            appVersion: "1.5.0",
            now: { clock }
        )
        await store.checkIfNeeded(isEnabled: true)
        clock = start.addingTimeInterval(AnnouncementStore.checkInterval + 1)
        XCTAssertTrue(store.isCheckDue())
    }

    /// A clock that moved backwards (or a restored defaults plist) must not suppress
    /// checks forever.
    func testFutureLastCheckCountsAsDue() {
        let defaults = freshDefaults("AnnouncementFutureClock")
        let now = Date()
        defaults.set(now.addingTimeInterval(60 * 60 * 24 * 30), forKey: AnnouncementStore.lastCheckDateKey)
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([]),
            appVersion: "1.5.0",
            now: { now }
        )
        XCTAssertTrue(store.isCheckDue())
    }

    /// A failed check still consumes the day's slot, so an offline machine doesn't
    /// retry on every launch in a hot loop.
    func testFailedCheckStillConsumesTheInterval() async {
        let defaults = freshDefaults("AnnouncementFailedStamp")
        let start = Date()
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([]),   // models a failure: empty result
            appVersion: "1.5.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertNil(store.visible)
        XCTAssertFalse(store.isCheckDue())
    }

    // MARK: - The setting gates the request

    func testDisabledSettingMakesNoRequestAtAll() async {
        let fetcher = FakeAnnouncementFetcher([announcement("a")])
        let store = AnnouncementStore(
            defaults: freshDefaults("AnnouncementDisabled"),
            fetcher: fetcher,
            appVersion: "1.5.0",
            now: { Date() }
        )

        await store.checkIfNeeded(isEnabled: false)

        let count = await fetcher.recordedFetchCount()
        XCTAssertEqual(count, 0, "The setting must gate the network request, not just the display")
        XCTAssertNil(store.visible)
    }

    func testEnabledSettingMakesExactlyOneRequestPerInterval() async {
        let fetcher = FakeAnnouncementFetcher([announcement("a")])
        let start = Date()
        let store = AnnouncementStore(
            defaults: freshDefaults("AnnouncementSingleRequest"),
            fetcher: fetcher,
            appVersion: "1.5.0",
            now: { start }
        )

        await store.checkIfNeeded(isEnabled: true)
        await store.checkIfNeeded(isEnabled: true)

        let count = await fetcher.recordedFetchCount()
        XCTAssertEqual(count, 1)
    }
}
