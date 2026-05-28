import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
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
    @State private var intelligentEditingStatus: String?
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    private let intelligentEditingService = FoundationModelsIntelligentEditingService()

    init(document: Binding<LineformDocument>, initialIntelligenceRailEnabled: Bool = false) {
        _document = document
        _isIntelligenceRailEnabled = State(initialValue: initialIntelligenceRailEnabled)
    }

    var body: some View {
        let theme = currentTheme

        NavigationSplitView(columnVisibility: outlineVisibility) {
            OutlineSidebarView(items: outlineItems, jumpToHeading: jumpToHeading)
                .environment(\.colorScheme, .light)
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
            HStack(spacing: 0) {
                editorPrimaryShell
                    .frame(minWidth: EditorLayout.minimumContentWidth, maxWidth: .infinity, maxHeight: .infinity)

                ZStack(alignment: .leading) {
                    ReadingExperienceInspector(store: readingProfileStore, usesDarkChrome: theme.usesDarkChrome)
                        .frame(
                            minWidth: EditorAuxiliaryPresentation.readingExperience.minimumWidth ?? 280,
                            idealWidth: EditorAuxiliaryPresentation.readingExperience.idealWidth ?? 320,
                            maxWidth: EditorAuxiliaryPresentation.readingExperience.maximumWidth ?? 380,
                            maxHeight: .infinity
                        )
                        .id(theme.usesDarkChrome)
                        .accessibilityLabel(EditorAuxiliaryPresentation.readingExperience.accessibilityLabel)
                        .opacity(isShowingReadingInspector ? 1 : 0)
                        .accessibilityHidden(!isShowingReadingInspector)
                }
                .frame(
                    width: isShowingReadingInspector
                        ? EditorAuxiliaryPresentation.readingExperience.idealWidth ?? 320
                        : 0,
                    alignment: .leading
                )
                .clipped()
                .allowsHitTesting(isShowingReadingInspector)
            }
            .animation(
                EditorMotionPolicy.animation(
                    .linear(duration: EditorInspectorTextResponse.transitionDuration),
                    reduceMotion: reduceMotion
                ),
                value: isShowingReadingInspector
            )

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
                    isLoading: isRunningIntelligentEdit && pendingIntelligentRequest != nil,
                    usesDarkChrome: currentTheme.usesDarkChrome,
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
                    let placement = IntelligentEditingOverlayPlacement.placement(
                        anchorRect: selectionAnchorRect,
                        containerSize: proxy.size,
                        replacementText: activeIntelligentSuggestion?.replacementText ?? ""
                    )

                    IntelligentEditingOptionsPanel(
                        suggestions: intelligentOptions,
                        selectedIndex: $selectedIntelligentOptionIndex,
                        loadingPreviewText: panelReferenceText,
                        maximumBodyHeight: placement.bodyHeight,
                        retry: retryIntelligentSuggestion,
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
            isPreparingSuggestion: isRunningIntelligentEdit && pendingIntelligentRequest != nil,
            hasSuggestions: !intelligentOptions.isEmpty
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
            isPreparingSuggestion: isRunningIntelligentEdit && pendingIntelligentRequest != nil
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
            isPreparingSuggestion: isRunningIntelligentEdit,
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

            await MainActor.run {
                switch result {
                case .ready(let suggestions, _):
                    isRunningIntelligentEdit = false
                    intelligentEditingTask = nil
                    pendingIntelligentRequest = nil
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
        guard let intelligentSuggestion = activeIntelligentSuggestion else {
            return
        }

        guard let updatedText = intelligentSuggestion.accept(in: document.text) else {
            clearIntelligentSuggestions()
            intelligentEditingStatus = "Suggestion expired after edits."
            return
        }

        document.text = updatedText
        requestedSelection = NSRange(location: intelligentSuggestion.selectedRange.location, length: (intelligentSuggestion.replacementText as NSString).length)
        clearIntelligentSuggestions()
        intelligentEditingStatus = "Suggestion accepted."
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
            clearIntelligentSuggestions()
            intelligentEditingStatus = "Suggestion canceled."
            return
        }

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
            instruction: intelligenceInstruction
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

        if let animation = EditorMotionPolicy.animation(
            .linear(duration: EditorInspectorTextResponse.transitionDuration),
            reduceMotion: reduceMotion
        ) {
            withAnimation(animation) {
                isShowingReadingInspector = isVisible
            }
        } else {
            isShowingReadingInspector = isVisible
        }
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

enum EditorReadingLayout {
    static func textColumnMaxWidth(for profile: ReadingProfile) -> CGFloat {
        CGFloat(profile.columnWidth)
    }

    static func horizontalInset(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(CGFloat(profile.marginWidth), (containerWidth - textColumnMaxWidth(for: profile)) / 2)
    }

    static func textContainerWidth(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(0, containerWidth - (horizontalInset(forContainerWidth: containerWidth, profile: profile) * 2))
    }
}

enum EditorLayout {
    static let minimumContentWidth: CGFloat = 300
    static let minimumContentHeight: CGFloat = 480
}

enum EditorInspectorTextResponse {
    static let smoothsHorizontalInsetChanges = false
    static let usesPresentationLayerHorizontalSmoothing = false
    static let preservesVerticalAnchorDuringPresentationSmoothing = false
    static let usesExplicitPresentationOffsetAnimation = false
    static let allowsImplicitContentAnimationDuringPresentationSmoothing = false
    static let transitionDuration: TimeInterval = 0.18
    static let horizontalInsetAnimationDuration: TimeInterval = transitionDuration
    static let presentationOffsetAnimationDuration = transitionDuration
    static let presentationOffsetDistance: CGFloat = 0

    static func presentationOffset(opening: Bool, reduceMotion: Bool) -> CGFloat {
        guard usesPresentationLayerHorizontalSmoothing, !reduceMotion else {
            return 0
        }

        return opening ? presentationOffsetDistance : -presentationOffsetDistance
    }
}

enum IntelligentEditingOverlayPlacement {
    struct Placement: Equatable {
        let position: CGPoint
        let width: CGFloat
        let bodyHeight: CGFloat?
    }

    static func placement(anchorRect: CGRect?, containerSize: CGSize, replacementText: String) -> Placement {
        let mode = IntelligentEditingOptionsPresentation.presentation(for: replacementText)
        let maxWidth = mode == .expandedReview
            ? IntelligentEditingOptionsPresentation.expandedMaximumWidth
            : IntelligentEditingOptionsPresentation.compactMaximumWidth
        let estimatedHeight = mode == .expandedReview
            ? min(IntelligentEditingOptionsPresentation.expandedEstimatedHeight, max(240, containerSize.height - 80))
            : IntelligentEditingOptionsPresentation.compactEstimatedHeight
        let bodyHeight = mode == .expandedReview ? max(180, estimatedHeight - 140) : nil
        let width = min(maxWidth, max(260, containerSize.width - 48))
        let anchor = anchorRect ?? CGRect(x: containerSize.width / 2, y: 96, width: 0, height: 0)
        let x = min(max(anchor.midX, width / 2 + 24), containerSize.width - width / 2 - 24)
        let preferredY = anchor.maxY + 16 + estimatedHeight / 2
        let fallbackY = anchor.minY - 16 - estimatedHeight / 2
        let y: CGFloat

        if preferredY + estimatedHeight / 2 <= containerSize.height - 24 {
            y = preferredY
        } else if fallbackY - estimatedHeight / 2 >= 24 {
            y = fallbackY
        } else {
            y = min(max(preferredY, estimatedHeight / 2 + 24), containerSize.height - estimatedHeight / 2 - 24)
        }

        return Placement(position: CGPoint(x: x, y: y), width: width, bodyHeight: bodyHeight)
    }
}

enum EditorToolbarVisibility {
    static func showsMarkdownBasics(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }

    static func showsIntelligence(in mode: EditorDisplayMode) -> Bool {
        mode == .write
    }
}

enum IntelligenceActionRailPresentation {
    static let placement = IntelligenceActionRailPlacement.bottomCenter
    static let bottomInset: CGFloat = 30
    static let transitionStyle = EditorAuxiliaryTransitionStyle.fadeAndMoveUp
    static let animationDuration = 0.24
    static let entranceYOffset: CGFloat = 10
    static let usesHorizontalLayout = true
    static let showsActionLabels = true
    static let buttonWidth: CGFloat = 88
    static let buttonHeight: CGFloat = 52
    static let iconSize: CGFloat = 15
    static let labelSize: CGFloat = 10
    static let cornerRadius: CGFloat = 12
    static let railSpacing: CGFloat = 10
    static let backgroundRedComponent: CGFloat = 0.90
    static let backgroundGreenComponent: CGFloat = 0.95
    static let backgroundBlueComponent: CGFloat = 1.0
    static let hoverBackgroundRedComponent: CGFloat = 0.80
    static let hoverBackgroundGreenComponent: CGFloat = 0.90
    static let hoverBackgroundBlueComponent: CGFloat = 1.0
    static let backgroundAlpha: CGFloat = 1.0
    static let borderOpacity = 0.55
    static let hoverBorderOpacity = 0.95
    static let disabledContentOpacity = 0.45
    static let shadowOpacity = 0.035
    static let shadowRadius: CGFloat = 5
    static let shadowYOffset: CGFloat = 1
    static let supportsHoverState = true
    static let hoverFeedbackRequiresEnabledAction = false
    static let usesRestoringHoverCursor = true
    static let usesAppKitCursorRect = true
    static let usesAppKitHoverTracking = true
    static let reassertsHoverCursorOnEnter = true
    static let hoverCursor = IntelligenceActionRailHoverCursor.pointingHand
    static let restoresPreviousCursorOnExit = true
    static let restoresPreviousCursorOnDisappear = true
    static let usesAccentTint = true

    static func isVisible(isEnabled: Bool, hasSelection: Bool, displayMode: EditorDisplayMode) -> Bool {
        isEnabled && hasSelection && displayMode == .write
    }

    static func backgroundColor(isHovered: Bool) -> Color {
        Color(
            nsColor: NSColor(
                srgbRed: isHovered ? hoverBackgroundRedComponent : backgroundRedComponent,
                green: isHovered ? hoverBackgroundGreenComponent : backgroundGreenComponent,
                blue: isHovered ? hoverBackgroundBlueComponent : backgroundBlueComponent,
                alpha: backgroundAlpha
            )
        )
    }

    static func borderColor(isHovered: Bool) -> Color {
        Color.accentColor.opacity(isHovered ? hoverBorderOpacity : borderOpacity)
    }
}

enum IntelligenceInstructionComposerPresentation {
    static let prompt = "Tell AI what to do..."
    static let submitSystemImage = "arrow.up"
    static let inputAccessibilityLabel = "AI instruction"
    static let inputAccessibilityHelp = "Describe how Lineform should edit the selected text."
    static let submitAccessibilityLabel = "Run AI instruction"
    static let submitAccessibilityHelp = "Apply the typed AI instruction to the selected text."
    static let usesFixedShortcutButtons = false
    static let animatesSelectionVisibilityChanges = true
    static let usesStableNativePlaceholder = true
    static let darkensWhenFocused = false
    static let showsBorderWhenFocused = true
    static let showsFocusedBorderBeforeTyping = true
    static let sendButtonSupportsHoverState = true
    static let usesWhiteCapsuleBackground = false
    static let usesLightBlueCapsuleBackground = true
    static let usesNavPillLikeShadow = true
    static let usesInlineLoadingState = true
    static let usesExistingSkeletonShimmerForLoading = true
    static let usesNeutralLoadingChrome = true
    static let showsLoadingSpinnerInSubmitSlot = false
    static let loadingStatePreservesCapsuleDimensions = true
    static let loadingSkeletonMinimumRows = 4
    static let loadingSkeletonColumns = 48
    static let loadingSkeletonBlockHeight: CGFloat = 4
    static let loadingSkeletonSpacing: CGFloat = 2
    static let loadingSkeletonMinimumCellWidth: CGFloat = 6
    static let loadingSkeletonMinimumBlockWidth: CGFloat = 7
    static let loadingSkeletonTextSlotHeight: CGFloat = 24
    static var loadingSkeletonGridHeight: CGFloat {
        CGFloat(loadingSkeletonMinimumRows) * loadingSkeletonBlockHeight
            + CGFloat(loadingSkeletonMinimumRows - 1) * loadingSkeletonSpacing
    }
    static var loadingSkeletonCapsuleInset: CGFloat {
        (height - loadingSkeletonGridHeight) / 2
    }
    static let maximumWidth: CGFloat = 560
    static let height: CGFloat = 52
    static let horizontalPadding: CGFloat = 14
    static let cornerRadius: CGFloat = 18
    static let backgroundOpacity = 1.0
    static let borderOpacity = 0.65
    static let disabledOpacity = 0.38
    static let sendButtonSize: CGFloat = 30
    static let sendButtonSymbolPointSize: CGFloat = 16
    static let sendButtonUsesFilledAccentBackground = true
    static let sendButtonUsesWhiteSymbol = true
    static let sendButtonHoverBackgroundOpacity = 0.28
    static let shadowOpacity = 0.08
    static let shadowRadius: CGFloat = 16
    static let shadowYOffset: CGFloat = 4

    static func usesDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func backgroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor(srgbRed: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0, alpha: 1)
            : .actionRailBackground(isHovered: false)
    }

    static func loadingBackgroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor(srgbRed: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0, alpha: 1)
            : .windowBackgroundColor
    }

    static func borderColor(usesDarkAppearance: Bool, isFocused: Bool) -> NSColor {
        if usesDarkAppearance {
            return NSColor.white.withAlphaComponent(isFocused ? 0.95 : 0.78)
        }

        return NSColor.controlAccentColor.withAlphaComponent(
            isFocused ? IntelligenceActionRailPresentation.hoverBorderOpacity : 0
        )
    }

    static func loadingBorderColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.7)
            : NSColor.separatorColor.withAlphaComponent(0.75)
    }

    static func foregroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? .white : .labelColor
    }

    static func insertionPointColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? .white : .controlAccentColor
    }

    static func iconColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? .white : .controlAccentColor
    }

    static func placeholderColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? NSColor.white.withAlphaComponent(0.62) : .placeholderTextColor
    }

    static func sendButtonFillColor(
        usesDarkAppearance: Bool,
        isHovered: Bool,
        isEnabled: Bool
    ) -> NSColor {
        let baseColor: NSColor
        if usesDarkAppearance {
            baseColor = isHovered ? NSColor.white.withAlphaComponent(0.84) : .white
        } else {
            let accentColor = NSColor.controlAccentColor
            baseColor = isHovered
                ? accentColor.blended(withFraction: 0.14, of: .black) ?? accentColor
                : accentColor
        }

        return baseColor.withAlphaComponent(isEnabled ? baseColor.alphaComponent : disabledOpacity)
    }

    static func sendButtonSymbolColor(usesDarkAppearance: Bool, isEnabled: Bool) -> NSColor {
        let baseColor: NSColor = usesDarkAppearance ? .black : .white
        return baseColor.withAlphaComponent(isEnabled ? 1 : disabledOpacity)
    }
}

