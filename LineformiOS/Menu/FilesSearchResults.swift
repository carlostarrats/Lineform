import LineformCore
import SwiftUI

/// One document among the search results: its name, where its first result is, and that result's
/// line (the match in bold). Tapping it activates its first row through `SearchController`: a match
/// in this document is selected and scrolled to; another file opens with its match selected.
struct SearchResultCard: Identifiable, Equatable {
    var id: String
    var title: String
    /// Like every document card (`DocumentCard.detail`): "folder · date"; for the open document,
    /// "folder · open now".
    var detail: String
    var snippet: CrossFileSearchSnippet?
    /// The row a tap activates.
    var row: SearchRow

    /// The controller's rows grouped into one card per document, in the controller's order (this
    /// document's matches first, then file names, then file contents).
    /// `rootNames` names a root's top-level folder the way Files' headings do ("On My iPhone",
    /// "iCloud"), so a card never shows the container's folder name ("Documents").
    static func cards(
        from rows: [SearchRow], currentTitle: String, currentURL: URL? = nil, rootNames: [String: String] = [:],
        modifiedDate: (URL) -> Date? = SearchResultCard.fileModifiedDate, now: Date = Date()
    ) -> [SearchResultCard] {
        func folderName(of url: URL) -> String {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            return rootNames[parent.path] ?? parent.lastPathComponent
        }
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
                let openNow = String(localized: "open now")
                detail = currentURL.map { String(localized: "\(folderName(of: $0)) · \(openNow)") } ?? openNow
            case .fileName, .fileContent:
                guard let url = row.url else { continue }
                key = url.standardizedFileURL.path
                title = url.deletingPathExtension().lastPathComponent
                let folder = folderName(of: url)
                if let date = modifiedDate(url) {
                    let when = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
                    detail = String(localized: "\(folder) · \(when)")
                } else {
                    detail = folder
                }
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

    /// A file's modification date, read fresh from disk (never a cached `URL` resource value).
    static func fileModifiedDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// What the Files search looks through: every document (cards, the default) or the open document
/// alone (its matches as rows, with the count, the arrows and Replace). The raw value is identity,
/// never localized.
enum FilesSearchScope: String, CaseIterable, Identifiable {
    case allDocuments
    case openDocument

    var id: Self { self }

    var filter: SearchFilter {
        switch self {
        case .allDocuments: .all
        case .openDocument: .document
        }
    }

    static var allDocumentsTitle: String { String(localized: "All documents") }

    /// The scope's name: "All documents", or the open document's FILE name with its extension
    /// ("Export update.md"; "Untitled" for a document never saved).
    static func title(for scope: FilesSearchScope, documentURL: URL?) -> String {
        switch scope {
        case .allDocuments: allDocumentsTitle
        case .openDocument: fileName(for: documentURL)
        }
    }

    static func fileName(for url: URL?) -> String {
        guard let url else { return WordMenu.documentTitle(for: nil) }
        return url.lastPathComponent
    }

    /// A long name cut in the MIDDLE to `limit` characters, so its extension stays in view
    /// ("My very long draft…notes.md"). For the native menu item, which cannot truncate in the
    /// middle by itself; the pill uses `.truncationMode(.middle)` on the full name.
    static func middleElided(_ name: String, limit: Int = 24) -> String {
        let characters = Array(name)
        guard limit > 4, characters.count > limit else { return name }
        let kept = limit - 1
        let extensionLength = (name as NSString).pathExtension.count
        let tailCount = min(max(kept / 2, extensionLength + 4), kept - 3)
        let headCount = kept - tailCount
        return String(characters.prefix(headCount)) + "…" + String(characters.suffix(tailCount))
    }

    /// The prompt in the search field.
    var prompt: String {
        switch self {
        case .allDocuments: String(localized: "Search all documents")
        case .openDocument: String(localized: "Find in document")
        }
    }
}

/// The Files search's results: the status ("Searching…", "No matches"), then a card per document,
/// or, with the open document as the scope, its matches as rows.
struct FilesSearchResults: View {
    @Bindable var controller: SearchController
    var scope: FilesSearchScope = .allDocuments
    var document: OpenDocument
    var store: FilesStore
    var onDismiss: () -> Void

    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.wordMenuSession) private var session

    /// The file a card stands for, for its swipe actions: another document's, or this one's. Its
    /// iCloud placeholder flag is the real one (`FilesStore.listedItem`), so a card for a file not
    /// downloaded yet offers no Move to Trash.
    private func item(for card: SearchResultCard) -> OutlineFileTreeItem? {
        guard let url = card.row.url ?? document.url else { return nil }
        return store.listedItem(at: url)
    }

    var body: some View {
        Group {
            switch scope {
            case .allDocuments: cardList
            case .openDocument: matchList
            }
        }
        // Measured: the results on screen after a keystroke or a scope switch.
        .onChange(of: controller.rows, initial: true) { resultsShown() }
        .onChange(of: controller.statusText) { resultsShown() }
        .onChange(of: scope) { resultsShown() }
    }

    private func resultsShown() {
        WordMenuTiming.end(.search)
        WordMenuTiming.end(.scope)
    }

    /// The open document's matches, one row each, the current one outlined in Lineform blue. A
    /// tap closes the menu and selects the match on the page.
    @ViewBuilder
    private var matchList: some View {
        let rows = controller.rows
        let count = controller.matches.count
        VStack(alignment: .leading, spacing: WordMenuMetrics.rowSpacing) {
            if rows.isEmpty, let status = controller.visibleStatusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.secondary))
                    .padding(.horizontal, 4)
            }
            LazyVStack(alignment: .leading, spacing: WordMenuMetrics.rowSpacing) {
                let name = WordMenu.documentTitle(for: document.url)
                let date = document.url.flatMap { SearchResultCard.fileModifiedDate($0) }
                    .map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SearchMatchRowView(
                        row: row,
                        name: name,
                        date: date,
                        isCurrent: controller.activeIndex == index,
                        position: String(localized: "\(index + 1) of \(count)")
                    ) {
                        session?.noteOpenedDocument()
                        controller.activate(row, dismiss: onDismiss)
                    }
                }
            }
        }
    }

    /// Each root folder's path → its heading in Files.
    static func rootNames(_ store: FilesStore) -> [String: String] {
        var names: [String: String] = [:]
        for root in store.roots {
            guard let folder = root.folderURL?.standardizedFileURL else { continue }
            switch root.id {
            case .icloud: names[folder.path] = FilesSection.iCloudHeading
            case .device: names[folder.path] = FilesStore.deviceTitle
            case .workspace: break
            }
        }
        return names
    }

    @ViewBuilder
    private var cardList: some View {
        let cards = SearchResultCard.cards(
            from: controller.rows, currentTitle: WordMenu.documentTitle(for: document.url), currentURL: document.url,
            rootNames: Self.rootNames(store)
        )
        VStack(alignment: .leading, spacing: WordMenuMetrics.rowSpacing) {
            if let status = controller.visibleStatusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.secondary))
                    .padding(.horizontal, 4)
            }
            WordMenuCardGrid(items: cards) { card in
                let actions = item(for: card).map { FilesSwipeAction.actions(for: $0, store: store) } ?? []
                SearchResultCardView(card: card) {
                    session?.noteOpenedDocument()
                    controller.activate(card.row, dismiss: onDismiss)
                }
                .filesSwipeAccessibilityActions(actions)
                .filesSwipeActions(actions)
            }
            if let note = controller.notDownloadedNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.secondary))
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One match in the open document, on a card: the file's name on the left and when it changed on
/// the right, then the line with the match on a blue wash. No outline on any card (owner review 4:
/// a phone has no hover, so a ring around one result read as a stray state); the current match
/// is known to VoiceOver (selected) and is the one ↑/↓ moved to.
private struct SearchMatchRowView: View {
    var row: SearchRow
    var name: String
    var date: String?
    var isCurrent: Bool
    /// "2 of 5", for VoiceOver.
    var position: String
    var action: () -> Void
    @Environment(\.wordMenuPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let date {
                        Text(verbatim: date)
                            .font(.caption)
                            .foregroundStyle(palette.color(palette.secondary))
                            .lineLimit(1)
                    }
                }
                if let snippet = row.snippet {
                    Text(Self.marked(snippet, wash: palette.color(palette.blueFill).opacity(0.42)))
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(palette.color(palette.ink))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
            .background(
                shape.fill(palette.color(palette.card))
                    .shadow(color: .black.opacity(palette.cardHasShadow ? 0.06 : 0), radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(palette.cardHasShadow ? 0.07 : 0), radius: 7, x: 0, y: 4)
            )
            .contentShape(shape)
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(position))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// The line with its match on the blue wash (the mockup's `mark.hit.now`), not bold.
    static func marked(_ snippet: CrossFileSearchSnippet, wash: Color) -> AttributedString {
        var attributed = AttributedString(snippet.lineText)
        let text = snippet.lineText
        if let range = Range(snippet.matchRange, in: text),
           let lower = AttributedString.Index(range.lowerBound, within: attributed),
           let upper = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[lower..<upper].backgroundColor = wash
        }
        return attributed
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
