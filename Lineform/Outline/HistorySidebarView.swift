import SwiftUI

/// What the History sidebar draws. Task 6 builds it from the live History model.
struct HistorySidebarModel: Equatable {
    var levels: [HistoryLevel] = []
    var currentLevel: HistoryLevel?
    var versions: [HistorySidebarRow] = []
    var hasSelection: Bool = false
}

struct HistorySidebarRow: Equatable, Identifiable {
    let id: Int
    /// The version's first line, whitespace-collapsed (see `displayText(for:)`).
    let text: String
    let author: HistoryAuthor
    let isCurrent: Bool

    /// First NON-empty line (blank leading lines are skipped) with every whitespace run collapsed to one space.
    static func displayText(for version: String) -> String {
        let firstLine = version
            .split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        return firstLine
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Spoken label for the row. `position` is 1-based.
    func accessibilityLabel(position: Int, of count: Int) -> String {
        switch author {
        case .you: return String(localized: "\(text), by you, version \(position) of \(count)")
        case .ai: return String(localized: "\(text), by AI, version \(position) of \(count)")
        }
    }
}

enum HistorySidebarPresentation {
    static func showsLevelSwitcher(_ levels: [HistoryLevel]) -> Bool {
        levels.count > 1
    }

    /// History rows are Files rows: every number here is the Files constant, so the two lists
    /// cannot drift apart.
    @MainActor struct RowLayout: Equatable {
        var containerPadding: CGFloat = OutlineSidebarView.filesContentHorizontalPadding
        var chevronSlotWidth: CGFloat = OutlineSidebarView.filesChevronSlotWidth
        var iconWidth: CGFloat = 18
        var iconLeading: CGFloat = 2
        var textLeading: CGFloat = 4
        var rowLeading: CGFloat = 6
        var rowTrailing: CGFloat = 6
        var backgroundInset: CGFloat = OutlineSidebarView.filesRowBackgroundHorizontalInset
        var height: CGFloat = OutlineSidebarView.filesChildRowHeight
    }
    @MainActor static let rowLayout = RowLayout()

    static let emptySelectionText = String(localized: "Click a highlighted passage to see its versions.")
    static let hintText = String(localized: "Click to select · ← → switch version · Esc closes")
    static let deleteVersionTitle = String(localized: "Delete from History")
    static let exitTitle = String(localized: "Exit")
    static let addReplacementTitle = String(localized: "Add Replacement")
    static let replacementPlaceholder = String(localized: "Type a replacement")
    /// The leading inset every line of History prose sits on: the empty-state text and the hint.
    static let textInset: CGFloat = 14

    /// A version row's actions: its context menu AND its accessibility actions are built from
    /// this one list, so the two cannot drift apart.
    enum RowAction: CaseIterable {
        case delete
        var title: String {
            switch self {
            case .delete: return HistorySidebarPresentation.deleteVersionTitle
            }
        }
    }
    static let rowActions = RowAction.allCases
}

struct HistorySidebarView: View {
    var model: HistorySidebarModel
    var usesDarkChrome: Bool
    var onSelectLevel: (HistoryLevel) -> Void
    var onSelectVersion: (Int) -> Void
    var onDeleteVersion: (Int) -> Void
    var onExit: () -> Void = {}
    /// Return in the replacement field: the typed text (the controller trims it and ignores an
    /// empty or unchanged one).
    var onAddReplacement: (String) -> Void = { _ in }
    /// The field closed (committed or cancelled): the editor takes the keys back, so ← → step
    /// versions again.
    var onReplacementFieldEnded: () -> Void = {}

