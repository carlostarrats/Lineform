import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// The word menu ▸ About Lineform ▸ Check for Updates…: the Mac's `AppUpdateCommand` behaviour on iPhone. The
/// checker and the alert are injected, so no test touches the network or presents an alert; the
/// one test of the real checker runs over `StubURLProtocol`.
@MainActor
final class PhoneUpdateCheckTests: XCTestCase {
    private let storeURL = URL(string: "https://apps.apple.com/us/app/lineform/id6800480078?uo=4")!

    override func tearDown() {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data()
        StubURLProtocol.declaredLength = nil
        StubURLProtocol.redirectTo = nil
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.requestedRequests = []
        StubURLProtocol.contentType = "application/json"
        super.tearDown()
    }

    func testOpensTheStoreOnlyWhenTheWriterChoosesOpenAppStore() async {
        var shown: [AppUpdatePresentation] = []
        var opened: [URL] = []
        let result = AppUpdateCheckResult.updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: storeURL)
        let command = PhoneUpdateCommand(
            checker: FixedChecker(result: result), currentVersion: { "1.8.0" },
            present: { shown.append($0); return .primary }, open: { opened.append($0) }
        )
        await command.run()
        XCTAssertEqual(shown, [AppUpdatePresentation(result: result)])
        XCTAssertEqual(opened, [storeURL])

