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
        .toolbar {
            ToolbarItem(placement: .principal) {
                EditorModeSegmentedControl(selection: $displayMode, usesDarkChrome: theme.usesDarkChrome)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(EditorToolbarAction.primaryActions(in: displayMode)) { action in
                    Button {
                        handleToolbarAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .help(action.title)
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
            if let activeIntelligentSuggestion, !activeIntelligentSuggestion.canApply(to: newValue) {
                clearIntelligentSuggestions()
                intelligentEditingStatus = "Suggestion expired after edits."
            }
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
            intelligentSuggestionRange: activeIntelligentSuggestion?.selectedRange
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

    private func jumpToHeading(_ item: MarkdownOutlineItem) {
        requestedSelection = item.characterRange
        if displayMode == .read {
            displayMode = .write
        }
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

        isRunningIntelligentEdit = true
        pendingIntelligentAction = action
        pendingIntelligentSelectedText = editingContext.selectedText
        clearIntelligentSuggestions()
        intelligentEditingStatus = nil

        let task = Task {
            let runner = IntelligentEditingRunner(service: intelligentEditingService)
            do {
                let optionCount = IntelligentEditingPresentationPolicy.optionCount(for: action, selectedText: editingContext.selectedText)

                if optionCount > 1 {
                    let suggestions = try await runner.runOptions(
                        action: action,
                        documentText: editingContext.text,
                        selectedRange: editingContext.selectedRange,
                        optionCount: optionCount
                    )

                    await MainActor.run {
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
                        intelligentEditingStatus = "\(applicableSuggestions.count) options ready."
                        requestedSelection = applicableSuggestions[0].selectedRange
                    }
                    return
                }

                let suggestion = try await runner.run(
                    action: action,
                    documentText: editingContext.text,
                    selectedRange: editingContext.selectedRange
                )

                await MainActor.run {
                    isRunningIntelligentEdit = false
                    intelligentEditingTask = nil
                    pendingIntelligentAction = nil
                    pendingIntelligentSelectedText = ""
                    guard suggestion.canApply(to: document.text) else {
                        clearIntelligentSuggestions()
                        intelligentEditingStatus = "Suggestion expired after edits."
                        return
                    }
                    intelligentOptions = [suggestion]
                    selectedIntelligentOptionIndex = 0
                    currentIntelligentChangeIndex = 0
                    intelligentEditingStatus = "1 option ready."
                    requestedSelection = suggestion.selectedRange
                }
            } catch {
                await MainActor.run {
                    clearIntelligentSuggestions()
                    isRunningIntelligentEdit = false
                    intelligentEditingTask = nil
                    pendingIntelligentAction = nil
                    pendingIntelligentSelectedText = ""
                    intelligentEditingStatus = error is CancellationError ? "Suggestion canceled." : (error as? LocalizedError)?.errorDescription ?? "Suggestion unavailable."
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

    private func handleToolbarAction(_ action: EditorToolbarAction) {
        switch action {
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
}

enum EditorToolbarAction: CaseIterable, Equatable, Identifiable {
    case markdownBasics
    case readingExperience

    var id: Self { self }

    var title: String {
        switch self {
        case .markdownBasics:
            return "Markdown Basics"
        case .readingExperience:
            return "Reading Experience"
        }
    }

    var systemImage: String {
        switch self {
        case .markdownBasics:
            return "info.circle"
        case .readingExperience:
            return "textformat.size"
        }
    }

    static func primaryActions(in mode: EditorDisplayMode) -> [EditorToolbarAction] {
        if EditorToolbarVisibility.showsMarkdownBasics(in: mode) {
            return [.markdownBasics, .readingExperience]
        }

        return [.readingExperience]
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
