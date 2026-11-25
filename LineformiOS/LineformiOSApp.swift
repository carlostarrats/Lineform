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

    @Environment(\.scenePhase) private var scenePhase

    /// A file from Files or another app opens as is; a widget's `lineform://` link opens that
    /// document or starts a new note.
    @MainActor
    static func handleOpen(_ url: URL, document: OpenDocument) async {
        switch WidgetRecents.link(from: url) {
        case .newNote:
            try? await PhoneIntentRouter.shared.handle(.newNote(""))
        case .open(let file):
            await document.openReportingFailure(file)
        case nil:
            await document.openReportingFailure(url)
        }
    }

    /// Writes the newest documents for the home-screen widget (titles and locations only).
    static func refreshWidgetRecents() {
        Task.detached(priority: .utility) {
            let resolver = DocumentFolderResolver.live()
            var roots: [(url: URL, location: String)] = []
            if let cloud = resolver.iCloudFolder() { roots.append((cloud, String(localized: "iCloud"))) }
            roots.append((resolver.deviceFolder, String(localized: "On My iPhone")))
            WidgetRecents.save(WidgetRecents.newestDocuments(in: roots))
        }
    }

    var body: some Scene {
        WindowGroup {
            DocumentScreen(document: document, profileStore: profileStore, showsFirstRun: showsFirstRun)
                .onOpenURL { url in Task { await Self.handleOpen(url, document: document) } }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The announcement check (once a day at most, gated by the setting) when the app
            // comes to the foreground: launch included. Never in the test host, at this call site.
            if PhoneAnnouncementStore.checksOnSceneChange(to: phase, isRunningUnderTests: Self.isRunningUnderTests) {
                Task { await PhoneAnnouncementStore.shared.checkIfNeeded(isEnabled: AppSettings.shared.checksForAnnouncements) }
            }
            // The widget's list: on launch and whenever the app leaves (after the save).
            if !Self.isRunningUnderTests, phase != .inactive { Self.refreshWidgetRecents() }
        }
    }
}
