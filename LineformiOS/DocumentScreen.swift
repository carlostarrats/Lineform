import LineformCore
import SwiftUI

/// The full-screen document. A normal launch opens a blank document; there is no bar across the
/// top of the text, and the page colour runs edge to edge under the status bar and home
/// indicator. The editor still resizes for the keyboard (only the container safe area is ignored).
struct DocumentScreen: View {
    @State private var text = ""
    private let profile = ReadingProfile.original

    var body: some View {
        PlainTextEditor(text: $text, profile: profile)
            .ignoresSafeArea(.container)
            .background(Color(uiColor: Theme.theme(for: profile).backgroundColor))
    }
}