enum IntelligenceInstructionComposerState {
    static func activeSelection(current: SelectionContext, retained: SelectionContext?) -> SelectionContext? {
        if !current.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return current
        }

        guard
            let retained,
            !retained.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return retained
    }

    static func hasVisibleSelection(
        current: SelectionContext,
        retained: SelectionContext?,
        isPreparingSuggestion: Bool
    ) -> Bool {
        isPreparingSuggestion || activeSelection(current: current, retained: retained) != nil
    }

    static func shouldClearRetainedSelection(
        current: SelectionContext,
        isFocused: Bool,
        instruction: String
    ) -> Bool {
        current.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isFocused
            && instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum IntelligenceActionRailPlacement: Equatable {
    case bottomCenter
}

enum IntelligenceActionRailHoverCursor: Equatable {
    case pointingHand
}

enum IntelligenceToolbarTogglePresentation {
    static let usesNativeToolbarButtonShell = true
    static let outerButtonWidth: CGFloat? = nil
    static let iconFillDiameter: CGFloat = 20
    static let fillOpacityWhenOn = 1.0
    static let usesWhiteIconWhenOn = true
    static let iconOpacityWhenOn = 1.0
    static let iconOpacityWhenOff = 0.72
}

enum EditorToolbarPressedState {
    static let usesFilledActiveIcon = true
    static let usesWhiteActiveIcon = true
    static let replacesActiveSymbolWithCloseAction = true
    static let closeSystemImage = "xmark"
    static let closeSymbolScale = 0.67
    static let openSymbolTransition = EditorToolbarSymbolTransitionStyle.replaceOffUp
    static let closeSymbolTransition = EditorToolbarSymbolTransitionStyle.instant

    static func isActive(
        _ action: EditorToolbarAction,
        isIntelligenceRailEnabled: Bool,
        isShowingMarkdownBasics: Bool,
        isShowingReadingInspector: Bool
    ) -> Bool {
        switch action {
        case .intelligence:
            return isIntelligenceRailEnabled
        case .markdownBasics:
            return isShowingMarkdownBasics
        case .readingExperience:
            return isShowingReadingInspector
        }
    }

    static func activeActions(
        isIntelligenceRailEnabled: Bool,
        isShowingMarkdownBasics: Bool,
        isShowingReadingInspector: Bool
    ) -> [EditorToolbarAction] {
        EditorToolbarAction.allCases.filter {
            isActive(
                $0,
                isIntelligenceRailEnabled: isIntelligenceRailEnabled,
                isShowingMarkdownBasics: isShowingMarkdownBasics,
                isShowingReadingInspector: isShowingReadingInspector
            )
        }
    }

    static func displaySystemImage(for action: EditorToolbarAction, isActive: Bool) -> String {
        isActive ? closeSystemImage : action.systemImage
    }

    static func displaySymbolScale(for action: EditorToolbarAction, isActive: Bool) -> CGFloat {
        isActive ? closeSymbolScale : 1
    }

    static func symbolTransitionStyle(isActive: Bool) -> EditorToolbarSymbolTransitionStyle {
        isActive ? openSymbolTransition : closeSymbolTransition
    }
}

enum EditorToolbarSymbolTransitionStyle: Equatable {
    case replaceOffUp
    case instant
}

struct IntelligenceToolbarIcon: View {
    let systemImage: String
    let isOn: Bool
    var symbolScale: CGFloat = 1
    var symbolTransitionStyle: EditorToolbarSymbolTransitionStyle = .instant

    var body: some View {
        ZStack {
            if isOn {
                Circle()
                    .fill(Color.accentColor.opacity(IntelligenceToolbarTogglePresentation.fillOpacityWhenOn))
                    .frame(
                        width: IntelligenceToolbarTogglePresentation.iconFillDiameter,
                        height: IntelligenceToolbarTogglePresentation.iconFillDiameter
                    )
            }

            Image(systemName: systemImage)
                .contentTransition(contentTransition)
                .animation(symbolAnimation, value: systemImage)
                .scaleEffect(symbolScale)
                .foregroundStyle(
                    isOn
                        ? Color.white.opacity(IntelligenceToolbarTogglePresentation.iconOpacityWhenOn)
                        : Color(nsColor: .labelColor).opacity(IntelligenceToolbarTogglePresentation.iconOpacityWhenOff)
                )
        }
    }

    private var contentTransition: ContentTransition {
        switch symbolTransitionStyle {
        case .replaceOffUp:
            return .symbolEffect(.replace.offUp)
        case .instant:
            return .identity
        }
    }

    private var symbolAnimation: Animation? {
        switch symbolTransitionStyle {
        case .replaceOffUp:
            return .easeOut(duration: 0.16)
        case .instant:
            return nil
        }
    }
}

enum EditorToolbarAction: CaseIterable, Equatable, Identifiable {
    case intelligence
    case markdownBasics
    case readingExperience

    var id: Self { self }

    var title: String {
        switch self {
        case .intelligence:
            return "Intelligence"
        case .markdownBasics:
            return "Markdown Basics"
        case .readingExperience:
            return "Reading Experience"
        }
    }

    var systemImage: String {
        switch self {
        case .intelligence:
            return "sparkles"
        case .markdownBasics:
            return "info.circle"
        case .readingExperience:
            return "textformat.size"
        }
    }

    static func primaryActions(in mode: EditorDisplayMode) -> [EditorToolbarAction] {
        if EditorToolbarVisibility.showsIntelligence(in: mode) {
            return [.intelligence, .markdownBasics, .readingExperience]
        }

        if EditorToolbarVisibility.showsMarkdownBasics(in: mode) {
            return [.markdownBasics, .readingExperience]
        }

        return [.readingExperience]
    }
}

enum EditorSearchResolver {
    struct RefreshState: Equatable {
        let activeIndex: Int?
        let requestedSelection: NSRange?
    }

    static func matches(in text: String, query: String) -> [NSRange] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var searchRange = fullRange
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = nsText.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )

            guard match.location != NSNotFound, match.length > 0 else {
                break
            }

            matches.append(match)
            let nextLocation = match.location + match.length
            searchRange = NSRange(
                location: nextLocation,
                length: max(0, NSMaxRange(fullRange) - nextLocation)
            )
        }

        return matches
    }

    static func refreshState(
        currentActiveIndex: Int?,
        matches: [NSRange],
        selectFirstWhenNeeded: Bool,
        navigatesToActiveMatch: Bool
    ) -> RefreshState {
        guard !matches.isEmpty else {
            return RefreshState(activeIndex: nil, requestedSelection: nil)
        }

        let activeIndex: Int?
        if let currentActiveIndex, matches.indices.contains(currentActiveIndex) {
            activeIndex = currentActiveIndex
        } else if selectFirstWhenNeeded {
            activeIndex = 0
        } else {
            activeIndex = nil
        }

        guard
            navigatesToActiveMatch,
            let activeIndex,
            matches.indices.contains(activeIndex)
        else {
            return RefreshState(activeIndex: activeIndex, requestedSelection: nil)
        }

        return RefreshState(activeIndex: activeIndex, requestedSelection: matches[activeIndex])
    }

    static func visibleMatches(_ ranges: [NSRange], activeRange: NSRange?, visibleCharacterRange: NSRange?) -> [NSRange] {
        guard let visibleCharacterRange else {
            return ranges
        }

        var visibleRanges: [NSRange] = []
        for range in ranges {
            let intersectsVisibleRange = NSIntersectionRange(range, visibleCharacterRange).length > 0
            if intersectsVisibleRange || range == activeRange {
                visibleRanges.append(range)
            }
        }
        return visibleRanges
    }

    static func nextIndex(after index: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let index else {
            return 0
        }

        return (index + 1) % matchCount
    }

    static func previousIndex(before index: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let index else {
            return matchCount - 1
        }

        return (index - 1 + matchCount) % matchCount
    }

    static func accessibilitySummary(query: String, matchCount: Int, activeIndex: Int?) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        guard matchCount > 0 else {
            return "Search for \(trimmedQuery). No matches."
        }

        let safeActiveIndex = min(max(activeIndex ?? 0, 0), matchCount - 1)
        let matchWord = matchCount == 1 ? "match" : "matches"
        return "Search for \(trimmedQuery). \(matchCount) \(matchWord). Result \(safeActiveIndex + 1) of \(matchCount)."
    }
}

