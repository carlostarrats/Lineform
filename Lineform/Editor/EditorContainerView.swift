import SwiftUI
import UniformTypeIdentifiers

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore: ReadingProfileStore
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingReadingInspector = false
    @State private var isShowingSettings = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline: Bool
    @State private var outlineItems: [MarkdownOutlineItem] = []
    @State private var requestedSelection: NSRange?
    @State private var searchQuery = ""
    @State private var searchMatches: [NSRange] = []
    @State private var activeSearchIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isShowingFindReplace = false
    @State private var replaceText = ""
    @State private var requestedReplacement: MarkdownEdit?
    @FocusState private var isReplaceFocused: Bool
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    @State private var currentFileURL: URL?
    @StateObject private var reloadController = DocumentReloadController()
    @State private var statusFlash: EditorStatusFlash?
    @State private var updatedIndicatorWorkItem: DispatchWorkItem?
    // Coalesces the heavy per-edit derived work (word/char count, heading outline,
    // search-match recompute) behind a short typing-pause debounce so large documents
    // don't re-walk the whole text on every keystroke. Mirrors the existing debounce
    // idiom (DebouncedMarkdownPreviewView, scheduleMarkdownHighlighting). The dirty flag
    // and external-reload text tracking are deliberately NOT debounced (see onChange).
    @State private var pendingDerivedRefresh: DispatchWorkItem?
    private let derivedRefreshDelay: TimeInterval = 0.2
    @State private var sidebarDialog: SidebarFileDialog?
    @State private var renameText = ""
    /// Set when a PDF export write fails, driving a native in-window `.alert` (no app-icon
    /// NSAlert). Holds the destination file name for the message.
    @State private var pdfExportErrorFileName: String?

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
        .alert(
            "Couldn’t Export PDF",
            isPresented: Binding(
                get: { pdfExportErrorFileName != nil },
                set: { if !$0 { pdfExportErrorFileName = nil } }
            ),
            presenting: pdfExportErrorFileName
        ) { _ in
            Button("OK", role: .cancel) { pdfExportErrorFileName = nil }
        } message: { fileName in
            Text("Lineform couldn’t write “\(fileName)”. Choose a different location and try again.")
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
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showFindReplace.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            // Replace needs the editor, which only exists in Write/Split; force Write so ⌥⌘F
            // always lands somewhere it can act (search likewise forces Write when it navigates
            // to a match, in refreshSearchMatches).
            if displayMode == .read {
                displayMode = .write
            }
            isShowingFindReplace = true
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
            // Settle any pending debounced work so the outline/count are correct the
            // instant the user switches modes (rather than a debounce interval later).
            flushDerivedRefresh()
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
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.printDocument.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            printCurrentDocument()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.exportPDF.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            exportCurrentDocumentAsPDF()
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
            // Instant, cheap, must stay accurate on every keystroke: external-reload text
            // tracking and the dirty/unsaved flag. (The latter is load-bearing for autosave
            // and for future Read-mode checkbox edits — never debounce it.)
            reloadController.currentText = newValue
            // An edit means the next write is an autosave of this change, not the
            // earlier ⌘S/Save As — so a still-pending manual intent no longer applies.
            documentSaveStatus.noteUserEdit()
            // Heavy full-document work (count/outline/search) is coalesced to run once
            // after a brief typing pause instead of on every keystroke.
            scheduleDerivedRefresh(for: newValue)
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
            // Guarantee the displayed count/outline match the just-saved file rather than
            // lagging by a debounce interval.
            flushDerivedRefresh()
        }
        .onChange(of: documentSaveStatus.lastSaveEvent) { _, event in
            // Flash a green save confirmation only for this document's real writes.
            guard let event, event.documentID == document.id else { return }
            flashStatus(event.kind == .manual ? .saved : .autosaved)
        }
        .onDisappear {
            reloadController.stop()
            // Drop any pending derived-refresh work for a window that's going away.
            pendingDerivedRefresh?.cancel()
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

            // Settings uses the shared Muse modal language: scrim + centered light
            // card + Esc/outside-click dismissal.
            if isShowingSettings {
                museModalLayer(scrimZIndex: 3, modalZIndex: 4, onDismiss: { isShowingSettings = false }) { geometry in
                    SettingsModal(settings: settings, availableWidth: geometry.size.width) {
                        isShowingSettings = false
                    }
                }
            }
        }
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: SettingsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingSettings
        )
    }

    /// The shared presentation for a Muse-style modal (Info, Settings): a tap-to-dismiss
    /// scrim beneath a centered card that fades and slides up on entry. Callers supply the
    /// card via `modal`, sized against the window's `GeometryProxy`, plus the z-indices that
    /// stack scrim below card (and one modal above another when both can appear).
    @ViewBuilder
    private func museModalLayer<Modal: View>(
        scrimZIndex: Double,
        modalZIndex: Double,
        onDismiss: @escaping () -> Void,
        @ViewBuilder modal: @escaping (GeometryProxy) -> Modal
    ) -> some View {
        MuseModalScrim(dismiss: onDismiss)
            .zIndex(scrimZIndex)
            .transaction { transaction in
                transaction.animation = nil
            }

        GeometryReader { geometry in
            modal(geometry)
                .transition(
                    .asymmetric(
                        insertion: EditorMotionPolicy.fadeAndMoveTransition(
                            y: MuseModalChrome.entranceYOffset,
                            reduceMotion: reduceMotion
                        ),
                        removal: EditorMotionPolicy.fadeAndMoveTransition(
                            y: MuseModalChrome.entranceYOffset / 2,
                            reduceMotion: reduceMotion
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .zIndex(modalZIndex)
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

            // Find & Replace floats OVER the page as a small panel (Safari-⌘F style). It is
            // deliberately an overlay, NOT a row in the VStack: a full-width strip at the top of
            // the layout becomes what the translucent toolbar samples for its own color, so a
            // laid-out bar visibly recolored the navigation whenever it opened. An overlay leaves
            // the view hierarchy at the top edge identical to when the bar is closed — the header
            // cannot change.
            if isShowingFindReplace && displayMode != .read {
                findReplaceBar
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
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

    /// Toggle a Read-mode task checkbox as a normal document edit: swap `[ ]`↔`[x]` at the clicked
    /// marker's source range. Because it mutates `document.text` through the binding like any edit,
    /// dirty-tracking, autosave, and undo (single ⌘Z) all apply. A stale range (the text changed
    /// out from under the render) yields nil and is ignored.
    private func toggleCheckbox(at range: NSRange) {
        guard let newText = CheckboxToggle.toggledText(in: document.text, at: range) else { return }
        document.text = newText
    }

    // The Find & Replace panel. The FIND term stays in the existing native toolbar search
    // field (`searchQuery`); this adds only the replacement field + actions beside it, so the
    // settled search UX is untouched. Rendered as a compact FLOATING card over the page (see the
    // overlay comment in editorPrimaryShell — never a laid-out top strip, which recolors the
    // toolbar). The card is the app's theme-independent light chrome (same family as the Muse
    // modals), so it looks identical on every page and its controls are always legible.
    private var findReplaceBar: some View {
        HStack(spacing: 8) {
            TextField("Replace", text: $replaceText)
                .textFieldStyle(.roundedBorder)
                // Compressible so the card fits a narrow editor pane (minimum content width is
                // 300pt): the field shrinks before the card can overflow and clip off-screen.
                .frame(minWidth: 80, idealWidth: 190, maxWidth: 190)
                .focused($isReplaceFocused)
                .onSubmit { replaceCurrentMatch() }
                .accessibilityLabel("Replacement text")

            Button("Replace") { replaceCurrentMatch() }
                .disabled(activeSearchRange == nil)
                .accessibilityLabel("Replace")

            Button("Replace All") { replaceAllMatches() }
                .disabled(searchMatches.isEmpty)
                .accessibilityLabel("Replace all")

            if let countLabel = replaceMatchCountLabel {
                Text(countLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // First to give way when the card is squeezed in a narrow window.
                    .layoutPriority(-1)
            }

            Button {
                dismissFindReplace()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close find and replace")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Two fixed card variants (user-requested): a light card for the light themes and a
        // darker card for the dark-chrome themes (Quiet/Night) so the panel isn't a bright block
        // on a dark page. Keyed on usesDarkChrome — two variants, not per-theme tinting — and the
        // controls are pinned to the matching appearance so field borders/labels always read.
        // Floating overlay, so neither variant can affect the toolbar (see editorPrimaryShell).
        .environment(\.colorScheme, currentTheme.usesDarkChrome ? .dark : .light)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    currentTheme.usesDarkChrome
                        ? Color(white: 0.15)
                        : Color(white: MuseModalChrome.backgroundWhiteComponent)
                )
                .shadow(color: .black.opacity(0.28), radius: 10, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    currentTheme.usesDarkChrome
                        ? Color.white.opacity(0.14)
                        : Color.black.opacity(0.10)
                )
        )
        .onExitCommand { dismissFindReplace() }
    }

    // Quiet count hint that informs the Replace All decision. Nil (no label) until the user
    // has typed a find term, so an empty bar reads as calm rather than "No matches".
    private var replaceMatchCountLabel: String? {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let count = searchMatches.count
        guard count > 0 else {
            return "No matches"
        }
        return count == 1 ? "1 found" : "\(count) found"
    }

    private func dismissFindReplace() {
        isShowingFindReplace = false
        isReplaceFocused = false
    }

    // Replace the current active match with the replacement text, then move to the next match
    // ("Replace & find next"). One undo step (routes through applyExternalReplacement).
    private func replaceCurrentMatch() {
        guard let currentIndex = activeSearchIndex, searchMatches.indices.contains(currentIndex) else {
            return
        }
        let matchRange = searchMatches[currentIndex]
        // Re-resolve against LIVE text: a body edit within the search debounce can shift offsets,
        // and replaceMatch only bounds-checks — replacing a stale range would overwrite non-matching
        // characters. Only proceed if the highlighted range is still a real match; otherwise resync.
        let liveMatches = EditorSearchResolver.matches(in: document.text, query: searchQuery)
        guard
            liveMatches.contains(matchRange),
            let result = EditorSearchResolver.replaceMatch(
                in: document.text,
                matchRange: matchRange,
                replacement: replaceText
            )
        else {
            searchMatches = liveMatches
            activeSearchIndex = liveMatches.isEmpty ? nil : min(currentIndex, liveMatches.count - 1)
            return
        }

        let newMatches = EditorSearchResolver.matches(in: result.text, query: searchQuery)
        let nextIndex = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: matchRange.location,
            replacementLength: (replaceText as NSString).length
        )
        applyReplacement(result: result, newMatches: newMatches, activeIndex: nextIndex)
    }

    private func replaceAllMatches() {
        guard let result = EditorSearchResolver.replaceAll(
            in: document.text,
            query: searchQuery,
            replacement: replaceText
        ) else {
            return
        }
        let newMatches = EditorSearchResolver.matches(in: result.text, query: searchQuery)
        applyReplacement(result: result, newMatches: newMatches, activeIndex: newMatches.isEmpty ? nil : 0)
    }

    // Shared tail for both replace actions. Refreshes search state against the post-replace text
    // now so highlights don't lag a debounce interval on the new text (the debounced recompute from
    // the text change reproduces the same result, so this is stable, not a race), then hands the
    // edit to the text view via the undoable `requestedReplacement` channel — a single ⌘Z step that
    // syncs `document.text` through didChangeText. `document.text` is deliberately NOT set here.
    private func applyReplacement(
        result: EditorSearchResolver.ReplacementResult,
        newMatches: [NSRange],
        activeIndex: Int?
    ) {
        searchMatches = newMatches
        activeSearchIndex = activeIndex
        let selection = activeIndex.map { newMatches[$0] } ?? result.selectedRange
        requestedReplacement = MarkdownEdit(text: result.text, selectedRange: selection)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch displayMode {
        case .write:
            markdownEditor
        case .read:
            HStack {
                DebouncedMarkdownPreviewView(
                    text: document.text,
                    profile: readingProfileStore.activeProfile,
                    onCheckboxToggle: toggleCheckbox
                )
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HStack(spacing: 0) {
                markdownEditor
                Divider()
                DebouncedMarkdownPreviewView(
                    text: document.text,
                    profile: readingProfileStore.activeProfile,
                    onCheckboxToggle: toggleCheckbox
                )
            }
        }
    }

    private var markdownEditor: some View {
        MarkdownTextViewRepresentable(
            text: $document.text,
            textFormat: $document.textFormat,
            plainTextConversion: $document.plainTextConversion,
            requestedSelection: $requestedSelection,
            requestedReplacement: $requestedReplacement,
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
        // Show the newly-opened file's outline/count at once, like a fresh window's .onAppear.
        recomputeDerivedNow(for: replacement.text)
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
        // Live reload is a discrete, non-typing change — refresh outline/count/search now so
        // they match the reloaded text immediately (they did before the debounce), rather than
        // lagging the "Updated" flash by the debounce interval.
        recomputeDerivedNow(for: result.text)

        if let backingDocument = activeWindow?.windowController?.document as? NSDocument {
            backingDocument.fileModificationDate = result.modificationDate
            backingDocument.updateChangeCount(.changeCleared)
        }
        DocumentSaveStatus.shared.markSaved(documentID: document.id, at: result.modificationDate ?? Date(), text: result.text)
        flashStatus(.updated)
        reloadController.clearLastReload()
    }

    // Schedules the heavy derived recompute (stats/outline/search) after a typing pause,
    // cancelling any earlier pending pass so a burst of keystrokes coalesces to one run.
    private func scheduleDerivedRefresh(for text: String) {
        pendingDerivedRefresh?.cancel()
        let work = DispatchWorkItem {
            pendingDerivedRefresh = nil
            recomputeDerived(from: text)
        }
        pendingDerivedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + derivedRefreshDelay, execute: work)
    }

    // The actual derived work: word/char count, heading outline, and search-match recompute.
    // Parse logic is unchanged from the old per-keystroke path — only its timing moved.
    // Keep the search refresh NON-navigating (navigatesToActiveMatch: false): it must never
    // move the caret/scroll. This is load-bearing now that recomputeDerivedNow reuses this on
    // reload and format-conversion, whose own caret placement and scroll preservation must be
    // left untouched (a `true` here would hijack the selection on those paths).
    private func recomputeDerived(from text: String) {
        documentStatistics = DocumentStatistics(text: text)
        outlineItems = MarkdownOutlineParser().items(in: text)
        refreshSearchMatches(selectFirstWhenNeeded: activeSearchIndex == nil, navigatesToActiveMatch: false)
    }

    // Runs any pending derived recompute immediately (on the live text) and clears the
    // timer. Called at moments the values must be current now — mode switch, save.
    private func flushDerivedRefresh() {
        guard let work = pendingDerivedRefresh else { return }
        work.cancel()
        pendingDerivedRefresh = nil
        recomputeDerived(from: document.text)
    }

    // A programmatic (non-typing) replacement of document.text — opening a file, an external
    // reload, a format conversion. Recompute the derived state at once: the debounce exists
    // only to smooth the continuous keystroke stream, not to lag these discrete changes (they
    // refreshed synchronously before the debounce, and the outline/count/search should settle
    // immediately). Cancels any pass still pending from prior edits so its captured older text
    // can't clobber the fresh values when it fires; the change's own onChange will schedule one
    // more identical pass a beat later, which is harmless.
    private func recomputeDerivedNow(for text: String) {
        pendingDerivedRefresh?.cancel()
        pendingDerivedRefresh = nil
        recomputeDerived(from: text)
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
        isShowingFindReplace = false
        isReplaceFocused = false
        replaceText = ""
        requestedReplacement = nil
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

    // MARK: - Print / PDF export

    /// Presents the standard print panel for the rich rendered document (white page, black ink,
    /// the reader's typography). Paper size, copies, and the OS "Save as PDF" come from the panel.
    ///
    /// The offscreen view is built once for `defaultExportPaperSize`. Prose and tables are live
    /// text and re-paginate to whatever paper the user picks in the panel, but rasterized mermaid/
    /// math images keep the width they were fit to — so changing paper size mid-print on a
    /// diagram-heavy document may scale those images slightly. Minor and cosmetic; Export as PDF,
    /// which fixes the paper before building the view, is unaffected.
    ///
    private func printCurrentDocument() {
        DocumentExportRenderer.runInteractivePrint(
            text: document.text,
            profile: readingProfileStore.activeProfile,
            paper: defaultExportPaperSize
        )
    }

    /// Prompts for a destination (with a Letter/A4 accessory) and writes the rich rendered PDF.
    private func exportCurrentDocumentAsPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultExportFileName
        panel.canCreateDirectories = true

        let paperPopup = makePaperSizePopup()
        panel.accessoryView = makePaperSizeAccessory(popup: paperPopup)

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let selection = paperPopup.indexOfSelectedItem
            let paper = ExportPaperSize.allCases.indices.contains(selection)
                ? ExportPaperSize.allCases[selection]
                : .usLetter
            let succeeded = DocumentExportRenderer.writePDF(
                text: document.text,
                profile: readingProfileStore.activeProfile,
                paper: paper,
                to: url
            )
            if !succeeded {
                pdfExportErrorFileName = url.lastPathComponent
            }
        }

        if let window = activeWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    private var defaultExportFileName: String {
        let base = currentFileURL?.deletingPathExtension().lastPathComponent
        return ((base?.isEmpty == false ? base! : "Untitled")) + ".pdf"
    }

    /// Defaults to whichever offered paper best matches the system's default (A4 in most of the
    /// world, Letter in the US/Canada). Compared on portrait dimensions so a landscape default
    /// printer isn't misread.
    private var defaultExportPaperSize: ExportPaperSize {
        let paper = NSPrintInfo.shared.paperSize
        let width = min(paper.width, paper.height)
        let height = max(paper.width, paper.height)
        return ExportPaperSize.allCases.min(by: { a, b in
            let sa = a.sizeInPoints, sb = b.sizeInPoints
            let da = abs(sa.width - width) + abs(sa.height - height)
            let db = abs(sb.width - width) + abs(sb.height - height)
            return da < db
        }) ?? .usLetter
    }

    private func makePaperSizePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 25))
        for size in ExportPaperSize.allCases {
            popup.addItem(withTitle: size.displayName)
        }
        if let index = ExportPaperSize.allCases.firstIndex(of: defaultExportPaperSize) {
            popup.selectItem(at: index)
        }
        return popup
    }

    private func makePaperSizeAccessory(popup: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: "Paper Size:")
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            container.heightAnchor.constraint(equalToConstant: 48)
        ])
        return container
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
        // Format conversion is a discrete command whose result the user expects settled at
        // once — refresh outline/count/search for the converted text immediately.
        recomputeDerivedNow(for: document.text)
    }

    @ViewBuilder
    private func toolbarControl(for action: EditorToolbarAction) -> some View {
        switch action {
        case .readingExperience:
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
            isShowingReadingInspector: isShowingReadingInspector
        )
    }

    private func toolbarHelp(for action: EditorToolbarAction) -> String {
        switch action {
        case .readingExperience:
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
