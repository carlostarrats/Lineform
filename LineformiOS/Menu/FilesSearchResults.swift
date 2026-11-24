import LineformCore
import SwiftUI

/// One document among the search results: its name, where its first result is, and that result's
/// line (the match in bold). Tapping it activates its first row through `SearchController`: a match
/// in this document is selected and scrolled to; another file opens with its match selected.
struct SearchResultCard: Identifiable, Equatable {
    var id: String
    var title: String
    /// "In document" for this document; the folder for another.
    var detail: String
    var snippet: CrossFileSearchSnippet?
    /// The row a tap activates.
    var row: SearchRow

    /// The controller's rows grouped into one card per document, in the controller's order (this
    /// document's matches first, then file names, then file contents).
    static func cards(from rows: [SearchRow], currentTitle: String) -> [SearchResultCard] {
        var cards: [SearchResultCard] = []
        var indexByKey: [String: Int] = [:]
        for row in rows {
            let key: String
            let title: String
            let detail: String
            switch row.kind {
            case .inDocument:
                key = "current"
                title = currentTitle
                detail = SearchRow.inDocumentIndicator
            case .fileName, .fileContent:
                guard let url = row.url else { continue }
                key = url.standardizedFileURL.path
                title = url.deletingPathExtension().lastPathComponent
                detail = url.deletingLastPathComponent().lastPathComponent
            }
            if let index = indexByKey[key] {
                // A file-name card picks up the first matching line when one arrives.
                if cards[index].snippet == nil, let snippet = row.snippet {
                    cards[index].snippet = snippet
                    cards[index].row = row
                }
                continue
            }
            indexByKey[key] = cards.count
            cards.append(SearchResultCard(id: key, title: title, detail: detail, snippet: row.snippet, row: row))
        }
        return cards
    }
}

/// The Files search's results: the status ("Searching…", "No matches"), then a card per document.
struct FilesSearchResults: View {
    @Bindable var controller: SearchController
    var document: OpenDocument
    var store: FilesStore
    var onDismiss: () -> Void

    @Environment(\.wordMenuPalette) private var palette

    /// The file a card stands for, for its swipe actions: another document's, or this one's.
    private func item(for card: SearchResultCard) -> OutlineFileTreeItem? {
        guard let url = card.row.url ?? document.url else { return nil }
        return OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: false, children: [])
    }

    var body: some View {
        let cards = SearchResultCard.cards(
            from: controller.rows, currentTitle: WordMenu.documentTitle(for: document.url)
        )
        VStack(alignment: .leading, spacing: WordMenuMetrics.rowSpacing) {
            if let status = controller.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.secondary))
                    .padding(.horizontal, 4)
            }
            WordMenuCardGrid(items: cards) { card in
                SearchResultCardView(card: card) {
                    controller.activate(card.row, dismiss: onDismiss)
                }
                .filesSwipeActions(item(for: card).map { FilesSwipeAction.actions(for: $0, store: store) } ?? [])
            }
        }
    }
}

private struct SearchResultCardView: View {
    var card: SearchResultCard
    var action: () -> Void
    @Environment(\.wordMenuPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.color(palette.ink))
                    .lineLimit(2)
                Text(verbatim: card.detail)
                    .font(.caption)
                    .foregroundStyle(palette.color(palette.secondary))
                    .lineLimit(1)
                if let snippet = card.snippet {
                    Text(Self.emphasized(snippet))
                        .font(.caption)
                        .foregroundStyle(palette.color(palette.secondary))
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .background(shape.fill(palette.color(palette.card)))
            .shadow(color: .black.opacity(palette.cardHasShadow ? 0.07 : 0), radius: 7, x: 0, y: 3)
            .contentShape(shape)
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityElement(children: .combine)
    }

    /// The snippet with its match in bold, in the ink.
    static func emphasized(_ snippet: CrossFileSearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.lineText)
        let text = snippet.lineText
        if let range = Range(snippet.matchRange, in: text),
           let lower = AttributedString.Index(range.lowerBound, within: attributed),
           let upper = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
