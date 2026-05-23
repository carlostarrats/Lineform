import SwiftUI

struct DebouncedMarkdownPreviewView: View {
    let text: String
    let profile: ReadingProfile
    @State private var previewText = ""
    @State private var pendingUpdate: DispatchWorkItem?

    var body: some View {
        MarkdownPreviewViewRepresentable(text: resolvedPreviewText, profile: profile)
            .accessibilityLabel("Markdown read view")
            .onAppear {
                previewText = text
            }
            .onChange(of: text) { _, newValue in
                pendingUpdate?.cancel()
                let workItem = DispatchWorkItem {
                    previewText = newValue
                }
                pendingUpdate = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
            }
            .onDisappear {
                pendingUpdate?.cancel()
            }
    }

    private var resolvedPreviewText: String {
        previewText.isEmpty && !text.isEmpty ? text : previewText
    }
}
