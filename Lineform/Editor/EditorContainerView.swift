import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument
    @State private var selectionContext = SelectionContext(text: "", selectedRange: NSRange(location: 0, length: 0))

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTextViewRepresentable(text: $document.text, selectionContext: $selectionContext)
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
