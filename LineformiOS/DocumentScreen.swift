import LineformCore
import SwiftUI
import UIKit
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
/// What the page draws with is that profile with Automatic Dark Mode applied for the iPhone's
/// appearance (`AppSettings.displayProfile`, the Mac's rule): the colour scheme comes from the
/// trait collection's `userInterfaceStyle`, so the page re-renders when the appearance changes.
struct DocumentScreen: View {
    var document: OpenDocument
    @ObservedObject var profileStore: ReadingProfileStore
    /// The Files section's store. One for the app's lifetime, so a Workspace folder's access
    /// outlives the Menu sheet.
    var files: FilesStore
    /// The Settings section's values: Automatic Dark Mode and the spelling switch apply here.
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var profile: ReadingProfile {
        settings.displayProfile(profileStore.activeProfile, userInterfaceStyle: UIUserInterfaceStyle(colorScheme))
    }
    @State private var isShowingMenu = false
    @State private var isShowingStyling = false
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
    /// Preview's linked scrolling, linked by default.
    @State private var linkedScroll = LinkedScroll()
    /// The link button's state (mirrors `linkedScroll.isLinked`, which SwiftUI does not observe).
    @State private var arePanesLinked = true
    /// The image line whose Reconnect pill opened the image picker, and the source the Read view
    /// had rendered it from: a pick that returns after the text changed is refused.
    @State private var reconnectRange: NSRange?
    @State private var reconnectRenderedText: String?
    @State private var isPickingReconnectImage = false
    /// Export, Print, Share and read aloud for the open document. Made once, on first appear, so
    /// re-creating this view never makes a second speech controller.
    @State private var exportCommands: ExportCommands?
    @SceneStorage("openDocumentBookmark") private var openDocumentBookmark = ""
    /// The older form, a path. Read once for a scene stored before bookmarks, then cleared.
    @SceneStorage("openDocumentPath") private var legacyOpenDocumentPath = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// First run (roadmap step 11): decided once, then latched off for the session by a restored
    /// scene, an opened document or finishing (`FirstRunPresentation`); it never comes back.
    @State private var firstRun: FirstRunPresentation
    /// Whether `onAppear` has checked the restored scene against first run yet.
    @State private var hasCheckedFirstRunRestore = false
    /// The selection row and comment field over the bottom of the page (spec §5.5). While either
    /// shows, it replaces the bottom-right buttons.
    @StateObject private var selection: SelectionController
    /// The Menu's Ask AI… was tapped: once the sheet has closed, the whole-document policy runs
    /// (a confirmation cannot be presented over the closing sheet).
    @State private var asksAIForWholeDocument = false

    /// The quiet notice over the bottom of the page, if any: a failed save, else an image that
    /// could not be written beside the document.
    private var noticeMessage: String? {
        if document.saveFailed { return String(localized: "Couldn’t save this document. Your text is still here.") }
        if let exportFailure = exportCommands?.failureNotice { return exportFailure }
        if document.imageSaveFailed { return String(localized: "Can't save images beside this document.") }
        return nil
    }

    /// `initialMode` is the mode of a scene with nothing stored: Write in the app; tests start
    /// elsewhere. `showsFirstRun` is the launch's answer from `FirstRunGate.shouldShowAtLaunch`.
    init(
        document: OpenDocument,
        profileStore: ReadingProfileStore,
        files: FilesStore = .shared,
        settings: AppSettings = .shared,
        initialMode: EditorDisplayMode = .write,
        showsFirstRun: Bool = false,
        selection: SelectionController? = nil
    ) {
        self.document = document
        self.profileStore = profileStore
        self.files = files
        self.settings = settings
        _storedDisplayMode = SceneStorage(wrappedValue: initialMode, "displayMode")
        _firstRun = State(initialValue: FirstRunPresentation(launchWantsFirstRun: showsFirstRun))
        _selection = StateObject(wrappedValue: selection ?? SelectionController())
    }

    private var presentsFirstRun: Bool {
        guard firstRun.isShowing else { return false }
        // Before `onAppear` latches the decision, a stored scene already hides first run, so a
        // restored document never flashes it.
        return hasCheckedFirstRunRestore || FirstRunGate.shouldPresent(
            launchWantsFirstRun: true,
            restoredBookmark: openDocumentBookmark,
            restoredPath: legacyOpenDocumentPath
        )
    }

