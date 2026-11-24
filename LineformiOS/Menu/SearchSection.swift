import LineformCore
import SwiftUI

/// The Menu sheet's Search: the field at the top, the All / In document / Files filter, then a
/// hint while the query is empty. Typing fades the hint out and the results in: this document's
/// matches first ("In document" on the right), then file-name matches, then matches inside other
/// files (the file's name on the right). The Replace row acts on this document only, so the Files
/// filter hides it. The rules live in `SearchController`.
struct SearchSection: View {
    var document: OpenDocument
    var editor: any EditorCommands
    var files: FilesStore
    var onDismiss: () -> Void

    /// Made once, when the section first appears: never in `init`, which SwiftUI runs on every
    /// update of the sheet (each keystroke changes the header's counts).
    @State private var controller: SearchController?

    /// Replace works on this document's matches only, never on files.
    static func showsReplaceRow(for filter: SearchFilter) -> Bool { filter != .files }

    /// Above and below Replace and Replace All, inside their targets.
    static let buttonTargetPadding: CGFloat = 14

    /// The filter is a menu, not segments, at accessibility sizes.
    static func usesFilterMenu(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    static var hintText: String { String(localized: "Search this document and your files.") }

    var body: some View {
        Group {
            if let controller {
                SearchSectionContent(controller: controller, document: document, files: files, onDismiss: onDismiss)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard controller == nil else { return }
            controller = SearchController(
                editor: editor,
                files: files,
                currentURL: { [weak document] in document?.url },
                open: SearchController.opener(for: document)
            )
        }
    }
}

/// The section's views over its controller. The fields write straight into the controller as the
/// writer types, so a tap on Replace or Replace All right after the last keystroke acts on what
/// the fields show, never on what they showed one view update earlier.
private struct SearchSectionContent: View {
    @Bindable var controller: SearchController
    var document: OpenDocument
    var files: FilesStore
    var onDismiss: () -> Void

    @FocusState private var focusedField: Field?
    @Environment(\.menuTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ink: PhoneInk { PhoneInk.menu(theme) }
    /// The fields' wash: the theme's ink at the alpha `PhoneInk` measures its inks on.
    private var fieldWash: Color {
        Color(uiColor: ink.theme.textColor).opacity(PhoneInk.searchFieldWashAlpha)
    }

    private enum Field { case query, replacement }

    private var hasQuery: Bool { !controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var queryBinding: Binding<String> {
        Binding(get: { controller.query }, set: { controller.setQuery($0) })
    }

    var body: some View {
        VStack(spacing: 10) {
            searchField
            filterPicker
                .padding(.horizontal, 16)

            ZStack(alignment: .top) {
                if hasQuery {
                    results
                        .transition(.opacity)
                } else {
                    Text(SearchSection.hintText)
                        .font(.callout)
                        .foregroundStyle(ink.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 28)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: hasQuery)
        }
        .padding(.top, 6)
        .onChange(of: document.text) { controller.textChanged() }
        .onChange(of: files.roots) { controller.rootsChanged() }
        .onDisappear { controller.stop() }
    }

    /// All / In document / Files: segmented at the default sizes; a menu at accessibility sizes,
    /// where segments keep the control's own small height and squeeze their titles.
    @ViewBuilder
    private var filterPicker: some View {
        let picker = Picker(String(localized: "Search"), selection: Binding(
            get: { controller.filter },
            set: { controller.setFilter($0) }
        )) {
            ForEach(SearchFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        if SearchSection.usesFilterMenu(for: dynamicTypeSize) {
            picker
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ink.color(.secondaryOnSearchField))
                .accessibilityHidden(true)
            TextField(text: queryBinding, prompt: Text(String(localized: "Search")).foregroundStyle(ink.color(.tertiaryOnSearchField))) {
                Text(String(localized: "Search"))
            }
                .focused($focusedField, equals: .query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldWash))
        .padding(.horizontal, 16)
    }

    private var results: some View {
        VStack(spacing: 6) {
            if SearchSection.showsReplaceRow(for: controller.filter) {
                replaceRow
            }
            if let status = controller.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(ink.secondary)
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
        let field = TextField(
            text: $controller.replacement,
            prompt: Text(String(localized: "Replace")).foregroundStyle(ink.color(.tertiaryOnSearchField))
        ) {
            Text(String(localized: "Replace"))
        }
        .focused($focusedField, equals: .replacement)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityLabel(String(localized: "Replacement text"))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldWash))
        // `canReplace` and `canReplaceAll` are only what the buttons show; the controller
        // checks again against its live state on every tap.
        let buttons = Group {
            replaceButton(String(localized: "Replace"), isEnabled: controller.canReplace) { controller.replace() }
            replaceButton(String(localized: "Replace All"), isEnabled: controller.canReplaceAll) { controller.replaceAll() }
        }
        return Group {
            // At accessibility sizes the field takes the whole line and the buttons go under it:
            // on one line the field shrank to nothing (German "Alles ersetzen").
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    field
                    HStack(spacing: 16) { buttons }
                }
            } else {
                HStack(spacing: 8) {
                    field
                    buttons
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
    }

    /// A Replace button whose target reaches 44 pt inside it; the negative padding outside gives
    /// the room back, so the row keeps its height.
    private func replaceButton(_ title: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.vertical, SearchSection.buttonTargetPadding)
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .padding(.vertical, -SearchSection.buttonTargetPadding)
    }
}

/// One result: the matching line (the match in bold) or, for a file-name match, the file's
/// folder; then where it is on the right.
struct SearchResultRow: View {
    var row: SearchRow
    var isActive: Bool
    @Environment(\.menuTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The widest the indicator (In document, or a file's name) grows beside the result; it
    /// scales with the caption text, so a translation that fits at the default size fits at all.
    @ScaledMetric(relativeTo: .caption) private var indicatorWidth: CGFloat = SearchResultRow.indicatorWidth

    static let indicatorWidth: CGFloat = 140

    /// At accessibility sizes the lines that are cut short at the default size get room.
    static func lineLimits(for dynamicTypeSize: DynamicTypeSize) -> (snippet: Int?, fileName: Int?) {
        dynamicTypeSize.isAccessibilitySize ? (nil, 3) : (2, 1)
    }

    var body: some View {
        let ink = PhoneInk.menu(theme)
        let limits = Self.lineLimits(for: dynamicTypeSize)
        let result = Group {
            if let snippet = row.snippet {
                Text(Self.emphasized(snippet))
                    .lineLimit(limits.snippet)
            } else {
                Label {
                    Text(verbatim: row.detail ?? "")
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(ink.icon)
                }
                .lineLimit(limits.fileName)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        let indicator = Text(verbatim: row.indicator)
            .font(.caption)
            .foregroundStyle(ink.secondary)
            .truncationMode(.middle)
        Group {
            // At accessibility sizes the indicator goes under the result, at its full width.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    result
                    indicator
                        .lineLimit(limits.fileName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    result
                    indicator
                        .lineLimit(1)
                        .frame(maxWidth: indicatorWidth, alignment: .trailing)
                }
            }
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
