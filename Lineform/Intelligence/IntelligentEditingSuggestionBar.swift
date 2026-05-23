import SwiftUI

struct IntelligentEditingSuggestionBar: View {
    let suggestion: IntelligentEditingSuggestion
    @Binding var currentChangeIndex: Int
    var navigateToChange: (MarkdownDiff.Change) -> Void
    var accept: () -> Void
    var reject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.action.title)
                    .font(.callout.weight(.semibold))
                Text(suggestion.diff.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                moveChange(by: -1)
            } label: {
                Label("Previous Change", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(suggestion.diff.changes.isEmpty)
            .help("Previous Change")

            Text(changePositionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72)
                .accessibilityLabel(changePositionAccessibilityLabel)

            Button {
                moveChange(by: 1)
            } label: {
                Label("Next Change", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(suggestion.diff.changes.isEmpty)
            .help("Next Change")

            Divider()
                .frame(height: 18)

            Button("Reject", action: reject)
                .keyboardShortcut(.cancelAction)

            Button("Accept", action: accept)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lineform suggestion")
    }

    private var changePositionText: String {
        guard !suggestion.diff.changes.isEmpty else {
            return "0 of 0"
        }
        return "\(currentChangeIndex + 1) of \(suggestion.diff.changes.count)"
    }

    private var changePositionAccessibilityLabel: String {
        guard !suggestion.diff.changes.isEmpty else {
            return "No changed lines"
        }
        return "Changed line \(currentChangeIndex + 1) of \(suggestion.diff.changes.count)"
    }

    private func moveChange(by offset: Int) {
        guard !suggestion.diff.changes.isEmpty else {
            return
        }

        let nextIndex = min(max(currentChangeIndex + offset, 0), suggestion.diff.changes.count - 1)
        currentChangeIndex = nextIndex
        navigateToChange(suggestion.diff.changes[nextIndex])
    }
}