    /// The fade first run leaves with (none under Reduce Motion).
    private var firstRunFade: Animation? {
        EditorMotionPolicy.animation(.easeInOut(duration: 0.32), reduceMotion: reduceMotion)
    }

    /// First run is over: fade it out, switch to Write if another mode was left on, then put the
    /// caret in the blank document.
    private func finishFirstRun() {
        withAnimation(firstRunFade) {
            firstRun.finished()
        }
        let needsSwitch = displayMode != .write
        if needsSwitch { switchMode(to: .write) }
        Task { @MainActor in
            if needsSwitch { await Task.yield() }
            positionKeeper.editor?.becomeFirstResponder()
        }
    }

    /// A document reached the screen some other way (restored, or opened): first run ends for
    /// good, and counts as completed.
    private func endFirstRun(_ ended: Bool) {
        guard ended else { return }
        FirstRunGate.markCompleted()
    }

    /// The mode control's binding: every switch goes through the position keeper first.
    private var modeSelection: Binding<EditorDisplayMode> {
        Binding(get: { displayMode }, set: { switchMode(to: $0) })
    }

    private func switchMode(to mode: EditorDisplayMode) {
        guard mode != displayMode else { return }
        // History mode is Write's: switching to Read or Preview leaves it (with the collapse).
        if mode != .write, let history = document.history, history.isHistoryModeActive {
            history.exitHistoryMode(text: editorText)
        }
        positionKeeper.switchMode(from: displayMode, to: mode)
        shownDisplayMode = mode
        storedDisplayMode = mode
    }