enum EditorSearchToolbarPresentation {
    static let usesNativeSearchableToolbarItem = true
    static let preservesSystemToolbarButtonGroup = true
    static let usesSeparateVisualCapsule = true
    static let embedsNavigationControlsInSearchField = false
    static let usesNativeSearchClearButton = true
    static let showsNavigationControlsWhenQueryIsEmpty = false
    static let usesSystemSearchFieldSizing = true
}

enum EditorMotionPolicy {
    static let supportsReduceMotion = true

    static func effectiveDuration(_ duration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : duration
    }

    static func usesAnimatedTransitions(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func fadeAndMoveTransition(y: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .offset(y: y).combined(with: .opacity)
    }

    static func scaleAndFadeTransition(scale: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }
}

struct IntelligenceActionRail: View {
    let actions: [IntelligentEditingAction]
    let isActionEnabled: Bool
    let runAction: (IntelligentEditingAction) -> Void

    var body: some View {
        HStack(spacing: IntelligenceActionRailPresentation.railSpacing) {
            ForEach(actions) { action in
                IntelligenceActionRailButton(
                    action: action,
                    isEnabled: isActionEnabled,
                    runAction: runAction
                )
            }
        }
    }
}

struct IntelligenceInstructionComposer: View {
    @Binding var instruction: String
    let isActionEnabled: Bool
    var isLoading = false
    var usesDarkChrome = false
    let onFocusChanged: (Bool) -> Void
    let submitInstruction: (String) -> Void

    var body: some View {
        IntelligenceInstructionComposerOverlayHost(
            instruction: $instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
    }
}

struct IntelligenceInstructionComposerOverlayHost: NSViewRepresentable {
    @Binding var instruction: String
    let isActionEnabled: Bool
    let isLoading: Bool
    let usesDarkChrome: Bool
    let onFocusChanged: (Bool) -> Void
    let submitInstruction: (String) -> Void

