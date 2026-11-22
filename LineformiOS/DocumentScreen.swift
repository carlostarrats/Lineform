import LineformCore
import SwiftUI

/// The full-screen document. A normal launch opens a blank document; there is no bar across the
/// top of the text, and the page colour runs edge to edge under the status bar and home
/// indicator. The editor still resizes for the keyboard (only the container safe area is ignored).
///
/// After iOS ends the app, the next launch reopens the document that was open: `@SceneStorage`
/// keeps a bookmark to its file, and the system discards it when the user force-quits, so a
/// normal launch is blank. Leaving the foreground (inactive or background) saves at once.
///
/// The reading profile comes from the per-device `ReadingProfileStore`, observed here, so a
/// profile change (the Styling sheet, roadmap step 7) re-applies to the editor without a relaunch.
struct DocumentScreen: View {
    var document: OpenDocument
    @ObservedObject var profileStore: ReadingProfileStore
    private var profile: ReadingProfile { profileStore.activeProfile }
    @State private var isShowingFiles = false
    @SceneStorage("openDocumentBookmark") private var openDocumentBookmark = ""
    /// The older form, a path. Read once for a scene stored before bookmarks, then cleared.
    @SceneStorage("openDocumentPath") private var legacyOpenDocumentPath = ""
    @Environment(\.scenePhase) private var scenePhase

    /// The quiet notice over the bottom of the page, if any: a failed save, else an image that
    /// could not be written beside the document.
    private var noticeMessage: String? {
        if document.saveFailed { return String(localized: "Couldn’t save this document. Your text is still here.") }
        if document.imageSaveFailed { return String(localized: "Can't save images beside this document.") }
        return nil
    }

    var body: some View {
        MarkdownEditor(
            text: Binding(get: { document.text }, set: { document.edit($0) }),
            profile: profile,
            imageHost: document
        )
        .ignoresSafeArea(.container)
        .background(Color(uiColor: Theme.theme(for: profile).backgroundColor))
        .overlay {
            if document.downloadingName != nil {
                DownloadingView(profile: profile)
            }
        }
        .overlay(alignment: .bottom) {
            // A failed save matters more than a failed image, and stays until a save succeeds.
            if let message = noticeMessage {
                QuietNotice(message: message, profile: profile)
                    .padding(.bottom, MarkdownEditor.chromeMargin + MenuButton.diameter + 12)
                    .padding(.horizontal, MarkdownEditor.chromeMargin)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: noticeMessage)
        .overlay(alignment: .bottomTrailing) {
            MenuButton(profile: profile) { isShowingFiles = true }
                .padding(MarkdownEditor.chromeMargin)
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
        .task {
            await document.prepare(
                restoringBookmark: openDocumentBookmark,
                restoringStoredPath: legacyOpenDocumentPath
            )
            legacyOpenDocumentPath = ""
            openDocumentBookmark = document.storedBookmark
        }
        .onChange(of: document.url) {
            openDocumentBookmark = document.storedBookmark
        }
        .onChange(of: scenePhase) { _, phase in
            if OpenDocument.savesImmediately(on: phase) { document.flushForBackground() }
        }
    }
}

/// Shown in place of the text while iCloud downloads the file being opened: quiet, no buttons.
private struct DownloadingView: View {
    var profile: ReadingProfile

    var body: some View {
        let theme = Theme.theme(for: profile)
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Downloading…"))
                .font(.callout)
                .foregroundStyle(Color(uiColor: theme.textColor).opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: theme.backgroundColor))
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

/// A small, calm notice: after a save failed (the text is still in memory, the next save tries
/// again, and it goes away once a save succeeds), or for a few seconds after an image could not be
/// saved beside the document. It never blocks typing.
private struct QuietNotice: View {
    var message: String
    var profile: ReadingProfile

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(uiColor: theme.textColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(uiColor: theme.backgroundColor)))
            .overlay(
                Capsule().strokeBorder(
                    isDark
                        ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                        : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                    lineWidth: LineformDesign.FloatingCard.hairlineWidth
                )
            )
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
    }
}