        let declining = PhoneUpdateCommand(
            checker: FixedChecker(result: result), currentVersion: { "1.8.0" },
            present: { _ in .dismissed }, open: { opened.append($0) }
        )
        await declining.run()
        XCTAssertEqual(opened, [storeURL], "Not Now opens nothing")
    }

    func testUpToDateAndFailedOpenNothing() async {
        for result in [AppUpdateCheckResult.upToDate(current: "1.9.0"), .failed] {
            var opened: [URL] = []
            var shown: [AppUpdatePresentation] = []
            let command = PhoneUpdateCommand(
                checker: FixedChecker(result: result), currentVersion: { "1.9.0" },
                present: { shown.append($0); return .primary }, open: { opened.append($0) }
            )
            await command.run()
            XCTAssertEqual(shown.count, 1)
            XCTAssertTrue(opened.isEmpty, "OK opens nothing")
            XCTAssertFalse(command.isChecking, "every path resets, so the row never goes dead")
        }
    }

    /// One check at a time: a second tap while the lookup runs, or while its alert is up, is
    /// ignored (the Mac's `isChecking`).
    func testASecondTapWhileCheckingIsIgnored() async throws {
        let checker = GatedChecker()
        var presents = 0
        var releaseAlert: CheckedContinuation<PhoneUpdateAlertOutcome, Never>?
        let command = PhoneUpdateCommand(
            checker: checker, currentVersion: { "1.8.0" },
            present: { _ in
                presents += 1
                return await withCheckedContinuation { releaseAlert = $0 }
            },
            open: { _ in }
        )
        let first = Task { await command.run() }
        try await waitUntil { checker.calls == 1 }
        XCTAssertTrue(command.isChecking)
        await command.run()
        XCTAssertEqual(checker.calls, 1, "a tap during the lookup is ignored")

        checker.finish(with: .failed)
        try await waitUntil { presents == 1 }
        await command.run()
        XCTAssertEqual(checker.calls, 1, "a tap while the alert is up is ignored")
        XCTAssertEqual(presents, 1)

        releaseAlert?.resume(returning: .primary)
        await first.value
        XCTAssertFalse(command.isChecking)

        // And the row works again afterwards.
        let again = Task { await command.run() }
        try await waitUntil { checker.calls == 2 }
        checker.finish(with: .upToDate(current: "1.8.0"))
        try await waitUntil { presents == 2 }
        releaseAlert?.resume(returning: .primary)
        await again.value
    }

    /// The real checker the command makes asks for the iPhone's listing (the iOS catalog), never
    /// the Mac's, and reads only the iPhone's entry. Over `StubURLProtocol`.
    func testTheDefaultCheckerLooksUpTheIPhoneListing() async throws {
        XCTAssertEqual(AppStorePlatform.current, .iPhone)
        // The shipping configuration is the package's to test; here only the transport matters.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let checker = AppStoreUpdateChecker(session: URLSession(configuration: configuration))
        StubURLProtocol.contentType = "text/javascript; charset=utf-8"
        StubURLProtocol.body = Data(#"{"resultCount":1,"results":[{"kind":"mac-software","version":"9.0","trackViewUrl":"https://apps.apple.com/us/app/lineform/id6800480078?mt=12"}]}"#.utf8)
        let result = await checker.check(currentVersion: "1.8.0")
        XCTAssertEqual(result, .failed, "the Mac entry is never offered on iPhone")
        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(url, AppStoreUpdateChecker.lookupURL(for: .iPhone))
        XCTAssertTrue(url.absoluteString.contains("bundleId=com.lineform.app&entity=software"))
    }

    /// The alert: Open App Store (the preferred action) and Not Now (Cancel's role) for an update,
    /// one OK otherwise. The package's strings, so they are the Mac's translations.
    func testTheAlertOffersOpenAppStoreAndNotNow() {
        let update = AppUpdatePresentation(
            result: .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: storeURL))
        let alert = PhoneUpdateCommand.makeAlert(update) { _ in }
        XCTAssertEqual(alert.title, update.title)
        XCTAssertEqual(alert.message, update.message)
        XCTAssertEqual(alert.actions.map(\.title), [update.primaryButton, update.secondaryButton])
        XCTAssertEqual(alert.actions.map(\.style), [.default, .cancel])
        XCTAssertEqual(alert.preferredAction, alert.actions.first)

        let upToDate = AppUpdatePresentation(result: .upToDate(current: "1.9.0"))
        let single = PhoneUpdateCommand.makeAlert(upToDate) { _ in }
        XCTAssertEqual(single.actions.map(\.title), [upToDate.primaryButton])
        XCTAssertEqual(single.actions.map(\.style), [.cancel])
    }

    /// The alert never names a Mac (the iPhone's wording rule), in any language.
    func testTheAlertNeverNamesAMac() throws {
        let results: [AppUpdateCheckResult] = [
            .upToDate(current: "1.9.0"),
            .updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: storeURL),
            .failed,
        ]
        for language in ["en", "de", "es", "fr", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.lineformCore.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for result in results {
                let presentation = AppUpdatePresentation(result: result, bundle: bundle)
                for text in [presentation.title, presentation.message, presentation.primaryButton, presentation.secondaryButton ?? ""] {
                    XCTAssertFalse(text.localizedCaseInsensitiveContains("mac"), "\(language): \(text)")
                }
            }
        }
    }

    /// The About Lineform row, first, as the Mac keeps it under About.
    func testAboutOffersCheckForUpdates() {
        if interfaceLanguage == "en" {
            XCTAssertEqual(AboutSection.checkForUpdatesTitle, "Check for Updates…") // pinned-en
        }
        XCTAssertEqual(AboutSection.rowTitles.first, AboutSection.checkForUpdatesTitle)
        XCTAssertFalse(AboutSection.checkForUpdatesNote.isEmpty)
        XCTAssertFalse(AboutSection.checkForUpdatesNote.localizedCaseInsensitiveContains("mac"))
    }

    // MARK: The result always reaches the writer, and the row never sticks

    /// When no alert can be shown, the result still reaches the writer as the app's quiet notice,
    /// and the row works again.
    func testAnAlertThatCantBeShownFallsBackToTheQuietNotice() async throws {
        let result = AppUpdateCheckResult.upToDate(current: "1.9.0")
        var opened: [URL] = []
        let command = PhoneUpdateCommand(
            checker: FixedChecker(result: result), currentVersion: { "1.9.0" },
            present: { _ in .notShown }, open: { opened.append($0) }, noticeDuration: .milliseconds(50)
        )
        await command.run()
        XCTAssertEqual(command.notice, AppUpdatePresentation(result: result).title)
        XCTAssertFalse(command.isChecking)
        XCTAssertTrue(opened.isEmpty)
        try await waitUntil { command.notice == nil }
    }

    /// Nothing to present on (no window, or a presenter that stays busy): it retries, then says so
    /// instead of waiting forever.
    func testPresentingRetriesThenReportsNotShown() async {
        var asked = 0
        let outcome = await PhoneUpdateCommand.presentAlert(
            AppUpdatePresentation(result: .failed),
            findPresenter: { asked += 1; return nil },
            attempts: 3, retryInterval: .milliseconds(10)
        )
        XCTAssertEqual(outcome, .notShown)
        XCTAssertEqual(asked, 3)
    }

    /// UIKit refuses the alert (its presenter is off screen): the watchdog notices it never came
    /// up, and the wait ends.
    func testAnAlertUIKitRefusesStillEndsTheWait() async {
        let offScreen = UIViewController()
        let outcome = await PhoneUpdateCommand.presentAlert(
            AppUpdatePresentation(result: .failed),
            findPresenter: { offScreen },
            attempts: 1, retryInterval: .milliseconds(10),
            watchdogInterval: .milliseconds(50), dismissalGrace: .milliseconds(10)
        )
        XCTAssertEqual(outcome, .notShown)
    }

    /// The alert is taken down without a button (its presenter went away): the wait ends as Not
    /// Now, so `isChecking` is reset.
    func testAnAlertDismissedWithoutAButtonEndsTheWait() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let waiting = Task { @MainActor in
            await PhoneUpdateCommand.presentAlert(
                AppUpdatePresentation(result: .failed),
                findPresenter: { host },
                attempts: 1, retryInterval: .milliseconds(10),
                watchdogInterval: .milliseconds(50), dismissalGrace: .milliseconds(10)
            )
        }
        try await waitUntil { host.presentedViewController is UIAlertController && !(host.presentedViewController?.isBeingPresented ?? true) }
        host.dismiss(animated: false)
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .dismissed)
    }

    /// The alert reports its own disappearance, which is what ends the wait without a button.
    func testTheAlertReportsItsDisappearance() {
        let alert = PhoneUpdateCommand.makeAlert(AppUpdatePresentation(result: .failed)) { _ in }
        var disappeared = 0
        alert.onDisappear = { disappeared += 1 }
        alert.viewDidDisappear(false)
        XCTAssertEqual(disappeared, 1)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct FixedChecker: AppUpdateChecking {
    let result: AppUpdateCheckResult
    func check(currentVersion: String) async -> AppUpdateCheckResult { result }
}

/// A checker that waits until the test answers, so a second tap can arrive mid-lookup.
private final class GatedChecker: AppUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var pending: CheckedContinuation<AppUpdateCheckResult, Never>?

    var calls: Int { lock.withLock { _calls } }

    func check(currentVersion: String) async -> AppUpdateCheckResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                _calls += 1
                pending = continuation
            }
        }
    }

    func finish(with result: AppUpdateCheckResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<AppUpdateCheckResult, Never>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: result)
    }
}