    func makeNSView(context: Context) -> IntelligenceInstructionComposerOverlayNSView {
        IntelligenceInstructionComposerOverlayNSView(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            textChanged: { instruction = $0 },
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
    }

    func updateNSView(_ nsView: IntelligenceInstructionComposerOverlayNSView, context: Context) {
        nsView.update(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            textChanged: { instruction = $0 },
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
    }
}

final class IntelligenceInstructionComposerOverlayNSView: NSView {
    private let composerView: IntelligenceInstructionComposerNSView

    init(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        composerView = IntelligenceInstructionComposerNSView(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            textChanged: textChanged,
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
        super.init(frame: .zero)
        addSubview(composerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var isFlipped: Bool {
        true
    }

    func update(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool = false,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        composerView.update(
            instruction: instruction,
            isActionEnabled: isActionEnabled,
            isLoading: isLoading,
            usesDarkChrome: usesDarkChrome,
            textChanged: textChanged,
            onFocusChanged: onFocusChanged,
            submitInstruction: submitInstruction
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let width = min(
            IntelligenceInstructionComposerPresentation.maximumWidth,
            max(0, bounds.width - 48)
        )
        composerView.frame = NSRect(
            x: (bounds.width - width) / 2,
            y: max(0, bounds.height - IntelligenceActionRailPresentation.bottomInset - IntelligenceInstructionComposerPresentation.height),
            width: width,
            height: IntelligenceInstructionComposerPresentation.height
        )
        composerView.layoutSubtreeIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let composerPoint = convert(point, to: composerView)
        return composerView.hitTest(composerPoint)
    }
}

final class IntelligenceInstructionComposerNSView: NSView {
    private let textView = IntelligenceInstructionTextView()
    private let submitButton: IntelligenceInstructionSubmitButtonNSView
    private let loadingSkeletonView = IntelligenceInstructionLoadingSkeletonNSView()
    private var textChanged: (String) -> Void
    private var onFocusChanged: (Bool) -> Void
    private var submitInstruction: (String) -> Void
    private var mouseDownMonitor: LocalEventMonitor?
    private var usesDarkChrome: Bool
    private var isLoading: Bool {
        didSet {
            applyLoadingState()
        }
    }
    private var isInputFocused = false {
        didSet {
            needsDisplay = true
        }
    }

    init(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool = false,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        self.textChanged = textChanged
        self.onFocusChanged = onFocusChanged
        self.submitInstruction = submitInstruction
        self.usesDarkChrome = usesDarkChrome
        self.isLoading = isLoading
        submitButton = IntelligenceInstructionSubmitButtonNSView(
            isActionEnabled: isActionEnabled,
            usesDarkChrome: usesDarkChrome,
            performAction: {}
        )
        super.init(frame: .zero)
        configureTextView()
        configureLoadingViews()
        configureTextViewCallbacks()
        textView.string = instruction
        submitButton.performAction = { [weak self] in
            self?.submitIfReady()
        }
        addSubview(textView)
        addSubview(submitButton)
        addSubview(loadingSkeletonView)
        wantsLayer = true
        applyLoadingState()
        updateLayerShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    func update(
        instruction: String,
        isActionEnabled: Bool,
        isLoading: Bool = false,
        usesDarkChrome: Bool = false,
        textChanged: @escaping (String) -> Void,
        onFocusChanged: @escaping (Bool) -> Void,
        submitInstruction: @escaping (String) -> Void
    ) {
        self.textChanged = textChanged
        self.onFocusChanged = onFocusChanged
        self.submitInstruction = submitInstruction
        if self.usesDarkChrome != usesDarkChrome {
            self.usesDarkChrome = usesDarkChrome
            applyAppearanceStyling()
        }
        self.isLoading = isLoading
        submitButton.isActionEnabled = isActionEnabled
        submitButton.usesDarkChrome = usesDarkChrome
        configureTextViewCallbacks()
        if window?.firstResponder !== textView && textView.string != instruction {
            textView.string = instruction
            textView.needsDisplay = true
        }
        submitButton.performAction = { [weak self] in
            self?.submitIfReady()
        }
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateLayerShadow()

        let horizontalPadding = IntelligenceInstructionComposerPresentation.horizontalPadding
        let sparklesWidth: CGFloat = 20
        let buttonSize = IntelligenceInstructionComposerPresentation.sendButtonSize
        let controlHeight: CGFloat = 24
        let centerY = bounds.midY
        submitButton.frame = NSRect(
            x: bounds.width - horizontalPadding - buttonSize,
            y: centerY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )
        textView.frame = NSRect(
            x: horizontalPadding + sparklesWidth + 10,
            y: centerY - controlHeight / 2,
            width: max(0, bounds.width - horizontalPadding * 2 - sparklesWidth - 20 - buttonSize),
            height: controlHeight
        )
        let loadingInset = IntelligenceInstructionComposerPresentation.loadingSkeletonCapsuleInset
        loadingSkeletonView.frame = bounds.insetBy(dx: loadingInset, dy: loadingInset)
        registerHitTestRegion()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearanceStyling()
        registerHitTestRegion()
        if window == nil {
            removeMouseDownMonitor()
            EditorFloatingControlHitTestRegistry.remove(owner: self)
        } else {
            installMouseDownMonitorIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.focusTextView()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceStyling()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard !isLoading else { return self }

        let submitPoint = convert(point, to: submitButton)
        if let submitHit = submitButton.hitTest(submitPoint) {
            return submitHit
        }

        if textView.frame.contains(point) {
            return textView
        }

        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        if !isLoading {
            addCursorRect(textView.frame, cursor: .iBeam)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard !isLoading else { return }

        let point = convert(event.locationInWindow, from: nil)
        if textView.frame.contains(point) {
            NSCursor.iBeam.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLoading else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard !submitButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }

        focusTextView(insertingAt: event.locationInWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: IntelligenceInstructionComposerPresentation.cornerRadius,
            yRadius: IntelligenceInstructionComposerPresentation.cornerRadius
        )
        let backgroundColor = isLoading
            ? IntelligenceInstructionComposerPresentation.loadingBackgroundColor(usesDarkAppearance: usesDarkChrome)
            : IntelligenceInstructionComposerPresentation.backgroundColor(usesDarkAppearance: usesDarkChrome)
        backgroundColor.setFill()
        path.fill()

        if isLoading || usesDarkChrome || isInputFocused {
            let borderColor = isLoading
                ? IntelligenceInstructionComposerPresentation.loadingBorderColor(usesDarkAppearance: usesDarkChrome)
                : IntelligenceInstructionComposerPresentation.borderColor(
                    usesDarkAppearance: usesDarkChrome,
                    isFocused: isInputFocused
                )
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if !isLoading {
            drawSparkles()
        }
    }

    deinit {
        EditorFloatingControlHitTestRegistry.remove(owner: self)
    }

    private func configureTextView() {
        textView.placeholder = IntelligenceInstructionComposerPresentation.prompt
        textView.font = .systemFont(ofSize: 15, weight: .regular)
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.setAccessibilityLabel(IntelligenceInstructionComposerPresentation.inputAccessibilityLabel)
        textView.setAccessibilityHelp(IntelligenceInstructionComposerPresentation.inputAccessibilityHelp)
        applyAppearanceStyling()
    }

    private func configureLoadingViews() {
        loadingSkeletonView.isHidden = true
        loadingSkeletonView.usesDarkChrome = usesDarkChrome
    }

    private func configureTextViewCallbacks() {
        textView.onTextChanged = { [weak self] text in
            self?.textChanged(text)
        }
        textView.onFocusChanged = { [weak self] isFocused in
            guard let self else { return }
            isInputFocused = isFocused
            onFocusChanged(isFocused)
        }
        textView.onSubmit = { [weak self] in
            self?.submitIfReady()
        }
    }

    private func submitIfReady() {
        guard !isLoading else { return }

        let trimmedInstruction = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard submitButton.isActionEnabled, !trimmedInstruction.isEmpty else {
            return
        }

        textView.string = ""
        textView.needsDisplay = true
        textChanged("")
        submitInstruction(trimmedInstruction)
    }

    private func focusTextView() {
        guard !isLoading else { return }

        isInputFocused = true
        onFocusChanged(true)
        window?.makeFirstResponder(textView)
    }

    private func focusTextView(insertingAt windowPoint: NSPoint?) {
        guard !isLoading else { return }

        focusTextView()
        guard let windowPoint else { return }

        let point = convert(windowPoint, from: nil)
        if textView.frame.contains(point) {
            let textViewPoint = textView.convert(windowPoint, from: nil)
            textView.setSelectedRange(NSRange(location: textView.characterIndexForInsertion(at: textViewPoint), length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }

    private func installMouseDownMonitorIfNeeded() {
        guard mouseDownMonitor == nil else { return }

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            guard
                let self,
                let window = self.window,
                event.window === window
            else {
                return event
            }

            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else {
                return event
            }

            guard !self.isLoading else {
                return nil
            }

            if self.submitButton.frame.contains(point) {
                self.submitIfReady()
            } else if self.textView.frame.contains(point) {
                self.textView.handleMouseDown(with: event)
            } else {
                self.focusTextView(insertingAt: event.locationInWindow)
            }
            return nil
        }) else { return }
        mouseDownMonitor = LocalEventMonitor(monitor)
    }

    private func removeMouseDownMonitor() {
        mouseDownMonitor?.remove()
        mouseDownMonitor = nil
    }

    private func applyAppearanceStyling() {
        textView.usesDarkChrome = usesDarkChrome
        textView.textColor = IntelligenceInstructionComposerPresentation.foregroundColor(
            usesDarkAppearance: usesDarkChrome
        )
        textView.insertionPointColor = IntelligenceInstructionComposerPresentation.insertionPointColor(
            usesDarkAppearance: usesDarkChrome
        )
        submitButton.usesDarkChrome = usesDarkChrome
        loadingSkeletonView.usesDarkChrome = usesDarkChrome
        textView.needsDisplay = true
        submitButton.needsDisplay = true
        loadingSkeletonView.needsDisplay = true
        needsDisplay = true
    }

    private func applyLoadingState() {
        textView.isHidden = isLoading
        submitButton.isHidden = isLoading
        loadingSkeletonView.isHidden = !isLoading
        loadingSkeletonView.setAnimating(isLoading)
        if isLoading {
            window?.makeFirstResponder(nil)
            isInputFocused = false
        }
        needsDisplay = true
        needsLayout = true
        discardCursorRects()
    }

    private func drawSparkles() {
        guard let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) else {
            return
        }

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let colorConfiguration = NSImage.SymbolConfiguration(
            hierarchicalColor: IntelligenceInstructionComposerPresentation.iconColor(
                usesDarkAppearance: usesDarkChrome
            )
        )
        let configuredImage = image.withSymbolConfiguration(
            symbolConfiguration.applying(colorConfiguration)
        ) ?? image
        let imageRect = NSRect(
            x: IntelligenceInstructionComposerPresentation.horizontalPadding,
            y: bounds.midY - 8,
            width: 16,
            height: 16
        )
        configuredImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func updateLayerShadow() {
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(IntelligenceInstructionComposerPresentation.shadowOpacity)
        layer?.shadowRadius = IntelligenceInstructionComposerPresentation.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -IntelligenceInstructionComposerPresentation.shadowYOffset)
    }

    private func registerHitTestRegion() {
        guard let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil),
            mouseDownHandler: { [weak self] in
                self?.focusTextView()
            }
        )
    }
}

final class IntelligenceInstructionLoadingSkeletonNSView: NSView {
    var usesDarkChrome = false {
        didSet {
            needsDisplay = true
        }
    }

    private var animationStartDate = Date()
    private var animationTimer: Timer?

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if !isHidden {
            startAnimating()
        }
    }

    func setAnimating(_ isAnimating: Bool) {
        if isAnimating, window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rowCount = IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumRows
        let columnCount = IntelligenceInstructionComposerPresentation.loadingSkeletonColumns
        let blockHeight = IntelligenceInstructionComposerPresentation.loadingSkeletonBlockHeight
        let spacing = IntelligenceInstructionComposerPresentation.loadingSkeletonSpacing
        let rowHeight = blockHeight + spacing
        let gridHeight = CGFloat(rowCount) * blockHeight + CGFloat(rowCount - 1) * spacing
        let originY = max(0, (bounds.height - gridHeight) / 2)
        let availableWidth = max(0, bounds.width - CGFloat(columnCount - 1) * spacing)
        let cellWidth = max(
            IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumCellWidth,
            availableWidth / CGFloat(columnCount)
        )

        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let cellIndex = row * columnCount + column
                guard shouldDrawSkeletonBlock(row: row, column: column, cellIndex: cellIndex) else {
                    continue
                }

                let scale = skeletonScale(cellIndex: cellIndex)
                let width = min(
                    cellWidth,
                    max(
                        IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumBlockWidth,
                        cellWidth * scale
                    )
                )
                let x = CGFloat(column) * (cellWidth + spacing) + (cellWidth - width) / 2
                let y = originY + CGFloat(row) * rowHeight
                let rect = NSRect(x: x, y: y, width: width, height: blockHeight)
                drawSkeletonBlock(in: rect, alpha: skeletonAlpha(row: row, column: column, cellIndex: cellIndex))
            }
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }

        animationStartDate = Date()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func drawSkeletonBlock(in rect: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let baseColor = NSColor.labelColor.withAlphaComponent(usesDarkChrome ? 0.08 + alpha * 0.17 : 0.045 + alpha * 0.17)
        baseColor.setFill()
        path.fill()

        guard let gradient = NSGradient(colors: [
            NSColor.labelColor.withAlphaComponent(0.018 + alpha * 0.04),
            NSColor.labelColor.withAlphaComponent(0.07 + alpha * 0.24),
            NSColor.labelColor.withAlphaComponent(0.022 + alpha * 0.05),
        ]) else {
            return
        }
        gradient.draw(in: path, angle: 0)
    }

    private func shouldDrawSkeletonBlock(row: Int, column: Int, cellIndex: Int) -> Bool {
        let preserveEdges = column == 0 || column == IntelligenceInstructionComposerPresentation.loadingSkeletonColumns - 1
        return preserveEdges || seededNoise(Double(cellIndex + 101)) >= 0.16
    }

    private func skeletonAlpha(row: Int, column: Int, cellIndex: Int) -> CGFloat {
        let elapsed = Date().timeIntervalSince(animationStartDate)
        let phase = (elapsed - skeletonDelay(row: row, column: column, cellIndex: cellIndex))
            / skeletonDuration(cellIndex: cellIndex)
        let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2
        return CGFloat(wave)
    }

    private func skeletonDelay(row: Int, column: Int, cellIndex: Int) -> TimeInterval {
        let secondaryNoise = seededNoise(Double(cellIndex + 101) * 3.17)
        return Double(column) * 0.045 + Double((row * 7) % 5) * 0.026 + secondaryNoise * 0.12
    }

    private func skeletonDuration(cellIndex: Int) -> TimeInterval {
        1.18 + seededNoise(Double(cellIndex) * 2.11 + 100) * 0.72
    }

    private func skeletonScale(cellIndex: Int) -> CGFloat {
        0.82 + CGFloat(seededNoise(Double(cellIndex) * 4.61 + 100)) * 0.18
    }

    private func seededNoise(_ seed: Double) -> Double {
        let value = sin(seed * 12.9898) * 43758.5453
        return value - floor(value)
    }
}

private final class LocalEventMonitor: @unchecked Sendable {
    private var monitor: Any?

    init(_ monitor: Any) {
        self.monitor = monitor
    }

    func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    deinit {
        remove()
    }
}

final class IntelligenceInstructionTextView: NSTextView {
    var placeholder = "" {
        didSet {
            needsDisplay = true
        }
    }
    var usesDarkChrome = false {
        didSet {
            needsDisplay = true
        }
    }
    var onTextChanged: (String) -> Void = { _ in }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(with: event)
    }

    func handleMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        let textLength = (string as NSString).length

        if event.clickCount >= 3 {
            setSelectedRange(NSRange(location: 0, length: textLength))
            return
        }

        let characterIndex = characterIndexForInsertion(at: localPoint)
        if event.clickCount == 2, textLength > 0 {
            let wordLocation = min(max(characterIndex, 0), textLength - 1)
            setSelectedRange(selectionRange(
                forProposedRange: NSRange(location: wordLocation, length: 0),
                granularity: .selectByWord
            ))
            return
        }

        setSelectedRange(NSRange(location: characterIndex, length: 0))
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onFocusChanged(true)
            needsDisplay = true
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            onFocusChanged(false)
            needsDisplay = true
        }
        return resignedFirstResponder
    }

    override func didChangeText() {
        super.didChangeText()
        string = string.replacingOccurrences(of: "\n", with: " ")
        onTextChanged(string)
        needsDisplay = true
    }

    override func insertNewline(_ sender: Any?) {
        onSubmit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: IntelligenceInstructionComposerPresentation.placeholderColor(
                usesDarkAppearance: usesDarkChrome
            )
        ]
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}

struct IntelligenceInstructionSubmitButton: NSViewRepresentable {
    let isActionEnabled: Bool
    var usesDarkChrome = false
    let performAction: () -> Void

    func makeNSView(context: Context) -> IntelligenceInstructionSubmitButtonNSView {
        IntelligenceInstructionSubmitButtonNSView(
            isActionEnabled: isActionEnabled,
            usesDarkChrome: usesDarkChrome,
            performAction: performAction
        )
    }

    func updateNSView(_ nsView: IntelligenceInstructionSubmitButtonNSView, context: Context) {
        nsView.isActionEnabled = isActionEnabled
        nsView.usesDarkChrome = usesDarkChrome
        nsView.performAction = performAction
    }
}

final class IntelligenceInstructionSubmitButtonNSView: NSView {
    var isActionEnabled: Bool {
        didSet {
            if oldValue != isActionEnabled {
                if !isActionEnabled {
                    setHovering(false)
                }
                setAccessibilityEnabled(isActionEnabled)
                window?.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var usesDarkChrome: Bool {
        didSet {
            needsDisplay = true
        }
    }
    var performAction: () -> Void

    private(set) var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    init(isActionEnabled: Bool, usesDarkChrome: Bool = false, performAction: @escaping () -> Void) {
        self.isActionEnabled = isActionEnabled
        self.usesDarkChrome = usesDarkChrome
        self.performAction = performAction
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(IntelligenceInstructionComposerPresentation.submitAccessibilityLabel)
        setAccessibilityHelp(IntelligenceInstructionComposerPresentation.submitAccessibilityHelp)
        setAccessibilityEnabled(isActionEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: IntelligenceInstructionComposerPresentation.sendButtonSize,
            height: IntelligenceInstructionComposerPresentation.sendButtonSize
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        isActionEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        guard isActionEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        registerHitTestRegion()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerHitTestRegion()
        window?.invalidateCursorRects(for: self)
        if window == nil {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            setHovering(false)
        }
    }

    override func layout() {
        super.layout()
        registerHitTestRegion()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActionEnabled else {
            setHovering(false)
            return
        }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActionEnabled else { return }
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isActionEnabled else { return }
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        performActionIfEnabled()
    }

    override func keyDown(with event: NSEvent) {
        let activatesButton = event.keyCode == 36 || event.keyCode == 49
        if activatesButton, performActionIfEnabled() {
            return
        }

        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        performActionIfEnabled()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        IntelligenceInstructionComposerPresentation.sendButtonFillColor(
            usesDarkAppearance: usesDarkChrome,
            isHovered: isHovering,
            isEnabled: isActionEnabled
        )
        .setFill()
        NSBezierPath(ovalIn: bounds).fill()

        guard let image = NSImage(
            systemSymbolName: IntelligenceInstructionComposerPresentation.submitSystemImage,
            accessibilityDescription: "Run AI instruction"
        ) else {
            return
        }

        let symbolPointSize = IntelligenceInstructionComposerPresentation.sendButtonSymbolPointSize
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .bold)
        let colorConfiguration = NSImage.SymbolConfiguration(
            hierarchicalColor: IntelligenceInstructionComposerPresentation.sendButtonSymbolColor(
                usesDarkAppearance: usesDarkChrome,
                isEnabled: isActionEnabled
            )
        )
        let configuredImage = image.withSymbolConfiguration(
            symbolConfiguration.applying(colorConfiguration)
        ) ?? image
        let imageSize = NSSize(width: symbolPointSize, height: symbolPointSize)
        let imageRect = NSRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )

        configuredImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    deinit {
        let wasHovering = isHovering
        let ownerID = ObjectIdentifier(self)
        EditorFloatingControlHitTestRegistry.remove(ownerID: ownerID)
        if wasHovering {
            NSCursor.pop()
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }

        isHovering = hovering
        if hovering {
            NSCursor.pointingHand.push()
            NSCursor.pointingHand.set()
        } else {
            NSCursor.pop()
        }
        needsDisplay = true
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        NSCursor.pointingHand.set()
    }

    @discardableResult
    private func performActionIfEnabled() -> Bool {
        guard isActionEnabled else {
            return false
        }

        performAction()
        return true
    }

    private func registerHitTestRegion() {
        guard let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil),
            mouseDownHandler: { [weak self] in
                self?.performActionIfEnabled()
            }
        )
    }
}

struct FloatingControlRegionRegistrationView: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> FloatingControlRegionRegistrationNSView {
        FloatingControlRegionRegistrationNSView(isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: FloatingControlRegionRegistrationNSView, context: Context) {
        nsView.isEnabled = isEnabled
        DispatchQueue.main.async {
            nsView.refreshFloatingHitTestRegion()
        }
    }
}

final class FloatingControlRegionRegistrationNSView: NSView {
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            refreshFloatingHitTestRegion()
        }
    }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        refreshFloatingHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshFloatingHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFloatingHitTestRegion()
        if window == nil {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
        }
    }

    override func layout() {
        super.layout()
        refreshFloatingHitTestRegion()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        EditorFloatingControlHitTestRegistry.remove(owner: self)
    }

    func refreshFloatingHitTestRegion() {
        guard isEnabled, let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil)
        )
    }
}

struct IntelligenceActionRailOverlayHost: NSViewRepresentable {
    let actions: [IntelligentEditingAction]
    let isActionEnabled: Bool
    let runAction: (IntelligentEditingAction) -> Void