    /// Makes the export commands once. Reading the previous document aloud stops whenever the
    /// document swaps (New Document, an open from the list or Files, the launch restore), and
    /// any export copy a share sheet (or Save As copy a picker) still held when iOS ended the app
    /// is deleted.
    private func makeExportCommandsIfNeeded() {
        guard exportCommands == nil else { return }
        let commands = ExportCommands(document: document, profile: { [profileStore] in profileStore.activeProfile })
        commands.removeExports()
        SaveAsStaging.removeAll()
        document.onDocumentSwap = { [weak commands] in commands?.documentWillChange() }
        exportCommands = commands
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
        .overlay(alignment: .bottom) {
            // History mode's card replaces the bottom chrome while it is up (Done leaves).
            if let history = document.history, history.isHistoryModeActive {
                historyCard(history)
                    .padding(.horizontal, MarkdownEditor.chromeMargin)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // The selection row, the comment field and a running request or review take the
            // bottom in turn. A message or Find's marks leave these reachable: that card sits
            // above them (`SelectionBottomChrome`). History's card replaces them all.
            if !isHistoryModeActive,
               SelectionController.showsBottomButtons(phase: selection.phase, aiState: selection.aiState) {
                HStack(spacing: Self.bottomChromeSpacing) {
                    if displayMode == .split {
                        PreviewLinkButton(isLinked: arePanesLinked, profile: profile) {
                            linkedScroll.toggleLink()
                            arePanesLinked = linkedScroll.isLinked
                        }
                    }
                    MenuButton(profile: profile) { isShowingMenu = true }
                    StylingButton(profile: profile) { isShowingStyling = true }
                }
                .padding(MarkdownEditor.chromeMargin)
                .transition(.opacity)
            }
        }
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: LineformDesign.Motion.standard), reduceMotion: reduceMotion),
            value: selection.phase
        )
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: LineformDesign.Motion.standard), reduceMotion: reduceMotion),
            value: SelectionController.showsBottomButtons(phase: selection.phase, aiState: selection.aiState)
        )
        .overlay {
            SelectionBottomChrome(controller: selection, profile: profile)
        }
        .overlay {
            // Above all the other chrome, so nothing of the document shows through or takes taps.
            if presentsFirstRun {
                FirstRunOverlay(onFinish: finishFirstRun)
                    .transition(.opacity)
            }
        }
        .background {
            // ⌘E on a hardware keyboard: Write ↔ Read, and Preview to Write, as on the Mac.
            Button(String(localized: "Toggle Write / Read")) {
                switchMode(to: displayMode.toggledWriteRead)
            }
            .keyboardShortcut(Self.toggleWriteReadShortcut)
            .disabled(presentsFirstRun)
            .hidden()
        }
        .sheet(isPresented: $isShowingMenu, onDismiss: {
            if asksAIForWholeDocument {
                asksAIForWholeDocument = false
                selection.askAIForWholeDocument()
            }
        }) {
            MenuSheet(
                document: document,
                editor: LiveEditorCommands(positionKeeper: positionKeeper, document: document, mode: displayMode),
                files: files,
                settings: settings,
                profile: profile,
                exportCommands: exportCommands,
                selection: { [positionKeeper] in positionKeeper.editor?.selectedRange },
                mode: displayMode,
                onShowHistory: { showHistoryFromMenu() },
                aiStore: selection.aiConnectionStore,
                onAskAI: { asksAIForWholeDocument = true },
                onDismiss: { isShowingMenu = false }
            )
        }
        .sheet(isPresented: $isShowingStyling, onDismiss: {
            // A Reconnect tapped on the page beside the open sheet waits for it to close: a view
            // already presenting cannot present the image picker too.
            if reconnectRange != nil, !isPickingReconnectImage { isPickingReconnectImage = true }
        }) {
            // The live profile's theme: the sheet recolours as a preset is picked.
            StylingSheet(store: profileStore)
                .stylingSheetChrome(theme: Theme.theme(for: profile))
        }
        .fileImporter(
            isPresented: $isPickingReconnectImage,
            allowedContentTypes: Self.reconnectImageTypes,
            allowsMultipleSelection: false
        ) { result in
            defer {
                reconnectRange = nil
                reconnectRenderedText = nil
            }
            guard let range = reconnectRange, case .success(let urls) = result, let picked = urls.first else { return }
            document.reconnectImage(at: range, with: picked, renderedFrom: reconnectRenderedText)
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
            if !hasCheckedFirstRunRestore {
                endFirstRun(firstRun.restored(bookmark: openDocumentBookmark, path: legacyOpenDocumentPath))
                hasCheckedFirstRunRestore = true
            }
            makeExportCommandsIfNeeded()
            // History for AI actions: the document's, the ONE assignment (`SelectionController`).
            selection.aiHistory = document.history
            shownDisplayMode = shownDisplayMode ?? storedDisplayMode
            selection.displayModeDidChange(to: displayMode)
            positionKeeper.adopt(displayMode)
            let linkedScroll = linkedScroll
            positionKeeper.isPreviewLinked = { [weak linkedScroll] in linkedScroll?.isLinked ?? true }
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
            if document.url != nil {
                withAnimation(firstRunFade) {
                    endFirstRun(firstRun.documentOpened())
                }
            }
        }
        .onChange(of: displayMode) {
            // Read has no editor on screen to hold a selection row, and allows no AI: a review
            // ends (keeping what was accepted), a request or marks are dropped.
            selection.displayModeDidChange(to: displayMode)
        }
        .onChange(of: scenePhase) { _, phase in
            if OpenDocument.savesImmediately(on: phase) { document.flushForBackground() }
        }
        .onChange(of: isHistoryModeActive) { _, active in
            // History mode is Write's: the row's Replace With… in Preview's editor lands here too.
            if active, displayMode != .write { switchMode(to: .write) }
        }
    }

    private var isHistoryModeActive: Bool { document.history?.isHistoryModeActive == true }

    /// The editor's text now (the document's before the editor exists).
    private var editorText: String { positionKeeper.editor?.textStorage.string ?? document.text }

    /// Menu ▸ History (D10): the sheet closes, Write comes up, and History mode opens.
    private func showHistoryFromMenu() {
        guard let history = document.history else { return }
        HistoryEntry.enterFromMenu(
            history: history,
            text: { editorText },
            dismissMenu: { isShowingMenu = false },
            endAI: { selection.endAIForHistory() },
            switchToWrite: { switchMode(to: .write) }
        )
        // Hardware ← / → and Esc reach the read-only editor once it is first responder.
        Task { @MainActor in
            if history.isHistoryModeActive { positionKeeper.editor?.becomeFirstResponder() }
        }
    }

    private func historyCard(_ history: PhoneHistoryController) -> some View {
        let text = { [positionKeeper, document] in positionKeeper.editor?.textStorage.string ?? document.text }
        return HistoryCard(
            model: HistoryCardModel(controller: history),
            profile: profile,
            onSelectLevel: { level in history.selectLevel(level) },
            onSelectVersion: { index in history.selectVersion(index, text: text()) },
            onDeleteVersion: { index in history.deleteVersion(index, text: text()) },
            onAddReplacement: { replacement, id in history.addReplacement(replacement, text: text(), for: id) },
            onReplacementFieldOpened: { history.replacementFieldDidOpen() },
            onDone: { history.exitHistoryMode(text: text()) }
        )
    }
}

