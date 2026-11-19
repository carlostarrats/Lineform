import os
import XCTest
@testable import Lineform
@testable import LineformCore

/// The Check for Updates command, with the alert and NSWorkspace injected: the default test
/// plan must never construct an `NSAlert` (it is a window), and no test here makes a request.
@MainActor
final class AppUpdateCommandTests: XCTestCase {
    private static let storeURL = URL(string: "https://apps.apple.com/app/lineform/id6738270430")!

    struct FixedChecker: AppUpdateChecking {
        let result: AppUpdateCheckResult
        func check(currentVersion: String) async -> AppUpdateCheckResult { result }
    }

    /// Records the version it was asked about and returns a fixed result.
    final class RecordingChecker: AppUpdateChecking {
        let result: AppUpdateCheckResult
        private let versions = OSAllocatedUnfairLock<[String]>(initialState: [])
        var requestedVersions: [String] { versions.withLock { $0 } }

        init(result: AppUpdateCheckResult) { self.result = result }

        func check(currentVersion: String) async -> AppUpdateCheckResult {
            versions.withLock { $0.append(currentVersion) }
            return result
        }
    }

    /// Suspends inside `check` until the test calls `finish`, so a second `run()` can be
    /// issued deterministically while the first is still in flight — no sleeps.
    final class SuspendingChecker: AppUpdateChecking {
        private let calls = OSAllocatedUnfairLock(initialState: 0)
        private let startedStream: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let resultStream: AsyncStream<AppUpdateCheckResult>
        private let resultContinuation: AsyncStream<AppUpdateCheckResult>.Continuation

        init() {
            (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            (resultStream, resultContinuation) = AsyncStream.makeStream(of: AppUpdateCheckResult.self)
        }

        var callCount: Int { calls.withLock { $0 } }

        func check(currentVersion: String) async -> AppUpdateCheckResult {
            calls.withLock { $0 += 1 }
            startedContinuation.yield()
            for await result in resultStream { return result }
            return .failed
        }

        /// Returns once a `check` call has begun.
        func waitUntilStarted() async {
            for await _ in startedStream { return }
        }

        func finish(with result: AppUpdateCheckResult) {
            resultContinuation.yield(result)
        }
    }

    /// Everything the command handed to its injected UI.
    @MainActor
    final class Recorder {
        var shown: [AppUpdatePresentation] = []
        var opened: [URL] = []
        var checkingWhilePresented: [Bool] = []
    }

    private func makeCommand(
        checker: AppUpdateChecking,
        recorder: Recorder,
        choosesPrimary: Bool = false,
        version: String = "1.8.0"
    ) -> AppUpdateCommand {
        AppUpdateCommand(
            checker: checker,
            currentVersion: { version },
            present: { presentation in
                recorder.shown.append(presentation)
                return choosesPrimary
            },
            open: { recorder.opened.append($0) }
        )
    }

    func testPresentsTheResultOnce() async {
        let recorder = Recorder()
        let command = makeCommand(checker: FixedChecker(result: .upToDate(current: "1.8.0")), recorder: recorder)
        XCTAssertFalse(command.isChecking)

        await command.run()

        XCTAssertEqual(recorder.shown, [AppUpdatePresentation(result: .upToDate(current: "1.8.0"))])
        XCTAssertFalse(command.isChecking)
    }

    func testChecksTheRunningVersion() async {
        let recorder = Recorder()
        let checker = RecordingChecker(result: .upToDate(current: "1.8.3"))
        let command = makeCommand(checker: checker, recorder: recorder, version: "1.8.3")

        await command.run()

        XCTAssertEqual(checker.requestedVersions, ["1.8.3"])
    }

    func testSecondRunWhileCheckingIsIgnored() async {
        let recorder = Recorder()
        let checker = SuspendingChecker()
        let command = makeCommand(checker: checker, recorder: recorder)

        let first = Task { await command.run() }
        await checker.waitUntilStarted()
        XCTAssertTrue(command.isChecking)

        // Returns at once: a check is already in flight.
        await command.run()
        XCTAssertTrue(recorder.shown.isEmpty, "the ignored run must not present anything")

        checker.finish(with: .upToDate(current: "1.8.0"))
        await first.value

        XCTAssertEqual(checker.callCount, 1)
        XCTAssertEqual(recorder.shown.count, 1)
        XCTAssertFalse(command.isChecking)
    }

    /// One alert at a time: the guard stays up while the alert is on screen, not only while
    /// the request is in flight — `runModal()` spins a nested run loop the menu can reach.
    func testStillCheckingWhileTheAlertIsShown() async {
        let recorder = Recorder()
        var command: AppUpdateCommand?
        command = AppUpdateCommand(
            checker: FixedChecker(result: .upToDate(current: "1.8.0")),
            currentVersion: { "1.8.0" },
            present: { presentation in
                recorder.shown.append(presentation)
                recorder.checkingWhilePresented.append(command?.isChecking ?? false)
                return true
            },
            open: { recorder.opened.append($0) }
        )

        await command?.run()

        XCTAssertEqual(recorder.checkingWhilePresented, [true])
        XCTAssertEqual(command?.isChecking, false)
    }

    func testFailedCheckStillResetsIsChecking() async {
        let recorder = Recorder()
        let command = makeCommand(checker: FixedChecker(result: .failed), recorder: recorder)

        await command.run()

        XCTAssertEqual(recorder.shown, [AppUpdatePresentation(result: .failed)])
        XCTAssertFalse(command.isChecking)

        // And the command is usable again.
        await command.run()
        XCTAssertEqual(recorder.shown.count, 2)
    }

    func testOpensTheStoreWhenTheUserChoosesOpenAppStore() async {
        let recorder = Recorder()
        let result = AppUpdateCheckResult.updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: Self.storeURL)
        let command = makeCommand(checker: FixedChecker(result: result), recorder: recorder, choosesPrimary: true)

        await command.run()

        XCTAssertEqual(recorder.shown, [AppUpdatePresentation(result: result)])
        XCTAssertEqual(recorder.opened, [Self.storeURL])
    }

    func testDoesNotOpenTheStoreWhenTheUserChoosesNotNow() async {
        let recorder = Recorder()
        let result = AppUpdateCheckResult.updateAvailable(current: "1.8.0", latest: "1.9.0", storeURL: Self.storeURL)
        let command = makeCommand(checker: FixedChecker(result: result), recorder: recorder, choosesPrimary: false)

        await command.run()

        XCTAssertEqual(recorder.shown.count, 1)
        XCTAssertEqual(recorder.opened, [])
    }

    /// OK is the first button of the up-to-date and failed alerts too; choosing it opens nothing.
    func testNeverOpensAnythingForUpToDateOrFailed() async {
        for result in [AppUpdateCheckResult.upToDate(current: "1.8.0"), .failed] {
            let recorder = Recorder()
            let command = makeCommand(checker: FixedChecker(result: result), recorder: recorder, choosesPrimary: true)

            await command.run()

            XCTAssertEqual(recorder.shown.count, 1, "\(result)")
            XCTAssertEqual(recorder.opened, [], "\(result)")
        }
    }
}
