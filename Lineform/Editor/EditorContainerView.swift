import SwiftUI

struct EditorContainerView: View {
    @Binding var document: LineformDocument

    var body: some View {
        MarkdownTextViewRepresentable(text: $document.text)
            .frame(minWidth: 640, minHeight: 480)
            .accessibilityLabel("Markdown editor")
    }
}
