import SwiftUI

/// The All Files search results page: a transient, READ-ONLY layer over the current tab's
/// content area (never a floating card — that was explicitly rejected in brainstorming as
/// convoluted). Opaque theme background, editor-family typography, a responsive grid of
/// equal-height cards (one per matching file) so the page fills the available width and
/// wraps down to a single stacked column as the window narrows. Clicking a card is a
/// sidebar-click-equivalent open; Esc dismisses. This view never takes text input — typing
/// stays in the toolbar search field.
struct CrossFileSearchResultsView: View {
    let query: String
    let results: [CrossFileSearchResult]
    let isSearching: Bool
    let theme: Theme
    var onOpen: (CrossFileSearchResult) -> Void
    var onDismiss: () -> Void

    @State private var hoveredResultID: String?

    static let cardHeight: CGFloat = 168

    private var primaryColor: Color { Color(nsColor: theme.textColor) }
    private var secondaryColor: Color { primaryColor.opacity(0.55) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(results) { result in
                    resultCard(result)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(secondaryColor)
    }

    private func resultCard(_ result: CrossFileSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader(result)
            Text(locationText(result))
                .font(.system(size: 10.5))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(result.snippets.enumerated()), id: \.offset) { _, snippet in
                        Text(snippetText(snippet))
                            .font(.system(size: 11.5))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(height: Self.cardHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(primaryColor.opacity(hoveredResultID == result.id ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(primaryColor.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onOpen(result) }
        .onHover { hovering in
            hoveredResultID = hovering ? result.id : (hoveredResultID == result.id ? nil : hoveredResultID)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText(result))
    }

    private func cardHeader(_ result: CrossFileSearchResult) -> some View {
        HStack(spacing: 8) {
            Text(result.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches")
                .font(.system(size: 10.5))
                .foregroundStyle(secondaryColor)
        }
    }

    /// The file's directory within its root — never repeats the filename. A root-level
    /// file (relativePath == name) shows the root title instead.
    private func locationText(_ result: CrossFileSearchResult) -> String {
        if result.relativePath == result.name {
            return result.rootTitle
        }
        let directory = (result.relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? result.rootTitle : directory
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
        attributed[range].font = .system(size: 11.5, weight: .semibold)
        attributed[range].foregroundColor = primaryColor
        return attributed
    }

    private func accessibilityText(_ result: CrossFileSearchResult) -> String {
        let matches = result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches"
        return "\(result.name), \(locationText(result)), \(matches)"
    }
}
