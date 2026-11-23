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

    /// How long the stage stays before it advances by itself; nil waits for the writer. For
    /// `.line` the hold runs from the moment the page has painted (`FirstRunTiming`), not from
    /// the stage's start. Under Reduce Motion the page shows the finished line at once, so it
    /// needs only a moment. While VoiceOver runs, "What to expect" stays long enough to be heard
    /// out before the points replace it (the switch to the points interrupts speech).
    func autoAdvanceDelay(reduceMotion: Bool, voiceOverRunning: Bool = false) -> Duration? {
        switch self {
        case .line: reduceMotion ? .milliseconds(1200) : .milliseconds(2600)
        case .expect: voiceOverRunning ? FirstRunTiming.voiceOverExpectHold : .milliseconds(1800)
        case .points, .done: nil
        }
    }
}

/// When a timed stage advances by itself.
enum FirstRunTiming {
    /// The line stage advances by this long after it began, painted or not (a missing page, a
    /// WebGL failure or a crashed web content process never strands the writer).
    static let lineCap: Duration = .seconds(4)
    /// "What to expect"'s hold while VoiceOver runs.
    static let voiceOverExpectHold: Duration = .seconds(4)

    /// The moment the stage that began at `stageStart` advances by itself, or nil when it waits
    /// for the writer. `.line` holds from `lineReadyAt` (the page's first painted frame), capped
    /// at `lineCap` from its start.
    static func deadline(
        for stage: FirstRunStage,
        stageStart: ContinuousClock.Instant,
        lineReadyAt: ContinuousClock.Instant?,
        reduceMotion: Bool,
        voiceOverRunning: Bool = false
    ) -> ContinuousClock.Instant? {
        guard let hold = stage.autoAdvanceDelay(reduceMotion: reduceMotion, voiceOverRunning: voiceOverRunning) else { return nil }
        guard stage == .line else { return stageStart + hold }
        let cap = stageStart + lineCap
        guard let ready = lineReadyAt else { return cap }
        return min(ready + hold, cap)
    }
}

/// Whether first run is on screen this session. Decided once at launch, then it only ever turns
/// off: a restored scene, an opened document or finishing ends it, and nothing brings it back
/// (a later empty scene bookmark, after New Document or a deleted file, must not re-arm it).
struct FirstRunPresentation: Equatable {
    private(set) var isShowing: Bool

    init(launchWantsFirstRun: Bool) {
        isShowing = launchWantsFirstRun
    }

    /// The scene's stored document, read when the screen appears. True when this ended first
    /// run (the writer reached a document, so the caller marks it completed).
    mutating func restored(bookmark: String, path: String) -> Bool {
        guard !FirstRunGate.shouldPresent(launchWantsFirstRun: true, restoredBookmark: bookmark, restoredPath: path)
        else { return false }
        return end()
    }

    /// A document was opened (Files' "Open in Lineform", the file sheet). True when this ended
    /// first run.
    mutating func documentOpened() -> Bool {
        end()
    }

    /// The writer finished first run.
    mutating func finished() {
        isShowing = false
    }

    private mutating func end() -> Bool {
        guard isShowing else { return false }
        isShowing = false
        return true
    }
}

/// One of first run's points: its symbol and its words, kept together so a point added or
/// removed in `FirstRunCopy.pointItems` always shows with its own symbol.
struct FirstRunPoint: Equatable {
    var symbol: String
    var text: String
}

/// First run's words: the ONE place the owner edits them. English is the catalog key; the
/// translations live in `LineformiOS/Localizable.xcstrings`.
enum FirstRunCopy {
    static var heading: String {
        String(localized: "What to expect", comment: "First run heading. The owner edits this copy in FirstRunCopy.")
    }

    /// The points, in order, each with its SF Symbol. Add, remove or reword them here.
    static var pointItems: [FirstRunPoint] {
        [
            FirstRunPoint(
                symbol: "lock",
                text: String(
                    localized: "Free, and everything stays on your device.",
                    comment: "First run point 1. The owner edits this copy in FirstRunCopy."
                )
            ),
            FirstRunPoint(
                symbol: "icloud",
                text: String(
                    localized: "Your files stay in iCloud, and sync with Lineform on your Mac if you use it there.",
                    comment: "First run point 2. The owner edits this copy in FirstRunCopy."
                )
            ),
            FirstRunPoint(
                symbol: "doc.richtext",
                text: String(
                    localized: "Markdown, styled PDFs, and AI only if you connect your own.",
                    comment: "First run point 3. The owner edits this copy in FirstRunCopy."
                )
            ),
        ]
    }

    /// The points' words, in order.
    static var points: [String] { pointItems.map(\.text) }

    static var startWriting: String {
        String(localized: "Start Writing", comment: "First run button that opens the document. The owner edits this copy in FirstRunCopy.")
    }
}
