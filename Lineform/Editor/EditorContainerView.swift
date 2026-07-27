import SwiftUI
import UniformTypeIdentifiers

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore: ReadingProfileStore
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
    @StateObject private var tabStore: EditorTabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingReadingInspector = false
    @State private var isShowingSettings = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline: Bool
    @State private var outlineItems: [MarkdownOutlineItem] = []
    /// The source-text range of the heading (or nearest content) currently at the top of the
    /// editor viewport. Kept in sync across Write, Read, and Preview modes so the outline
    /// sidebar can bold the active item.
    @State private var activeOutlineSourceRange: NSRange?
    @State private var requestedSelection: NSRange?
    @State private var requestedScrollToTopRange: NSRange?
    @State private var searchQuery = ""
    @State private var searchScope: EditorSearchScope = .thisFile
    @StateObject private var crossFileSearchModel = CrossFileSearchModel()
    @State private var searchMatches: [NSRange] = []
    @State private var activeSearchIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isShowingFindReplace = false
    @State private var isShowingQuickOpen = false
    @State private var quickOpenQuery = ""
    @State private var replaceText = ""
    @State private var requestedReplacement: MarkdownEdit?
    @FocusState private var isReplaceFocused: Bool
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    @State private var currentFileURL: URL?
    @StateObject private var reloadController = DocumentReloadController()
    @StateObject private var speechController = SpeechController()
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
    /// Set when an RTF export write fails, driving a native in-window `.alert` (no app-icon
    /// NSAlert). Holds the destination file name for the message.
    @State private var rtfExportErrorFileName: String?
    /// Set when an HTML export write fails, driving a native in-window `.alert` (no app-icon
    /// NSAlert). Holds the destination file name for the message.
    @State private var htmlExportErrorFileName: String?
    /// Set when a Save As → Markdown save fails, driving a native in-window `.alert`.
    @State private var markdownSaveErrorFileName: String?
    /// Set when Save As targets a file already open in another tab of this window. Holds that
    /// tab's title for the refusal alert (see `SaveAsConflict`).
    @State private var saveAsConflictTabTitle: String?
    @State private var tabCloseDialog: TabCloseDialog?
    /// Coordinates saving a dirty tab before closing it.
    @State private var saveAndCloseCoordinator: SaveAndCloseCoordinator?
    /// Coordinates saving every unsaved tab before closing the whole window ("Save All").
    @State private var saveTabsBeforeCloseCoordinator: SaveTabsBeforeCloseCoordinator?
    /// Intercepts window close to guard against losing non-active dirty tabs.
    @State private var windowCloseController: WindowCloseController?

    /// Owned here (not in the sidebar) so quick-open can read the scanned tree even with
    /// the sidebar closed. Passed down to OutlineSidebarView, which adopts an injected
    /// store instead of creating its own — one store per window either way.
    @StateObject private var fileBrowserStore: OutlineFileBrowserStore
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
        _tabStore = StateObject(wrappedValue: EditorTabStore(initialDocument: document.wrappedValue))
        _fileBrowserStore = StateObject(
            wrappedValue: fileBrowserStore ?? OutlineFileBrowserStore(runsScanInBackground: true)
        )
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
                activeSourceRange: activeOutlineSourceRange,
                jumpToHeading: jumpToHeading,
                // Explicit closure, not a bare method reference: openSidebarFile carries defaulted
                // parameters now, and letting SwiftUI infer a function value through those times
                // out this body's type-checker.
                openFile: { url in openSidebarFile(url) },
                currentFileURL: currentFileURL,
                fileBrowserStore: fileBrowserStore,
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
                // Without an explicit width, NavigationSplitView applies its own default detail-column
                // minimum (~500pt, measured 2026-07-17), which — added to the sidebar column — forced
                // the whole window out to ~756pt whenever the sidebar opened on a small window. Our
                // content already carries its real minimum (EditorLayout.minimumContentWidth).
                .navigationSplitViewColumnWidth(
                    min: EditorLayout.minimumContentWidth,
                    ideal: 640,
                    max: .infinity
                )
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
        .modifier(WriteFailureAlert(title: "Couldn\u{2019}t Export PDF", fileName: $pdfExportErrorFileName))
        .modifier(WriteFailureAlert(title: "Couldn\u{2019}t Export RTF", fileName: $rtfExportErrorFileName))
        .modifier(WriteFailureAlert(title: "Couldn\u{2019}t Export HTML", fileName: $htmlExportErrorFileName))
        .modifier(WriteFailureAlert(title: "Couldn\u{2019}t Save", fileName: $markdownSaveErrorFileName))
        .alert(
            "File Already Open",
            isPresented: Binding(
                get: { saveAsConflictTabTitle != nil },
                set: { if !$0 { saveAsConflictTabTitle = nil } }
            ),
            presenting: saveAsConflictTabTitle
        ) { _ in
            Button("OK", role: .cancel) { saveAsConflictTabTitle = nil }
        } message: { tabTitle in
            Text("\u{201C}\(tabTitle)\u{201D} is open in another tab, so saving over it would discard that tab\u{2019}s contents. Close that tab first, or choose a different name.")
        }
        .alert(
            "Close Tab",
            isPresented: Binding(
                get: { tabCloseDialog != nil },
                set: { if !$0 { tabCloseDialog = nil } }
            ),
            presenting: tabCloseDialog
        ) { dialog in
            Button("Save", role: .none) {
                saveAndCloseTab(id: dialog.tabID)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                tabCloseDialog = nil
            }
            Button("Don't Save", role: .destructive) {
                confirmCloseTab(id: dialog.tabID)
            }
        } message: { dialog in
            Text("Do you want to save changes to \u{201C}\(dialog.tabTitle)\u{201D} before closing?")
        }
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .preferredColorScheme(theme.usesDarkChrome ? .dark : .light)
        // The nav band must read as the SAME surface as the page — no darker strip, no shade
        // shift when tabs appear. Two pieces make that exact: the window's backgroundColor is
        // pinned to the theme page color (EditorWindowChrome.apply), and the toolbar MATERIAL
        // is hidden here so the band shows that backdrop directly instead of tinting it (the
        // dark material read visibly darker than the page on Quiet/Night; the light material
        // washed Paper's cream toward neutral). Visibility.hidden is spelled explicitly — the
        // bare `.hidden` overload is ambiguous against ShapeStyle and blows up type-checking.
        // An OPAQUE painted band was also tried and rejected: it covers the sidebar/drawer
        // divider hairlines at the toolbar edge. Do not reintroduce the material: with it, the
        // band can never equal the page color in dark themes.
        .toolbarBackground(Visibility.hidden, for: .windowToolbar)
        .background(WindowChromeReader(
            windowNumber: $windowNumber,
            usesDarkChrome: theme.usesDarkChrome,
            pageBackground: theme.backgroundColor
        ))
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search")
        .searchScopes($searchScope) {
            Text("This File").tag(EditorSearchScope.thisFile)
            Text("All Files").tag(EditorSearchScope.allFiles)
        }
        .searchFocusedCompat($isSearchFocused)
        .toolbar {
            ToolbarItem(placement: .principal) {
                EditorModePrincipalControl(
                    selection: $displayMode,
                    windowNumber: windowNumber,
                    usesDarkChrome: theme.usesDarkChrome,
                    reduceMotion: reduceMotion,
                    openReadingExperience: { setReadingInspectorVisible(true) }
                )
            }

            ToolbarItemGroup(placement: .primaryAction) {
                EditorReadingExperienceToolbarButton(windowNumber: windowNumber) {
                    ForEach(EditorToolbarAction.primaryActions(in: displayMode)) { action in
                        toolbarControl(for: action)
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showQuickOpen.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            // First ⌘K of a session triggers the deferred iCloud scan — the same
            // user-gesture trigger the Files tab uses, so the iCloud-laziness
            // invariant (never scan at launch/construction) holds. Workspace was
            // already scanned at store init; refresh it here too so a session-old
            // tree gets one catch-up walk (background-scanning store, no hitch).
            if !fileBrowserStore.hasPerformedICloudScan {
                fileBrowserStore.refreshICloud()
                fileBrowserStore.refreshWorkspace()
            }
            quickOpenQuery = ""
            isShowingQuickOpen = true
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
            tabStore.updateActiveTabDisplayMode(mode)
            // Settle any pending debounced work so the outline/count are correct the
            // instant the user switches modes (rather than a debounce interval later).
            flushDerivedRefresh()
            // Remember the reading position across the switch: scroll the newly shown view to the
            // exact source line that was at the top of the outgoing view, so toggling Write/Read/
            // Split resumes where the reader was instead of jumping to the top. Tab switches clear
            // `activeOutlineSourceRange` first (resetTransientDocumentState) so a stale position is
            // never restored into a different document. Deferred one runloop tick: the incoming
            // view is created fresh by the mode switch and isn't sized yet this cycle, so a scroll
            // request applied now wouldn't stick — by the next tick it has a real viewport.
            if let target = activeOutlineSourceRange {
                DispatchQueue.main.async {
                    requestedScrollToTopRange = target
                }
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
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.saveAsDocument.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            saveAsDocument()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.exportDocument.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            guard let raw = notificationPayloadValue(notification),
                  let value = Int(raw),
                  let format = ExportFormat(rawValue: value) else { return }
            exportDocument(format)
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.newTab.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            createNewTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.closeTab.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            requestCloseTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.selectNextTab.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            tabStore.selectNextTab()
            activateSelectedTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.selectPreviousTab.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else { return }
            tabStore.selectPreviousTab()
            activateSelectedTab()
        }
        // Bundled as a modifier (same rationale as ReissueCrossFileSearchOnRootChange below):
        // three `.onReceive`s + one `.onChange` inline pushed this very large body expression's
        // type-checker over budget.
        .modifier(SpeechNotificationHandlers(
            windowNumber: windowNumber,
            speechController: speechController,
            isKeyWindow: { activeWindow?.isKeyWindow == true },
            startSpeaking: startSpeakingCurrentDocument
        ))
        .onChange(of: tabStore.selectedTabID) { _, newID in
            guard newID != nil else { return }
            activateSelectedTab()
        }
        // Both chrome-rebuild appearance re-asserts bundled as a modifier (same
        // type-checker-budget rationale as SpeechNotificationHandlers below).
        .modifier(ReassertWindowChromeOnHierarchyRebuild(
            isShowingOutline: isShowingOutline,
            shouldShowTabBar: tabStore.shouldShowTabBar,
            apply: {
                EditorWindowChrome.apply(
                    to: activeWindow,
                    usesDarkChrome: currentTheme.usesDarkChrome,
                    pageBackground: currentTheme.backgroundColor
                )
            }
        ))
        .onChange(of: currentFileURL) { _, newValue in
            // Keep the File-menu Rename…/Delete… enabled state tracking the key window.
            if activeWindow?.isKeyWindow == true {
                LineformCurrentFileMenuState.shared.setCurrentFileURL(newValue)
            }
            tabStore.updateActiveTabFileURL(newValue)
            // A window opened by ⌘O/Finder/CLI/App Intents for a file another window already holds
            // hands it back and closes, instead of becoming a second live copy that autosaves over
            // it. This is the edge that carries the URL — onAppear runs before it is known.
            handOffToExistingWindowIfDuplicate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            LineformCurrentFileMenuState.shared.setCurrentFileURL(currentFileURL)
            LineformSpeechMenuState.shared.setState(speechController.state)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard
                let closingWindow = notification.object as? NSWindow,
                closingWindow.windowNumber == windowNumber
            else {
                return
            }
            // Audio must never outlive the window it was started from.
            speechController.stop()
            guard closingWindow.isKeyWindow || LineformCurrentFileMenuState.shared.currentFileURL == currentFileURL else {
                return
            }
            // Without this, closing the last window leaves File > Rename.../Delete...
            // enabled against a dead URL (a no-op menu command). Guarded so a background
            // window closing can't wipe the key window's state; if another window becomes
            // key next, its didBecomeKey update immediately repopulates it.
            LineformCurrentFileMenuState.shared.setCurrentFileURL(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.sidebarItemRenamed.name)) { notification in
            guard let payload = notification.object as? LineformAppNotification.RenamePayload else {
                return
            }
            // Retarget ALL tabs that point to the moved file or any descendant of a moved folder,
            // so switching tabs later does not try to autosave to a stale path.
            //
            // UNCONDITIONAL, and before the window guard below: this is a TAB-level operation, and
            // gating it on the ACTIVE file being affected meant a file open only in a BACKGROUND
            // tab was never retargeted. Switching to that tab later pointed the window's NSDocument
            // at a path that no longer exists — exactly what the comment above promises it prevents.
            tabStore.retargetFileURL(from: payload.from, to: payload.to, isDirectory: payload.isDirectory)

            guard
                let newURL = payload.rebased(currentFileURL),
                let backingDocument = activeWindow?.windowController?.document as? NSDocument
            else {
                return
            }
            // This window's active document follows the rename so the title bar, autosave
            // target, selection highlight, and reload watcher all track the new location.
            // The reload watcher is re-pointed with noteMoved — NOT registerReloadWatcher/register,
            // whose new-URL path resets the synced baseline to the live text and would bless
            // unsaved edits as synced (letting a later external write clobber them).
            backingDocument.fileURL = newURL
            backingDocument.fileModificationDate = LineformDocument.modificationDate(at: newURL)
            activeWindow?.representedURL = newURL
            activeWindow?.setTitleWithRepresentedFilename(newURL.path)
            reloadController.noteMoved(to: newURL)
            currentFileURL = newURL
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.sidebarFileDeleted.name)) { notification in
            guard let deletedURL = notification.object as? URL else {
                return
            }
            // Clear the file URL for ALL tabs that pointed at this deleted file, so they become
            // untitled-with-content and the next save prompts for a location.
            //
            // UNCONDITIONAL, for the same reason as the rename above: a file trashed while it sits
            // in a BACKGROUND tab was left pointing into the Trash, and activating that tab later
            // repointed the window's NSDocument there — where the next autosave writes the file
            // back out, which is the resurrection this app deliberately avoids.
            tabStore.markFileDeleted(deletedURL)

            guard
                currentFileURL?.standardizedFileURL == deletedURL.standardizedFileURL,
                let backingDocument = activeWindow?.windowController?.document as? NSDocument
            else {
                return
            }
            // The file is in the Trash; keep the text in the window as unsaved content.
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
            // (no nil→value transition) — e.g. the detail hierarchy rebuild that fires when
            // tabStore.shouldShowTabBar toggles (see the onChange below) tears down and
            // recreates this view's host, running onDisappear (which restores the window's
            // original delegate) without a matching windowNumber change to re-trigger the
            // onChange install below. Idempotent with the windowNumber onChange below.
            tabStore.windowNumber = windowNumber
            registerReloadWatcher()
            installWindowCloseControllerIfNeeded()
        }
        .onChange(of: document.textFormat) { _, newValue in
            LineformTextFormatMenuState.shared.setTextFormat(newValue)
            // The tab snapshot is otherwise only refreshed by the `document.text` observer below,
            // so a conversion that changes the FORMAT without changing the text — Convert to Plain
            // Text on a document that holds no markup — left the tab remembering the old format.
            // Switching away and back then restored the wrong one.
            tabStore.updateActiveTab(document: document)
        }
        .onChange(of: document.text) { _, newValue in
            // Instant, cheap, must stay accurate on every keystroke: external-reload text
            // tracking and the dirty/unsaved flag. (The latter is load-bearing for autosave
            // and for future Read-mode checkbox edits — never debounce it.)
            reloadController.currentText = newValue
            // An edit means the next write is an autosave of this change, not the
            // earlier ⌘S/Save As — so a still-pending manual intent no longer applies.
            documentSaveStatus.noteUserEdit()
            tabStore.updateActiveTab(document: document)
            // Heavy full-document work (count/outline/search) is coalesced to run once
            // after a brief typing pause instead of on every keystroke.
            scheduleDerivedRefresh(for: newValue)
        }
        .onChange(of: windowNumber) { _, newValue in
            // The store can't discover its own window; the view is what learns it. Needed so
            // app-wide open dedupe (EditorTabStore.locate) can bring the owning window forward.
            tabStore.windowNumber = newValue
            registerReloadWatcher()
            installWindowCloseControllerIfNeeded()
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
            // Restore the original window delegate if our intercept is still installed.
            if let controller = windowCloseController, controller.window?.delegate === controller {
                controller.window?.delegate = controller.originalDelegate
            }
            windowCloseController = nil
        }
        .onChange(of: searchQuery) { _, _ in
            handleSearchQueryChange()
        }
        .onChange(of: searchScope) { _, newScope in
            handleSearchScopeChange(newScope)
        }
        .onChange(of: isSearchFocused) { _, focused in
            handleSearchFocusChange(focused)
        }
        // When the deferred Workspace/iCloud scans land, the roots republish. If the user is
        // in All Files with a live query, re-issue the cross-file search so first-ever All
        // Files results are not stale against the pre-scan (empty) snapshot. The model is
        // debounced + latest-wins, so a burst of republishes collapses to one fresh scan.
        // Bundled in a ViewModifier so this large body expression gains only one modifier
        // (the two observers were tipping the type-checker's budget over).
        .modifier(ReissueCrossFileSearchOnRootChange(
            iCloudRoot: fileBrowserStore.iCloudRoot,
            workspaceRoot: fileBrowserStore.workspaceRoot,
            action: reissueCrossFileSearchIfActive
        ))
        .onSubmit(of: .search) {
            handleSearchSubmit()
        }
    }

    private func handleSearchQueryChange() {
        if searchScope == .allFiles {
            updateCrossFileSearch()
        } else {
            refreshSearchMatches(selectFirstWhenNeeded: true, navigatesToActiveMatch: true)
        }
    }

    private func handleSearchScopeChange(_ newScope: EditorSearchScope) {
        switch newScope {
        case .allFiles:
            // Entering All Files: stop the in-file highlight machinery and, first time
            // in this window session, trigger the deferred scans — the same explicit
            // user-gesture trigger ⌘K uses, so the iCloud-laziness invariant holds.
            searchMatches = []
            activeSearchIndex = nil
            if !fileBrowserStore.hasPerformedICloudScan {
                fileBrowserStore.refreshICloud()
                fileBrowserStore.refreshWorkspace()
            }
            updateCrossFileSearch()
        case .thisFile:
            crossFileSearchModel.reset()
            refreshSearchMatches(selectFirstWhenNeeded: true, navigatesToActiveMatch: false)
        }
    }

    /// The full-bleed All Files results page must never outlive the search session it belongs
    /// to. The system search scope bar is only shown while `.searchable` is active/focused; if
    /// the user clears the query and defocuses the search field without explicitly navigating
    /// back to This File, the scope bar disappears but the page would otherwise stay stranded
    /// over the document with no visible search UI (final-review finding; spec "Backing out"
    /// clause — no search residue after dismissing search). A non-empty query keeps the page up,
    /// since the field still shows the query and search is still considered active in that case.
    private func handleSearchFocusChange(_ focused: Bool) {
        guard !focused, searchScope == .allFiles else { return }
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearAllSearchState()
    }

    private func handleSearchSubmit() {
        guard searchScope == .thisFile else { return }
        advanceToNextSearchMatch()
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

        // The tab bar lives INSIDE the view the inspector attaches to, so the Reading drawer
        // presents as a full-height trailing column beside (tab bar + editor) — rising up under
        // the toolbar/search exactly like the no-tab case, with the tab strip ending at the
        // drawer's edge. When the tab bar instead sat ABOVE the inspector's anchor (the old
        // structure), the drawer was pushed below the tab strip and drew its own rounded
        // corner + hairline (a floating panel with "a line around it"), while the toolbar's
        // native inspector section still tinted the area behind the search field — leaving a
        // hard-edged dark patch up there aligned with nothing beneath it.
        // The modal layers (Settings, ⌘K) live INSIDE the inspector's anchor, so their
        // GeometryReader spans only the page column — the card centers between the sidebar
        // edge and the drawer edge, exactly as it already centers beside the sidebar. As
        // ZStack siblings OUTSIDE the inspector they spanned the full detail width, so an
        // open Reading drawer visibly pushed the "centered" card off the page's midline.
        return ZStack {
            VStack(spacing: 0) {
                if tabStore.shouldShowTabBar {
                    TabBarView(
                        tabStore: tabStore,
                        documentSaveStatus: documentSaveStatus,
                        usesDarkChrome: theme.usesDarkChrome,
                        pageBackground: theme.backgroundColor,
                        onSelectTab: switchToTab,
                        onCloseTab: requestCloseTab
                    )
                }
                editorPrimaryShell
            }

            // Settings uses the shared Muse modal language: scrim + centered light
            // card + Esc/outside-click dismissal.
            if isShowingSettings {
                museModalLayer(scrimZIndex: 3, modalZIndex: 4, onDismiss: { isShowingSettings = false }) { geometry in
                    SettingsModal(
                        settings: settings,
                        usesDarkChrome: theme.usesDarkChrome,
                        availableWidth: geometry.size.width
                    ) {
                        isShowingSettings = false
                    }
                }
            }

            // Quick open (⌘K) uses the same shared Muse modal language as Settings:
            // scrim + centered card + Esc/outside-click dismissal.
            if isShowingQuickOpen {
                museModalLayer(scrimZIndex: 5, modalZIndex: 6, onDismiss: { dismissQuickOpen() }) { geometry in
                    QuickOpenPalette(
                        entries: QuickOpenIndex.flatten(
                            iCloudRoot: fileBrowserStore.iCloudRoot,
                            workspaceRoot: fileBrowserStore.workspaceRoot
                        ),
                        query: $quickOpenQuery,
                        usesDarkChrome: theme.usesDarkChrome,
                        availableWidth: geometry.size.width,
                        onOpen: { entry in
                            openSidebarFile(entry.url)
                            dismissQuickOpen()
                        },
                        onDismiss: { dismissQuickOpen() }
                    )
                }
            }
        }
        // NOTE: no SwiftUI background on the anchor can theme the nav band. Without tabs the
        // nav color comes from AppKit extending the detail's root SCROLL VIEW under the
        // titlebar; with the tab strip as the topmost view that extension stops, and a
        // `.background(color)` — with or without .ignoresSafeArea(.top) — never reaches
        // the titlebar region from inside the inspector container (both pixel-verified
        // 2026-07-18). The themed band with tabs comes from the WINDOW's backgroundColor,
        // set to the theme page color in EditorWindowChrome.apply.
        .inspector(isPresented: $isShowingReadingInspector) {
            ReadingExperienceInspector(
                store: readingProfileStore,
                usesDarkChrome: theme.usesDarkChrome,
                pageBackground: theme.backgroundColor,
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
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: SettingsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingSettings
        )
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: SettingsModal.animationDuration), reduceMotion: reduceMotion),
            value: isShowingQuickOpen
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
        MuseModalScrim(
            usesDarkChrome: currentTheme.usesDarkChrome,
            themeID: currentTheme.chromeTintID,
            dismiss: onDismiss
        )
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
                // Keep the arrow cursor over the card too (the editor I-beam otherwise lingers).
                .modalArrowCursor()
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

            // All Files search results: a transient READ-ONLY page over the content area
            // (spec: never a floating card, never a laid-out top strip — as a full-bleed
            // opaque layer inside the existing ZStack it leaves the top-edge hierarchy
            // unchanged, so the translucent toolbar's sampled color cannot shift).
            if searchScope == .allFiles {
                CrossFileSearchResultsView(
                    query: searchQuery,
                    results: crossFileSearchModel.results,
                    isSearching: crossFileSearchModel.isSearching,
                    theme: currentTheme,
                    onOpen: { result in
                        // Only wipe THIS window's results when the document actually landed here.
                        // If it was revealed in another window, the user is still looking at this
                        // results list and will want to click a second hit.
                        openSidebarFile(result.url, whenOpenedHere: clearAllSearchState)
                    },
                    onDismiss: { clearAllSearchState() }
                )
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

    /// Reconnect a broken/unresolved image placeholder: present an image-restricted `NSOpenPanel`,
    /// compute the new link (relative to the document's folder when the picked file is under it,
    /// otherwise absolute), and rewrite `![alt](old)` -> `![alt](new)` at the clicked source range.
    /// Because it mutates `document.text` through the binding like any edit, dirty-tracking,
    /// autosave, and undo (single ⌘Z) all apply. A stale range (the text changed out from under the
    /// render) is a no-op. The `NSOpenPanel` grant gives the app a security scope for the picked
    /// file, so the very next re-render resolves and loads it — no network access.
    private func reconnectImage(at range: NSRange) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff, .bmp, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let dir = currentFileURL?.deletingLastPathComponent()
        let newPath = ImageLinkRewrite.linkPath(for: picked, documentDirectory: dir)
        guard let newText = ImageLinkRewrite.rewritten(in: document.text, at: range, newPath: newPath) else { return }
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

    private func dismissQuickOpen() {
        isShowingQuickOpen = false
        quickOpenQuery = ""
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
                    onCheckboxToggle: toggleCheckbox,
                    onImageReconnect: reconnectImage,
                    onVisibleTopRangeChanged: { activeOutlineSourceRange = $0 },
                    documentDirectory: currentFileURL?.deletingLastPathComponent(),
                    requestedScrollToTopRange: $requestedScrollToTopRange
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
                    onCheckboxToggle: toggleCheckbox,
                    onImageReconnect: reconnectImage,
                    onVisibleTopRangeChanged: { activeOutlineSourceRange = $0 },
                    documentDirectory: currentFileURL?.deletingLastPathComponent(),
                    requestedScrollToTopRange: $requestedScrollToTopRange
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
            requestedScrollToTopRange: $requestedScrollToTopRange,
            profile: readingProfileStore.activeProfile,
            documentDirectory: currentFileURL?.deletingLastPathComponent(),
            smoothsHorizontalInsetChanges: false,
            searchRanges: searchMatches,
            activeSearchRange: activeSearchRange,
            activeTabID: tabStore.selectedTabID,
            liveTabIDs: Set(tabStore.tabs.map(\.id)),
            onWritingToolsSessionChange: { active in
                // Binding writes are deferred during a Writing Tools session, so the reload
                // dirty gate can't see the in-progress edits; suspend external reloads until
                // the session ends (the controller reconciles once on resume).
                reloadController.isWritingToolsSessionActive = active
            },
            onVisibleTopRangeChanged: { activeOutlineSourceRange = $0 }
        )
        // No SwiftUI accessibility modifiers here, deliberately. `LineformTextView` sets its own
        // label, role, and help through AppKit, and it is a real `NSTextView`: VoiceOver reads it
        // by character, word, and line, and tracks the caret, because the system text-area
        // implementation is intact. Wrapping it in a SwiftUI accessibility element to restate the
        // label buys nothing and risks flattening that. The search summary especially does not
        // belong here — the AX *value* of a text area is its text; announcing match counts through
        // it would replace what a VoiceOver user is trying to read. It is spoken as an
        // announcement instead (`announceSearchStatus`).
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
        requestedScrollToTopRange = item.characterRange
        // Bold the clicked heading immediately rather than waiting for the post-scroll report —
        // the report then confirms the same heading (it now parks at the viewport top), so the
        // selection never flickers to a neighbor.
        activeOutlineSourceRange = item.characterRange
        // No mode switch: the Read/Preview view honors the scroll request in place (it maps the
        // source heading range back to rendered position), so an outline click no longer kicks
        // the reader out of Read mode into Write.
    }

    /// `whenOpenedHere` runs only if the document ends up in THIS window, so a caller clearing
    /// window-local state (the cross-file search results page) doesn't wipe it when the document was
    /// revealed in another window. It is a callback rather than a return value because the reveal
    /// path can defer a tick (`.retryReveal`) — a Bool would have to be returned before that
    /// resolves, and the deferred outcome would be silently dropped.
    private func openSidebarFile(
        _ url: URL,
        revealAttemptsRemaining: Int = revealRetryBudget,
        whenOpenedHere: @escaping () -> Void = {}
    ) {
        // Already open somewhere? Reveal it instead of opening a second copy. Two windows holding
        // one file means two in-memory snapshots autosaving over each other — the same data loss the
        // Save As guard refuses, reached from the other direction — so dedupe is app-wide, not just
        // within this window. `preferring: tabStore` keeps a file this window already has from
        // sending the user to some other window that also has it.
        let located = EditorTabStore.locate(url, preferring: tabStore)
        // Resolved ONCE and reused below: re-reading `.window` inside the case would scan
        // NSApp.windows again and could disagree with the decision just made, which would drop the
        // click entirely (no open here, no reveal there).
        let revealWindow = located?.store === tabStore ? nil : located?.store.window
        switch SidebarOpenRoute.route(
            locatedTabID: located?.tabID,
            isOwnStore: located?.store === tabStore,
            revealWindowAvailable: revealWindow != nil,
            canRetry: revealAttemptsRemaining > 0
        ) {
        case .selectHere(let tabID):
            tabStore.selectTab(id: tabID)
            whenOpenedHere()
            return
        case .reveal(let tabID):
            located?.store.selectTab(id: tabID)
            // makeKeyAndOrderFront alone leaves a MINIMIZED window in the Dock, so the click would
            // produce no visible result at all — the file neither opening here nor appearing there.
            if revealWindow?.isMiniaturized == true { revealWindow?.deminiaturize(nil) }
            revealWindow?.makeKeyAndOrderFront(nil)
            return
        case .retryReveal:
            // Re-locates from scratch next tick (deliberately not caching this result): if a second
            // click already opened the file here, the retry finds THAT tab and selects it instead of
            // adding a duplicate.
            DispatchQueue.main.async {
                openSidebarFile(
                    url,
                    revealAttemptsRemaining: revealAttemptsRemaining - 1,
                    whenOpenedHere: whenOpenedHere
                )
            }
            return
        case .openHere:
            break
        }
        do {
            let loadedDocument = try LineformDocument(contentsOf: url)
            let modificationDate = LineformDocument.modificationDate(at: url) ?? Date()
            DocumentSaveStatus.shared.markSaved(
                documentID: loadedDocument.id,
                at: modificationDate,
                text: loadedDocument.text
            )
            tabStore.openTab(document: loadedDocument, fileURL: url)
            whenOpenedHere()
        } catch {
            // Unreadable file: nothing opened anywhere, so the caller keeps its state.
        }
    }

    /// Hands this window's file back to the window that already had it, then closes this one — the
    /// after-the-fact half of open dedupe, covering ⌘O/Finder/CLI/App Intents, which build their
    /// window through DocumentGroup before any of our code can intervene.
    ///
    /// Called from the `currentFileURL` change rather than `onAppear`: a freshly opened window runs
    /// onAppear with BOTH its window number and its file still nil (verified by trace), so there is
    /// nothing to decide on yet.
    ///
    /// Deferred a runloop turn so AppKit has finished opening this window before it is closed, and
    /// re-checked after the hop — closing a window is destructive, so every condition is confirmed
    /// twice and `shouldHandOff` refuses anything but a single-tab, unedited window that lost the
    /// window-number tie-break.
    private func handOffToExistingWindowIfDuplicate() {
        DispatchQueue.main.async {
            guard let url = currentFileURL,
                  let myWindow = activeWindow,
                  let other = EditorTabStore.locate(url, excluding: tabStore),
                  let otherWindow = other.store.window,
                  DuplicateWindowMerge.shouldHandOff(
                    incomingTabCount: tabStore.tabCount,
                    incomingIsEdited: myWindow.isDocumentEdited,
                    incomingWindowNumber: myWindow.windowNumber,
                    existingWindowNumber: otherWindow.windowNumber
                  )
            else { return }

            other.store.selectTab(id: other.tabID)
            if otherWindow.isMiniaturized { otherWindow.deminiaturize(nil) }
            otherWindow.makeKeyAndOrderFront(nil)
            // Close the DOCUMENT, not just the window: this window came from DocumentGroup and its
            // NSDocument would otherwise outlive it. Safe without a save prompt because the guard
            // established the window is unedited and holds nothing but this one file.
            (myWindow.windowController?.document as? NSDocument)?.close()
        }
    }

    /// How many runloop turns a reveal will wait for the owning window to resolve before giving up
    /// and opening the file here. The store learns its window from a binding SwiftUI publishes a
    /// tick or more after the view re-attaches, and re-attach happens on every detail-hierarchy
    /// rebuild (tab bar appearing, reading inspector opening) — one tick is not reliably enough.
    /// Exhausting the budget opens a duplicate, which is the failure this trades against a click
    /// that appears to do nothing; more attempts make that outcome rarer without ever hanging.
    private static let revealRetryBudget = 3

    private func switchToTab(id: UUID) {
        guard id != tabStore.selectedTabID else { return }
        // The outgoing tab's document/displayMode/fileURL are already kept current in the
        // store by the .onChange(of:) syncs, so no explicit snapshot is needed here.
        tabStore.selectTab(id: id)
    }

    private func activateSelectedTab() {
        guard let tab = tabStore.selectedTab else { return }

        guard let backingDocument = activeWindow?.windowController?.document as? NSDocument else {
            // No backing document yet (view appearing before window bind); just load the tab state.
            resetTransientDocumentState()
            document = tab.document
            displayMode = tab.displayMode
            recomputeDerivedNow(for: tab.document.text)
            LineformTextFormatMenuState.shared.setTextFormat(document.textFormat)
            LineformDisplayModeMenuState.shared.setDisplayMode(displayMode)
            return
        }

        // Repoint the NSDocument to the incoming tab's file FIRST, before mutating the
        // binding's document text, so any autosave/Versions operation that fires in this
        // window cannot write the new tab's text to the outgoing tab's file.
        backingDocument.fileURL = tab.fileURL
        backingDocument.fileType = tab.fileURL.map { LineformDocument.contentType(for: $0).identifier }
        backingDocument.fileModificationDate = tab.fileURL.flatMap { LineformDocument.modificationDate(at: $0) }

        resetTransientDocumentState()
        document = tab.document
        displayMode = tab.displayMode
        recomputeDerivedNow(for: tab.document.text)

        // Sync the system dirty state with the incoming tab. Untitled documents with any
        // content are marked edited so the window close sheet prompts to save; a clean saved
        // file is NOT edited (see DocumentTab.hasUnsavedWork — an unconditional emptiness
        // check here previously marked every real file edited, forcing spurious autosaves).
        let isEdited = tab.hasUnsavedWork(documentSaveStatus: documentSaveStatus)
        if isEdited {
            backingDocument.updateChangeCount(.changeDone)
        } else {
            backingDocument.updateChangeCount(.changeCleared)
        }
        activeWindow?.isDocumentEdited = isEdited
        // KNOWN LIMITATION (intentional): tabs share the window's single undo manager, so
        // switching tabs clears undo history — a user cannot ⌘Z edits made in a tab after
        // switching away and back. Per-tab undo stacks are a large, regression-prone change
        // deliberately out of scope. See docs/superpowers/specs/2026-07-18-review-followups-design.md.
        backingDocument.undoManager?.removeAllActions()

        activeWindow?.representedURL = tab.fileURL
        activeWindow?.setTitleWithRepresentedFilename(tab.fileURL?.path ?? tab.title)

        // Defensive re-clear after SwiftUI's async binding registration, but this time
        // preserving the dirty state we just set.
        DispatchQueue.main.async { [weak backingDocument, weak window = activeWindow] in
            guard let backingDocument else { return }
            backingDocument.undoManager?.removeAllActions()
            window?.isDocumentEdited = isEdited
        }

        registerReloadWatcher()
        // A background tab is not watched while inactive, so its file may have been rewritten on
        // disk (Lineform's core use case: an agent edits the .md). registerReloadWatcher just
        // blessed the tab's in-memory snapshot as the synced baseline WITHOUT reading disk, so —
        // for a CLEAN incoming tab — reconcile with disk now. Without this, switching to a clean
        // tab whose file changed externally shows stale content, and the next keystroke autosaves
        // over the external rewrite (silent data loss). A dirty tab is deliberately left untouched:
        // its unsaved edits win, exactly like live reload's .ignoreDirty policy.
        if !isEdited {
            reloadController.fileDidChange()
        }
        LineformTextFormatMenuState.shared.setTextFormat(document.textFormat)
        LineformDisplayModeMenuState.shared.setDisplayMode(displayMode)
    }

    private func requestCloseTab(id: UUID? = nil) {
        let targetID = id ?? tabStore.selectedTabID
        guard let targetID, let tabIndex = tabStore.tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let tab = tabStore.tabs[tabIndex]
        let isDirty = tab.hasUnsavedWork(documentSaveStatus: documentSaveStatus)

        if isDirty {
            tabCloseDialog = TabCloseDialog(tabID: targetID, tabTitle: tab.title)
        } else {
            performCloseTab(id: targetID)
        }
    }

    private func performCloseTab(id: UUID) {
        // Re-activate ONLY when the closed tab was the selected one (closeTab then moves the
        // selection to a sibling). Closing a BACKGROUND tab leaves selectedTabID unchanged, so
        // activating again would needlessly re-run activateSelectedTab against the still-active
        // tab — which clears its live search/Find&Replace + caret (resetTransientDocumentState)
        // and wipes its undo stack (undoManager.removeAllActions). None of that should happen
        // just because the user closed a different tab.
        let wasSelected = (id == tabStore.selectedTabID)
        tabStore.closeTab(id: id)
        if tabStore.tabs.isEmpty {
            activeWindow?.performClose(nil)
        } else if wasSelected {
            activateSelectedTab()
        }
    }

    private func confirmCloseTab(id: UUID) {
        tabCloseDialog = nil
        performCloseTab(id: id)
    }

    private func saveAndCloseTab(id: UUID) {
        tabCloseDialog = nil

        // The document backing the window must be the one we save. Switch first, then
        // save; the coordinator closes the right tab after the save completes.
        if id != tabStore.selectedTabID {
            switchToTab(id: id)
            activateSelectedTab()
        }

        guard let backingDocument = activeWindow?.windowController?.document as? NSDocument else {
            return
        }

        let coordinator = SaveAndCloseCoordinator(
            targetID: id,
            tabStore: tabStore,
            activeWindow: activeWindow,
            document: backingDocument,
            onFinish: { saveAndCloseCoordinator = nil }
        )
        saveAndCloseCoordinator = coordinator
        coordinator.start()
    }

    private func createNewTab() {
        let newDocument = LineformDocument()
        tabStore.openTab(document: newDocument)
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

    private func installWindowCloseControllerIfNeeded() {
        guard let window = activeWindow, windowCloseController?.window !== window else { return }
        let controller = WindowCloseController()
        controller.window = window
        controller.originalDelegate = window.delegate
        controller.tabStore = tabStore
        controller.documentSaveStatus = documentSaveStatus
        controller.saveTabsAndClose = { ids in saveDirtyTabsThenCloseWindow(ids) }
        window.delegate = controller
        windowCloseController = controller
    }

    /// Saves every unsaved tab in `ids` (each made the backing document in turn), then closes
    /// the window. Backs the close-window "Save All" choice. If a save panel is cancelled the
    /// coordinator stops and the window stays open.
    private func saveDirtyTabsThenCloseWindow(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            activeWindow?.performClose(nil)
            return
        }
        let coordinator = SaveTabsBeforeCloseCoordinator(
            tabIDs: ids,
            activateTab: { id in activateTabReturningDocument(id) },
            window: activeWindow,
            onFinish: { saveTabsBeforeCloseCoordinator = nil }
        )
        saveTabsBeforeCloseCoordinator = coordinator
        coordinator.start()
    }

    /// Makes the given tab the window's active/backing document and returns that NSDocument,
    /// so the close-window save loop can save each tab's real document in turn.
    private func activateTabReturningDocument(_ id: UUID) -> NSDocument? {
        if id != tabStore.selectedTabID {
            switchToTab(id: id)
            activateSelectedTab()
        }
        return activeWindow?.windowController?.document as? NSDocument
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
        // Defensive identity re-check at APPLY time. applyDiskSnapshot guards snapshotURL==url at
        // PUBLISH time and sets lastSyncedText to exactly the published text, but a tab switch
        // interleaving between the @Published mutation and this onChange delivery resets
        // lastSyncedText to the incoming tab's text (via register→update). If that happened this
        // result belongs to a file we're no longer showing, so dropping it prevents writing the
        // previous tab's disk content into the now-active document. (The per-tab activation
        // reconcile fires a disk read on every clean switch, widening this window.)
        guard result.text == reloadController.lastSyncedText else {
            reloadController.clearLastReload()
            return
        }
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
        isShowingQuickOpen = false
        quickOpenQuery = ""
        searchScope = .thisFile
        crossFileSearchModel.reset()
        // Drop the cross-mode scroll anchor so a mode switch in the incoming tab never restores
        // the previous document's reading position (activateSelectedTab calls this before setting
        // the tab's displayMode, so the onChange restore sees a cleared anchor).
        activeOutlineSourceRange = nil
        requestedScrollToTopRange = nil
    }

    /// Locked spec behavior: after opening a cross-file result (or backing out), NO search
    /// residue may remain anywhere — empty query, no highlights, scope back to This File
    /// (which also dismisses the results page and, because search deactivates, the system
    /// scope bar), search focus resigned.
    private func clearAllSearchState() {
        searchQuery = ""
        searchMatches = []
        activeSearchIndex = nil
        searchScope = .thisFile
        crossFileSearchModel.reset()
        isSearchFocused = false
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

        announceSearchStatus()
    }

    /// Speak "3 matches, result 1 of 3" when the in-file search result set or the active match
    /// changes.
    ///
    /// Sighted users read this off the match counter beside the field; without an announcement a
    /// VoiceOver user pressing Return in the search field hears nothing at all and cannot tell a
    /// jump from a dead end. It is posted as an `.announcementRequested` rather than attached to
    /// the editor's AX value, which is the document text (see `markdownEditor`). Announcements are
    /// dropped silently when VoiceOver is off, so this costs nothing in the common case.
    private func announceSearchStatus() {
        guard let summary = searchAccessibilitySummary else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: summary,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    /// Kicks off (or re-kicks, debounced inside the model) an All Files scan against the
    /// current sidebar-scanned tree — the same entries ⌘K's QuickOpenPalette uses.
    private func updateCrossFileSearch() {
        crossFileSearchModel.search(
            query: searchQuery,
            entries: QuickOpenIndex.flatten(
                iCloudRoot: fileBrowserStore.iCloudRoot,
                workspaceRoot: fileBrowserStore.workspaceRoot
            )
        )
    }

    /// Re-runs the All Files scan when the scanned roots change, but only while All Files is
    /// the active scope with a non-empty query — otherwise there is nothing to refresh.
    private func reissueCrossFileSearchIfActive() {
        guard searchScope == .allFiles,
              !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        updateCrossFileSearch()
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
        announceSearchStatus()
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
    private func startSpeakingCurrentDocument(_ notification: Notification) {
        guard let payload = notification.object as? LineformAppNotification.Payload else { return }
        let source = speechSource(for: payload)
        speechController.startSpeaking(SpeechTextExtractor.spokenText(from: source))
    }

    /// The text to speak, per the start-point rule: selection → caret-to-end (Write/Split) →
    /// whole document (Read / no caret).
    private func speechSource(for payload: LineformAppNotification.Payload) -> String {
        let ns = document.text as NSString
        // In Read mode the selection range comes from the rendered preview text view
        // (rendered coordinates — markup stripped, images become attachments), while
        // `document.text` is in SOURCE coordinates. The two are not comparable, so a
        // Read-mode selection must never be used to substring source text (it would
        // speak the wrong passage or fail the bounds guard) — fall through to the
        // whole-document branch below. Write/Split selections ARE source-coordinate.
        if displayMode != .read, let range = payload.selectedRange, range.length > 0, NSMaxRange(range) <= ns.length {
            return ns.substring(with: range)
        }
        if displayMode != .read, let range = payload.selectedRange, range.location <= ns.length {
            return ns.substring(from: range.location)
        }
        return document.text
    }

    /// Styled export/print pre-flight: if the document references local images the app can't
    /// currently read, present ONE NSOpenPanel (its `message` is the whole explanation; Cancel =
    /// "continue without") so the user can grant access to include them. Retains the granted
    /// security scopes for the duration of `perform`, then releases them. In-scope documents (the
    /// common case) never see a prompt.
    private func withImageAccessGrantsIfNeeded(documentDirectory: URL?, perform: () -> Void) {
        let unresolved = ImageExportPreflight.unresolvedLocalReferences(
            in: document.text, documentDirectory: documentDirectory)
        var granted: [URL] = []
        if !unresolved.isEmpty {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Grant Access"
            panel.message = "This document uses \(unresolved.count) image\(unresolved.count == 1 ? "" : "s") "
                + "stored outside the folders Lineform can access. Choose the folder or files to "
                + "include them in the PDF, or Cancel to export without them."
            if panel.runModal() == .OK {
                for url in panel.urls where url.startAccessingSecurityScopedResource() {
                    granted.append(url)
                }
            }
        }
        defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }
        perform()
    }

    private func printCurrentDocument() {
        // Print renders the document the way Read mode does (the "Styled" preset uses the user's
        // selected reading profile at document size) — printing what you read, not the raw source.
        let dir = currentFileURL?.deletingLastPathComponent()
        withImageAccessGrantsIfNeeded(documentDirectory: dir) {
            DocumentExportRenderer.runInteractivePrint(
                text: document.text,
                profile: readingProfileStore.activeProfile,
                paper: defaultExportPaperSize,
                preset: .styled,
                documentDirectory: dir
            )
        }
    }

    /// File ▸ Save As… — retargets the document's own .md file. Markdown only: every other
    /// format is File ▸ Export As, which writes a COPY and leaves this document alone.
    private func saveAsDocument() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = "\(base).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel's own "Replace?" warning is about the file on DISK; it says nothing about
            // that file also being open in another tab, whose stale snapshot would autosave right
            // back over whatever we write here. Refuse and name the tab instead of clobbering.
            // Checked against EVERY window's tabs, not just this one's: the other window has no idea
            // its file was rewritten, so a cross-window save is the same data loss. Export needs no
            // such guard — .html/.pdf/.rtf are not openable document types, so no tab holds one.
            if let conflictingTab = SaveAsConflict.conflictingTabTitle(
                destination: url, tabs: EditorTabStore.allOpenTabs, activeTabID: tabStore.selectedTabID) {
                saveAsConflictTabTitle = conflictingTab
                return
            }
            // A real macOS "Save As": drive the backing document's own save-as so the write goes
            // through the FileDocument machinery (recordWrite → the savedAt observer re-points the
            // reload watcher and currentFileURL), and AppKit retargets NSDocument.fileURL — so the
            // open document (and an Untitled one) actually BECOMES this file, autosave following it.
            // A raw Data.write would leave the in-app document detached from the file on disk.
            if let backingDocument = activeWindow?.windowController?.document as? NSDocument {
                let fileType = LineformDocument.contentType(for: url).identifier
                backingDocument.save(to: url, ofType: fileType, for: .saveAsOperation) { error in
                    if error != nil { markdownSaveErrorFileName = url.lastPathComponent }
                }
            } else {
                do {
                    try Data(document.text.utf8).write(to: url, options: .atomic)
                } catch {
                    markdownSaveErrorFileName = url.lastPathComponent
                }
            }
        }

        if let window = activeWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    /// File ▸ Export As ▸ … — writes a COPY in the chosen format. The open document is never
    /// retargeted and never marked dirty.
    private func exportDocument(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let controller = ExportPanelController(
            panel: panel,
            baseName: base,
            format: format,
            paperTitles: ExportPaperSize.allCases.map(\.displayName),
            selectedPaper: ExportPaperSize.allCases.firstIndex(of: defaultExportPaperSize) ?? 0
        )

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let paperIndex = controller.paperPopup.indexOfSelectedItem
            let paper = ExportPaperSize.allCases.indices.contains(paperIndex)
                ? ExportPaperSize.allCases[paperIndex] : .usLetter
            let dir = currentFileURL?.deletingLastPathComponent()

            switch format {
            case .html:
                // The <title> is the document's own name, not the export destination's — the user
                // may be naming the .html file something else entirely.
                let data = DocumentExportRenderer.htmlData(text: document.text, title: base)
                do {
                    // Atomic: a failed write leaves no partial file, and any file being
                    // overwritten survives intact unless the write fully succeeds.
                    try data.write(to: url, options: .atomic)
                } catch {
                    htmlExportErrorFileName = url.lastPathComponent
                }
            case .pdf, .styledPDF:
                let preset: ExportTypographyPreset = (format == .styledPDF) ? .styled : .standard
                // NSPrintOperation writes straight to its target, so a mid-write failure (disk full,
                // render error, crash) would leave a truncated PDF — and when overwriting, it would
                // have already destroyed the file that was there. Staging the render and moving it
                // into place on success means a failed export leaves the destination untouched.
                let runExport = {
                    let succeeded = DocumentExportRenderer.writePDFAtomically(
                        text: document.text,
                        profile: readingProfileStore.activeProfile,
                        paper: paper,
                        preset: preset,
                        documentDirectory: dir,
                        to: url
                    )
                    if !succeeded {
                        pdfExportErrorFileName = url.lastPathComponent
                    }
                }
                if format == .styledPDF {
                    withImageAccessGrantsIfNeeded(documentDirectory: dir, perform: runExport)
                } else {
                    runExport()
                }
            case .rtf:
                do {
                    let data = try DocumentExportRenderer.rtfData(for: document, profile: readingProfileStore.activeProfile, paper: paper)
                    try data.write(to: url, options: .atomic)
                } catch {
                    rtfExportErrorFileName = url.lastPathComponent
                }
            }
        }

        if let window = activeWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
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
                // A real Label (title + icon), NOT the bare icon view: the toolbar shows the
                // icon as before, but the native "»" overflow popover renders the item from its
                // label — a bare icon view appeared there as a tiny orphaned "Aa" glyph, while
                // a Label gets a proper "Reading Experience" menu row.
                Label {
                    Text(action.title)
                } icon: {
                    EditorToolbarIcon(
                        systemImage: action.systemImage,
                        usesDarkChrome: currentTheme.usesDarkChrome
                    )
                }
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

struct TabCloseDialog: Identifiable {
    let id = UUID()
    let tabID: UUID
    let tabTitle: String
}

/// Re-runs the cross-file search when either scanned root changes. Bundled as a modifier so
/// EditorContainerView's very large `body` expression takes only one added modifier rather
/// than two `.onChange`s inline (which pushed the type-checker over its budget).
/// Wires the three Edit ▸ Speech notifications (Start Speaking / Pause·Resume / Stop) plus the
/// menu-state sync for this window's `SpeechController`. Bundled as a modifier for the same
/// type-checker-budget reason as `ReissueCrossFileSearchOnRootChange`.
private struct SpeechNotificationHandlers: ViewModifier {
    let windowNumber: Int?
    @ObservedObject var speechController: SpeechController
    let isKeyWindow: () -> Bool
    let startSpeaking: (Notification) -> Void

    private func matchesActiveWindow(_ notification: Notification) -> Bool {
        guard let payload = notification.object as? LineformAppNotification.Payload else {
            return false
        }
        return payload.matches(windowNumber: windowNumber)
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.startSpeaking.name)) { notification in
                guard matchesActiveWindow(notification) else { return }
                startSpeaking(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.pauseResumeSpeech.name)) { notification in
                guard matchesActiveWindow(notification) else { return }
                speechController.pauseOrResume()
            }
            .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.stopSpeech.name)) { notification in
                guard matchesActiveWindow(notification) else { return }
                speechController.stop()
            }
            .onChange(of: speechController.state) { _, newState in
                if isKeyWindow() {
                    LineformSpeechMenuState.shared.setState(newState)
                }
            }
    }
}

