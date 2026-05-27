import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
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
    @State private var isIntelligenceRailEnabled = false
    @State private var intelligentOptions: [IntelligentEditingSuggestion] = []
    @State private var selectedIntelligentOptionIndex = 0
    @State private var currentIntelligentChangeIndex = 0
    @State private var isRunningIntelligentEdit = false
    @State private var intelligentEditingTask: Task<Void, Never>?
    @State private var pendingIntelligentAction: IntelligentEditingAction?
    @State private var pendingIntelligentSelectedText = ""
    @State private var intelligentEditingStatus: String?
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    private let intelligentEditingService = FoundationModelsIntelligentEditingService()

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
                EditorModeSegmentedControl(selection: $displayMode, usesDarkChrome: theme.usesDarkChrome)
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
            isShowingReadingInspector = true
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
        .onChange(of: displayMode) { _, mode in
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
            documentStatistics = DocumentStatistics(text: document.text)
            outlineItems = MarkdownOutlineParser().items(in: document.text)
        }
        .onChange(of: document.text) { _, newValue in
            documentStatistics = DocumentStatistics(text: newValue)
            outlineItems = MarkdownOutlineParser().items(in: newValue)
            refreshSearchMatches(selectFirstWhenNeeded: activeSearchIndex == nil)
            if let activeIntelligentSuggestion, !activeIntelligentSuggestion.canApply(to: newValue) {
                clearIntelligentSuggestions()
                intelligentEditingStatus = "Suggestion expired after edits."
            }
        }
        .onChange(of: searchQuery) { _, _ in
            refreshSearchMatches(selectFirstWhenNeeded: true)
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
                        insertion: .offset(y: MarkdownBasicsModal.entranceYOffset).combined(with: .opacity),
                        removal: .offset(y: MarkdownBasicsModal.entranceYOffset / 2).combined(with: .opacity)
                    )
                )
                .zIndex(2)
            }
        }
        .animation(.easeOut(duration: MarkdownBasicsModal.animationDuration), value: isShowingMarkdownBasics)
    }

    private var editorPrimaryShell: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                editorContent
                    .frame(minWidth: EditorLayout.minimumContentWidth, minHeight: EditorLayout.minimumContentHeight)

                if EditorStatusBar.isVisible(in: displayMode) {
                    EditorStatusBar(
                        lastSavedDisplay: lastSavedDisplay,
                        statusText: statusText,
                        statusAccessibilityLabel: statusAccessibilityLabel
                    )
                }
            }

            if IntelligenceActionRailPresentation.isVisible(isEnabled: isIntelligenceRailEnabled, displayMode: displayMode) {
                IntelligenceActionRailOverlayHost(
                    actions: IntelligentEditingAction.actionRailActions,
                    isActionEnabled: intelligenceRailActionsAreEnabled,
                    runAction: { action in
                        runIntelligentEditingAction(action)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    .asymmetric(
                        insertion: .offset(y: IntelligenceActionRailPresentation.entranceYOffset).combined(with: .opacity),
                        removal: .offset(y: IntelligenceActionRailPresentation.entranceYOffset / 2).combined(with: .opacity)
                    )
                )
                .zIndex(1)
            }

            if shouldShowIntelligentOptionsPanel {
                GeometryReader { proxy in
                    let isLoadingIntelligentOptions = isRunningIntelligentEdit && pendingIntelligentAction != nil
                    let panelReferenceText = isLoadingIntelligentOptions
                        ? pendingIntelligentSelectedText
                        : activeIntelligentSuggestion?.originalText ?? ""
                    let placement = IntelligentEditingOverlayPlacement.placement(
                        anchorRect: selectionAnchorRect,
                        containerSize: proxy.size,
                        replacementText: isLoadingIntelligentOptions ? panelReferenceText : activeIntelligentSuggestion?.replacementText ?? ""
                    )

                    IntelligentEditingOptionsPanel(
                        suggestions: isLoadingIntelligentOptions ? [] : intelligentOptions,
                        selectedIndex: $selectedIntelligentOptionIndex,
                        loadingActionTitle: isLoadingIntelligentOptions ? pendingIntelligentAction?.title : nil,
                        loadingPreviewText: panelReferenceText,
                        maximumBodyHeight: placement.bodyHeight,
                        retry: retryIntelligentSuggestion,
                        accept: acceptIntelligentSuggestion,
                        reject: rejectIntelligentSuggestion
                    )
                    .frame(maxWidth: placement.width)
                    .position(placement.position)
                }
                .transition(.scale(scale: 0.98).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .background(Color(nsColor: currentTheme.backgroundColor))
        .animation(.easeOut(duration: 0.18), value: intelligentOptions)
        .animation(.easeOut(duration: IntelligenceActionRailPresentation.animationDuration), value: isIntelligenceRailEnabled)
        .animation(.easeOut(duration: IntelligenceActionRailPresentation.animationDuration), value: displayMode)
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
            selectionContext: $selectionContext,
            requestedSelection: $requestedSelection,
            selectionAnchorRect: $selectionAnchorRect,
            profile: readingProfileStore.activeProfile,
            intelligentSuggestionRange: activeIntelligentSuggestion?.selectedRange,
            searchRanges: searchMatches,
            activeSearchRange: activeSearchRange
        )
        .accessibilityLabel("Markdown editor")
    }

    private var activeIntelligentSuggestion: IntelligentEditingSuggestion? {
        guard !intelligentOptions.isEmpty else {
            return nil
        }

        let safeIndex = min(max(selectedIntelligentOptionIndex, 0), intelligentOptions.count - 1)
        return intelligentOptions[safeIndex]
    }

    private var shouldShowIntelligentOptionsPanel: Bool {
        (isRunningIntelligentEdit && pendingIntelligentAction != nil) || !intelligentOptions.isEmpty
    }

    private var hasActionableIntelligentSelection: Bool {
        !selectionContext.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var intelligenceRailActionsAreEnabled: Bool {
        hasActionableIntelligentSelection
            && !isRunningIntelligentEdit
            && IntelligenceAvailabilityService().currentStatus().isAvailable
    }

    private var activeSearchRange: NSRange? {
        guard let activeSearchIndex, searchMatches.indices.contains(activeSearchIndex) else {
            return nil
        }
        return searchMatches[activeSearchIndex]
    }

    private func jumpToHeading(_ item: MarkdownOutlineItem) {
        requestedSelection = item.characterRange
        if displayMode == .read {
            displayMode = .write
        }
    }

    private func refreshSearchMatches(selectFirstWhenNeeded: Bool) {
        let matches = EditorSearchResolver.matches(in: document.text, query: searchQuery)
        searchMatches = matches

        guard !matches.isEmpty else {
            activeSearchIndex = nil
            return
        }

        if
            let activeSearchIndex,
            matches.indices.contains(activeSearchIndex)
        {
            selectSearchMatch(at: activeSearchIndex)
        } else if selectFirstWhenNeeded {
            activeSearchIndex = 0
            selectSearchMatch(at: 0)
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

    private var statusText: String {
        EditorStatusFormatter.statusText(
            wordCount: documentStatistics.wordCount,
            characterCount: documentStatistics.characterCount,
            isPreparingSuggestion: isRunningIntelligentEdit,
            intelligentEditingStatus: intelligentEditingStatus
        )
    }

    private var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay {
        EditorStatusFormatter.lastSavedDisplay(for: documentSaveStatus.savedAt(for: document.id))
    }

    private var statusAccessibilityLabel: String {
        return "Document contains \(documentStatistics.wordCount) words and \(documentStatistics.characterCount) characters"
    }

    private func runIntelligentEditingAction(_ action: IntelligentEditingAction, selectedRange overrideSelectedRange: NSRange? = nil) {
        guard !isRunningIntelligentEdit else {
            return
        }

        let editingContext = SelectionContext(
            text: document.text,
            selectedRange: overrideSelectedRange ?? selectionContext.selectedRange
        )

        guard !editingContext.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            intelligentEditingStatus = "Select text to use Intelligence."
            return
        }

        isRunningIntelligentEdit = true
        pendingIntelligentAction = action
        pendingIntelligentSelectedText = editingContext.selectedText
        clearIntelligentSuggestions()
        intelligentEditingStatus = nil

        let task = Task {
            let coordinator = IntelligentEditingRequestCoordinator(service: intelligentEditingService)
            let result = await coordinator.run(
                action: action,
                documentText: editingContext.text,
                currentDocumentText: editingContext.text,
                selectedRange: editingContext.selectedRange
            )

            await MainActor.run {
                switch result {
                case .ready(let suggestions, _):
                    isRunningIntelligentEdit = false
                    intelligentEditingTask = nil
                    pendingIntelligentAction = nil
                    pendingIntelligentSelectedText = ""
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
                    pendingIntelligentAction = nil
                    pendingIntelligentSelectedText = ""
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

        runIntelligentEditingAction(intelligentSuggestion.action, selectedRange: intelligentSuggestion.selectedRange)
    }

    private func rejectIntelligentSuggestion() {
        if isRunningIntelligentEdit {
            intelligentEditingTask?.cancel()
            intelligentEditingTask = nil
            isRunningIntelligentEdit = false
            pendingIntelligentAction = nil
            pendingIntelligentSelectedText = ""
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
        if !isRunningIntelligentEdit {
            pendingIntelligentSelectedText = ""
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

    @ViewBuilder
    private func toolbarControl(for action: EditorToolbarAction) -> some View {
        switch action {
        case .intelligence:
            Button {
                isIntelligenceRailEnabled.toggle()
            } label: {
                IntelligenceToolbarIcon(
                    systemImage: action.systemImage,
                    isOn: isIntelligenceRailEnabled
                )
            }
            .help(isIntelligenceRailEnabled ? "Hide Intelligence Actions" : "Show Intelligence Actions")
            .accessibilityLabel(action.title)
        case .markdownBasics, .readingExperience:
            Button {
                handleToolbarAction(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .help(action.title)
        }
    }

    private func handleToolbarAction(_ action: EditorToolbarAction) {
        switch action {
        case .intelligence:
            isIntelligenceRailEnabled.toggle()
        case .markdownBasics:
            isShowingMarkdownBasics.toggle()
        case .readingExperience:
            isShowingReadingInspector.toggle()
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
}

enum EditorLayout {
    static let minimumContentWidth: CGFloat = 300
    static let minimumContentHeight: CGFloat = 480
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

    static func isVisible(isEnabled: Bool, displayMode: EditorDisplayMode) -> Bool {
        isEnabled && displayMode == .write
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

struct IntelligenceToolbarIcon: View {
    let systemImage: String
    let isOn: Bool

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
                .foregroundStyle(
                    isOn
                        ? Color.white.opacity(IntelligenceToolbarTogglePresentation.iconOpacityWhenOn)
                        : Color(nsColor: .labelColor).opacity(IntelligenceToolbarTogglePresentation.iconOpacityWhenOff)
                )
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

    var isEnabled: Bool
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
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        registerHitTestRegion()

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
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
        guard let window else {
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

        init(window: NSWindow, rect: NSRect) {
            self.window = window
            self.rect = rect
        }
    }

    nonisolated(unsafe) private static var regions: [ObjectIdentifier: Region] = [:]

    static func setRegion(owner: AnyObject, window: NSWindow, rect: NSRect) {
        regions[ObjectIdentifier(owner)] = Region(window: window, rect: rect)
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
        kind: .nativeInspector,
        presenter: .systemInspector,
        accessibilityLabel: "Reading Experience Inspector",
        minimumWidth: 280,
        idealWidth: 320,
        maximumWidth: 380,
        transitionStyle: .slideAndFade,
        animationDuration: nil
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
            return "Preparing suggestion — \(statistics)"
        }

        if let intelligentEditingStatus {
            return "\(intelligentEditingStatus) — \(statistics)"
        }

        return statistics
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

struct EditorStatusBar: View {
    static let showsTopSeparator = false
    static let lastSavedDetailUsesPrimaryForeground = true

    static func isVisible(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }

    var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay
    var statusText: String
    var statusAccessibilityLabel: String

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text(lastSavedDisplay.label)
                    .foregroundStyle(.secondary)

                if let detail = lastSavedDisplay.detail {
                    Text(detail)
                        .foregroundStyle(.primary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lastSavedDisplay.accessibilityText)

            Spacer(minLength: 16)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(statusAccessibilityLabel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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

    @Binding var selection: EditorDisplayMode
    var usesDarkChrome = false

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
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: selection)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: liquidBridge)
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
