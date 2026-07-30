import Foundation

/// Complete teardown for a test's isolated `UserDefaults` suite.
///
/// **Why this exists.** `removePersistentDomain(forName:)` clears a suite's VALUES but leaves its
/// backing `.plist` on disk. Most suites here are named with a fresh `UUID` per test for order
/// independence, so every run left one more file behind — permanently.
///
/// That is invisible until it isn't. By 2026-07-29 the Debug host's container Preferences
/// directory held **7,694 plists / 30 MB**, and because `cfprefsd`'s per-operation cost scales
/// with that directory, the default 1,256-test plan had slowed from ~7s to **480s** of test time.
/// Nothing looked wrong: every individual test still reported single-digit milliseconds, every
/// suite reported well under a second, and the plan stayed green the whole way. Deleting the
/// leaked files took the same plan back to **12.4s** — a 39× swing with no code change.
///
/// So: destroying a suite means removing the domain, unregistering it, AND deleting the file.
/// Removing only the domain is what caused this.
enum TestDefaults {
    /// Tear down `defaults` completely: values, registration, and the backing plist.
    static func destroy(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        // Drop the suite from the search list too, so a later `UserDefaults.standard` read in the
        // same process can't still see it.
        UserDefaults.standard.removeSuite(named: suiteName)
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