    @State private var isEditingReplacement = false
    @State private var replacementDraft = ""
    @FocusState private var replacementFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.hasSelection {
                if HistorySidebarPresentation.showsLevelSwitcher(model.levels) {
                    levelSwitcher
                }
                ScrollView {
                    VStack(spacing: 10) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.versions.enumerated()), id: \.element.id) { index, row in
                                HistoryVersionRowView(
                                    row: row,
                                    position: index + 1,
                                    count: model.versions.count,
                                    usesDarkChrome: usesDarkChrome,
                                    onSelect: { onSelectVersion(row.id) },
                                    onDelete: { onDeleteVersion(row.id) }
                                )
                            }
                        }
                        replacementControl
                    }
                    .padding(.horizontal, HistorySidebarPresentation.rowLayout.containerPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
            } else {
                Text(HistorySidebarPresentation.emptySelectionText)
                    .font(.system(size: 12))
                    .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, HistorySidebarPresentation.textInset)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }

            Text(HistorySidebarPresentation.hintText)
                .font(.system(size: 11))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HistorySidebarPresentation.textInset)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Another passage (or none) is selected: an open field belonged to the old one.
        .onChange(of: model.hasSelection) { _, _ in closeReplacementField() }
    }

    /// "History" with Exit on the right — the Files root row's geometry: 28pt tall, the capsule
    /// 12pt in from the sidebar edge (6 content padding + 6 row trailing).
    private var header: some View {
        HStack(spacing: 8) {
            Text(OutlineSidebarTab.history.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(HistorySidebarPresentation.exitTitle, action: onExit)
                .buttonStyle(SidebarCapsuleButtonStyle(usesDarkChrome: usesDarkChrome, emphasis: .quiet))
        }
        .padding(.leading, HistorySidebarPresentation.textInset)
        .padding(.trailing, OutlineSidebarView.filesContentHorizontalPadding + 6)
        .frame(maxWidth: .infinity, minHeight: OutlineSidebarView.filesRootRowHeight,
               maxHeight: OutlineSidebarView.filesRootRowHeight)
        .padding(.top, 8)
    }

    /// Below the versions: the Add Replacement capsule, or — once clicked — the field it opens.
    /// While the field has focus it owns the keys (arrows edit the text, Esc closes the field and
    /// leaves History on); Return adds the text as the passage's new current version.
    @ViewBuilder
    private var replacementControl: some View {
        if isEditingReplacement {
            TextField(
                HistorySidebarPresentation.replacementPlaceholder,
                text: $replacementDraft,
                prompt: Text(HistorySidebarPresentation.replacementPlaceholder)
                    .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.22),
                                  lineWidth: 1)
            }
            .padding(.horizontal, HistorySidebarPresentation.rowLayout.backgroundInset)
            .focused($replacementFieldFocused)
            .onSubmit(commitReplacement)
            .onExitCommand(perform: closeReplacementField)
            .onChange(of: replacementFieldFocused) { _, focused in
                // Clicking away (into the text, another passage) closes the field unsaved.
                if !focused, isEditingReplacement { closeReplacementField() }
            }
            .onAppear { replacementFieldFocused = true }
        } else {
            Button(HistorySidebarPresentation.addReplacementTitle) {
                replacementDraft = ""
                isEditingReplacement = true
            }
            .buttonStyle(SidebarCapsuleButtonStyle(usesDarkChrome: usesDarkChrome, emphasis: .quiet))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func commitReplacement() {
        let text = replacementDraft
        isEditingReplacement = false
        replacementDraft = ""
        onAddReplacement(text)
        onReplacementFieldEnded()
    }

    private func closeReplacementField() {
        guard isEditingReplacement else { return }
        isEditingReplacement = false
        replacementDraft = ""
        onReplacementFieldEnded()
    }

    private var levelSwitcher: some View {
        HStack(spacing: 14) {
            ForEach(model.levels, id: \.self) { level in
                HistoryLevelButton(
                    level: level,
                    isCurrent: level == model.currentLevel,
                    usesDarkChrome: usesDarkChrome,
                    action: { onSelectLevel(level) }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

private struct HistoryLevelButton: View {
    var level: HistoryLevel
    var isCurrent: Bool
    var usesDarkChrome: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(level.title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(OutlineSidebarView.tabTextColor(
                    usesDarkChrome: usesDarkChrome,
                    isSelected: isCurrent,
                    isHovered: isHovered
                ))
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

private struct HistoryVersionRowView: View {
    var row: HistorySidebarRow
    var position: Int
    var count: Int
    var usesDarkChrome: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false

    private var foreground: Color {
        row.isCurrent
            ? OutlineSidebarView.rowSelectionLabelColor(usesDarkChrome: usesDarkChrome)
            : OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }

    private var background: Color {
        if row.isCurrent {
            return OutlineSidebarView.rowSelectionFillColor(usesDarkChrome: usesDarkChrome)
        }
        if isHovered {
            return OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
                .opacity(OutlineSidebarView.filesRowHoverFillOpacity)
        }
        return .clear
    }

    var body: some View {
        let layout = HistorySidebarPresentation.rowLayout
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.chevronSlotWidth)
            Image(systemName: row.author == .you ? "pencil" : "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: layout.iconWidth)
                .padding(.leading, layout.iconLeading)
            Text(row.text)
                .font(.system(size: 13, weight: row.isCurrent ? .semibold : .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, layout.textLeading)
            Spacer(minLength: 0)
        }
        .padding(.leading, layout.rowLeading)
        .padding(.trailing, layout.rowTrailing)
        .frame(maxWidth: .infinity, minHeight: layout.height, maxHeight: layout.height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
                .padding(.horizontal, layout.backgroundInset)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            rowActionButtons()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(position: position, of: count))
        .accessibilityAddTraits(row.isCurrent ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onSelect() }
        // Right-click must not be the only path to Delete: the actions rotor offers the same set.
        .accessibilityActions {
            rowActionButtons()
        }
    }

    /// The single source of truth for a row's actions — the context menu and the VoiceOver
    /// actions rotor both build from it, so they cannot drift apart.
    @ViewBuilder
    private func rowActionButtons() -> some View {
        ForEach(HistorySidebarPresentation.rowActions, id: \.self) { action in
            switch action {
            case .delete:
                Button(role: .destructive, action: onDelete) {
                    Text(action.title)
                }
            }
        }
    }
}
