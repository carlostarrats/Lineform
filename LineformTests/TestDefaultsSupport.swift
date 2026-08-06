import Foundation

/// Complete teardown for a test's isolated `UserDefaults` suite.
///
/// **Why this exists.** `removePersistentDomain(forName:)` clears a suite's VALUES but leaves its
/// backing `.plist` on disk. Most suites here are named with a fresh `UUID` per test for order
/// independence, so every run left one more file behind — permanently.
///
/// Nothing surfaces it: the suite is empty, the tests pass, and the only symptom is a directory
/// that grows forever. By 2026-07-29 the Debug host's container Preferences directory held
/// **7,694 plists / 30 MB**, accumulated since June.
///
/// **This is hygiene, not performance.** It was found while chasing a 7s → 480s swing in the same
/// 1,256-test plan, and deleting the files appeared to fix that — the plan ran in 12.4s straight
/// afterwards. That was a coincidence: an unchanged re-run right after a 395s run took 4.7s, and a
/// run forced through a recompile took 4.7s too. Steady state is ~5-8s. Do not cite this file as
/// the cause of a slow suite.
///
/// Destroying a suite therefore means removing the domain AND deleting the file — and deleting it
/// twice, because `cfprefsd` writes the emptied domain back after the first delete (see `destroy`).
enum TestDefaults {
    /// Vend a single-use `UserDefaults` suite that no earlier run can have written to.
    ///
    /// **A fixed suite name is not isolation.** The name outlives the process, so a test that
    /// WRITES a key and later asserts that same key is ABSENT poisons its own next run: the value
    /// is already there before the test does anything.
    /// `testFirstLaunchIntroCompletionIgnoresLegacyDebugKey` was exactly that shape — it calls
    /// `markFirstLaunchIntroCompleted` at the end and asserts the versioned key reads `false` at
    /// the start — and it failed on a developer machine while passing in a fresh checkout, which
    /// reads exactly like a production regression in `hasCompletedFirstLaunchIntro`.
    ///
    /// Destroying the suite first is not a reliable answer, which is why this exists alongside
    /// `destroy`: `removePersistentDomain` races `cfprefsd`, and under the sandboxed test host a
    /// suite name can also resolve to a source OUTSIDE the container that the host is then denied
    /// permission to read or rewrite ("accessing preferences outside an application's container
    /// requires user-preference-read or file-read-data sandbox access").
    ///
    /// Appending a UUID removes the question rather than racing it: the name has never existed
    /// before, so there is nothing to clear. The plist is still swept at exit.
    ///
    /// Note for anyone tracing a defaults bug from the other direction: a suite's search list does
    /// NOT include the application's own domain. A key sitting in `com.lineform.app.debug` — say,
    /// because a developer ran the Debug app past its first-launch intro — is invisible through a
    /// suite instance and cannot be the cause of a test like this one failing.
    static func makeSuite(_ label: String) -> UserDefaults {
        let suiteName = "\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults(suiteName: \"\(suiteName)\") returned nil")
        }
        record(suiteName)
        return defaults
    }

    /// Tear down `defaults` completely: values, registration, and the backing plist.
    static func destroy(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        remove(suiteName)
        // Deleting here is not enough on its own: the `UserDefaults` object outlives this call and
        // `cfprefsd` writes the (now empty) domain back to disk afterwards, so the file reappears
        // as a 42-byte `{}`. Measured: growth fell from ~2,000 files per run to ~40, not to zero.
        // The exit sweep below is what actually finishes the job, once every suite object is gone.
        record(suiteName)
    }

    // MARK: - Exit sweep

    // `nonisolated(unsafe)` because access is serialised by `lock` — the compiler cannot see that.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var destroyedSuiteNames: Set<String> = []
    nonisolated(unsafe) private static var sweepInstalled = false

    /// Remember a suite so it can be deleted again at process exit, and install the one-time
    /// `atexit` hook. Only names this type actually destroyed are ever removed — no pattern
    /// matching against the Preferences directory, so nothing else can be caught by it.
    private static func record(_ suiteName: String) {
        lock.lock()
        defer { lock.unlock() }
        destroyedSuiteNames.insert(suiteName)
        guard !sweepInstalled else { return }
        sweepInstalled = true
        atexit {
            // No lock: by the time atexit handlers run the test bundle is single-threaded.
            for name in TestDefaults.destroyedSuiteNames { TestDefaults.remove(name) }
        }
    }

    private static func remove(_ suiteName: String) {
        for directory in preferenceDirectories {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(suiteName).plist")
            )
        }
    }

    /// Both places a suite's plist can land. Under the sandboxed test host `NSHomeDirectory()` is
    /// the CONTAINER, which is where these actually accumulated; the real home is included because
    /// an unsandboxed run writes there instead, and a teardown that only cleaned one of them would
    /// keep leaking on the other.
    private static var preferenceDirectories: [URL] {
        var directories = [URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)]
        let realHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        if !directories.contains(realHome) { directories.append(realHome) }
        return directories
    }
}
