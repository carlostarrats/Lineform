import LineformCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// Read mode in place of the editor. Temporary until the Write / Read / Preview control
    /// (roadmap step 5, Task 3): tests start the screen in Read, and Debug builds show a small
    /// switch; Release always shows Write.
    @State private var isReading: Bool
    /// The image line whose Reconnect pill opened the image picker.
    @State private var reconnectRange: NSRange?
    @State private var isPickingReconnectImage = false
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

    init(document: OpenDocument, profileStore: ReadingProfileStore, startsInRead: Bool = false) {
        self.document = document
        self.profileStore = profileStore
        _isReading = State(initialValue: startsInRead)
    }

    /// The image types Reconnect offers, as on the Mac.
    static let reconnectImageTypes: [UTType] = [.png, .jpeg, .gif, .heic, .tiff, .bmp, .image]

    var body: some View {
        page
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
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            DebugReadSwitch(isReading: $isReading, profile: profile)
                .padding(MarkdownEditor.chromeMargin)
        }
        #endif
        .sheet(isPresented: $isShowingFiles) {
            FileListSheet(document: document)
        }
        .fileImporter(
            isPresented: $isPickingReconnectImage,
            allowedContentTypes: Self.reconnectImageTypes,
            allowsMultipleSelection: false
        ) { result in
            defer { reconnectRange = nil }
            guard let range = reconnectRange, case .success(let urls) = result, let picked = urls.first else { return }
            document.reconnectImage(at: range, with: picked)
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

extension DocumentScreen {
    /// Write's editor, or the Read view.
    @ViewBuilder
    private var page: some View {
        if isReading {
            ReadViewRepresentable(
                text: document.text,
                profile: profile,
                documentDirectory: document.documentDirectory,
                onCheckboxToggle: { range, renderedFrom in
                    document.toggleCheckbox(at: range, renderedFrom: renderedFrom)
                },
                onImageReconnect: { range in
                    reconnectRange = range
                    isPickingReconnectImage = true
                },
                undoManager: document.undoManager
            )
        } else {
            MarkdownEditor(
                text: Binding(get: { document.text }, set: { document.edit($0) }),
                profile: profile,
                imageHost: document
            )
        }
    }
}

#if DEBUG
/// Debug builds only: switches between Write and Read until the real mode control arrives.
private struct DebugReadSwitch: View {
    @Binding var isReading: Bool
    var profile: ReadingProfile

    var body: some View {
        let theme = Theme.theme(for: profile)
        Button {
            isReading.toggle()
        } label: {
            Image(systemName: isReading ? "pencil" : "book")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.textColor))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(uiColor: theme.backgroundColor)))
                .overlay(Circle().strokeBorder(Color(uiColor: theme.textColor).opacity(0.2), lineWidth: 1))
        }
        // Debug-only and never shipped: VoiceOver reads the symbol's own name, so no string
        // goes in the catalog.
    }
}
#endif

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
