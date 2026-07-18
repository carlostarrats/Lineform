import SwiftUI

/// The All Files search results page: a transient, READ-ONLY layer over the current tab's
/// content area (never a floating card — that was explicitly rejected in brainstorming as
/// convoluted). Opaque theme background, editor-family typography, one row per matching
/// file. Clicking a row is a sidebar-click-equivalent open; Esc dismisses. This view never
/// takes text input — typing stays in the toolbar search field.
struct CrossFileSearchResultsView: View {
    let query: String
    let results: [CrossFileSearchResult]
    let isSearching: Bool
    let theme: Theme
    var onOpen: (CrossFileSearchResult) -> Void
    var onDismiss: () -> Void

    @State private var hoveredResultID: String?

    static let columnMaximumWidth: CGFloat = 560

    private var primaryColor: Color { Color(nsColor: theme.textColor) }
    private var secondaryColor: Color { primaryColor.opacity(0.55) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: Self.columnMaximumWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.backgroundColor))
        .onExitCommand { onDismiss() }
        .accessibilityLabel("All files search results")
    }

    private var header: some View {
        Text(headerText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(secondaryColor)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Search All Files" }
        if isSearching && results.isEmpty { return "Searching…" }
        let files = results.count == 1 ? "1 file" : "\(results.count) files"
        return "\(files) matching \u{201C}\(trimmed)\u{201D}"
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hint("Type to search all files…")
        } else if results.isEmpty && !isSearching {
            hint("No matches in any file.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(results) { result in
                    resultRow(result)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(secondaryColor)
    }

    private func resultRow(_ result: CrossFileSearchResult) -> some View {
        Button {
            onOpen(result)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(result.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryColor)
                    Text(result.relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryColor)
                }
                Text(snippetText(result.snippet))
                    .font(.system(size: 12.5))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoveredResultID == result.id ? primaryColor.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredResultID = hovering ? result.id : (hoveredResultID == result.id ? nil : hoveredResultID)
        }
        .accessibilityLabel(accessibilityText(result))
    }

    /// The snippet line with the matched substring emphasized (semibold, primary color).
    private func snippetText(_ snippet: CrossFileSearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.lineText)
        let nsLine = snippet.lineText as NSString
        guard snippet.matchRange.location != NSNotFound,
              NSMaxRange(snippet.matchRange) <= nsLine.length,
              let range = Range(snippet.matchRange, in: attributed) else {
            return attributed
        }
        attributed[range].font = .system(size: 12.5, weight: .semibold)
        attributed[range].foregroundColor = primaryColor
        return attributed
    }

    private func accessibilityText(_ result: CrossFileSearchResult) -> String {
        let matches = result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches"
        return "\(result.name), \(result.relativePath), \(matches)"
    }
}
