import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
    @ObservedObject private var documentSaveStatus = DocumentSaveStatus.shared
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))
    @State private var isShowingReadingExperience = false
    @State private var isShowingMarkdownBasics = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline = false
    @State private var outlineItems: [MarkdownOutlineItem] = []
    @State private var requestedSelection: NSRange?
    @State private var intelligentSuggestion: IntelligentEditingSuggestion?
    @State private var currentIntelligentChangeIndex = 0
    @State private var isRunningIntelligentEdit = false
    @State private var intelligentEditingStatus: String?
    @State private var documentStatistics = DocumentStatistics(text: "")
    @State private var windowNumber: Int?
    private let intelligentEditingService = FoundationModelsIntelligentEditingService()

    var body: some View {
        NavigationSplitView(columnVisibility: outlineVisibility) {
            OutlineSidebarView(items: outlineItems, jumpToHeading: jumpToHeading)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            editorShell
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowNumberReader(windowNumber: $windowNumber))
        .toolbar {
            ToolbarItem(placement: .principal) {
                EditorModeSegmentedControl(selection: $displayMode)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if EditorToolbarVisibility.showsMarkdownBasics(in: displayMode) {
                    Button {
                        isShowingMarkdownBasics.toggle()
                    } label: {
                        Label("Markdown Basics", systemImage: "info.circle")
                    }
                    .help("Markdown Basics")
                    .popover(isPresented: $isShowingMarkdownBasics, arrowEdge: .bottom) {
                        MarkdownBasicsPopover()
                    }
                }

                Button {
                    isShowingReadingExperience.toggle()
                } label: {
                    Label("Reading Experience", systemImage: "textformat.size")
                }
                .help("Reading Experience")
                .popover(isPresented: $isShowingReadingExperience, arrowEdge: .bottom) {
                    ReadingExperiencePopover(store: readingProfileStore)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showReadingExperience.name)) { notification in
            guard notificationMatchesActiveWindow(notification) else {
                return
            }
            isShowingReadingExperience = true
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.runIntelligentEditingAction.name)) { notification in
            guard
                notificationMatchesActiveWindow(notification),
                let rawValue = notificationPayloadValue(notification),
                let action = IntelligentEditingAction(rawValue: rawValue)
            else {
                return
            }
            runIntelligentEditingAction(action)
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
            if let intelligentSuggestion, !intelligentSuggestion.canApply(to: newValue) {
                self.intelligentSuggestion = nil
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
        VStack(spacing: 0) {
            editorContent
                .frame(minWidth: 640, minHeight: 480)

            if let intelligentSuggestion {
                IntelligentEditingSuggestionBar(
                    suggestion: intelligentSuggestion,
                    currentChangeIndex: $currentIntelligentChangeIndex,
                    navigateToChange: navigateToSuggestedChange,
                    accept: acceptIntelligentSuggestion,
                    reject: rejectIntelligentSuggestion
                )
            }

            if EditorStatusBar.isVisible(in: displayMode) {
                EditorStatusBar(
                    lastSavedDisplay: lastSavedDisplay,
                    statusText: statusText,
                    statusAccessibilityLabel: statusAccessibilityLabel
                )
            }
        }
        .background(Color(nsColor: Theme.theme(for: readingProfileStore.activeProfile).backgroundColor))
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
            profile: readingProfileStore.activeProfile,
            intelligentSuggestionRange: intelligentSuggestion?.selectedRange
        )
        .accessibilityLabel("Markdown editor")
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

    private func runIntelligentEditingAction(_ action: IntelligentEditingAction) {
        guard !isRunningIntelligentEdit else {
            return
        }

        isRunningIntelligentEdit = true
        intelligentEditingStatus = nil

        Task {
            let runner = IntelligentEditingRunner(service: intelligentEditingService)
            do {
                let suggestion = try await runner.run(
                    action: action,
                    documentText: document.text,
                    selectedRange: selectionContext.selectedRange
                )

                await MainActor.run {
                    isRunningIntelligentEdit = false
                    guard suggestion.canApply(to: document.text) else {
                        intelligentSuggestion = nil
                        intelligentEditingStatus = "Suggestion expired after edits."
                        return
                    }
                    intelligentSuggestion = suggestion
                    currentIntelligentChangeIndex = 0
                    intelligentEditingStatus = suggestion.diff.summary
                    requestedSelection = suggestion.selectedRange
                }
            } catch {
                await MainActor.run {
                    intelligentSuggestion = nil
                    isRunningIntelligentEdit = false
                    intelligentEditingStatus = (error as? LocalizedError)?.errorDescription ?? "Suggestion unavailable."
                }
            }
        }
    }

    private func navigateToSuggestedChange(_ change: MarkdownDiff.Change) {
        guard let intelligentSuggestion else {
            return
        }

        requestedSelection = NSRange(
            location: intelligentSuggestion.selectedRange.location + change.replacementRange.location,
            length: max(change.replacementRange.length, 1)
        )
    }

    private func acceptIntelligentSuggestion() {
        guard let intelligentSuggestion else {
            return
        }

        guard let updatedText = intelligentSuggestion.accept(in: document.text) else {
            self.intelligentSuggestion = nil
            intelligentEditingStatus = "Suggestion expired after edits."
            return
        }

        document.text = updatedText
        requestedSelection = NSRange(location: intelligentSuggestion.selectedRange.location, length: (intelligentSuggestion.replacementText as NSString).length)
        self.intelligentSuggestion = nil
        intelligentEditingStatus = "Suggestion accepted."
    }

    private func rejectIntelligentSuggestion() {
        intelligentSuggestion = nil
        intelligentEditingStatus = "Suggestion rejected."
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
}

enum EditorReadingLayout {
    static func textColumnMaxWidth(for profile: ReadingProfile) -> CGFloat {
        CGFloat(profile.columnWidth)
    }

    static func horizontalInset(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(CGFloat(profile.marginWidth), (containerWidth - textColumnMaxWidth(for: profile)) / 2)
    }
}

enum EditorToolbarVisibility {
    static func showsMarkdownBasics(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }
}

struct MarkdownBasicsPopover: View {
    struct Example: Identifiable, Equatable {
        var label: String
        var syntax: String

        var id: String { syntax }
    }

    static let title = "Markdown Basics"
    static let examples = [
        Example(label: "Title", syntax: "# Title"),
        Example(label: "Section", syntax: "## Section"),
        Example(label: "Bold", syntax: "**bold**"),
        Example(label: "Italic", syntax: "_italic_"),
        Example(label: "Bullet", syntax: "- bullet"),
        Example(label: "Code", syntax: "`code`"),
        Example(label: "Link", syntax: "[link](https://example.com)")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.examples) { example in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(example.syntax)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(width: 178, alignment: .leading)

                        Text(example.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
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
    static let shadowRadius: CGFloat = 5
    static let hitAreaWidth: CGFloat = segmentWidth
    static let hitAreaHeight: CGFloat = segmentHeight
    static let dividerSlotWidth: CGFloat = 3
    static let liquidSettleDelay: TimeInterval = 0.16

    @Binding var selection: EditorDisplayMode

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
                            .foregroundStyle(.primary)
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
                            .fill(Color(nsColor: .separatorColor).opacity(shouldShowDivider(after: index) ? 0.45 : 0))
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
                        .fill(Self.backgroundFillColor.opacity(0.82))
                }
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.72), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.035), radius: Self.shadowRadius, y: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
    }

    private var selectedPill: some View {
        Capsule()
            .fill(Self.selectedFillColor)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.36), lineWidth: 0.5)
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
                .fill(Self.selectedFillColor.opacity(0.48))
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

    private static var selectedFillColor: Color {
        Color(
            nsColor: NSColor(
                calibratedRed: selectedFillRedComponent,
                green: selectedFillRedComponent,
                blue: selectedFillRedComponent,
                alpha: 0.74
            )
        )
    }

    private static var backgroundFillColor: Color {
        Color(
            nsColor: NSColor(
                calibratedRed: backgroundFillRedComponent,
                green: backgroundFillRedComponent,
                blue: backgroundFillRedComponent,
                alpha: 1
            )
        )
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

private struct WindowNumberReader: NSViewRepresentable {
    @Binding var windowNumber: Int?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            windowNumber = view.window?.windowNumber
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            windowNumber = nsView.window?.windowNumber
        }
    }
}
