import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// Announcements on iPhone: the Mac's store rules (request gated by the setting, once a day, the
/// cached feed restored, nil vs [] kept apart, dismissals forever), the launch rule (never under
/// XCTest), and the floating card above the bottom chrome. Every fetch is a spy; nothing here
/// touches the network.
@MainActor
final class PhoneAnnouncementTests: XCTestCase {
    private var suites: [String] = []
    private var folder: URL!
    private var window: UIWindow?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("announcements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: folder)
    }

    private let feed = #"{"version":1,"announcements":[{"id":"a","title":"Lineform 2","body":"Something new.","actionLabel":"Read more","actionURL":"https://lineform.app/news"},{"id":"b","title":"Second","body":"Next."}]}"#

    private func announcements(_ json: String) throws -> [Announcement] {
        try XCTUnwrap(AnnouncementFeed.decode(Data(json.utf8)))
    }

    // MARK: The store

    /// "Off" means no outbound call at all: the setting gates the REQUEST.
    func testTheSettingGatesTheRequest() async throws {
        let defaults = try makeDefaults()
        let fetcher = SpyFetcher(result: try announcements(feed))
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: fetcher, appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: false)
        XCTAssertEqual(fetcher.calls, 0)
        XCTAssertNil(store.visible)
        XCTAssertNil(defaults.object(forKey: PhoneAnnouncementStore.lastCheckDateKey), "nothing is stamped either")

        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(fetcher.calls, 1)
        XCTAssertEqual(store.visible?.id, "a")
    }

    func testChecksAtMostOnceADay() async throws {
        let defaults = try makeDefaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        let fetcher = SpyFetcher(result: try announcements(feed))
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: fetcher, appVersion: "1.8.0", now: { clock })
        await store.checkIfNeeded(isEnabled: true)
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(fetcher.calls, 1)
        clock = start.addingTimeInterval(PhoneAnnouncementStore.checkInterval + 1)
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(fetcher.calls, 2)
        // A clock that went backwards counts as due, so a bad clock never suppresses checks.
        clock = start.addingTimeInterval(-60)
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(fetcher.calls, 3)
    }

    /// The keys are the Mac's (each device keeps its own), and dismissal is forever: never pruned
    /// against the live feed.
    func testDismissalIsPermanentAndUsesTheMacKeys() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        store.dismiss(try XCTUnwrap(store.visible))
        XCTAssertEqual(store.visible?.id, nil, "one card at a time; the next shows at the next check")
        XCTAssertEqual(PhoneAnnouncementStore.dismissedIDsKey, "Lineform.announcements.dismissedIDs")
        XCTAssertEqual(PhoneAnnouncementStore.lastCheckDateKey, "Lineform.announcements.lastCheckDate")
        XCTAssertEqual(PhoneAnnouncementStore.cachedFeedKey, "Lineform.announcements.cachedFeed")
        XCTAssertEqual(defaults.stringArray(forKey: PhoneAnnouncementStore.dismissedIDsKey), ["a"])

        // A later feed without "a", then one with it again: it never comes back.
        let later = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(
            #"{"version":1,"announcements":[{"id":"a","title":"Lineform 2","body":"Something new."}]}"#
        )), appVersion: "1.8.0", now: { Date().addingTimeInterval(PhoneAnnouncementStore.checkInterval * 2) })
        await later.checkIfNeeded(isEnabled: true)
        XCTAssertNil(later.visible)
    }

    /// The throttle governs the network call, not the card: an undismissed card is back at the
    /// next launch from the cache — unless the setting is off.
    func testTheCachedFeedRestoresTheCardOnlyWhileOn() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)

        let relaunched = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: nil), appVersion: "1.8.0")
        XCTAssertEqual(relaunched.visible?.id, "a")

        defaults.set(false, forKey: LineformSettingKeys.checksForAnnouncements)
        let off = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: nil), appVersion: "1.8.0")
        XCTAssertNil(off.visible)
    }

    /// nil (learned nothing) leaves the card and the cache alone; [] (the publisher shows
    /// nothing) retracts both.
    func testNilLeavesTheCardAndAnEmptyFeedRetractsIt() async throws {
        let defaults = try makeDefaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)),
                                           appVersion: "1.8.0", now: { start })
        await store.checkIfNeeded(isEnabled: true)

        let offline = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: nil), appVersion: "1.8.0",
                                             now: { start.addingTimeInterval(PhoneAnnouncementStore.checkInterval + 1) })
        await offline.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(offline.visible?.id, "a")
        XCTAssertNotNil(defaults.data(forKey: PhoneAnnouncementStore.cachedFeedKey))

        let retracted = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: []), appVersion: "1.8.0",
                                               now: { start.addingTimeInterval(PhoneAnnouncementStore.checkInterval * 3) })
        await retracted.checkIfNeeded(isEnabled: true)
        XCTAssertNil(retracted.visible)
        let afterRetraction = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: nil), appVersion: "1.8.0")
        XCTAssertNil(afterRetraction.visible)
    }

    func testAnAnnouncementForANewerBuildWaits() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(
            #"{"version":1,"announcements":[{"id":"future","title":"T","body":"B","minAppVersion":"2.0"}]}"#
        )), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertNil(store.visible)
    }

    /// A feed entry may name its apps: the iPhone skips one meant only for the Mac, and shows one
    /// with no `platforms` or naming "ios".
    func testAnAnnouncementMeantOnlyForTheMacIsSkipped() async throws {
        let defaults = try makeDefaults()
        let feed = try announcements(#"{"version":1,"announcements":[{"id":"mac","title":"T","body":"B","platforms":["mac"]},{"id":"ios","title":"T","body":"B","platforms":["ios"]},{"id":"both","title":"T","body":"B"}]}"#)
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: feed), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        XCTAssertEqual(store.visible?.id, "ios")
        XCTAssertEqual(PhoneAnnouncementStore.firstShowable(in: feed, dismissedIDs: ["ios"], appVersion: "1.8.0")?.id, "both")
        XCTAssertNil(PhoneAnnouncementStore.firstShowable(in: [feed[0]], dismissedIDs: [], appVersion: "1.8.0"))
    }

    /// Acting on an announcement opens its link (through the injected opener) and dismisses it.
    func testTheActionOpensTheLinkAndDismisses() async throws {
        let defaults = try makeDefaults()
        var opened: [URL] = []
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)),
                                           appVersion: "1.8.0", open: { opened.append($0) })
        await store.checkIfNeeded(isEnabled: true)
        store.performAction(for: try XCTUnwrap(store.visible))
        XCTAssertEqual(opened, [URL(string: "https://lineform.app/news")!])
        XCTAssertNil(store.visible)
        XCTAssertEqual(defaults.stringArray(forKey: PhoneAnnouncementStore.dismissedIDsKey), ["a"])
    }

    func testTurningTheSettingOffRetractsTheCard() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        store.settingChanged(isEnabled: true)
        XCTAssertNotNil(store.visible)
        store.settingChanged(isEnabled: false)
        XCTAssertNil(store.visible)
    }

    func testTheStoreFollowsTheSwitch() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        let settings = AppSettings(defaults: defaults)
        store.follow(settings)
        store.follow(settings)
        XCTAssertNotNil(store.visible, "following reports no change")
        settings.checksForAnnouncements = false
        XCTAssertNil(store.visible)
    }

    // MARK: When the check runs

    /// The check runs when the scene becomes active (throttled to once a day) and NEVER in the
    /// test host: the test host is the app, and a test run must not call the production feed.
    func testTheCheckNeverRunsUnderTests() {
        XCTAssertTrue(LineformiOSApp.isRunningUnderTests)
        XCTAssertFalse(PhoneAnnouncementStore.checksOnSceneChange(to: .active, isRunningUnderTests: true))
        XCTAssertTrue(PhoneAnnouncementStore.checksOnSceneChange(to: .active, isRunningUnderTests: false))
        XCTAssertFalse(PhoneAnnouncementStore.checksOnSceneChange(to: .background, isRunningUnderTests: false))
        XCTAssertFalse(PhoneAnnouncementStore.checksOnSceneChange(to: .inactive, isRunningUnderTests: false))
    }

    // MARK: The card on screen

    /// The card floats above the Menu and Aa buttons (no full-width bar), and its ✕ dismisses it.
    func testTheCardFloatsAboveTheBottomChromeAndDismisses() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        let settings = AppSettings(defaults: defaults)
        let window = try await hostScreen(store: store, settings: settings)

        try await spin { self.element(labelled: PhoneAnnouncementCard.dismissTitle, in: window) != nil }
        // The labels the card and button carry, so the `de` configuration finds them too.
        let shown = try XCTUnwrap(store.visible)
        let card = try XCTUnwrap(element(labelled: PhoneAnnouncementCard.accessibilityTitle(shown), in: window))
        let menu = try XCTUnwrap(element(labelled: MenuButton.accessibilityTitle, in: window))
        XCTAssertLessThanOrEqual(card.accessibilityFrame.maxY, menu.accessibilityFrame.minY + 1, "above the buttons")
        XCTAssertGreaterThan(card.accessibilityFrame.minX, window.bounds.minX, "a floating card, not a bar: \(card.accessibilityFrame) in \(window.bounds)")
        XCTAssertLessThan(card.accessibilityFrame.maxX, window.bounds.maxX)

        let close = try XCTUnwrap(element(labelled: PhoneAnnouncementCard.dismissTitle, in: window))
        XCTAssertTrue(close.accessibilityTraits.contains(.button))
        XCTAssertTrue(close.accessibilityActivate())
        try await spin { store.visible == nil }
        try await spin { self.element(labelled: PhoneAnnouncementCard.dismissTitle, in: window) == nil }
    }

    /// Turning In-app notifications off takes the card away at once.
    func testTurningTheSwitchOffHidesTheCard() async throws {
        let defaults = try makeDefaults()
        let store = PhoneAnnouncementStore(defaults: defaults, fetcher: SpyFetcher(result: try announcements(feed)), appVersion: "1.8.0")
        await store.checkIfNeeded(isEnabled: true)
        let settings = AppSettings(defaults: defaults)
        let window = try await hostScreen(store: store, settings: settings)
        try await spin { self.element(labelled: PhoneAnnouncementCard.dismissTitle, in: window) != nil }
        settings.checksForAnnouncements = false
        try await spin { store.visible == nil }
        try await spin { self.element(labelled: PhoneAnnouncementCard.dismissTitle, in: window) == nil }
    }

    // MARK: Helpers

    private func makeDefaults() throws -> UserDefaults {
        let suite = "announcements-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func hostScreen(store: PhoneAnnouncementStore, settings: AppSettings) async throws -> UIWindow {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: AnnouncementTestUbiquitousItems())
        await document.prepare()
        let profiles = ReadingProfileStore(defaults: try makeDefaults())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: DocumentScreen(document: document, profileStore: profiles, settings: settings, announcements: store)
        )
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func spin(timeout: TimeInterval = 5, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
            window?.layoutIfNeeded()
        }
    }

    /// The accessibility element labelled exactly `label`, through views and their elements.
    private func element(labelled label: String, in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if root.accessibilityLabel == label, !(root is UIWindow) { return root }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        if let elements = root.accessibilityElements as? [NSObject] { children += elements }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = root.accessibilityElement(at: index) as? NSObject { children.append(element) }
            }
        }
        for child in children where child !== root {
            if let found = element(labelled: label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

/// Counts fetches and answers with a fixed result; never touches the network.
private final class SpyFetcher: AnnouncementFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: [Announcement]?
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(result: [Announcement]?) { self.result = result }

    func fetch() async -> [Announcement]? {
        lock.withLock { _calls += 1 }
        return result
    }
}

private struct AnnouncementTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
