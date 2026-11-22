import LineformCore
import SwiftUI

/// Lineform on iPhone: one window holding one full-screen document.
@main
struct LineformiOSApp: App {
    /// The app has a single scene, so the open document lives here, where "Open in Lineform"
    /// from the Files app (`onOpenURL`) can reach it.
    @State private var document = OpenDocument.live()
    /// The reading profile, per device (`UserDefaults.standard`, never synced).
    @StateObject private var profileStore = ReadingProfileStore()
    /// Whether this launch shows first run, decided once. Never under XCTest: the test host IS the
    /// app, and the hosted tests expect the document on screen. Guarded here, at the launch call
    /// site, never inside the gate, whose own tests drive it directly.
    private let showsFirstRun = !Self.isRunningUnderTests && FirstRunGate.shouldShowAtLaunch()

    /// True when this process is a test host rather than a real launch: the same check as the
    /// Mac's `AnnouncementStore.isRunningUnderTests`, which lives in the Mac app, not the package.
    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        // Atkinson Hyperlegible and OpenDyslexic ship in `Fonts/` (shared with the Mac app, by
        // reference, with their licences); register them before the first editor resolves a font.
        BundledFontRegistrar.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            DocumentScreen(document: document, profileStore: profileStore, showsFirstRun: showsFirstRun)
                .onOpenURL { url in Task { await document.openReportingFailure(url) } }
        }
    }
}
