import LineformCore
import SwiftUI

/// The Menu sheet's Search: the field at the top, the All / In document / Files filter, then a
/// hint while the query is empty. Typing fades the hint out and the results in: this document's
/// matches first ("In document" on the right), then file-name matches, then matches inside other
/// files (the file's name on the right). The Replace row acts on this document only, so the Files
/// filter hides it. The rules live in `SearchController`.
struct SearchSection: View {
    var document: OpenDocument
    var files: FilesStore
    var onDismiss: () -> Void

    @State private var controller: SearchController
    @State private var queryText = ""
    @State private var replacementText = ""
    @FocusState private var focusedField: Field?

    private enum Field { case query, replacement }

    init(document: OpenDocument, editor: any EditorCommands, files: FilesStore, onDismiss: @escaping () -> Void) {
        self.document = document
        self.files = files
        self.onDismiss = onDismiss
        _controller = State(initialValue: SearchController(
            editor: editor,
            files: files,
            currentURL: { [weak document] in document?.url },
            open: SearchController.opener(for: document)
        ))
    }

    /// Replace works on this document's matches only, never on files.
    static func showsReplaceRow(for filter: SearchFilter) -> Bool { filter != .files }

    static var hintText: String { String(localized: "Search this document and your files.") }

    private var hasQuery: Bool { !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            searchField
            Picker(String(localized: "Search"), selection: Binding(
                get: { controller.filter },
                set: { controller.setFilter($0) }
            )) {
                ForEach(SearchFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ZStack(alignment: .top) {
                if hasQuery {
                    results
                        .transition(.opacity)
                } else {
                    Text(Self.hintText)
                        .font(.callout)
                        .opacity(0.6)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 28)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.2), value: hasQuery)
        }
        .padding(.top, 6)
        .onChange(of: queryText) { _, newValue in controller.setQuery(newValue) }
        .onChange(of: replacementText) { _, newValue in controller.replacement = newValue }
        .onChange(of: document.text) { controller.textChanged() }
        .onChange(of: files.roots) { controller.rootsChanged() }
        .onDisappear { controller.stop() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .opacity(0.5)
                .accessibilityHidden(true)
            TextField(String(localized: "Search"), text: $queryText)
                .focused($focusedField, equals: .query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 16)
    }

    private var results: some View {
        VStack(spacing: 6) {
            if Self.showsReplaceRow(for: controller.filter) {
                replaceRow
            }
            if let status = controller.statusText {
                Text(status)
                    .font(.footnote)
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            List(controller.rows) { row in
                Button {
                    controller.activate(row, dismiss: onDismiss)
                } label: {
                    SearchResultRow(row: row, isActive: isActive(row))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func isActive(_ row: SearchRow) -> Bool {
        guard case .inDocument(let range) = row.kind, let index = controller.activeIndex,
              controller.matches.indices.contains(index) else { return false }
        return controller.matches[index] == range
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Replace"), text: $replacementText)
                .focused($focusedField, equals: .replacement)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(String(localized: "Replacement text"))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            Button(String(localized: "Replace")) { controller.replace() }
                .disabled(!controller.canReplace)
            Button(String(localized: "Replace All")) { controller.replaceAll() }
                .disabled(!controller.canReplaceAll)
        }
        .font(.callout)
        .padding(.horizontal, 16)
    }
}

/// One result: the matching line (the match in bold) or, for a file-name match, the file's
/// folder; then where it is on the right.
struct SearchResultRow: View {
    var row: SearchRow
    var isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let snippet = row.snippet {
                    Text(Self.emphasized(snippet))
                        .lineLimit(2)
                } else {
                    Label {
                        Text(verbatim: row.detail ?? "")
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.primary)
                            .opacity(0.6)
                    }
                    .lineLimit(1)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.indicator)
                .font(.caption)
                .opacity(0.6)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// The snippet with its match in bold.
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