    func makeNSView(context: Context) -> IntelligenceActionRailOverlayNSView {
        IntelligenceActionRailOverlayNSView(
            actions: actions,
            isActionEnabled: isActionEnabled,
            runAction: runAction
        )
    }

    func updateNSView(_ nsView: IntelligenceActionRailOverlayNSView, context: Context) {
        nsView.update(
            actions: actions,
            isActionEnabled: isActionEnabled,
            runAction: runAction
        )
    }
}

final class IntelligenceActionRailOverlayNSView: NSView {
    private var actions: [IntelligentEditingAction]
    private var isActionEnabled: Bool
    private var runAction: (IntelligentEditingAction) -> Void
    private var buttonViews: [ActionRailButtonNSView] = []

    init(
        actions: [IntelligentEditingAction],
        isActionEnabled: Bool,
        runAction: @escaping (IntelligentEditingAction) -> Void
    ) {
        self.actions = actions
        self.isActionEnabled = isActionEnabled
        self.runAction = runAction
        super.init(frame: .zero)
        rebuildButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var isFlipped: Bool {
        true
    }

    func update(
        actions: [IntelligentEditingAction],
        isActionEnabled: Bool,
        runAction: @escaping (IntelligentEditingAction) -> Void
    ) {
        let needsRebuild = actions != self.actions
        self.actions = actions
        self.isActionEnabled = isActionEnabled
        self.runAction = runAction

        if needsRebuild {
            rebuildButtons()
        } else {
            buttonViews.forEach { buttonView in
                buttonView.isEnabled = isActionEnabled
                buttonView.performAction = { [weak self, action = buttonView.action] in
                    self?.runAction(action)
                }
            }
        }

        needsLayout = true
    }

    override func layout() {
        super.layout()

        let width = min(railWidth, bounds.width)
        let height = IntelligenceActionRailPresentation.buttonHeight
        let origin = NSPoint(
            x: (bounds.width - width) / 2,
            y: max(0, bounds.height - IntelligenceActionRailPresentation.bottomInset - height)
        )

        for (index, buttonView) in buttonViews.enumerated() {
            buttonView.frame = NSRect(
                x: origin.x + CGFloat(index) * (IntelligenceActionRailPresentation.buttonWidth + IntelligenceActionRailPresentation.railSpacing),
                y: origin.y,
                width: IntelligenceActionRailPresentation.buttonWidth,
                height: IntelligenceActionRailPresentation.buttonHeight
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for buttonView in buttonViews.reversed() {
            let buttonPoint = convert(point, to: buttonView)
            if let hitView = buttonView.hitTest(buttonPoint) {
                return hitView
            }
        }

        return nil
    }

    private var railWidth: CGFloat {
        guard !buttonViews.isEmpty else { return 0 }
        return CGFloat(buttonViews.count) * IntelligenceActionRailPresentation.buttonWidth
            + CGFloat(buttonViews.count - 1) * IntelligenceActionRailPresentation.railSpacing
    }

    private func rebuildButtons() {
        buttonViews.forEach { $0.removeFromSuperview() }
        buttonViews = actions.map { action in
            let buttonView = ActionRailButtonNSView(
                action: action,
                isEnabled: isActionEnabled,
                performAction: { [weak self] in
                    self?.runAction(action)
                }
            )
            addSubview(buttonView)
            return buttonView
        }
        needsLayout = true
    }
}

final class ActionRailButtonNSView: NSView {
    let action: IntelligentEditingAction
    var performAction: () -> Void
    var isEnabled: Bool {
        didSet {
            if isEnabled {
                registerHitTestRegion()
            } else {
                setHovering(false)
                removeHoverTrackingArea()
                EditorFloatingControlHitTestRegistry.remove(owner: self)
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    init(
        action: IntelligentEditingAction,
        isEnabled: Bool,
        performAction: @escaping () -> Void
    ) {
        self.action = action
        self.isEnabled = isEnabled
        self.performAction = performAction
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: IntelligenceActionRailPresentation.buttonWidth,
            height: IntelligenceActionRailPresentation.buttonHeight
        )
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled && bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        removeHoverTrackingArea()

        guard isEnabled else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            super.updateTrackingAreas()
            return
        }

        registerHitTestRegion()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerHitTestRegion()
        window?.invalidateCursorRects(for: self)
        if window == nil {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            setHovering(false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled else { return }
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isEnabled else { return }
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        performAction()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: IntelligenceActionRailPresentation.cornerRadius,
            yRadius: IntelligenceActionRailPresentation.cornerRadius
        )
        NSColor.actionRailBackground(isHovered: isHovering).setFill()
        path.fill()

        NSColor.controlAccentColor
            .withAlphaComponent(isHovering ? IntelligenceActionRailPresentation.hoverBorderOpacity : IntelligenceActionRailPresentation.borderOpacity)
            .setStroke()
        path.lineWidth = 1
        path.stroke()

        drawIcon(in: bounds)
        drawLabel(in: bounds)
    }

    deinit {
        let wasHovering = isHovering
        let ownerID = ObjectIdentifier(self)
        EditorFloatingControlHitTestRegistry.remove(ownerID: ownerID)
        if wasHovering {
            NSCursor.pop()
        }
    }

    private func drawIcon(in rect: NSRect) {
        guard let image = NSImage(
            systemSymbolName: action.railSystemImage,
            accessibilityDescription: action.title
        ) else {
            return
        }

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: IntelligenceActionRailPresentation.iconSize,
            weight: .semibold
        )
        let iconColor = NSColor.controlAccentColor.withAlphaComponent(
            isEnabled ? 1 : IntelligenceActionRailPresentation.disabledContentOpacity
        )
        let colorConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: iconColor)
        let configuredImage = image.withSymbolConfiguration(
            symbolConfiguration.applying(colorConfiguration)
        ) ?? image

        let iconSize = NSSize(
            width: IntelligenceActionRailPresentation.iconSize + 3,
            height: IntelligenceActionRailPresentation.iconSize + 3
        )
        let iconRect = NSRect(
            x: rect.midX - iconSize.width / 2,
            y: 12,
            width: iconSize.width,
            height: iconSize.height
        )

        configuredImage.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func drawLabel(in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: IntelligenceActionRailPresentation.labelSize,
                weight: .semibold
            ),
            .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : IntelligenceActionRailPresentation.disabledContentOpacity),
            .paragraphStyle: paragraphStyle
        ]
        let label = NSAttributedString(string: action.railDisplayTitle, attributes: attributes)
        label.draw(
            in: NSRect(
                x: 5,
                y: rect.height - 20,
                width: rect.width - 10,
                height: 14
            )
        )
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }

        isHovering = hovering
        if hovering {
            NSCursor.pointingHand.push()
            NSCursor.pointingHand.set()
        } else {
            NSCursor.pop()
        }
        needsDisplay = true
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        NSCursor.pointingHand.set()
    }

