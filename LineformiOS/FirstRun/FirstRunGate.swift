import Foundation

/// Whether this launch shows first run (roadmap step 11). The flag is per device, in
/// `UserDefaults.standard` (never iCloud key-value storage), and is set only when the writer
/// reaches the document, so quitting mid-intro shows it again next launch.
///
/// The test host IS the app: the launch call site (`LineformiOSApp`) skips first run under XCTest
/// (`AnnouncementStore.isRunningUnderTests`); the gate itself stays pure so it can be tested.
enum FirstRunGate {
    static let completedKey = "LineformiOSFirstRunCompleted.v1"
    /// `"1"` shows first run whatever the flag says (QA, screenshots).
    static let forceEnvironmentKey = "LINEFORM_SHOW_FIRST_RUN"

    static func shouldShowAtLaunch(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[forceEnvironmentKey] == "1" { return true }
        return !defaults.bool(forKey: completedKey)
    }

    /// A scene that iOS ended with a document open reopens that document: scene restoration wins
    /// over first run.
    static func shouldPresent(launchWantsFirstRun: Bool, restoredBookmark: String, restoredPath: String) -> Bool {
        launchWantsFirstRun && restoredBookmark.isEmpty && restoredPath.isEmpty
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }
}

/// First run's stages, in order. `.line` and `.expect` advance on a timer; `.points` waits for the
/// writer; `.done` hands over to the document. A tap or swipe skips ahead.
enum FirstRunStage: Int, CaseIterable {
    case line, expect, points, done

    /// The stage after this one; `.done` stays `.done`, so a late tap does nothing.
    var next: FirstRunStage {
        FirstRunStage(rawValue: rawValue + 1) ?? .done
    }

    /// How long the stage stays before it advances by itself; nil waits for the writer.
    /// Under Reduce Motion the web page shows the finished line at once, so it needs only a moment.
    func autoAdvanceDelay(reduceMotion: Bool) -> Duration? {
        switch self {
        case .line: reduceMotion ? .milliseconds(1200) : .milliseconds(2600)
        case .expect: .milliseconds(1800)
        case .points, .done: nil
        }
    }
}

/// First run's words: the ONE place the owner edits them. English is the catalog key; the
/// translations live in `LineformiOS/Localizable.xcstrings`.
enum FirstRunCopy {
    static var heading: String {
        String(localized: "What to expect", comment: "First run heading. The owner edits this copy in FirstRunCopy.")
    }

    static var points: [String] {
        [
            String(
                localized: "Free, and everything stays on your device.",
                comment: "First run point 1. The owner edits this copy in FirstRunCopy."
            ),
            String(
                localized: "Your files stay in iCloud, and sync with Lineform on your Mac if you use it there.",
                comment: "First run point 2. The owner edits this copy in FirstRunCopy."
            ),
            String(
                localized: "Markdown, styled PDFs, and AI only if you connect your own.",
                comment: "First run point 3. The owner edits this copy in FirstRunCopy."
            ),
        ]
    }

    static var startWriting: String {
        String(localized: "Start Writing", comment: "First run button that opens the document. The owner edits this copy in FirstRunCopy.")
    }
}
