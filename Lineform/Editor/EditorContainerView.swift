import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore: ReadingProfileStore
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingReadingInspector = false
    @State private var isShowingMarkdownBasics = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline = false
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
    @State private var showsUpdatedIndicator = false
    @State private var updatedIndicatorWorkItem: DispatchWorkItem?

    private let injectedFileBrowserStore: OutlineFileBrowserStore?

    init(
        document: Binding<LineformDocument>,
        readingProfileStore: ReadingProfileStore = ReadingProfileStore(),
        fileBrowserStore: OutlineFileBrowserStore? = nil
    ) {
        _document = document
        _readingProfileStore = StateObject(wrappedValue: readingProfileStore)
        injectedFileBrowserStore = fileBrowserStore
    }

    var body: some View {
        let theme = currentTheme

        NavigationSplitView(columnVisibility: outlineVisibility) {
            OutlineSidebarView(
                items: outlineItems,
                jumpToHeading: jumpToHeading,
                openFile: openSidebarFile,
                currentFileURL: currentFileURL,
                fileBrowserStore: injectedFileBrowserStore
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
        .onDisappear {
            reloadController.stop()
        }
        .onChange(of: searchQuery) { _, _ in
            refreshSearchMatches(selectFirstWhenNeeded: true, navigatesToActiveMatch: true)
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
                    ReadingExperienceInspector(store: readingProfileStore, usesDarkChrome: theme.usesDarkChrome)
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

                MarkdownBasicsModal {
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
                .zIndex(2)
            }
        }
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: MarkdownBasicsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingMarkdownBasics
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
                        showsUpdatedIndicator: showsUpdatedIndicator
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
        flashUpdatedIndicator()
        reloadController.clearLastReload()
    }

    private func flashUpdatedIndicator() {
        updatedIndicatorWorkItem?.cancel()
        withAnimation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
            showsUpdatedIndicator = true
        }
        let work = DispatchWorkItem {
            withAnimation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
                showsUpdatedIndicator = false
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
                    systemImage: EditorToolbarPressedState.displaySystemImage(for: action, isActive: isActive),
                    isOn: isActive,
                    usesDarkChrome: currentTheme.usesDarkChrome,
                    symbolScale: EditorToolbarPressedState.displaySymbolScale(for: action, isActive: isActive),
                    symbolTransitionStyle: EditorToolbarPressedState.symbolTransitionStyle(isActive: isActive)
                )
            }
            .help(toolbarHelp(for: action))
            .accessibilityLabel(action.title)
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