/// Entering History mode from the Menu sheet (D10), apart from the screen so it can be tested:
/// the sheet closes, the screen switches to Write, then History mode opens (selecting a passage
/// an AI accept left remembered). False when there was nothing to show.
@MainActor
enum HistoryEntry {
    @discardableResult
    static func enterFromMenu(
        history: PhoneHistoryController,
        text: () -> String,
        dismissMenu: () -> Void,
        endAI: () -> Void,
        switchToWrite: () -> Void
    ) -> Bool {
        dismissMenu()
        endAI()
        switchToWrite()
        return history.enterHistoryModeFromMenu(text: text())
    }
}

extension DocumentScreen {
    /// The gap between the bottom-trailing buttons: Preview's link, Menu, and Aa.
    static let bottomChromeSpacing: CGFloat = 12
    /// The room the Read view (and Preview's lower pane) keeps below its last line, so it scrolls
    /// clear of the floating buttons: the tallest of Menu, Aa and the link button.
    static var bottomChromeClearance: CGFloat {
        MarkdownEditor.chromeMargin + max(MenuButton.diameter, StylingButton.diameter, PreviewLinkButton.diameter) + 8
    }
    /// ⌘E, the Mac's Toggle Write / Read.
    static let toggleWriteReadShortcut = KeyboardShortcut("e", modifiers: .command)

    /// The editor and the Read view, placed for the mode (`PreviewSplit`).
    private var page: some View {
        PreviewSplit(mode: displayMode, profile: profile) {
            editor
        } reader: {
            reader
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
            linkedScroll: displayMode == .split ? linkedScroll : nil,
            keepsCaretVisibleOnResize: displayMode == .split,
            topChromeInset: ModeSwitch.pageTopClearance,
            readEditDocument: document,
            checksSpelling: settings.checksSpellingWhileTyping,
            history: document.history,
            selectionController: selection
        )
        // Above the editor (Write, and Preview's top pane) and below the chrome, which overlays
        // the whole page.
        .overlay { aiReviewOverlay }
    }

    /// The review overlay, while a review is up and an editor is on screen (Read allows no AI).
    @ViewBuilder
    private var aiReviewOverlay: some View {
        if displayMode != .read, case .reviewing(let session) = selection.aiState, let editor = selection.editor {
            AIReviewOverlay(
                composition: selection.compositionCache.composition(text: editor.string, session: session),
                currentID: session.currentID,
                pendingCount: session.pending.count,
                profile: profile,
                editor: editor,
                bottomObscured: { [selection] view in
                    // The card, plus a little air: the current change is revealed above it.
                    let frame = view.convert(view.bounds, to: nil)
                    return max(0, frame.maxY - selection.aiCardTopInWindow + 8)
                },
                onCommand: { [selection] command in selection.aiController.handle(command) },
                onRefused: { [selection] in selection.editRefusedDuringReview() }
            )
            .ignoresSafeArea(.keyboard)
        }
    }

    private var reader: some View {
        ReadViewRepresentable(
            text: document.text,
            profile: profile,
            documentDirectory: document.documentDirectory,
            onCheckboxToggle: { range, renderedFrom in
                document.toggleCheckbox(at: range, renderedFrom: renderedFrom)
            },
            onImageReconnect: { range, renderedFrom in
                reconnectRange = range
                reconnectRenderedText = renderedFrom
                if isShowingStyling {
                    isShowingStyling = false
                } else {
                    isPickingReconnectImage = true
                }
            },
            // One undo history in every mode: the editor's, which applied the Read edits.
            undoManager: { [positionKeeper] in positionKeeper.editor?.undoManager },
            positionKeeper: positionKeeper,
            topChromeInset: displayMode == .split ? 0 : ModeSwitch.pageTopClearance,
            bottomChromeInset: Self.bottomChromeClearance,
            linkedScroll: displayMode == .split ? linkedScroll : nil,
            textDelay: displayMode == .split ? LineformReadView.previewTextDelay : 0
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
