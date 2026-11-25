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

/// First run's stages, in order. Nothing advances by itself: `.welcome` waits for Get Started,
/// `.points` for Start Writing; `.done` hands over to the document.
enum FirstRunStage: Int, CaseIterable {
    case welcome, points, done

    /// The stage after this one; `.done` stays `.done`, so a late tap does nothing.
    var next: FirstRunStage {
        FirstRunStage(rawValue: rawValue + 1) ?? .done
    }
}

/// First run's timing. None of it moves the writer on; it only paces what they see.
enum FirstRunTiming {
    /// How long the wordmark takes to write itself (the Mac's intro takes 1 s).
    static let writeSeconds = 3.5
    /// Get Started shows at the latest this long after the welcome began, if the page never says
    /// the wordmark is written (a missing page, a WebGL failure, a crashed web content process).
    static let getStartedCap: Duration = .seconds(7)
    /// The wordmark's shrink and glide to the top after Get Started (ease-in-out).
    static let shrinkSeconds = 0.9
    /// When each point starts to arrive after Get Started, one after another.
    static func pointDelay(_ index: Int) -> Double {
        0.7 + 0.2 * Double(index)
    }

    /// When Start Writing arrives: after the last point.
    static func startWritingDelay(pointCount: Int) -> Double {
        pointDelay(max(0, pointCount - 1)) + 0.25
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

/// One of first run's points: its symbol, title and words, kept together so a point added or
/// removed in `FirstRunCopy.pointItems` always shows with its own symbol.
struct FirstRunPoint: Equatable {
    var symbol: String
    var title: String
    var text: String
}

/// First run's words: the ONE place the owner edits them. English is the catalog key; the
/// translations live in `LineformiOS/Localizable.xcstrings`.
enum FirstRunCopy {
    /// Under the wordmark on the welcome screen.
    static var tagline: String {
        String(localized: "Simple markdown editing", comment: "First run tagline under the wordmark. The owner edits this copy in FirstRunCopy.")
    }

    static var getStarted: String {
        String(localized: "Get Started", comment: "First run button under the tagline. The owner edits this copy in FirstRunCopy.")
    }

    /// The points, in order, each with its SF Symbol. Add, remove or reword them here.
    static var pointItems: [FirstRunPoint] {
        [
            FirstRunPoint(
                symbol: "lock",
                title: String(localized: "Free and private", comment: "First run point 1 title. The owner edits this copy in FirstRunCopy."),
                text: String(
                    localized: "No account, nothing to sign up for. Your writing stays with you.",
                    comment: "First run point 1. The owner edits this copy in FirstRunCopy."
                )
            ),
            FirstRunPoint(
                symbol: "icloud",
                title: String(localized: "Real files, in iCloud", comment: "First run point 2 title. The owner edits this copy in FirstRunCopy."),
                text: String(
                    localized: "Plain Markdown files that sync with Lineform for Mac and open anywhere.",
                    comment: "First run point 2. The owner edits this copy in FirstRunCopy."
                )
            ),
            FirstRunPoint(
                symbol: "doc.richtext",
                title: String(localized: "More than text", comment: "First run point 3 title. The owner edits this copy in FirstRunCopy."),
                text: String(
                    localized: "Images, tables, math and diagrams. Export styled PDFs in a tap.",
                    comment: "First run point 3. The owner edits this copy in FirstRunCopy."
                )
            ),
            FirstRunPoint(
                symbol: "accessibility",
                title: String(localized: "Made to be read", comment: "First run point 4 title. The owner edits this copy in FirstRunCopy."),
                text: String(
                    localized: "Reading themes, accessible fonts and read aloud. AI only if you connect your own.",
                    comment: "First run point 4. The owner edits this copy in FirstRunCopy."
                )
            ),
        ]
    }

    static var startWriting: String {
        String(localized: "Start Writing", comment: "First run button that opens the document. The owner edits this copy in FirstRunCopy.")
    }

    /// Every string first run shows, in screen order.
    static var allStrings: [String] {
        [tagline, getStarted] + pointItems.flatMap { [$0.title, $0.text] } + [startWriting]
    }
}
