import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore: ReadingProfileStore
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))
    @State private var isShowingReadingInspector = false
    @State private var isShowingMarkdownBasics = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline = false
    @State private var outlineItems: [MarkdownOutlineItem] = []
    @State private var requestedSelection: NSRange?
    @State private var selectionAnchorRect: CGRect?
    @State private var searchQuery = ""
    @State private var searchMatches: [NSRange] = []
    @State private var activeSearchIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isIntelligenceRailEnabled: Bool
    @State private var intelligenceInstruction = ""
    @State private var retainedIntelligenceSelection: SelectionContext?
    @State private var isIntelligenceComposerFocused = false
    @State private var intelligentOptions: [IntelligentEditingSuggestion] = []
    @State private var selectedIntelligentOptionIndex = 0
    @State private var currentIntelligentChangeIndex = 0
    @State private var isRunningIntelligentEdit = false
    @State private var intelligentEditingTask: Task<Void, Never>?
    @State private var pendingIntelligentRequest: IntelligentEditingRequest?
    @State private var activeIntelligentEditingRequestID: UUID?
    @State private var intelligentEditingStatus: String?
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    private let intelligentEditingService = FoundationModelsIntelligentEditingService()

    init(
        document: Binding<LineformDocument>,
        initialIntelligenceRailEnabled: Bool = false,
        readingProfileStore: ReadingProfileStore = ReadingProfileStore()
    ) {
        _document = document
        _isIntelligenceRailEnabled = State(initialValue: initialIntelligenceRailEnabled)
        _readingProfileStore = StateObject(wrappedValue: readingProfileStore)
    }

    var body: some View {
        let theme = currentTheme

        NavigationSplitView(columnVisibility: outlineVisibility) {
            OutlineSidebarView(items: outlineItems, jumpToHeading: jumpToHeading)
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
        .searchFocused($isSearchFocused)
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
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.runIntelligentEditingAction.name)) { notification in
            guard
                notificationMatchesActiveWindow(notification),
                let rawValue = notificationPayloadValue(notification),
                let action = IntelligentEditingAction(rawValue: rawValue)
            else {
                return
            }
            runIntelligentEditingAction(action, selectedRange: notificationPayloadSelectedRange(notification))
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
        }
        .onChange(of: document.textFormat) { _, newValue in
            LineformTextFormatMenuState.shared.setTextFormat(newValue)
        }
        .onChange(of: document.text) { _, newValue in
            documentStatistics = DocumentStatistics(text: newValue)
            outlineItems = MarkdownOutlineParser().items(in: newValue)
            if let retainedIntelligenceSelection {
                let refreshedSelection = SelectionContext(
                    text: newValue,
                    selectedRange: retainedIntelligenceSelection.selectedRange
                )
                self.retainedIntelligenceSelection = refreshedSelection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : refreshedSelection
            }
            refreshSearchMatches(selectFirstWhenNeeded: activeSearchIndex == nil, navigatesToActiveMatch: false)
            if let activeIntelligentSuggestion, !activeIntelligentSuggestion.canApply(to: newValue) {
                clearIntelligentSuggestions()
                intelligentEditingStatus = "Suggestion expired after edits."
            }
        }
        .onChange(of: selectionContext) { _, newValue in
            refreshRetainedIntelligenceSelection(from: newValue)
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
                        statusIndicator: statusIndicator,
                        statisticsText: statisticsText,
                        statusAccessibilityLabel: statusAccessibilityLabel,
                        usesDarkChrome: currentTheme.usesDarkChrome
                    )
                }
            }

            if IntelligenceActionRailPresentation.isVisible(
                isEnabled: isIntelligenceRailEnabled,
                hasSelection: hasVisibleIntelligenceComposerSelection,
                displayMode: displayMode
            ) {
                IntelligenceInstructionComposer(
                    instruction: $intelligenceInstruction,
                    isActionEnabled: intelligenceComposerIsEnabled,
                    isLoading: isPreparingIntelligentSuggestion,
                    usesDarkChrome: currentTheme.usesDarkChrome,
                    reduceMotion: reduceMotion,
                    allowsAutomaticFocus: !isSearchFocused,
                    onFocusChanged: { isFocused in
                        isIntelligenceComposerFocused = isFocused
                        if !isFocused {
                            clearRetainedIntelligenceSelectionIfIdle()
                        }
                    },
                    submitInstruction: { instruction in
                        runIntelligentEditingRequest(.custom(instruction))
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    .asymmetric(
                        insertion: EditorMotionPolicy.fadeAndMoveTransition(
                            y: IntelligenceActionRailPresentation.entranceYOffset,
                            reduceMotion: reduceMotion
                        ),
                        removal: EditorMotionPolicy.fadeAndMoveTransition(
                            y: IntelligenceActionRailPresentation.entranceYOffset / 2,
                            reduceMotion: reduceMotion
                        )
                    )
                )
                .zIndex(1)
            }

            if shouldShowIntelligentOptionsPanel {
                GeometryReader { proxy in
                    let panelReferenceText = activeIntelligentSuggestion?.originalText ?? ""
                    let panelPlacementText = activeIntelligentSuggestion.map {
                        IntelligentEditingProofreadChangeReview.previewText(
                            for: $0,
                            changeIndex: currentIntelligentChangeIndex
                        )
                    } ?? ""
                    let placement = IntelligentEditingOverlayPlacement.placement(
                        anchorRect: selectionAnchorRect,
                        containerSize: proxy.size,
                        replacementText: panelPlacementText
                    )

                    IntelligentEditingOptionsPanel(
                        suggestions: intelligentOptions,
                        selectedIndex: $selectedIntelligentOptionIndex,
                        currentChangeIndex: $currentIntelligentChangeIndex,
                        loadingPreviewText: panelReferenceText,
                        maximumBodyHeight: placement.bodyHeight,
                        usesDarkChrome: currentTheme.usesDarkChrome,
                        navigateToChange: navigateToSuggestedChange,
                        retry: retryIntelligentSuggestion,
                        acceptAll: acceptAllIntelligentSuggestion,
                        accept: acceptIntelligentSuggestion,
                        reject: rejectIntelligentSuggestion
                    )
                    .frame(maxWidth: placement.width)
                    .position(placement.position)
                }
                .transition(EditorMotionPolicy.scaleAndFadeTransition(scale: 0.98, reduceMotion: reduceMotion))
                .zIndex(2)
            }
        }
        .background(Color(nsColor: currentTheme.backgroundColor))
        .animation(EditorMotionPolicy.animation(.easeOut(duration: 0.18), reduceMotion: reduceMotion), value: intelligentOptions)
        .animation(
            EditorMotionPolicy.animation(
                .easeOut(duration: IntelligenceActionRailPresentation.animationDuration),
                reduceMotion: reduceMotion
            ),
            value: isIntelligenceRailEnabled
        )
        .animation(
            EditorMotionPolicy.animation(
                .easeOut(duration: IntelligenceActionRailPresentation.animationDuration),
                reduceMotion: reduceMotion
            ),
            value: hasActiveIntelligentSelection
        )
        .animation(
            EditorMotionPolicy.animation(
                .easeOut(duration: IntelligenceActionRailPresentation.animationDuration),
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
            selectionContext: $selectionContext,
            requestedSelection: $requestedSelection,
            selectionAnchorRect: $selectionAnchorRect,
            profile: readingProfileStore.activeProfile,
            smoothsHorizontalInsetChanges: false,
            intelligentSuggestionRange: activeIntelligentSuggestion?.selectedRange,
            searchRanges: searchMatches,
            activeSearchRange: activeSearchRange
        )
        .accessibilityLabel("Markdown editor")
        .accessibilityValue(searchAccessibilitySummary ?? "")
    }

    private var activeIntelligentSuggestion: IntelligentEditingSuggestion? {
        guard !intelligentOptions.isEmpty else {
            return nil
        }

        let safeIndex = min(max(selectedIntelligentOptionIndex, 0), intelligentOptions.count - 1)
        return intelligentOptions[safeIndex]
    }

    private var shouldShowIntelligentOptionsPanel: Bool {
        IntelligentEditingOptionsPresentation.isVisible(
            isPreparingSuggestion: isPreparingIntelligentSuggestion,
            hasSuggestions: !intelligentOptions.isEmpty
        )
    }

    private var isPreparingIntelligentSuggestion: Bool {
        IntelligentEditingRequestLifecycle.isPreparingSuggestion(
            isRunning: isRunningIntelligentEdit,
            pendingRequest: pendingIntelligentRequest,
            activeRequestID: activeIntelligentEditingRequestID
        )
    }

    private var hasActionableIntelligentSelection: Bool {
        !selectionContext.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeIntelligenceSelection: SelectionContext? {
        IntelligenceInstructionComposerState.activeSelection(
            current: selectionContext,
            retained: retainedIntelligenceSelection
        )
    }

    private var hasActiveIntelligentSelection: Bool {
        activeIntelligenceSelection != nil
    }

    private var hasVisibleIntelligenceComposerSelection: Bool {
        IntelligenceInstructionComposerState.hasVisibleSelection(
            current: selectionContext,
            retained: retainedIntelligenceSelection,
            isPreparingSuggestion: isPreparingIntelligentSuggestion
        )
    }

    private var intelligenceComposerIsEnabled: Bool {
        hasActiveIntelligentSelection
            && !isRunningIntelligentEdit
            && IntelligenceAvailabilityService().currentStatus().isAvailable
            && !intelligenceInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var statusIndicator: EditorStatusIndicator {
        EditorStatusFormatter.statusIndicator(
            isPreparingSuggestion: isPreparingIntelligentSuggestion,
            intelligentEditingStatus: intelligentEditingStatus,
            intelligenceAvailability: IntelligenceAvailabilityService().currentStatus()
        )
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

    private func runIntelligentEditingAction(_ action: IntelligentEditingAction, selectedRange overrideSelectedRange: NSRange? = nil) {
        runIntelligentEditingRequest(.action(action), selectedRange: overrideSelectedRange)
    }

    private func runIntelligentEditingRequest(_ request: IntelligentEditingRequest, selectedRange overrideSelectedRange: NSRange? = nil) {
        guard !isRunningIntelligentEdit else {
            return
        }

        let editingContext = SelectionContext(
            text: document.text,
            selectedRange: overrideSelectedRange ?? activeIntelligenceSelection?.selectedRange ?? selectionContext.selectedRange
        )

        guard !editingContext.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            intelligentEditingStatus = "Select text to use Intelligence."
            return
        }

        isRunningIntelligentEdit = true
        pendingIntelligentRequest = request
        let requestID = UUID()
        activeIntelligentEditingRequestID = requestID
        clearIntelligentSuggestions()
        intelligentEditingStatus = nil
        if request.usesUserInstruction {
            intelligenceInstruction = ""
            clearRetainedIntelligenceSelectionIfIdle()
        }

        let task = Task {
            let coordinator = IntelligentEditingRequestCoordinator(service: intelligentEditingService)
            let result = await coordinator.run(
                request: request,
                documentText: editingContext.text,
                currentDocumentText: editingContext.text,
                selectedRange: editingContext.selectedRange
            )

            let isCancelled = Task.isCancelled
            await MainActor.run {
                guard IntelligentEditingRequestLifecycle.canPublishResult(
                    activeRequestID: activeIntelligentEditingRequestID,
                    completingRequestID: requestID,
                    isCancelled: isCancelled
                ) else {
                    return
                }

                switch result {
                case .ready(let suggestions, _):
                    isRunningIntelligentEdit = false
                    intelligentEditingTask = nil
                    pendingIntelligentRequest = nil
                    activeIntelligentEditingRequestID = nil
                    let applicableSuggestions = suggestions.filter { $0.canApply(to: document.text) }
                    guard !applicableSuggestions.isEmpty else {
                        clearIntelligentSuggestions()
                        intelligentEditingStatus = "Suggestion expired after edits."
                        return
                    }
                    intelligentOptions = applicableSuggestions
                    selectedIntelligentOptionIndex = 0
                    currentIntelligentChangeIndex = 0
                    intelligentEditingStatus = IntelligentEditingRequestCoordinator.readyStatus(for: applicableSuggestions.count)
                    requestedSelection = applicableSuggestions[0].selectedRange

                case .expired(let message), .failed(let message):
                    clearIntelligentSuggestions()
                    isRunningIntelligentEdit = false
                    intelligentEditingTask = nil
                    pendingIntelligentRequest = nil
                    activeIntelligentEditingRequestID = nil
                    intelligentEditingStatus = message
                }
            }
        }
        intelligentEditingTask = task
    }

    private func navigateToSuggestedChange(_ change: MarkdownDiff.Change) {
        guard let intelligentSuggestion = activeIntelligentSuggestion else {
            return
        }

        requestedSelection = NSRange(
            location: intelligentSuggestion.selectedRange.location + change.replacementRange.location,
            length: max(change.replacementRange.length, 1)
        )
    }

    private func acceptIntelligentSuggestion() {
        if acceptCurrentProofreadChange() {
            return
        }

        acceptAllIntelligentSuggestion()
    }

    private func acceptAllIntelligentSuggestion() {
        guard let intelligentSuggestion = activeIntelligentSuggestion else {
            return
        }

        guard let updatedText = intelligentSuggestion.accept(in: document.text) else {
            clearIntelligentSuggestions()
            intelligentEditingStatus = "Suggestion expired after edits."
            return
        }

        document.text = updatedText
        requestedSelection = IntelligentEditingSelectionDismissal.acceptedCaretSelection(for: intelligentSuggestion)
        retainedIntelligenceSelection = nil
        clearIntelligentSuggestions()
        intelligentEditingStatus = "Suggestion accepted."
    }

    private func acceptCurrentProofreadChange() -> Bool {
        guard let intelligentSuggestion = activeIntelligentSuggestion,
              intelligentOptions.count == 1,
              !IntelligentEditingProofreadChangeReview.items(for: intelligentSuggestion).isEmpty
        else {
            return false
        }

        guard let acceptance = IntelligentEditingProofreadChangeReview.acceptChange(
            in: document.text,
            suggestion: intelligentSuggestion,
            changeIndex: currentIntelligentChangeIndex
        ) else {
            clearIntelligentSuggestions()
            intelligentEditingStatus = "Suggestion expired after edits."
            return true
        }

        document.text = acceptance.documentText

        guard let remainingSuggestion = acceptance.remainingSuggestion else {
            requestedSelection = IntelligentEditingSelectionDismissal.acceptedCaretSelection(for: intelligentSuggestion)
            retainedIntelligenceSelection = nil
            clearIntelligentSuggestions()
            intelligentEditingStatus = "Suggestion accepted."
            return true
        }

        intelligentOptions = [remainingSuggestion]
        selectedIntelligentOptionIndex = 0
        currentIntelligentChangeIndex = min(currentIntelligentChangeIndex, remainingSuggestion.diff.changes.count - 1)
        let nextChange = remainingSuggestion.diff.changes[currentIntelligentChangeIndex]
        requestedSelection = NSRange(
            location: remainingSuggestion.selectedRange.location + nextChange.replacementRange.location,
            length: max(nextChange.replacementRange.length, 1)
        )
        intelligentEditingStatus = "Change accepted."
        return true
    }

    private func retryIntelligentSuggestion() {
        guard let intelligentSuggestion = activeIntelligentSuggestion else {
            return
        }

        runIntelligentEditingRequest(intelligentSuggestion.request, selectedRange: intelligentSuggestion.selectedRange)
    }

    private func rejectIntelligentSuggestion() {
        if isRunningIntelligentEdit {
            intelligentEditingTask?.cancel()
            intelligentEditingTask = nil
            isRunningIntelligentEdit = false
            pendingIntelligentRequest = nil
            activeIntelligentEditingRequestID = nil
            clearIntelligentSuggestions()
            intelligentEditingStatus = "Suggestion canceled."
            return
        }

        if let activeIntelligentSuggestion {
            requestedSelection = IntelligentEditingSelectionDismissal.rejectedCaretSelection(for: activeIntelligentSuggestion)
        }
        retainedIntelligenceSelection = nil
        clearIntelligentSuggestions()
        intelligentEditingStatus = "Suggestion rejected."
    }

    private func clearIntelligentSuggestions() {
        intelligentOptions = []
        selectedIntelligentOptionIndex = 0
        currentIntelligentChangeIndex = 0
    }

    private func refreshRetainedIntelligenceSelection(from nextSelection: SelectionContext) {
        if !nextSelection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            retainedIntelligenceSelection = nextSelection
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            clearRetainedIntelligenceSelectionIfIdle()
        }
    }

    private func clearRetainedIntelligenceSelectionIfIdle() {
        if IntelligenceInstructionComposerState.shouldClearRetainedSelection(
            current: selectionContext,
            isFocused: isIntelligenceComposerFocused,
            instruction: intelligenceInstruction,
            isPreparingSuggestion: isPreparingIntelligentSuggestion
        ) {
            retainedIntelligenceSelection = nil
        }
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
        case .intelligence, .markdownBasics, .readingExperience:
            let isActive = toolbarActionIsActive(action)
            Button {
                handleToolbarAction(action)
            } label: {
                IntelligenceToolbarIcon(
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
        case .intelligence:
            isIntelligenceRailEnabled.toggle()
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
            isIntelligenceRailEnabled: isIntelligenceRailEnabled,
            isShowingMarkdownBasics: isShowingMarkdownBasics,
            isShowingReadingInspector: isShowingReadingInspector
        )
    }

    private func toolbarHelp(for action: EditorToolbarAction) -> String {
        switch action {
        case .intelligence:
            return isIntelligenceRailEnabled ? "Hide Intelligence Actions" : "Show Intelligence Actions"
        case .markdownBasics, .readingExperience:
            return action.title
        }
    }
}