private struct ReissueCrossFileSearchOnRootChange: ViewModifier {
    let iCloudRoot: OutlineFileRoot
    let workspaceRoot: OutlineFileRoot
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: iCloudRoot) { _, _ in action() }
            .onChange(of: workspaceRoot) { _, _ in action() }
    }
}

/// Re-asserts the themed window chrome after the two hierarchy rebuilds that can make AppKit
/// reset it: the tab bar appearing/disappearing and the sidebar column collapsing/expanding.
///
/// The window APPEARANCE is healed deterministically by `WindowChromeReader.ChromeView`'s
/// direct `window.appearance` observation — this modifier does not race that and must never be
/// grown back into a timing-based re-assert (a next-tick + 0.35s pair used to chase the
/// sidebar's mid-animation reset and still lost; see the ChromeView comment for why the drift
/// is invisible to `viewDidChangeEffectiveAppearance`). What remains here covers the rest of
/// `EditorWindowChrome.apply` — notably the window `backgroundColor` that paints the nav band —
/// which no observation watches.
private struct ReassertWindowChromeOnHierarchyRebuild: ViewModifier {
    let isShowingOutline: Bool
    let shouldShowTabBar: Bool
    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: shouldShowTabBar) { _, _ in
                DispatchQueue.main.async { apply() }
            }
            .onChange(of: isShowingOutline) { _, _ in
                DispatchQueue.main.async { apply() }
            }
    }
}

/// The export/save write-failure alerts are identical apart from their title and which piece of
/// state drives them. Extracted into one modifier both to remove four copies of the same block and
/// because four inline `.alert`s in `body` exceeded the type-checker's budget — that fails the
/// BUILD, not just readability.
private struct WriteFailureAlert: ViewModifier {
    let title: String
    @Binding var fileName: String?

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { fileName != nil },
                set: { if !$0 { fileName = nil } }
            ),
            presenting: fileName
        ) { _ in
            Button("OK", role: .cancel) { fileName = nil }
        } message: { name in
            Text("Lineform couldn\u{2019}t write \u{201C}\(name)\u{201D}. Choose a different location and try again.")
        }
    }
}
