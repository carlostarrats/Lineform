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

    init() {
        // Atkinson Hyperlegible and OpenDyslexic ship in `Fonts/` (shared with the Mac app, by
        // reference, with their licences); register them before the first editor resolves a font.
        BundledFontRegistrar.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            DocumentScreen(document: document, profileStore: profileStore)
                .onOpenURL { url in Task { await document.openReportingFailure(url) } }
        }
    }
}
