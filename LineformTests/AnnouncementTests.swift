import XCTest
@testable import Lineform

/// Feed validation, version comparison, and store lifecycle.
///
/// No test here touches the network: `AnnouncementFetching` is faked throughout. The
/// fake models the SHIPPING contract — `fetch()` returns nil for a FAILED check and an
/// array (possibly empty) for a successful one, and never throws — so a test can't
/// certify behaviour the real fetcher doesn't have.
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

    func testDecodesValidEntry() throws {
        let announcements = try XCTUnwrap(AnnouncementFeed.decode(feedJSON(validEntry)))
        XCTAssertEqual(announcements.count, 1)
        let first = announcements[0]
        XCTAssertEqual(first.id, "ios-app-1")
        XCTAssertEqual(first.title, "Lineform for iPhone and iPad")
        XCTAssertEqual(first.body, "Now on the App Store.")
        XCTAssertEqual(first.actionLabel, "Learn more")
        XCTAssertEqual(first.actionURL, URL(string: "https://example.com/ios"))
        XCTAssertEqual(first.minAppVersion, "1.5.0")
    }

    func testDecodesEntryWithoutOptionalFields() throws {
        let entry = """
        { "id": "a", "title": "T", "body": "B" }
        """
        let announcements = try XCTUnwrap(AnnouncementFeed.decode(feedJSON(entry)))
        XCTAssertEqual(announcements.count, 1)
        XCTAssertNil(announcements[0].actionLabel)
        XCTAssertNil(announcements[0].actionURL)
        XCTAssertNil(announcements[0].minAppVersion)
    }

    func testMalformedJSONYieldsNothing() {
        XCTAssertNil(AnnouncementFeed.decode(Data("not json".utf8)))
        XCTAssertNil(AnnouncementFeed.decode(Data()))
    }

    func testUnsupportedFeedVersionYieldsNothing() {
        XCTAssertNil(AnnouncementFeed.decode(feedJSON(validEntry, version: 2)))
        XCTAssertNil(AnnouncementFeed.decode(feedJSON(validEntry, version: 0)))
    }

    /// The size ceiling is enforced on the decoded bytes as well as at the network
    /// layer, so a fetcher change can never quietly remove the only bound.
    func testOversizedPayloadYieldsNothing() {
        let padding = String(repeating: "a", count: AnnouncementFeed.maximumPayloadBytes)
        let oversized = Data("""
        { "version": 1, "announcements": [], "junk": "\(padding)" }
        """.utf8)
        XCTAssertGreaterThan(oversized.count, AnnouncementFeed.maximumPayloadBytes)
        XCTAssertNil(AnnouncementFeed.decode(oversized))
    }

    func testEntryCountIsCapped() {
        let many = (0..<(AnnouncementFeed.maximumEntryCount + 10))
            .map { #"{ "id": "id\#($0)", "title": "T", "body": "B" }"# }
            .joined(separator: ",")
        XCTAssertEqual(
            AnnouncementFeed.decode(feedJSON(many))?.count,
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
            AnnouncementFeed.decode(feedJSON(entries))?.map(\.id),
            ["good-1", "good-2"]
        )
    }

    /// The cache is written with `encode` and read back with `decode`, so the two must
    /// agree on the wire format. If they drift, the cached feed silently stops decoding
    /// and every relaunch loses the card — the exact bug the cache exists to fix.
    func testEncodeDecodeRoundTripsThroughTheSameValidator() throws {
        let original = try XCTUnwrap(AnnouncementFeed.decode(feedJSON(validEntry)))
        let encoded = try XCTUnwrap(AnnouncementFeed.encode(original))
        XCTAssertEqual(AnnouncementFeed.decode(encoded), original)
    }

    func testEncodeRoundTripsEntriesWithNoOptionalFields() throws {
        let entry = """
        { "id": "a", "title": "T", "body": "B" }
        """
        let original = try XCTUnwrap(AnnouncementFeed.decode(feedJSON(entry)))
        let encoded = try XCTUnwrap(AnnouncementFeed.encode(original))
        XCTAssertEqual(AnnouncementFeed.decode(encoded), original)
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

    /// U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) are NOT in
    /// `CharacterSet.controlCharacters` (they are Zl/Zp, not Cc/Cf), yet SwiftUI `Text`
    /// still breaks a line on them. A hostile feed used them to smuggle a multi-line card
    /// past the one-liner rule; the sanitizer must reject an interior one like any newline.
    func testUnicodeLineSeparatorsAreRejected() {
        XCTAssertNil(AnnouncementFeed.sanitized("line\u{2028}break", maximumLength: 20))
        XCTAssertNil(AnnouncementFeed.sanitized("para\u{2029}break", maximumLength: 20))
        XCTAssertNil(AnnouncementFeed.sanitized("next\u{0085}line", maximumLength: 20))
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

    /// The destination is bounded like every other string. Unbounded, it could push the
    /// re-encoded cache past the payload ceiling and quietly break restore-on-relaunch.
    func testOverLongURLIsRejected() {
        let long = "https://example.com/" + String(repeating: "a", count: AnnouncementFeed.maximumActionURLLength)
        XCTAssertGreaterThan(long.count, AnnouncementFeed.maximumActionURLLength)
        XCTAssertNil(AnnouncementFeed.validatedURL(long))
        XCTAssertNotNil(AnnouncementFeed.validatedURL("https://example.com/" + String(repeating: "a", count: 100)))
    }

    /// A full-size feed must still re-encode small enough to decode back, or the cache
    /// silently stops working at exactly the moment it matters most.
    func testMaximumSizedFeedStillRoundTripsUnderThePayloadCeiling() throws {
        let url = "https://example.com/" + String(repeating: "a", count: 480)
        let entries = (0..<AnnouncementFeed.maximumEntryCount).map { index in
            """
            { "id": "\(String(repeating: "i", count: 60))\(index)",
              "title": "\(String(repeating: "t", count: AnnouncementFeed.maximumTitleLength))",
              "body": "\(String(repeating: "b", count: AnnouncementFeed.maximumBodyLength))",
              "actionLabel": "\(String(repeating: "l", count: AnnouncementFeed.maximumActionLabelLength))",
              "actionURL": "\(url)" }
            """
        }.joined(separator: ",")

        let decoded = try XCTUnwrap(AnnouncementFeed.decode(feedJSON(entries)))
        XCTAssertEqual(decoded.count, AnnouncementFeed.maximumEntryCount)

        let encoded = try XCTUnwrap(AnnouncementFeed.encode(decoded))
        XCTAssertLessThanOrEqual(encoded.count, AnnouncementFeed.maximumPayloadBytes)
        XCTAssertEqual(AnnouncementFeed.decode(encoded), decoded)
    }

    func testURLSchemeComparisonIsCaseInsensitive() {
        XCTAssertNotNil(AnnouncementFeed.validatedURL("HTTPS://example.com/x"))
    }

    func testEntryWithRejectedURLIsDropped() {
        let entry = """
        { "id": "a", "title": "T", "body": "B",
          "actionLabel": "Go", "actionURL": "javascript:alert(1)" }
        """
        XCTAssertEqual(AnnouncementFeed.decode(feedJSON(entry)), [])
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
        XCTAssertEqual(AnnouncementFeed.decode(feedJSON(labelOnly)), [])
        XCTAssertEqual(AnnouncementFeed.decode(feedJSON(urlOnly)), [])
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
        XCTAssertEqual(AnnouncementFeed.decode(feedJSON(entry)), [])
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
///
/// Models the SHIPPING contract exactly: `nil` is a failed check, `[]` is a successfully
/// read but empty feed. A fake that collapsed the two would certify the retraction bug
/// instead of catching it.
private actor FakeAnnouncementFetcher: AnnouncementFetching {
    private let result: [Announcement]?
    private(set) var fetchCount = 0

    init(_ result: [Announcement]?) {
        self.result = result
    }

    func fetch() async -> [Announcement]? {
        fetchCount += 1
        return result
    }

    func recordedFetchCount() async -> Int { fetchCount }
}

@MainActor
final class AnnouncementStoreTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        TestDefaults.destroy(defaults, suiteName: name)
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

    // MARK: - Cache survives relaunch

    /// The throttle governs the NETWORK CALL, not the card. Without a cache, an
    /// announcement the user never dismissed vanished on the next launch and stayed gone
    /// until the check fell due again — up to a day of invisibility.
    func testUndismissedAnnouncementSurvivesRelaunchWithoutARecheck() async {
        let defaults = freshDefaults("AnnouncementCacheSurvives")
        let start = Date()
        let fetcher = FakeAnnouncementFetcher([announcement("a")])

        let store = AnnouncementStore(
            defaults: defaults, fetcher: fetcher, appVersion: "1.5.0", now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "a")

        // Relaunch one minute later: the check is NOT due, so no fetch happens...
        let relaunched = AnnouncementStore(
            defaults: defaults,
            fetcher: fetcher,
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(60) }
        )
        await relaunched.checkIfNeeded(isEnabled: true)

        // ...and the card is still there, restored from cache.
        XCTAssertEqual(relaunched.visible?.id, "a")
        let count = await fetcher.recordedFetchCount()
        XCTAssertEqual(count, 1, "the relaunch must not have re-fetched")
    }

    /// With the setting OFF, the cached feed must NOT repopulate the card at launch — a
    /// user who turned announcements off should not see one come back next time they open
    /// the app. (The network request is already gated separately; this is the display side.)
    func testDisabledSettingDoesNotRestoreCardFromCacheAtLaunch() async {
        let defaults = freshDefaults("AnnouncementDisabledNoRestore")
        let start = Date()
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "a", "precondition: the card was cached while on")

        // The user turns announcements off, then relaunches.
        defaults.set(false, forKey: LineformSettingsStore.checksForAnnouncementsKey)
        let relaunched = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(60) }
        )
        XCTAssertNil(relaunched.visible, "off means the cache must not restore the card")
    }

    /// Turning the setting off mid-session retracts the card already on screen.
    func testRetractForDisabledSettingHidesTheVisibleCard() async {
        let store = AnnouncementStore(
            defaults: freshDefaults("AnnouncementRetract"),
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { Date() }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertNotNil(store.visible)
        store.retractForDisabledSetting()
        XCTAssertNil(store.visible)
    }

    func testDismissedAnnouncementDoesNotReturnFromCache() async {
        let defaults = freshDefaults("AnnouncementCacheRespectsDismissal")
        let start = Date()
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        store.dismiss(store.visible!)

        let relaunched = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(60) }
        )
        XCTAssertNil(relaunched.visible)
    }

    /// The cache is re-decoded through `AnnouncementFeed.decode`, so a version bump
    /// re-filters it rather than replaying a stale decision.
    func testCacheIsRefilteredAgainstTheRunningAppVersion() async {
        let defaults = freshDefaults("AnnouncementCacheRefilters")
        let start = Date()
        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("future", minAppVersion: "2.0.0")]),
            appVersion: "2.0.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "future")

        // Same cache read by an OLDER build: the entry no longer applies.
        let older = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher(nil),
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(60) }
        )
        XCTAssertNil(older.visible)
    }

    // MARK: - A failed check is not a retraction

    /// nil means "we learned nothing". It must leave a shown announcement alone, or one
    /// offline launch pulls a live card off the screen.
    func testFailedCheckLeavesAShownAnnouncementAlone() async {
        let defaults = freshDefaults("AnnouncementFailedNoRetract")
        let start = Date()

        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "a")

        // A day later, offline.
        let offline = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher(nil),
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(AnnouncementStore.checkInterval + 1) }
        )
        await offline.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(offline.visible?.id, "a", "an offline check must not retract")
    }

    /// An EMPTY array is a real answer — the publisher retracted everything — and does
    /// clear the card and the cache.
    func testEmptyFeedRetractsTheAnnouncement() async {
        let defaults = freshDefaults("AnnouncementEmptyRetracts")
        let start = Date()

        let store = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([announcement("a")]),
            appVersion: "1.5.0",
            now: { start }
        )
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "a")

        let retracted = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher([]),
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(AnnouncementStore.checkInterval + 1) }
        )
        await retracted.checkIfNeeded(isEnabled: true)
        XCTAssertNil(retracted.visible)

        // And the cache is cleared, so a later relaunch doesn't resurrect it.
        let afterRetraction = AnnouncementStore(
            defaults: defaults,
            fetcher: FakeAnnouncementFetcher(nil),
            appVersion: "1.5.0",
            now: { start.addingTimeInterval(AnnouncementStore.checkInterval + 2) }
        )
        XCTAssertNil(afterRetraction.visible)
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
            fetcher: FakeAnnouncementFetcher(nil),   // nil = the check failed
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
