import SwiftUI

/// Lineform on iPhone: one window holding one full-screen document.
@main
struct LineformiOSApp: App {
    /// The app has a single scene, so the open document lives here, where "Open in Lineform"
    /// from the Files app (`onOpenURL`) can reach it.
    @State private var document = OpenDocument.live()

    var body: some Scene {
        WindowGroup {
            DocumentScreen(document: document)
                .onOpenURL { url in Task { await document.openReportingFailure(url) } }
        }
    }
}
