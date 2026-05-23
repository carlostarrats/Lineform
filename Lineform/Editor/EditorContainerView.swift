import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @StateObject private var readingProfileStore = ReadingProfileStore()
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))
    @State private var isShowingReadingExperience = false

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTextViewRepresentable(
                text: $document.text,
                selectionContext: $selectionContext,
                profile: readingProfileStore.activeProfile
            )
                .frame(minWidth: 640, minHeight: 480)
                .accessibilityLabel("Markdown editor")

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
        .background(Color(nsColor: Theme.theme(for: readingProfileStore.activeProfile.themeID).backgroundColor))
        .toolbar {
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

    private var statusText: String {
        let stats = DocumentStatistics(text: document.text)
        return "\(stats.wordCount) words, \(stats.characterCount) characters"
    }

    private var statusAccessibilityLabel: String {
        let stats = DocumentStatistics(text: document.text)
        return "Document contains \(stats.wordCount) words and \(stats.characterCount) characters"
    }
}
