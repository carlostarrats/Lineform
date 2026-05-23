import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))
    @State private var isShowingReadingExperience = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline = false
    @State private var requestedSelection: NSRange?
    @State private var intelligentSuggestion: IntelligentEditingSuggestion?
    @State private var currentIntelligentChangeIndex = 0
    @State private var isRunningIntelligentEdit = false
    @State private var intelligentEditingStatus: String?
    private let intelligentEditingService = FoundationModelsIntelligentEditingService()

    var body: some View {
        HStack(spacing: 0) {
            if isShowingOutline {
                OutlineSidebarView(items: outlineItems, jumpToHeading: jumpToHeading)
                Divider()
            }

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
        }
        .background(Color(nsColor: Theme.theme(for: readingProfileStore.activeProfile.themeID).backgroundColor))
        .toolbar {
            Picker("Mode", selection: $displayMode) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .accessibilityLabel("Editor mode")

            Button {
                isShowingOutline.toggle()
            } label: {
                Label("Outline", systemImage: "sidebar.leading")
            }
            .help("Outline")

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
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.showReadingExperience.name)) { _ in
            isShowingReadingExperience = true
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.runIntelligentEditingAction.name)) { notification in
            guard
                let rawValue = notification.object as? String,
                let action = IntelligentEditingAction(rawValue: rawValue)
            else {
                return
            }
            runIntelligentEditingAction(action)
        }
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

    private var outlineItems: [MarkdownOutlineItem] {
        MarkdownOutlineParser().items(in: document.text)
    }

    private func jumpToHeading(_ item: MarkdownOutlineItem) {
        requestedSelection = item.characterRange
        if displayMode == .read {
            displayMode = .write
        }
    }

    private var statusText: String {
        let stats = DocumentStatistics(text: document.text)
        if isRunningIntelligentEdit {
            return "Preparing suggestion - \(stats.wordCount) words, \(stats.characterCount) characters"
        }
        if let intelligentEditingStatus {
            return "\(intelligentEditingStatus) - \(stats.wordCount) words, \(stats.characterCount) characters"
        }
        return "\(stats.wordCount) words, \(stats.characterCount) characters"
    }

    private var statusAccessibilityLabel: String {
        let stats = DocumentStatistics(text: document.text)
        return "Document contains \(stats.wordCount) words and \(stats.characterCount) characters"
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
                    intelligentSuggestion = suggestion
                    currentIntelligentChangeIndex = 0
                    isRunningIntelligentEdit = false
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

        document.text = intelligentSuggestion.accept(in: document.text)
        requestedSelection = NSRange(location: intelligentSuggestion.selectedRange.location, length: (intelligentSuggestion.replacementText as NSString).length)
        self.intelligentSuggestion = nil
        intelligentEditingStatus = "Suggestion accepted."
    }

    private func rejectIntelligentSuggestion() {
        intelligentSuggestion = nil
        intelligentEditingStatus = "Suggestion rejected."
    }
}
