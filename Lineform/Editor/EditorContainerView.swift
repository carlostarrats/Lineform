import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))
    @State private var isShowingReadingExperience = false
    @State private var displayMode = EditorDisplayMode.write
    @State private var isShowingOutline = false
    @State private var requestedSelection: NSRange?

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
    }

    @ViewBuilder
    private var editorContent: some View {
        switch displayMode {
        case .write:
            markdownEditor
        case .preview:
            MarkdownPreviewViewRepresentable(text: document.text, profile: readingProfileStore.activeProfile)
                .accessibilityLabel("Markdown preview")
        case .split:
            HStack(spacing: 0) {
                markdownEditor
                Divider()
                MarkdownPreviewViewRepresentable(text: document.text, profile: readingProfileStore.activeProfile)
                    .accessibilityLabel("Markdown preview")
            }
        }
    }

    private var markdownEditor: some View {
        MarkdownTextViewRepresentable(
            text: $document.text,
            selectionContext: $selectionContext,
            requestedSelection: $requestedSelection,
            profile: readingProfileStore.activeProfile
        )
        .accessibilityLabel("Markdown editor")
    }

    private var outlineItems: [MarkdownOutlineItem] {
        MarkdownOutlineParser().items(in: document.text)
    }

    private func jumpToHeading(_ item: MarkdownOutlineItem) {
        requestedSelection = item.characterRange
        if displayMode == .preview {
            displayMode = .write
        }
    }

    private var statusText: String {
        let stats = DocumentStatistics(text: document.text)
        return "\(stats.wordCount) words, \(stats.characterCount) characters"
    }

    private var statusAccessibilityLabel: String {
        let stats = DocumentStatistics(text: document.text)
        return "Document contains \(stats.wordCount) words and \(stats.characterCount) characters"
    }
}