    private func registerHitTestRegion() {
        guard isEnabled, let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil)
        )
    }

    private func removeHoverTrackingArea() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        hoverTrackingArea = nil
    }
}

private extension NSColor {
    static func actionRailBackground(isHovered: Bool) -> NSColor {
        NSColor(
            srgbRed: isHovered
                ? IntelligenceActionRailPresentation.hoverBackgroundRedComponent
                : IntelligenceActionRailPresentation.backgroundRedComponent,
            green: isHovered
                ? IntelligenceActionRailPresentation.hoverBackgroundGreenComponent
                : IntelligenceActionRailPresentation.backgroundGreenComponent,
            blue: isHovered
                ? IntelligenceActionRailPresentation.hoverBackgroundBlueComponent
                : IntelligenceActionRailPresentation.backgroundBlueComponent,
            alpha: IntelligenceActionRailPresentation.backgroundAlpha
        )
    }
}

struct IntelligenceActionRailButton: View {
    let action: IntelligentEditingAction
    let isEnabled: Bool
    let runAction: (IntelligentEditingAction) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if isEnabled {
                runAction(action)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.railSystemImage)
                    .font(.system(size: IntelligenceActionRailPresentation.iconSize, weight: .semibold))

                Text(action.railDisplayTitle)
                    .font(.system(size: IntelligenceActionRailPresentation.labelSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.accentColor.opacity(isEnabled ? 1 : IntelligenceActionRailPresentation.disabledContentOpacity))
            .frame(
                width: IntelligenceActionRailPresentation.buttonWidth,
                height: IntelligenceActionRailPresentation.buttonHeight
            )
            .background(
                RoundedRectangle(cornerRadius: IntelligenceActionRailPresentation.cornerRadius)
                    .fill(IntelligenceActionRailPresentation.backgroundColor(isHovered: isHovered))
            )
            .overlay {
                RoundedRectangle(cornerRadius: IntelligenceActionRailPresentation.cornerRadius)
                    .strokeBorder(
                        IntelligenceActionRailPresentation.borderColor(isHovered: isHovered),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(IntelligenceActionRailPresentation.shadowOpacity),
                radius: IntelligenceActionRailPresentation.shadowRadius,
                y: IntelligenceActionRailPresentation.shadowYOffset
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: IntelligenceActionRailPresentation.cornerRadius))
        .help(action.title)
        .accessibilityLabel(action.title)
        .overlay {
            ActionRailButtonEventView(
                isEnabled: isEnabled,
                onHoverChanged: { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                },
                performAction: {
                    guard isEnabled else { return }
                    runAction(action)
                }
            )
        }
    }
}

struct ActionRailButtonEventView: NSViewRepresentable {
    let isEnabled: Bool
    let onHoverChanged: (Bool) -> Void
    let performAction: () -> Void

    func makeNSView(context: Context) -> ActionRailButtonEventNSView {
        ActionRailButtonEventNSView(
            isEnabled: isEnabled,
            onHoverChanged: onHoverChanged,
            performAction: performAction
        )
    }

    func updateNSView(_ nsView: ActionRailButtonEventNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onHoverChanged = onHoverChanged
        nsView.performAction = performAction
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class ActionRailButtonEventNSView: NSView {
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled {
                setHovering(false)
                EditorFloatingControlHitTestRegistry.remove(owner: self)
            } else {
                registerHitTestRegion()
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHoverChanged: (Bool) -> Void
    var performAction: () -> Void

    init(
        isEnabled: Bool,
        onHoverChanged: @escaping (Bool) -> Void,
        performAction: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.onHoverChanged = onHoverChanged
        self.performAction = performAction
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerHitTestRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        registerHitTestRegion()
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        guard isEnabled else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            super.updateTrackingAreas()
            return
        }

        registerHitTestRegion()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        return bounds.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled else { return }
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEnabled && isHovering {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        performAction()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerHitTestRegion()
        window?.invalidateCursorRects(for: self)
        if window == nil {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            setHovering(false)
        }
    }

    override func layout() {
        super.layout()
        registerHitTestRegion()
    }

    deinit {
        let wasHovering = isHovering
        let ownerID = ObjectIdentifier(self)
        EditorFloatingControlHitTestRegistry.remove(ownerID: ownerID)
        if wasHovering {
            NSCursor.pop()
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }

        isHovering = hovering
        if hovering {
            NSCursor.pointingHand.push()
            NSCursor.pointingHand.set()
        } else {
            NSCursor.pop()
        }
        onHoverChanged(hovering)
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        NSCursor.pointingHand.set()
    }

    private func registerHitTestRegion() {
        guard isEnabled, let window else {
            EditorFloatingControlHitTestRegistry.remove(owner: self)
            return
        }

        EditorFloatingControlHitTestRegistry.setRegion(
            owner: self,
            window: window,
            rect: convert(bounds, to: nil)
        )
    }
}

enum EditorFloatingControlHitTestRegistry {
    private final class Region {
        weak var window: NSWindow?
        var rect: NSRect
        var mouseDownHandler: (() -> Void)?

        init(window: NSWindow, rect: NSRect, mouseDownHandler: (() -> Void)?) {
            self.window = window
            self.rect = rect
            self.mouseDownHandler = mouseDownHandler
        }
    }

    nonisolated(unsafe) private static var regions: [ObjectIdentifier: Region] = [:]

    static func setRegion(
        owner: AnyObject,
        window: NSWindow,
        rect: NSRect,
        mouseDownHandler: (() -> Void)? = nil
    ) {
        regions[ObjectIdentifier(owner)] = Region(
            window: window,
            rect: rect,
            mouseDownHandler: mouseDownHandler
        )
    }

    static func remove(owner: AnyObject) {
        regions.removeValue(forKey: ObjectIdentifier(owner))
    }

    static func remove(ownerID: ObjectIdentifier) {
        regions.removeValue(forKey: ownerID)
    }

    static func contains(windowPoint: NSPoint, in window: NSWindow) -> Bool {
        regions = regions.filter { _, region in
            region.window != nil
        }

        return regions.values.contains { region in
            region.window === window && region.rect.contains(windowPoint)
        }
    }

    @discardableResult
    static func handleMouseDown(windowPoint: NSPoint, in window: NSWindow) -> Bool {
        regions = regions.filter { _, region in
            region.window != nil
        }

        let matchingRegions = regions.values
            .filter { region in
                region.window === window && region.rect.contains(windowPoint)
            }
            .sorted { lhs, rhs in
                switch (lhs.mouseDownHandler == nil, rhs.mouseDownHandler == nil) {
                case (false, true):
                    return true
                case (true, false):
                    return false
                default:
                    break
                }

                return lhs.rect.width * lhs.rect.height < rhs.rect.width * rhs.rect.height
            }

        guard let region = matchingRegions.first else {
            return false
        }

        region.mouseDownHandler?()
        return true
    }
}

struct RestoringHoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    pushCursor()
                } else {
                    popCursorIfNeeded()
                }
            }
            .onDisappear {
                popCursorIfNeeded()
            }
    }

    private func pushCursor() {
        guard !hasPushedCursor else { return }
        cursor.push()
        cursor.set()
        hasPushedCursor = true
    }

    private func popCursorIfNeeded() {
        guard hasPushedCursor else { return }
        NSCursor.pop()
        hasPushedCursor = false
    }
}

