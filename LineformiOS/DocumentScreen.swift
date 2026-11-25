import LineformCore
import StoreKit
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
    /// outlives the word menu.
    var files: FilesStore
    /// The Settings section's values: Automatic Dark Mode and the spelling switch apply here.
    @ObservedObject var settings: AppSettings
    /// The announcement card's store (`PhoneAnnouncementStore.shared` in the app).
    @ObservedObject var announcements: PhoneAnnouncementStore
    /// When to ask for the App Store review sheet (`PhoneReviewPromptStore.shared` in the app,
    /// inert in the test host).
    @ObservedObject var reviewPrompt: PhoneReviewPromptStore
    /// Check for Updates: its result shows here as the quiet notice when no alert could come up.
    @ObservedObject var updateCommand: PhoneUpdateCommand
    @Environment(\.colorScheme) private var colorScheme
    private var profile: ReadingProfile {
        settings.displayProfile(profileStore.activeProfile, userInterfaceStyle: UIUserInterfaceStyle(colorScheme))
    }
    @State private var isShowingMenu = false
    /// Where the writer is in the word menu: fresh for every ⋯ open, kept after a card opens a
    /// document so the ← at the bottom left can reopen the menu exactly there.
    @State private var menuSession = WordMenuSession()
    /// The session the ← reopens, while it shows (nil: no ←).
    @State private var resumeSession: WordMenuSession?
    /// Hides the ← after `resumeButtonDuration` (never while VoiceOver runs).
    @State private var resumeHideTask: Task<Void, Never>?
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
    /// The announcement sheet on screen.
    @State private var presentedAnnouncement: Announcement?
    /// The keyboard is up: no announcement sheet comes up over typing.
    @State private var isKeyboardUp = false

    /// The quiet notice over the bottom of the page, if any: a failed save, else an image that
    /// could not be written beside the document, else a Check for Updates result whose alert
    /// could not come up.
    private var noticeMessage: String? {
        if document.saveFailed { return String(localized: "Couldn’t save this document. Your text is still here.") }
        if let exportFailure = exportCommands?.failureNotice { return exportFailure }
        if document.imageSaveFailed { return String(localized: "Can't save images beside this document.") }
        if let updateNotice = updateCommand.notice { return updateNotice }
        return nil
    }

    /// `initialMode` is the mode of a scene with nothing stored: Write in the app; tests start
    /// elsewhere. `showsFirstRun` is the launch's answer from `FirstRunGate.shouldShowAtLaunch`.
    init(
        document: OpenDocument,
        profileStore: ReadingProfileStore,
        files: FilesStore = .shared,
        settings: AppSettings = .shared,
        announcements: PhoneAnnouncementStore = .shared,
        reviewPrompt: PhoneReviewPromptStore = .shared,
        updateCommand: PhoneUpdateCommand = .shared,
        initialMode: EditorDisplayMode = .write,
        showsFirstRun: Bool = false,
        selection: SelectionController? = nil
    ) {
        self.document = document
        self.profileStore = profileStore
        self.files = files
        self.settings = settings
        self.announcements = announcements
        self.reviewPrompt = reviewPrompt
        self.updateCommand = updateCommand
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

    /// First run is over: fade it out and switch to Write if another mode was left on. The blank
    /// document opens WITHOUT the keyboard (and so without the format row, the owner's decision
    /// of 2026-11-24): a tap on the page raises them as usual.
    private func finishFirstRun() {
        withAnimation(firstRunFade) {
            firstRun.finished()
        }
        if displayMode != .write { switchMode(to: .write, announces: false) }
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

    /// `announces` is false when the switch is a side effect of something that moves VoiceOver's
    /// focus itself (History mode's card, first run's end): two focus moves would race.
    private func switchMode(to mode: EditorDisplayMode, announces: Bool = true) {
        guard mode != displayMode else { return }
        let previous = displayMode
        // History mode is Write's: switching to Read or Preview leaves it (with the collapse).
        if mode != .write, let history = document.history, history.isHistoryModeActive {
            history.exitHistoryMode(text: editorText)
        }
        positionKeeper.switchMode(from: displayMode, to: mode)
        shownDisplayMode = mode
        storedDisplayMode = mode
        if announces { ChromeAnnouncer.modeDidChange(from: previous, to: mode) }
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
        let selection = self.selection
        document.onDocumentSwap = { [weak commands, weak selection] in
            commands?.documentWillChange()
            // The AI conversation belongs to the document being replaced.
            selection?.documentWillSwap()
        }
        exportCommands = commands
    }

    /// The image types Reconnect offers, as on the Mac.
    static let reconnectImageTypes: [UTType] = [.png, .jpeg, .gif, .heic, .tiff, .bmp, .image]

    var body: some View {
        page
        .ignoresSafeArea(.container)
        // The page colour reaches under the keyboard too: without `ignoresSafeArea()` here the
        // background stopped at the keyboard's edge and the window's black showed through the
        // translucent keyboard (and in screenshots).
        .background(Color(uiColor: Theme.theme(for: profile).backgroundColor).ignoresSafeArea())
        .overlay {
            if document.downloadingName != nil {
                DownloadingView(profile: profile)
            }
        }
        .overlay(alignment: .bottom) {
            // A failed save matters more than a failed image, and stays until a save succeeds.
            if let message = noticeMessage {
                QuietNotice(message: message, profile: profile)
                    .padding(.bottom, MarkdownEditor.chromeMargin + MoreButton.diameter + 12)
                    .padding(.horizontal, MarkdownEditor.chromeMargin)
                    .transition(.opacity)
            }
        }
        .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: noticeMessage)
        .onChange(of: noticeMessage) { _, message in
            // The notice never takes the focus; VoiceOver hears it as it appears.
            if let message { ChromeAnnouncer.announce(message) }
        }
        .overlay(alignment: .top) {
            // The control's touch band is taller than the drawn capsule: the capsule still sits
            // `topMargin` below the safe area.
            ModeSwitch(mode: modeSelection, usesDarkChrome: Theme.theme(for: profile).usesDarkChrome)
                .padding(.top, ModeSwitch.topMargin - ModeSwitch.verticalTouchOutset)
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
            // The comment field and a running request or review take the bottom in turn. While
            // the selection row shows (a selection, or a caret with the software keyboard up)
            // these float just above it, so ⋯ stays reachable. A message or Find's marks leave
            // these reachable: that card sits above them (`SelectionBottomChrome`). History's
            // card replaces them all, the ⋯ button included, so nothing sits behind its Done.
            if !isHistoryModeActive,
               SelectionController.showsBottomButtons(phase: selection.phase, aiState: selection.aiState) {
                // The link button's touch square is wider than its circle: the gap to ⋯ shrinks
                // by the difference, so the circles stay `bottomChromeSpacing` apart.
                HStack(spacing: Self.bottomChromeSpacing - PreviewLinkButton.horizontalTouchOutset) {
                    // The way back to the word menu, mirroring ⋯ at the bottom left.
                    if let resumeSession {
                        ResumeMenuButton(profile: profile, label: resumeSession.resumeAccessibilityLabel) {
                            resumeWordMenu()
                        }
                        .padding(.trailing, PreviewLinkButton.horizontalTouchOutset)
                        .transition(.opacity)
                    }
                    // Read aloud's pill: on the ⋯ button's line, from the left margin up to it.
                    if let exportCommands, exportCommands.speechState != .idle {
                        ReadAloudPill(commands: exportCommands, profile: profile)
                            .padding(.trailing, PreviewLinkButton.horizontalTouchOutset)
                    } else if resumeSession != nil {
                        Spacer(minLength: 0)
                    }
                    if displayMode == .split {
                        PreviewLinkButton(isLinked: arePanesLinked, profile: profile) {
                            linkedScroll.toggleLink()
                            arePanesLinked = linkedScroll.isLinked
                        }
                    }
                    MoreButton(profile: profile) { openWordMenu() }
                }
                .padding(MarkdownEditor.chromeMargin)
                .padding(.bottom, selection.phase == .row ? Self.selectionRowClearance : 0)
                .transition(.opacity)
            }
        }
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: LineformDesign.Motion.standard), reduceMotion: reduceMotion),
            value: selection.phase
        )
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: Self.resumeFadeDuration), reduceMotion: reduceMotion),
            value: resumeSession == nil
        )
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: LineformDesign.Motion.standard), reduceMotion: reduceMotion),
            value: SelectionController.showsBottomButtons(phase: selection.phase, aiState: selection.aiState)
        )
        .overlay {
            SelectionBottomChrome(controller: selection, profile: profile)
        }
        .overlay(alignment: .bottomTrailing) {
            // The word menu covers the whole screen, at once (no motion), over every other chrome
            // but first run.
            if isShowingMenu {
                wordMenu
            }
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
            .disabled(presentsFirstRun || isShowingMenu)
            .hidden()
        }
        // An announcement is a small one-time sheet, shown only when the page is idle (never over
        // first run, the menu, History, an AI review or the keyboard); it waits until then.
        .onChange(of: canPresentAnnouncement, initial: true) { _, can in
            if can, presentedAnnouncement == nil { presentedAnnouncement = shownAnnouncement }
        }
        .onChange(of: shownAnnouncement?.id) {
            // Switched off (or dismissed elsewhere): the sheet goes too.
            if shownAnnouncement == nil { presentedAnnouncement = nil }
        }
        .sheet(item: $presentedAnnouncement) { announcement in
            PhoneAnnouncementSheet(
                announcement: announcement,
                profile: profile,
                onAction: {
                    announcements.performAction(for: announcement)
                    presentedAnnouncement = nil
                },
                onDismiss: {
                    announcements.dismiss(announcement)
                    presentedAnnouncement = nil
                }
            )
            // Not now, a swipe down and the action all dismiss it for good (idempotent).
            .onDisappear { announcements.dismiss(announcement) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardUp = false
        }
        // Typing means styling is done: the sheet leaves when the keyboard comes up, rather than
        // staying half-hidden behind it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if isShowingStyling { isShowingStyling = false }
        }
        .sheet(isPresented: $selection.isShowingAISheet) {
            AISheetView(conversation: selection.conversation, profile: profile) { [selection] top in
                selection.aiCardTopInWindow = top
            }
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
            // In-app notifications off takes the card away at once (the request is gated at the check).
            announcements.follow(settings)
            // A write that reached disk is use, for the review prompt (single subscriber).
            document.onConfirmedWrite = { [reviewPrompt] in reviewPrompt.recordSuccessfulWrite() }
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
            // Shortcuts' New Lineform Note and Open in Lineform reach the document from here on,
            // after the launch restore (one that arrived earlier runs now).
            await PhoneIntentRouter.shared.attach(document)
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
            // Back in the foreground: an eligible prompt schedules again (never counts as use).
            if phase == .active { reviewPrompt.reconsiderPresentation() }
        }
        .task(id: reviewPrompt.activityRevision) {
            // A new write restarts the quiet period; the sheet comes up only with nothing in the way.
            await reviewPrompt.requestAfterQuietPeriod(
                canPresent: { canPresentReviewPrompt },
                request: { requestReviewSheet() }
            )
        }
        .onChange(of: isHistoryModeActive) { _, active in
            // History mode is Write's: the row's Replace With… in Preview's editor lands here too.
            // The History card takes VoiceOver's focus itself.
            if active, displayMode != .write { switchMode(to: .write, announces: false) }
        }
    }

    private var isHistoryModeActive: Bool { document.history?.isHistoryModeActive == true }

    /// The review sheet may come up: the scene is in the foreground with nothing presented over
    /// the page, and nothing of Lineform's holds the screen (the Mac's obstruction list, in iPhone
    /// terms: a sheet or picker, first run, History, the selection row or comment field, an AI
    /// card, an announcement, a notice or alert, a download, an update check).
    private var canPresentReviewPrompt: Bool {
        let obstructed = isShowingMenu || isShowingStyling || isPickingReconnectImage || reconnectRange != nil
            || presentsFirstRun || isHistoryModeActive
            || selection.phase != .hidden || selection.aiState != .idle
            || announcements.visible != nil || noticeMessage != nil
            || document.failedOpenURL != nil || document.downloadingName != nil
            || updateCommand.isChecking
        let presenter = ActivityShareSheet.topPresenter()
        return PhoneReviewPromptStore.canPresent(
            isSceneActive: scenePhase == .active && Self.foregroundScene() != nil,
            hasPresentedController: presenter == nil || presenter?.presentingViewController != nil,
            hasInAppObstruction: obstructed
        )
    }

    /// StoreKit's system sheet, in the foreground scene. StoreKit decides whether it shows.
    private func requestReviewSheet() {
        guard let scene = Self.foregroundScene() else { return }
        AppStore.requestReview(in: scene)
    }

    private static func foregroundScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// The announcement the store holds, while In-app notifications is on.
    private var shownAnnouncement: Announcement? {
        guard let visible = announcements.visible, settings.checksForAnnouncements else { return nil }
        return visible
    }

    /// The announcement sheet may come up: the page is idle. Never over first run, the word menu,
    /// the Styling sheet, History mode, the selection row or comment field, an AI request or
    /// review, a notice, a download, or the keyboard; it waits for the next idle moment instead.
    private var canPresentAnnouncement: Bool {
        shownAnnouncement != nil
            && !presentsFirstRun && !isShowingMenu && !isShowingStyling && !isHistoryModeActive
            && !isKeyboardUp && !isPickingReconnectImage && reconnectRange == nil
            && selection.phase == .hidden && selection.aiState == .idle && !selection.isShowingAISheet
            && noticeMessage == nil && document.downloadingName == nil && document.failedOpenURL == nil
    }

    /// The editor's text now (the document's before the editor exists).
    private var editorText: String { positionKeeper.editor?.textStorage.string ?? document.text }

    // MARK: - The word menu

    /// The ⋯ button: the keyboard goes first (the menu covers the screen), then the menu opens.
    private func openWordMenu() {
        WordMenuTiming.tapped()
        positionKeeper.editor?.resignFirstResponder()
        // ⋯ starts at the word list; the ← (if it showed) goes, and its session with it.
        endResumeOffer()
        menuSession = WordMenuSession()
        isShowingMenu = true
    }

    /// The ←: the menu opens again on the session the writer left it in (page, search, scroll).
    private func resumeWordMenu() {
        guard let session = resumeSession else { return }
        WordMenuTiming.tapped()
        resumeHideTask?.cancel()
        resumeHideTask = nil
        resumeSession = nil
        positionKeeper.editor?.resignFirstResponder()
        session.resumed()
        menuSession = session
        isShowingMenu = true
    }

    /// How long the ← stays when it is not used.
    static let resumeButtonDuration: Duration = .seconds(5)
    /// The ←'s fade in and out, as one layer (`ResumeMenuButton`).
    static let resumeFadeDuration: TimeInterval = 0.22

    /// The menu closed after a card or search result opened a document: the ← shows at the bottom
    /// left. It fades after `resumeButtonDuration`, or at once when the writer types; while
    /// VoiceOver runs it never times out and stays until the next action.
    private func offerResume(_ session: WordMenuSession) {
        resumeHideTask?.cancel()
        resumeSession = session
        document.onWriterEdit = { endResumeOffer() }
        guard !UIAccessibility.isVoiceOverRunning else {
            resumeHideTask = nil
            return
        }
        resumeHideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resumeButtonDuration)
            guard !Task.isCancelled else { return }
            endResumeOffer()
        }
    }

    /// The ← goes, and the search it would have reopened stops.
    private func endResumeOffer() {
        resumeHideTask?.cancel()
        resumeHideTask = nil
        document.onWriterEdit = nil
        guard let session = resumeSession else { return }
        resumeSession = nil
        session.end()
    }

    /// Closes the menu at once, with no motion. A card or search result that opened a document
    /// lands straight on the page (the owner's review of 2026-11-24: no card expansion).
    private func closeWordMenu() {
        // A card or search result opened a document: the ← offers the way back.
        if menuSession.openedDocument {
            WordMenuTiming.end(.openCard)
            offerResume(menuSession)
        } else {
            menuSession.end()
        }
        isShowingMenu = false
    }

    private var wordMenu: some View {
        WordMenu(
            document: document,
            editor: LiveEditorCommands(positionKeeper: positionKeeper, document: document, mode: displayMode),
            files: files,
            settings: settings,
            profile: profile,
            exportCommands: exportCommands,
            mode: displayMode,
            aiStore: selection.aiConnectionStore,
            updateCommand: updateCommand,
            onClose: { closeWordMenu() },
            onThemes: {
                WordMenuTiming.begin(.themes)
                closeWordMenu()
                isShowingStyling = true
            },
            onReadAloud: { readAloudFromMenu() },
            onShowHistoryPassage: { id in showHistoryFromMenu(passage: id) },
            onAskAI: {
                closeWordMenu()
                // Once the menu is gone: the policy may ask for a confirmation.
                Task { @MainActor in selection.askAIForWholeDocument() }
            },
            session: menuSession
        )
    }

    /// Read Aloud: the menu closes and reading starts (the selection in Write and Preview, the
    /// whole document in Read); its pill shows beside the ⋯ button. Already reading, the pill is
    /// already there.
    private func readAloudFromMenu() {
        closeWordMenu()
        guard let exportCommands, exportCommands.speechState == .idle else { return }
        ExportRows.perform(.start, commands: exportCommands, selection: positionKeeper.editor?.selectedRange, mode: displayMode)
    }

    /// The word menu's History (D10): the menu closes, Write comes up, and History mode opens on
    /// the passage.
    private func showHistoryFromMenu(passage: UUID?) {
        guard let history = document.history else { return }
        HistoryEntry.enterFromMenu(
            history: history,
            text: { editorText },
            passage: passage,
            dismissMenu: { closeWordMenu() },
            endAI: { selection.endAIForHistory() },
            switchToWrite: { switchMode(to: .write, announces: false) }
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

/// Entering History mode from the word menu (D10), apart from the screen so it can be tested: the
/// menu closes, the screen switches to Write, then History mode opens — on `passage` when one was
/// tapped, else selecting a passage an AI accept left remembered. False when there was nothing to
/// show.
@MainActor
enum HistoryEntry {
    @discardableResult
    static func enterFromMenu(
        history: PhoneHistoryController,
        text: () -> String,
        passage: UUID? = nil,
        dismissMenu: () -> Void,
        endAI: () -> Void,
        switchToWrite: () -> Void
    ) -> Bool {
        dismissMenu()
        endAI()
        switchToWrite()
        if let passage { return history.showPassage(passage, text: text()) }
        return history.enterHistoryModeFromMenu(text: text())
    }
}

extension DocumentScreen {
    /// The gap between the bottom-trailing controls: Read aloud's pill, Preview's link, and ⋯.
    static let bottomChromeSpacing: CGFloat = 12
    /// The bottom-trailing controls' bottom padding change while the format row shows. The row is
    /// the keyboard's accessory, so the keyboard's safe area already lifts them above it; this
    /// only brings them to `bottomChromeSpacing` above the row instead of the usual margin.
    static var selectionRowClearance: CGFloat {
        bottomChromeSpacing - MarkdownEditor.chromeMargin
    }
    /// The room the Read view (and Preview's lower pane) keeps below its last line, so it scrolls
    /// clear of the floating buttons: the taller of ⋯ and the link button.
    static var bottomChromeClearance: CGFloat {
        MarkdownEditor.chromeMargin + max(MoreButton.diameter, PreviewLinkButton.diameter) + 8
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.theme(for: profile)
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Downloading…"))
                .font(.callout)
                .foregroundStyle(PhoneInk(theme: theme, colorScheme: colorScheme).secondary)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // A capsule for the usual one or two lines; at the accessibility sizes the text wraps to
        // many lines, where a capsule's round ends would cut into it.
        if dynamicTypeSize.isAccessibilitySize {
            notice(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            notice(in: Capsule())
        }
    }

    private func notice<Shape: InsettableShape>(in shape: Shape) -> some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        return Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(uiColor: theme.textColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(shape.fill(Color(uiColor: theme.backgroundColor)))
            .overlay(
                shape.strokeBorder(
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

/// The chrome's spoken announcements: a mode switch, a notice, a copy in Read. Every string is
/// localized by the caller. `post` is the one way out, so tests can record what was said.
@MainActor
enum ChromeAnnouncer {
    /// Posts a notification to VoiceOver. Tests replace it.
    static var post: (UIAccessibility.Notification, Any?) -> Void = { notification, argument in
        UIAccessibility.post(notification: notification, argument: argument)
    }

    /// Speaks `message` without moving the VoiceOver cursor.
    static func announce(_ message: String) {
        post(.announcement, message)
    }

    /// The writer switched modes: VoiceOver says the new mode's name (Write, Read, Preview).
    static func modeDidChange(from old: EditorDisplayMode, to new: EditorDisplayMode) {
        post(modeChangeNotification(from: old, to: new), new.title)
    }

    /// How a switch is spoken. Read replaces the editor (and Write or Preview replace Read's own
    /// view), so the element under VoiceOver's cursor may be gone: `.layoutChanged` names the mode
    /// and keeps the cursor where it is if that element is still there (the mode control), or
    /// moves it to the new page if not. Write ↔ Preview keeps the editor on screen, so the name is
    /// only announced and the cursor never moves. `.screenChanged` is never used: it sends the
    /// cursor back to the top of the screen, away from the control just used.
    static func modeChangeNotification(from old: EditorDisplayMode, to new: EditorDisplayMode) -> UIAccessibility.Notification {
        (old == .read) != (new == .read) ? .layoutChanged : .announcement
    }
}
