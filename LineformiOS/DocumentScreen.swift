import LineformCore
import SwiftUI
import UniformTypeIdentifiers

/// The full-screen document. A normal launch opens a blank document; there is no bar across the
/// top of the text, and the page colour runs edge to edge under the status bar and home
/// indicator. The editor still resizes for the keyboard (only the container safe area is ignored).
///
/// The Write / Read / Preview pill (`ModeSwitch`) floats at the top centre, inside the safe area,
/// over the page. The mode is kept with the scene; a switch keeps the passage at the top of the
/// page (`ModePositionKeeper`), and ⌘E toggles Write and Read as on the Mac.
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
    /// Write, Read or Preview. Kept with the scene, so a Preview restored after iOS ended the app
    /// opens in Preview; a new scene starts in Write.
    @SceneStorage("displayMode") private var storedDisplayMode: EditorDisplayMode = .write
    /// The mode on screen: the stored one, adopted on appear, then every switch (written back to
    /// the scene). Plain state as well, because a screen hosted outside a SwiftUI scene (a test)
    /// has no scene storage to write to.
    @State private var shownDisplayMode: EditorDisplayMode?
    private var displayMode: EditorDisplayMode { shownDisplayMode ?? storedDisplayMode }
    /// Records the position at a mode switch and restores it on the new surface.
    @State private var positionKeeper = ModePositionKeeper()
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

    /// `initialMode` is the mode of a scene with nothing stored: Write in the app; tests start
    /// elsewhere.
    init(document: OpenDocument, profileStore: ReadingProfileStore, initialMode: EditorDisplayMode = .write) {
        self.document = document
        self.profileStore = profileStore
        _storedDisplayMode = SceneStorage(wrappedValue: initialMode, "displayMode")
    }

    /// The mode control's binding: every switch goes through the position keeper first.
    private var modeSelection: Binding<EditorDisplayMode> {
        Binding(get: { displayMode }, set: { switchMode(to: $0) })
    }

    private func switchMode(to mode: EditorDisplayMode) {
        guard mode != displayMode else { return }
        positionKeeper.switchMode(from: displayMode, to: mode)
        shownDisplayMode = mode
        storedDisplayMode = mode
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
        .overlay(alignment: .top) {
            ModeSwitch(mode: modeSelection, usesDarkChrome: Theme.theme(for: profile).usesDarkChrome)
                .padding(.top, ModeSwitch.topMargin)
        }
        .overlay(alignment: .bottomTrailing) {
            MenuButton(profile: profile) { isShowingFiles = true }
                .padding(MarkdownEditor.chromeMargin)
        }
        .background {
            // ⌘E on a hardware keyboard: Write ↔ Read, and Preview to Write, as on the Mac.
            Button(String(localized: "Toggle Write / Read")) {
                switchMode(to: displayMode.toggledWriteRead)
            }
            .keyboardShortcut(Self.toggleWriteReadShortcut)
            .hidden()
        }
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
        .onAppear {
            shownDisplayMode = shownDisplayMode ?? storedDisplayMode
            positionKeeper.adopt(displayMode)
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
    /// ⌘E, the Mac's Toggle Write / Read.
    static let toggleWriteReadShortcut = KeyboardShortcut("e", modifiers: .command)

    /// The editor and the Read view, placed for the mode. The editor stays in the hierarchy in
    /// every mode (under the Read view in Read), so Write keeps its undo history across a switch;
    /// the Read view exists only in Read and Preview, so typing in Write renders nothing.
    @ViewBuilder
    private var page: some View {
        let mode = displayMode
        GeometryReader { proxy in
            let height = proxy.size.height
            let editorHeight = mode == .split ? (height / 2).rounded() : height
            ZStack(alignment: .top) {
                editor
                    .frame(height: editorHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(mode != .read)
                    .accessibilityHidden(mode == .read)
                if mode != .write {
                    reader
                        .frame(height: mode == .split ? height - editorHeight : height)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        // The pill animates; the page itself switches at once, so the restore lands on settled
        // frames.
        .transaction { $0.animation = nil }
    }

    private var editor: some View {
        MarkdownEditor(
            text: Binding(get: { document.text }, set: { document.edit($0) }),
            profile: profile,
            imageHost: document,
            positionKeeper: positionKeeper,
            topChromeInset: ModeSwitch.pageTopClearance
        )
    }

    private var reader: some View {
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
            undoManager: document.undoManager,
            positionKeeper: positionKeeper,
            topChromeInset: displayMode == .split ? 0 : ModeSwitch.pageTopClearance
        )
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