extension View {
    func restoringHoverCursor(_ cursor: NSCursor) -> some View {
        modifier(RestoringHoverCursorModifier(cursor: cursor))
    }
}

struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> CursorRectNSView {
        CursorRectNSView(cursor: cursor, onHoverChanged: onHoverChanged)
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
        nsView.onHoverChanged = onHoverChanged
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class CursorRectNSView: NSView {
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    var cursor: NSCursor {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHoverChanged: (Bool) -> Void

    init(cursor: NSCursor, onHoverChanged: @escaping (Bool) -> Void) {
        self.cursor = cursor
        self.onHoverChanged = onHoverChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        reassertCursorIfHovering()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isHovering {
            cursor.set()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window == nil {
            setHovering(false)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        if isHovering {
            NSCursor.pop()
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }

        isHovering = hovering
        if hovering {
            cursor.push()
            cursor.set()
        } else {
            NSCursor.pop()
        }
        onHoverChanged(hovering)
    }

    private func reassertCursorIfHovering() {
        guard isHovering else { return }
        cursor.set()
    }
}

struct EditorAuxiliaryPresentation: Equatable {
    enum Kind: Equatable {
        case nativeInspector
        case trailingDrawer
        case centeredModal
    }

    var kind: Kind
    var presenter: EditorAuxiliaryPresenter
    var accessibilityLabel: String
    var minimumWidth: CGFloat?
    var idealWidth: CGFloat?
    var maximumWidth: CGFloat?
    var transitionStyle: EditorAuxiliaryTransitionStyle
    var animationDuration: Double?

    static let readingExperience = EditorAuxiliaryPresentation(
        kind: .trailingDrawer,
        presenter: .customLayout,
        accessibilityLabel: "Reading Experience Inspector",
        minimumWidth: 280,
        idealWidth: 320,
        maximumWidth: 380,
        transitionStyle: .slideAndFade,
        animationDuration: EditorInspectorTextResponse.transitionDuration
    )

    static let markdownBasics = EditorAuxiliaryPresentation(
        kind: .centeredModal,
        presenter: .customOverlay,
        accessibilityLabel: "Markdown Basics",
        minimumWidth: nil,
        idealWidth: nil,
        maximumWidth: nil,
        transitionStyle: .fadeAndMoveUp,
        animationDuration: 0.24
    )
}

enum EditorAuxiliaryPresenter: Equatable {
    case systemInspector
    case customLayout
    case customOverlay
}

enum EditorAuxiliaryTransitionStyle: Equatable {
    case instant
    case fadeAndMoveUp
    case slideAndFade
}

struct MarkdownBasicsModal: View {
    struct Example: Identifiable, Equatable {
        var label: String
        var syntax: String

        var id: String { syntax }
    }

    static let title = "Markdown Basics"
    static let showsCloseButton = true
    static let dismissesWhenClickingOutside = true
    static let closeRestingFillOpacity = 0.0
    static let closeHoverFillOpacity = 0.08
    static let animationDuration = 0.24
    static let entranceYOffset: CGFloat = 10
    static let usesThemeIndependentLightChrome = true
    static let backgroundWhiteComponent: CGFloat = 0.98
    static let textRedComponent: CGFloat = 0.12
    static let transitionStyle = EditorAuxiliaryTransitionStyle.fadeAndMoveUp
    static let examples = [
        Example(label: "Title", syntax: "# Title"),
        Example(label: "Section", syntax: "## Section"),
        Example(label: "Bold", syntax: "**bold**"),
        Example(label: "Italic", syntax: "_italic_"),
        Example(label: "Bullet", syntax: "- bullet"),
        Example(label: "Code", syntax: "`code`"),
        Example(label: "Link", syntax: "[link](https://example.com)")
    ]

    var dismiss: () -> Void = {}
    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Self.primaryTextColor)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Self.secondaryTextColor)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Self.primaryTextColor.opacity(isCloseHovered ? Self.closeHoverFillOpacity : Self.closeRestingFillOpacity))
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help("Close")
                .onHover { hovering in
                    isCloseHovered = hovering
                }
                .animation(.easeOut(duration: 0.12), value: isCloseHovered)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.examples) { example in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(example.syntax)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Self.primaryTextColor)
                            .frame(width: 178, alignment: .leading)

                        Text(example.label)
                            .foregroundStyle(Self.secondaryTextColor)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .background(Self.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 28, x: 0, y: 14)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(EditorAuxiliaryPresentation.markdownBasics.accessibilityLabel)
    }

    private static var backgroundColor: Color {
        Color(nsColor: NSColor(calibratedWhite: backgroundWhiteComponent, alpha: 1))
    }

    private static var primaryTextColor: Color {
        Color(nsColor: NSColor(calibratedRed: textRedComponent, green: textRedComponent, blue: textRedComponent, alpha: 1))
    }

    private static var secondaryTextColor: Color {
        primaryTextColor.opacity(0.58)
    }
}

struct MarkdownBasicsOverlay: View {
    static let scrimOpacity = 0.32
    static let scrimTransitionStyle = EditorAuxiliaryTransitionStyle.instant

