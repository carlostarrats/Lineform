import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))
    @State private var isShowingReadingExperience = false
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
                Picker("Mode", selection: $displayMode) {
                    ForEach(EditorDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .accessibilityLabel("Editor mode")
            }

            ToolbarItem(placement: .primaryAction) {
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

            Divider()

            if let intelligentSuggestion {
                IntelligentEditingSuggestionBar(
                    suggestion: intelligentSuggestion,
                    currentChangeIndex: $currentIntelligentChangeIndex,
                    navigateToChange: navigateToSuggestedChange,
                    accept: acceptIntelligentSuggestion,
                    reject: rejectIntelligentSuggestion
                )

                Divider()
            }

            HStack {
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(statusAccessibilityLabel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: Theme.theme(for: readingProfileStore.activeProfile).backgroundColor))
    }

    @ViewBuilder
    private var editorContent: some View {
        switch displayMode {
        case .write:
            markdownEditor
        case .read:
            DebouncedMarkdownPreviewView(text: document.text, profile: readingProfileStore.activeProfile)
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
        if isRunningIntelligentEdit {
            return "Preparing suggestion - \(documentStatistics.wordCount) words, \(documentStatistics.characterCount) characters"
        }
        if let intelligentEditingStatus {
            return "\(intelligentEditingStatus) - \(documentStatistics.wordCount) words, \(documentStatistics.characterCount) characters"
        }
        return "\(documentStatistics.wordCount) words, \(documentStatistics.characterCount) characters"
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
