import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore: ReadingProfileStore
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingReadingInspector = false
    @State private var isShowingMarkdownBasics = false
    @State private var isShowingSettings = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline: Bool
    @State private var outlineItems: [MarkdownOutlineItem] = []
    @State private var requestedSelection: NSRange?
    @State private var searchQuery = ""
    @State private var searchMatches: [NSRange] = []
    @State private var activeSearchIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    @State private var currentFileURL: URL?
    @StateObject private var reloadController = DocumentReloadController()
    @State private var statusFlash: EditorStatusFlash?
    @State private var updatedIndicatorWorkItem: DispatchWorkItem?
    @State private var sidebarDialog: SidebarFileDialog?
    @State private var renameText = ""

    private let injectedFileBrowserStore: OutlineFileBrowserStore?
    /// Held so the sidebar (Files tab) observes the SAME store this window was built
    /// with — tests inject an isolated store and it governs the whole view tree.
    private let settings: LineformSettingsStore

    init(
        document: Binding<LineformDocument>,
        readingProfileStore: ReadingProfileStore = ReadingProfileStore(),
        fileBrowserStore: OutlineFileBrowserStore? = nil,
        settings: LineformSettingsStore = .shared
    ) {
        _document = document
        _readingProfileStore = StateObject(wrappedValue: readingProfileStore)
        injectedFileBrowserStore = fileBrowserStore
        self.settings = settings
        // New windows open with the sidebar in the user's preferred launch state
        // (Settings › Show sidebar on launch, default on). Initial value only;
        // once open, the user's ⌥⌘0 toggle takes over.
        _isShowingOutline = State(initialValue: settings.showSidebarOnLaunch)
    }

    var body: some View {
        let theme = currentTheme

        NavigationSplitView(columnVisibility: outlineVisibility) {
            OutlineSidebarView(
                items: outlineItems,
                jumpToHeading: jumpToHeading,
                openFile: openSidebarFile,
                currentFileURL: currentFileURL,
                fileBrowserStore: injectedFileBrowserStore,
                settings: settings,
                renameItem: { renameSidebarItem(at: $0.url, isDirectory: $0.isDirectory) },
                deleteItem: { deleteSidebarItem(at: $0.url) },
                revealItem: { SidebarFileActionPresenter.showInFinder($0.url) }
            )
                .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
                .navigationSplitViewColumnWidth(
                    min: OutlineSidebarView.minimumColumnWidth,
                    ideal: OutlineSidebarView.idealColumnWidth,
                    max: OutlineSidebarView.maximumColumnWidth
                )
        } detail: {
            editorShell
        }
        .navigationSplitViewStyle(.balanced)
        // A single native SwiftUI alert (title + message + text field + buttons) — the
        // standard macOS confirmation look, no app icon. One `.alert` driven by one enum
        // state so rename and delete can never compete for the view's alert slot.
        .alert(sidebarDialogTitle, isPresented: sidebarDialogPresented, presenting: sidebarDialog) { dialog in
            switch dialog {
            case .rename(let request):
                TextField("Name", text: $renameText)
                Button(SidebarFileActionPresenter.cancelButtonTitle, role: .cancel) {
                    sidebarDialog = nil
                }
                Button(SidebarFileActionPresenter.renameButtonTitle) {
                    commitPendingRename(request)
                }
                .keyboardShortcut(.defaultAction)
            case .delete(let url):
                // Cancel is the Return default; deleting is deliberate and takes a click.
                Button(SidebarFileActionPresenter.cancelButtonTitle, role: .cancel) {
                    sidebarDialog = nil
                }
                .keyboardShortcut(.defaultAction)
                Button(SidebarFileActionPresenter.deleteButtonTitle, role: .destructive) {
                    performSidebarDelete(url)
                }
            }
        } message: { dialog in
            switch dialog {
            case .rename(let request):
                Text(request.isDirectory ? SidebarFileActionPresenter.renameFolderMessage : SidebarFileActionPresenter.renameFileMessage)
            case .delete:
                Text(SidebarFileActionPresenter.deleteMessage)
            }
        }
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .preferredColorScheme(theme.usesDarkChrome ? .dark : .light)
        .background(WindowChromeReader(windowNumber: $windowNumber, usesDarkChrome: theme.usesDarkChrome))
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search")
        .searchFocusedCompat($isSearchFocused)
        .toolbar {
            ToolbarItem(placement: .principal) {
                EditorModeSegmentedControl(
                    selection: $displayMode,
                    usesDarkChrome: theme.usesDarkChrome,
                    reduceMotion: reduceMotion
                )
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(EditorToolbarAction.primaryActions(in: displayMode)) { action in
                    toolbarControl(for: action)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showReadingExperience.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            setReadingInspectorVisible(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.focusSearch.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.setDisplayMode.name)) { notification in
            guard
                notificationMatchesActiveWindow(notification),
                let rawValue = notificationPayloadValue(notification),
                let mode = EditorDisplayMode(rawValue: rawValue)
            else {
                return
            }
            displayMode = mode
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.convertTextFormat.name)) { notification in
            guard
                notificationMatchesActiveWindow(notification),
                let rawValue = notificationPayloadValue(notification),
                let format = LineformTextFormat(rawValue: rawValue)
            else {
                return
            }
            convertDocumentTextFormat(to: format, selectedRange: notificationPayloadSelectedRange(notification))
        }
        .onChange(of: displayMode) { _, mode in
            LineformDisplayModeMenuState.shared.setDisplayMode(mode)
            if !EditorToolbarVisibility.showsMarkdownBasics(in: mode) {
                isShowingMarkdownBasics = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.toggleOutline.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            isShowingOutline.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showSettings.name)) { _ in
            // Present in the MAIN window, not via key-window payload matching: still
            // works when a panel (About, open/save) is key, and can never match
            // several windows at once the way a nil window number could.
            guard activeWindow?.isMainWindow == true else {
                return
            }
            // One modal at a time — also keeps a single live Esc (.cancelAction)
            // target, so Esc can't dismiss a hidden Info modal underneath.
            isShowingMarkdownBasics = false
            isShowingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.renameCurrentFile.name)) { notification in
            guard notificationMatchesActiveWindow(notification), let url = currentFileURL else {
                return
            }
            renameSidebarItem(at: url, isDirectory: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.deleteCurrentFile.name)) { notification in
            guard notificationMatchesActiveWindow(notification), let url = currentFileURL else {
                return
            }
            deleteSidebarItem(at: url)
        }
        .onChange(of: currentFileURL) { _, newValue in
            // Keep the File-menu Rename…/Delete… enabled state tracking the key window.
            if activeWindow?.isKeyWindow == true {
                LineformCurrentFileMenuState.shared.setCurrentFileURL(newValue)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            LineformCurrentFileMenuState.shared.setCurrentFileURL(currentFileURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard
                let closingWindow = notification.object as? NSWindow,
                closingWindow.windowNumber == windowNumber,
                closingWindow.isKeyWindow || LineformCurrentFileMenuState.shared.currentFileURL == currentFileURL
            else {
                return
            }
            // Without this, closing the last window leaves File > Rename.../Delete...
            // enabled against a dead URL (a no-op menu command). Guarded so a background
            // window closing can't wipe the key window's state; if another window becomes
            // key next, its didBecomeKey update immediately repopulates it.
            LineformCurrentFileMenuState.shared.setCurrentFileURL(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.sidebarItemRenamed.name)) { notification in
            guard
                let payload = notification.object as? LineformAppNotification.RenamePayload,
                let newURL = payload.rebased(currentFileURL),
                let backingDocument = activeWindow?.windowController?.document as? NSDocument
            else {
                return
            }
            // This window's document just moved on disk (file rename, or an ancestor
            // folder rename). Follow it so the title bar, autosave target, selection
            // highlight, and reload watcher all track the new location. The reload watcher
            // is re-pointed with noteMoved — NOT registerReloadWatcher/register, whose
            // new-URL path resets the synced baseline to the live text and would bless
            // unsaved edits as synced (letting a later external write clobber them).
            backingDocument.fileURL = newURL
            backingDocument.fileModificationDate = LineformDocument.modificationDate(at: newURL)
            activeWindow?.representedURL = newURL
            activeWindow?.setTitleWithRepresentedFilename(newURL.path)
            reloadController.noteMoved(to: newURL)
            currentFileURL = newURL
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.sidebarFileDeleted.name)) { notification in
            guard
                let deletedURL = notification.object as? URL,
                currentFileURL?.standardizedFileURL == deletedURL.standardizedFileURL,
                let backingDocument = activeWindow?.windowController?.document as? NSDocument
            else {
                return
            }
            // The file is in the Trash; keep the text in the window as unsaved content
            // (nothing is lost — the next save prompts for a location). Without this,
            // the next autosave would silently resurrect the file the user just deleted.
            backingDocument.fileURL = nil
            backingDocument.updateChangeCount(.changeDone)
            activeWindow?.representedURL = nil
            backingDocument.windowControllers.first?.synchronizeWindowTitleWithDocumentName()
            registerReloadWatcher()
        }
        .onAppear {
            LineformTextFormatMenuState.shared.setTextFormat(document.textFormat)
            LineformDisplayModeMenuState.shared.setDisplayMode(displayMode)
            documentStatistics = DocumentStatistics(text: document.text)
            outlineItems = MarkdownOutlineParser().items(in: document.text)
            // Registration fallback: covers a view recreated with windowNumber already set
            // (no nil→value transition). Idempotent with the windowNumber onChange below.
            registerReloadWatcher()
        }
        .onChange(of: document.textFormat) { _, newValue in
            LineformTextFormatMenuState.shared.setTextFormat(newValue)
        }
        .onChange(of: document.text) { _, newValue in
            documentStatistics = DocumentStatistics(text: newValue)
            outlineItems = MarkdownOutlineParser().items(in: newValue)
            refreshSearchMatches(selectFirstWhenNeeded: activeSearchIndex == nil, navigatesToActiveMatch: false)
            reloadController.currentText = newValue
        }
        .onChange(of: windowNumber) { _, _ in
            registerReloadWatcher()
        }
        .onChange(of: reloadController.lastReload) { _, result in
            guard let result else { return }
            applyReload(result)
        }
        .onChange(of: documentSaveStatus.savedAt(for: document.id)) { _, _ in
            // A first save on an untitled doc (or any save) can create/replace the file URL;
            // re-point the watcher and refresh the synced baseline with the saved text.
            noteSavedToReloadWatcher()
        }
        .onChange(of: documentSaveStatus.lastSaveEvent) { _, event in
            // Flash a green save confirmation only for this document's real writes.
            guard let event, event.documentID == document.id else { return }
            flashStatus(event.kind == .manual ? .saved : .autosaved)
        }
        .onDisappear {
            reloadController.stop()
        }
        .onChange(of: searchQuery) { _, _ in
            refreshSearchMatches(selectFirstWhenNeeded: true, navigatesToActiveMatch: true)
        }
        .onSubmit(of: .search) {
            advanceToNextSearchMatch()
        }
    }

    private var outlineVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isShowingOutline ? .all : .detailOnly },
            set: { visibility in
                isShowingOutline = visibility != .detailOnly
            }
        )
    }

    private var editorShell: some View {
        let theme = currentTheme

        return ZStack {
            editorPrimaryShell
                .inspector(isPresented: $isShowingReadingInspector) {
                    ReadingExperienceInspector(
                        store: readingProfileStore,
                        usesDarkChrome: theme.usesDarkChrome,
                        onClose: { setReadingInspectorVisible(false) }
                    )
                        .inspectorColumnWidth(
                            min: EditorAuxiliaryPresentation.readingExperience.minimumWidth ?? 280,
                            ideal: EditorAuxiliaryPresentation.readingExperience.idealWidth ?? 320,
                            max: EditorAuxiliaryPresentation.readingExperience.maximumWidth ?? 380
                        )
                        .id(theme.usesDarkChrome)
                        .accessibilityLabel(EditorAuxiliaryPresentation.readingExperience.accessibilityLabel)
                }

            if isShowingMarkdownBasics {
                MarkdownBasicsOverlay {
                    isShowingMarkdownBasics = false
                }
                .zIndex(1)
                .transaction { transaction in
                    transaction.animation = nil
                }

                GeometryReader { geometry in
                    MarkdownBasicsModal(availableHeight: geometry.size.height) {
                        isShowingMarkdownBasics = false
                    }
                    .transition(
                        .asymmetric(
                            insertion: EditorMotionPolicy.fadeAndMoveTransition(
                                y: MarkdownBasicsModal.entranceYOffset,
                                reduceMotion: reduceMotion
                            ),
                            removal: EditorMotionPolicy.fadeAndMoveTransition(
                                y: MarkdownBasicsModal.entranceYOffset / 2,
                                reduceMotion: reduceMotion
                            )
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .zIndex(2)
            }

            // Settings uses the same modal language as Info: scrim + centered light
            // card + Esc/outside-click dismissal. Higher zIndex so that if both are
            // ever up, Settings (the more deliberate action) sits on top.
            if isShowingSettings {
                MarkdownBasicsOverlay {
                    isShowingSettings = false
                }
                .zIndex(3)
                .transaction { transaction in
                    transaction.animation = nil
                }

                GeometryReader { geometry in
                    SettingsModal(settings: settings, availableWidth: geometry.size.width) {
                        isShowingSettings = false
                    }
                    .transition(
                        .asymmetric(
                            insertion: EditorMotionPolicy.fadeAndMoveTransition(
                                y: SettingsModal.entranceYOffset,
                                reduceMotion: reduceMotion
                            ),
                            removal: EditorMotionPolicy.fadeAndMoveTransition(
                                y: SettingsModal.entranceYOffset / 2,
                                reduceMotion: reduceMotion
                            )
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .zIndex(4)
            }
        }
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: MarkdownBasicsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingMarkdownBasics
        )
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: SettingsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingSettings
        )
    }

    private var editorPrimaryShell: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                editorContent
                    .frame(minWidth: EditorLayout.minimumContentWidth, minHeight: EditorLayout.minimumContentHeight)

                if EditorStatusBar.isVisible(in: displayMode) {
                    EditorStatusBar(
                        lastSavedDisplay: lastSavedDisplay,
                        statisticsText: statisticsText,
                        statusAccessibilityLabel: statusAccessibilityLabel,
                        indicator: statusIndicator
                    )
                }
            }
        }
        .background(Color(nsColor: currentTheme.backgroundColor))
        .animation(
            EditorMotionPolicy.animation(
                .easeOut(duration: 0.24),
                reduceMotion: reduceMotion
            ),
            value: displayMode
        )
    }

    private var currentTheme: Theme {
        Theme.theme(for: readingProfileStore.activeProfile)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch displayMode {
        case .write:
            markdownEditor
        case .read:
            HStack {
                DebouncedMarkdownPreviewView(text: document.text, profile: readingProfileStore.activeProfile)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HStack(spacing: 0) {
                markdownEditor
                Divider()
                DebouncedMarkdownPreviewView(text: document.text, profile: readingProfileStore.activeProfile)
            }
        }
    }

    private var markdownEditor: some View {
        MarkdownTextViewRepresentable(
            text: $document.text,
            textFormat: $document.textFormat,
            plainTextConversion: $document.plainTextConversion,
            requestedSelection: $requestedSelection,
            profile: readingProfileStore.activeProfile,
            smoothsHorizontalInsetChanges: false,
            searchRanges: searchMatches,
            activeSearchRange: activeSearchRange,
            onWritingToolsSessionChange: { active in
                // Binding writes are deferred during a Writing Tools session, so the reload
                // dirty gate can't see the in-progress edits; suspend external reloads until
                // the session ends (the controller reconciles once on resume).
                reloadController.isWritingToolsSessionActive = active
            }
        )
        .accessibilityLabel("Markdown editor")
        .accessibilityValue(searchAccessibilitySummary ?? "")
    }

    private var activeSearchRange: NSRange? {
        guard let activeSearchIndex, searchMatches.indices.contains(activeSearchIndex) else {
            return nil
        }
        return searchMatches[activeSearchIndex]
    }

    private var searchAccessibilitySummary: String? {
        EditorSearchResolver.accessibilitySummary(
            query: searchQuery,
            matchCount: searchMatches.count,
            activeIndex: activeSearchIndex
        )
    }

    private func jumpToHeading(_ item: MarkdownOutlineItem) {
        requestedSelection = item.characterRange
        if displayMode == .read {
            displayMode = .write
        }
    }

    private func openSidebarFile(_ url: URL) {
        LineformSidebarFileOpener.open(
            url,
            replacing: activeWindow,
            updateEditorDocument: replaceDocumentFromSidebar
        )
    }

    private func renameSidebarItem(at url: URL, isDirectory: Bool) {
        renameText = SidebarFileRenaming.displayName(for: url, isDirectory: isDirectory)
        sidebarDialog = .rename(SidebarRenameRequest(url: url, isDirectory: isDirectory))
    }

    private func deleteSidebarItem(at url: URL) {
        sidebarDialog = .delete(url)
    }

    private var sidebarDialogPresented: Binding<Bool> {
        Binding(get: { sidebarDialog != nil }, set: { if !$0 { sidebarDialog = nil } })
    }

    private var sidebarDialogTitle: String {
        switch sidebarDialog {
        case .rename(let request):
            return request.isDirectory
                ? SidebarFileActionPresenter.renameFolderTitle
                : SidebarFileActionPresenter.renameFileTitle
        case .delete(let url):
            return SidebarFileActionPresenter.deleteTitle(for: url)
        case nil:
            return ""
        }
    }

    private func commitPendingRename(_ request: SidebarRenameRequest) {
        guard let destination = SidebarFileRenaming.validatedDestination(
            for: request.url,
            isDirectory: request.isDirectory,
            newDisplayName: renameText
        ) else {
            // Empty / unchanged / invalid name — dismiss without touching disk.
            sidebarDialog = nil
            return
        }
        performSidebarRename(request, to: destination)
    }

    private func performSidebarRename(_ request: SidebarRenameRequest, to destination: URL) {
        sidebarDialog = nil
        do {
            try SidebarFileOperations().rename(request.url, to: destination)
        } catch {
            presentSidebarOperationError(error)
            return
        }
        // Every window (including this one) retargets via the rename broadcast; every
        // visible Files tab re-scans via the refresh broadcast (FSEvents deliberately
        // ignores our own process's events).
        LineformAppNotification.sidebarItemRenamed.post(
            object: LineformAppNotification.RenamePayload(from: request.url, to: destination, isDirectory: request.isDirectory)
        )
        LineformAppNotification.refreshSidebarFiles.post(object: destination)
    }

    private func performSidebarDelete(_ url: URL) {
        sidebarDialog = nil
        do {
            try SidebarFileOperations().trash(url)
        } catch {
            presentSidebarOperationError(error)
            return
        }
        LineformAppNotification.sidebarFileDeleted.post(object: url)
        LineformAppNotification.refreshSidebarFiles.post(object: url)
    }

    /// The rare failure path (name collision, no permission). A system error alert is
    /// fine here — it's an error, not the primary Muse-style action dialog.
    private func presentSidebarOperationError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func replaceDocumentFromSidebar(_ replacement: LineformDocument) -> UUID {
        let documentID = document.id
        resetTransientDocumentState()
        document.text = replacement.text
        document.textFormat = replacement.textFormat
        document.plainTextConversion = replacement.plainTextConversion
        // Re-point the watcher at the newly-swapped file. Async so it runs after the sidebar
        // opener has retargeted the window's NSDocument.fileURL.
        DispatchQueue.main.async { registerReloadWatcher() }
        return documentID
    }

    private var reloadWatcherURL: URL? {
        (activeWindow?.windowController?.document as? NSDocument)?.fileURL
    }

    private func registerReloadWatcher() {
        // Appear/open/sidebar-swap registration. `register` resets the baseline only for a
        // NEW url (a memory==disk moment); re-appearing at the same url preserves baselines
        // so unsaved edits are never blessed as synced. Saves go through noteSavedToReloadWatcher.
        reloadController.register(url: reloadWatcherURL, syncedText: document.text)
        // Same source of truth drives the Files-tab selection highlight; keep it in step with
        // every watcher retarget (appear, window bind, sidebar swap) so the blue row follows
        // the document actually on screen.
        currentFileURL = reloadWatcherURL
    }

    private func noteSavedToReloadWatcher() {
        // Deferred one runloop turn so AppKit has retargeted NSDocument.fileURL (first save of
        // an untitled document, Save As) before we re-point the watcher — the same ordering
        // heuristic replaceDocumentFromSidebar uses. (SwiftUI's DocumentGroup exposes no
        // fileURL-change hook to close this deterministically; a late retarget self-heals at
        // the next save.) The baseline is the exact text the save wrote, not the live text,
        // which may already have newer keystrokes.
        DispatchQueue.main.async {
            reloadController.noteSaved(
                url: reloadWatcherURL,
                savedText: documentSaveStatus.savedText(for: document.id) ?? document.text
            )
            // A first save on an untitled doc (or Save As) mints/retargets the file URL — refresh
            // the highlight so the newly-real file shows as selected in the Files tab.
            currentFileURL = reloadWatcherURL
        }
    }

    private func applyReload(_ result: ReloadResult) {
        // No selection request is pending in the common case, so the text replacement takes
        // MarkdownTextViewRepresentable's scroll-preserving branch (requestedSelection == nil).
        // A pending outline/search jump is deliberately left alone — the user's navigation wins.
        document.plainTextConversion = nil
        document.text = result.text
        reloadController.currentText = result.text

        if let backingDocument = activeWindow?.windowController?.document as? NSDocument {
            backingDocument.fileModificationDate = result.modificationDate
            backingDocument.updateChangeCount(.changeCleared)
        }
        DocumentSaveStatus.shared.markSaved(documentID: document.id, at: result.modificationDate ?? Date(), text: result.text)
        flashStatus(.updated)
        reloadController.clearLastReload()
    }

    private func flashStatus(_ flash: EditorStatusFlash) {
        updatedIndicatorWorkItem?.cancel()
        withAnimation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
            statusFlash = flash
        }
        let token = flash
        let work = DispatchWorkItem {
            // Only clear if still showing the same flash; a newer edit/flash may have replaced it.
            guard statusFlash == token else { return }
            withAnimation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
                statusFlash = nil
            }
        }
        updatedIndicatorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private var activeWindow: NSWindow? {
        guard let windowNumber else {
            return nil
        }

        return NSApp.windows.first { $0.windowNumber == windowNumber }
    }

    private func resetTransientDocumentState() {
        requestedSelection = NSRange(location: 0, length: 0)
        searchQuery = ""
        searchMatches = []
        activeSearchIndex = nil
    }

    private func refreshSearchMatches(selectFirstWhenNeeded: Bool, navigatesToActiveMatch: Bool = true) {
        let matches = EditorSearchResolver.matches(in: document.text, query: searchQuery)
        searchMatches = matches

        let refresh = EditorSearchResolver.refreshState(
            currentActiveIndex: activeSearchIndex,
            matches: matches,
            selectFirstWhenNeeded: selectFirstWhenNeeded,
            navigatesToActiveMatch: navigatesToActiveMatch
        )
        activeSearchIndex = refresh.activeIndex

        if let requestedSelection = refresh.requestedSelection {
            if displayMode == .read {
                displayMode = .write
            }
            self.requestedSelection = requestedSelection
        }
    }

    private func advanceToNextSearchMatch() {
        guard
            let next = EditorSearchResolver.nextIndex(
                after: activeSearchIndex,
                matchCount: searchMatches.count
            )
        else {
            return
        }
        selectSearchMatch(at: next)
    }

    private func selectSearchMatch(at index: Int) {
        guard searchMatches.indices.contains(index) else {
            return
        }

        activeSearchIndex = index
        if displayMode == .read {
            displayMode = .write
        }
        requestedSelection = searchMatches[index]
    }

    private var statisticsText: String {
        EditorStatusFormatter.statisticsText(
            wordCount: documentStatistics.wordCount,
            characterCount: documentStatistics.characterCount
        )
    }

    private var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay {
        EditorStatusFormatter.lastSavedDisplay(for: documentSaveStatus.savedAt(for: document.id))
    }

    private var isDocumentDirty: Bool {
        documentSaveStatus.isDirty(documentID: document.id, currentText: document.text)
    }

    private var statusIndicator: EditorStatusIndicator {
        EditorStatusFormatter.indicator(
            savedAt: documentSaveStatus.savedAt(for: document.id),
            isDirty: isDocumentDirty,
            flash: statusFlash
        )
    }

    private var statusAccessibilityLabel: String {
        return "Document contains \(documentStatistics.wordCount) words and \(documentStatistics.characterCount) characters"
    }

    private func notificationMatchesActiveWindow(_ notification: Notification) -> Bool {
        guard let payload = notification.object as? LineformAppNotification.Payload else {
            return false
        }
        return payload.matches(windowNumber: windowNumber)
    }

    private func notificationPayloadValue(_ notification: Notification) -> String? {
        (notification.object as? LineformAppNotification.Payload)?.value
    }

    private func notificationPayloadSelectedRange(_ notification: Notification) -> NSRange? {
        (notification.object as? LineformAppNotification.Payload)?.selectedRange
    }

    private func convertDocumentTextFormat(to format: LineformTextFormat, selectedRange: NSRange?) {
        switch format {
        case .markdown:
            requestedSelection = document.restoreConvertedMarkdown()
        case .plainText:
            requestedSelection = document.convertMarkdownToPlainText(selectedRange: selectedRange)
        }
        LineformTextFormatMenuState.shared.setTextFormat(document.textFormat)
    }

    @ViewBuilder
    private func toolbarControl(for action: EditorToolbarAction) -> some View {
        switch action {
        case .markdownBasics, .readingExperience:
            let isActive = toolbarActionIsActive(action)
            Button {
                handleToolbarAction(action)
            } label: {
                EditorToolbarIcon(
                    systemImage: action.systemImage,
                    usesDarkChrome: currentTheme.usesDarkChrome
                )
            }
            .help(toolbarHelp(for: action))
            .accessibilityLabel(action.title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
        }
    }

    private func handleToolbarAction(_ action: EditorToolbarAction) {
        switch action {
        case .markdownBasics:
            isShowingMarkdownBasics.toggle()
        case .readingExperience:
            setReadingInspectorVisible(!isShowingReadingInspector)
        }
    }

    private func setReadingInspectorVisible(_ isVisible: Bool) {
        guard isShowingReadingInspector != isVisible else {
            return
        }

        isShowingReadingInspector = isVisible
    }

    private func toolbarActionIsActive(_ action: EditorToolbarAction) -> Bool {
        EditorToolbarPressedState.isActive(
            action,
            isShowingMarkdownBasics: isShowingMarkdownBasics,
            isShowingReadingInspector: isShowingReadingInspector
        )
    }

    private func toolbarHelp(for action: EditorToolbarAction) -> String {
        switch action {
        case .markdownBasics, .readingExperience:
            return action.title
        }
    }
}

private extension View {
    /// Binds the search field's focus state where supported. `searchFocused` is
    /// macOS 15+, so on macOS 14 this is a no-op: search still works via
    /// `.searchable`, only the programmatic focus binding is inactive.
    @ViewBuilder
    func searchFocusedCompat(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(binding)
        } else {
            self
        }
    }
}