    var dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(Self.scrimOpacity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum EditorStatusFormatter {
    static let maximumStatusMessageLength = 72

    struct LastSavedDisplay: Equatable {
        var label: String
        var detail: String?

        var accessibilityText: String {
            if let detail {
                return "\(label) \(detail)"
            }

            return label
        }
    }

    static func statisticsText(wordCount: Int, characterCount: Int) -> String {
        "\(wordCount) words — \(characterCount) characters"
    }

    static func statusText(
        wordCount: Int,
        characterCount: Int,
        isPreparingSuggestion: Bool,
        intelligentEditingStatus: String?
    ) -> String {
        let statistics = statisticsText(wordCount: wordCount, characterCount: characterCount)

        if isPreparingSuggestion {
            return statistics
        }

        if let message = statusMessage(
            isPreparingSuggestion: false,
            intelligentEditingStatus: intelligentEditingStatus
        ) {
            return "\(message) — \(statistics)"
        }

        return statistics
    }

    static func statusMessage(
        isPreparingSuggestion: Bool,
        intelligentEditingStatus: String?
    ) -> String? {
        if isPreparingSuggestion {
            return nil
        }

        guard let intelligentEditingStatus else {
            return nil
        }

        let message = userFacingMessage(from: intelligentEditingStatus)
        guard !message.isEmpty else {
            return nil
        }

        return truncatedStatusMessage(message)
    }

    static func statusIndicator(
        isPreparingSuggestion: Bool,
        intelligentEditingStatus: String?,
        intelligenceAvailability: IntelligenceAvailabilityStatus
    ) -> EditorStatusIndicator {
        guard intelligenceAvailability.isAvailable else {
            return EditorStatusIndicator(text: "AI not enabled", tone: .warning)
        }

        if let message = statusMessage(
            isPreparingSuggestion: isPreparingSuggestion,
            intelligentEditingStatus: intelligentEditingStatus
        ) {
            return EditorStatusIndicator(text: message, tone: .warning)
        }

        return EditorStatusIndicator(text: "AI available", tone: .available)
    }

    static func metadataText(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> String {
        if let detail = lastSavedDisplay.detail {
            return "\(lastSavedDisplay.label): \(detail)  |  \(statisticsText)"
        }

        return "\(lastSavedDisplay.label)  |  \(statisticsText)"
    }

    private static func userFacingMessage(from status: String) -> String {
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            trimmedStatus.contains("Apple Intelligence returned an unusable replacement")
                || trimmedStatus.contains("unchangedTransformOutput")
                || trimmedStatus.contains("fallback rejected")
                || trimmedStatus == "Intelligence could not make a useful suggestion."
                || trimmedStatus == "No replacement was suggested."
        {
            return "Suggestion unavailable."
        }

        let visibleMessages = [
            "Suggestion unavailable.",
            "Suggestion took too long.",
            "Apple Intelligence is not available on this Mac.",
            "Apple Intelligence is turned off in System Settings.",
            "Apple Intelligence is not ready yet.",
            "Apple Intelligence is unavailable.",
            "Apple Intelligence editing requires macOS 26 or later.",
            "Apple Intelligence editing requires Foundation Models."
        ]

        if visibleMessages.contains(trimmedStatus) {
            return trimmedStatus
        }

        let visibleAppleAvailabilityPrefixes = [
            "Apple Intelligence is not available on this Mac.",
            "Apple Intelligence is turned off in System Settings.",
            "Apple Intelligence is not ready yet.",
            "Apple Intelligence is unavailable.",
            "Apple Intelligence editing requires macOS 26 or later.",
            "Apple Intelligence editing requires Foundation Models."
        ]

        return visibleAppleAvailabilityPrefixes.contains { trimmedStatus.hasPrefix($0) } ? trimmedStatus : ""
    }

    private static func truncatedStatusMessage(_ message: String) -> String {
        guard message.count > maximumStatusMessageLength else {
            return message
        }

        return "\(message.prefix(maximumStatusMessageLength - 1))…"
    }

    static func lastSavedText(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        lastSavedDisplay(for: date, now: now, calendar: calendar).accessibilityText
    }

    static func lastSavedDisplay(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> LastSavedDisplay {
        guard let date else {
            return LastSavedDisplay(label: "Not saved yet", detail: nil)
        }

        let timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return LastSavedDisplay(label: "Last save", detail: formatted(date, format: "h:mm a", timeZone: timeZone))
        }

        return LastSavedDisplay(label: "Last save", detail: formatted(date, format: "MMM d, yyyy 'at' h:mm a", timeZone: timeZone))
    }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

struct EditorStatusIndicator: Equatable {
    enum Tone: Equatable {
        case available
        case warning
    }

    var text: String
    var tone: Tone

    var accessibilityText: String {
        switch tone {
        case .available:
            return "Status: \(text)"
        case .warning:
            return "Warning: \(text)"
        }
    }
}

struct EditorStatusBar: View {
    static let showsTopSeparator = false
    static let lastSavedDetailUsesPrimaryForeground = false
    static let horizontalInset: CGFloat = 28
    static let statusMessageMaximumWidth: CGFloat = 520
    static let statusDotDiameter: CGFloat = 7

    static func isVisible(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }

    var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay
    var statusIndicator: EditorStatusIndicator
    var statisticsText: String
    var statusAccessibilityLabel: String
    var usesDarkChrome: Bool

    nonisolated static func warningAmberColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(srgbRed: 0.97, green: 0.73, blue: 0.33, alpha: 1)
            : NSColor(srgbRed: 0.48, green: 0.29, blue: 0.0, alpha: 1)
    }

    nonisolated static func availableGreenColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(srgbRed: 0.47, green: 0.84, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.0, green: 0.39, blue: 0.16, alpha: 1)
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(nsColor: statusIndicatorColor))
                    .frame(width: Self.statusDotDiameter, height: Self.statusDotDiameter)

                Text(statusIndicator.text)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: statusIndicatorColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.statusMessageMaximumWidth, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusIndicator.accessibilityText)

            Spacer(minLength: 16)

            Text(EditorStatusFormatter.metadataText(lastSavedDisplay: lastSavedDisplay, statisticsText: statisticsText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("\(lastSavedDisplay.accessibilityText), \(statusAccessibilityLabel)")
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, 6)
    }

    private var statusIndicatorColor: NSColor {
        switch statusIndicator.tone {
        case .available:
            return Self.availableGreenColor(usesDarkChrome: usesDarkChrome)
        case .warning:
            return Self.warningAmberColor(usesDarkChrome: usesDarkChrome)
        }
    }
}

struct EditorModeSegmentedControl: View {
    struct LiquidBridge: Equatable {
        var from: EditorDisplayMode
        var to: EditorDisplayMode
    }

    static let segmentWidth: CGFloat = 78
    static let segmentHeight: CGFloat = 30
    static let selectedFillRedComponent: CGFloat = 0.86
    static let backgroundFillRedComponent: CGFloat = 1.0
    static let textFillRedComponent: CGFloat = 0.18
    static let darkSelectedFillRedComponent: CGFloat = 0.20
    static let darkBackgroundFillRedComponent: CGFloat = (LineformColors.darkControlBackground.usingColorSpace(.sRGB) ?? LineformColors.darkControlBackground).redComponent
    static let darkTextFillRedComponent: CGFloat = 0.92
    static let shadowRadius: CGFloat = 5
    static let hitAreaWidth: CGFloat = segmentWidth
    static let hitAreaHeight: CGFloat = segmentHeight
    static let dividerSlotWidth: CGFloat = 3
    static let liquidSettleDelay: TimeInterval = 0.16
    static let usesReduceMotionForLiquidBridge = true

    @Binding var selection: EditorDisplayMode
    var usesDarkChrome = false
    var reduceMotion = false

    @State private var hoveredMode: EditorDisplayMode?
    @State private var liquidBridge: LiquidBridge?
    @State private var liquidTransitionID = 0

    private let modes = EditorDisplayMode.allCases
    private let controlPadding: CGFloat = 3

    var body: some View {
        ZStack(alignment: .leading) {
            hoverPill
            selectedPill

            HStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    Button {
                        select(mode)
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Self.textFillColor(usesDarkChrome: usesDarkChrome))
                            .lineLimit(1)
                            .frame(width: Self.hitAreaWidth, height: Self.hitAreaHeight)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
                    .onHover { isHovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            hoveredMode = isHovering ? mode : nil
                        }
                    }

                    if index < modes.index(before: modes.endIndex) {
                        Rectangle()
                            .fill(Self.dividerColor(usesDarkChrome: usesDarkChrome).opacity(shouldShowDivider(after: index) ? 0.45 : 0))
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 1)
                    }
                }
            }
        }
        .padding(controlPadding)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Self.backgroundFillColor(usesDarkChrome: usesDarkChrome).opacity(usesDarkChrome ? 0.86 : 0.82))
                }
                .overlay {
                    Capsule()
                        .stroke((usesDarkChrome ? Color.white.opacity(0.10) : Color.white.opacity(0.72)), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.035), radius: Self.shadowRadius, y: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
    }

    private var selectedPill: some View {
        Capsule()
            .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome))
            .overlay {
                Capsule()
                    .stroke((usesDarkChrome ? Color.white.opacity(0.16) : Color.white.opacity(0.36)), lineWidth: 0.5)
            }
            .frame(width: selectedPillWidth, height: Self.segmentHeight)
            .offset(x: selectedPillOffset)
            .animation(
                EditorMotionPolicy.animation(.spring(response: 0.30, dampingFraction: 0.82), reduceMotion: reduceMotion),
                value: selection
            )
            .animation(
                EditorMotionPolicy.animation(.spring(response: 0.24, dampingFraction: 0.78), reduceMotion: reduceMotion),
                value: liquidBridge
            )
    }

    @ViewBuilder
    private var hoverPill: some View {
        if let hoveredMode, hoveredMode != selection {
            Capsule()
                .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome).opacity(0.48))
                .frame(width: Self.segmentWidth, height: Self.segmentHeight)
                .offset(x: Self.segmentOffset(for: hoveredMode))
                .transition(.opacity)
        }
    }

    private var selectedPillWidth: CGFloat {
        if let liquidBridge {
            return Self.liquidPillWidth(from: liquidBridge.from, to: liquidBridge.to)
        }

        return Self.segmentWidth
    }

    private var selectedPillOffset: CGFloat {
        if let liquidBridge {
            return Self.liquidPillOffset(from: liquidBridge.from, to: liquidBridge.to)
        }

        return Self.segmentOffset(for: selection)
    }

    private static func selectedFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkSelectedFillRedComponent : selectedFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: usesDarkChrome ? 0.92 : 0.74
            )
        )
    }

    private static func backgroundFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkBackgroundFillRedComponent : backgroundFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: 1
            )
        )
    }

    private static func textFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkTextFillRedComponent : textFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: 1
            )
        )
    }

    private static func dividerColor(usesDarkChrome: Bool) -> Color {
        usesDarkChrome ? .white : Color(nsColor: .separatorColor)
    }

    static func segmentOffset(for mode: EditorDisplayMode) -> CGFloat {
        guard let index = EditorDisplayMode.allCases.firstIndex(of: mode) else {
            return 0
        }

        return CGFloat(index) * (Self.segmentWidth + Self.dividerSlotWidth)
    }

    static func liquidPillOffset(from source: EditorDisplayMode, to destination: EditorDisplayMode) -> CGFloat {
        min(segmentOffset(for: source), segmentOffset(for: destination))
    }

    static func liquidPillWidth(from source: EditorDisplayMode, to destination: EditorDisplayMode) -> CGFloat {
        abs(segmentOffset(for: destination) - segmentOffset(for: source)) + Self.segmentWidth
    }

    private func select(_ mode: EditorDisplayMode) {
        guard mode != selection else {
            return
        }

        guard !reduceMotion else {
            liquidTransitionID += 1
            liquidBridge = nil
            selection = mode
            return
        }

        let previousSelection = selection
        liquidTransitionID += 1
        let transitionID = liquidTransitionID

        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            liquidBridge = LiquidBridge(from: previousSelection, to: mode)
            selection = mode
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liquidSettleDelay) {
            guard transitionID == liquidTransitionID else {
                return
            }

            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                liquidBridge = nil
            }
        }
    }

    private func shouldShowDivider(after index: Int) -> Bool {
        guard index < modes.index(before: modes.endIndex) else {
            return false
        }

        let nextIndex = modes.index(after: index)
        return modes[index] != selection && modes[nextIndex] != selection
    }
}

private struct WindowChromeReader: NSViewRepresentable {
    @Binding var windowNumber: Int?
    var usesDarkChrome: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyChrome(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyChrome(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.appearance = nil
    }

    private func applyChrome(to window: NSWindow?) {
        windowNumber = window?.windowNumber
        window?.appearance = EditorWindowChrome.appearance(usesDarkChrome: usesDarkChrome)
    }
}

struct EditorWindowChrome {
    static func appearanceName(usesDarkChrome: Bool) -> NSAppearance.Name {
        usesDarkChrome ? .darkAqua : .aqua
    }

    static func appearance(usesDarkChrome: Bool) -> NSAppearance? {
        NSAppearance(named: appearanceName(usesDarkChrome: usesDarkChrome))
    }
}
