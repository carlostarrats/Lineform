import SwiftUI

/// Lineform on iPhone: one window holding one full-screen document.
@main
struct LineformiOSApp: App {
    var body: some Scene {
        WindowGroup {
            DocumentScreen()
        }
    }
}
