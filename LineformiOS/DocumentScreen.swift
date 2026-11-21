import LineformCore
import SwiftUI

/// The full-screen document. A normal launch opens a blank document; there is no bar across the
/// top of the text, and the page colour runs edge to edge under the status bar and home
/// indicator. The editor still resizes for the keyboard (only the container safe area is ignored).
struct DocumentScreen: View {
    var document: OpenDocument
    private let profile = ReadingProfile.original
    @State private var isShowingFiles = false

    var body: some View {
        PlainTextEditor(
            text: Binding(get: { document.text }, set: { document.edit($0) }),
            profile: profile
        )
        .ignoresSafeArea(.container)
        .background(Color(uiColor: Theme.theme(for: profile).backgroundColor))
        .overlay(alignment: .bottomTrailing) {
            MenuButton(profile: profile) { isShowingFiles = true }
                .padding(PlainTextEditor.minimumSideMargin)
        }
        .sheet(isPresented: $isShowingFiles) {
            FileListSheet(document: document)
        }
        .alert(
            String(localized: "That file couldn't be opened in Lineform."),
            isPresented: Binding(
                get: { document.failedOpenURL != nil },
                set: { if !$0 { document.failedOpenURL = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
        .task { await document.prepare() }
    }
}
