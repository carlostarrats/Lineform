import SwiftUI

/// What the History sidebar draws. Task 6 builds it from the live History model.
struct HistorySidebarModel: Equatable {
    var levels: [HistoryLevel] = []
    var currentLevel: HistoryLevel?
    var versions: [HistorySidebarRow] = []
    var hasSelection: Bool = false
    /// The passage the versions belong to. The replacement field is opened for ONE passage and
    /// closes when this changes (`HistoryReplacementFieldState.selectionChanged`).
    var selectedPassageID: UUID?
}

/// The sidebar's replacement field: open for exactly one passage. The level buttons take no
/// focus from the field, so focus loss alone cannot close it when the selection moves — the
/// selected passage id does. Return commits the text FOR that passage; the controller refuses
/// it when the selection is no longer that passage.
struct HistoryReplacementFieldState: Equatable {
    /// The passage the field was opened for; nil while closed.
    private(set) var passageID: UUID?
    var draft = ""

    var isOpen: Bool { passageID != nil }

    /// The field's return button is enabled only for text that would add something.
    var canCommit: Bool {
        isOpen && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// False (and stays closed) when no passage is selected.
    mutating func open(for id: UUID?) -> Bool {
        guard let id else { return false }
        passageID = id
        draft = ""
        return true
    }

    /// True when the field WAS open: the caller reports the end exactly once.
    mutating func close() -> Bool {
        guard isOpen else { return false }
        passageID = nil
        draft = ""
        return true
    }

    /// The selected passage changed: an open field belonged to the old one and closes unsaved.
    mutating func selectionChanged(to id: UUID?) -> Bool {
        guard isOpen, id != passageID else { return false }
        return close()
    }

    /// Return: the typed text and the passage it is for; the field closes.
    mutating func commit() -> (text: String, passageID: UUID)? {
        guard let id = passageID else { return nil }
        let text = draft
        _ = close()
        return (text, id)
    }
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
    /// The section row's Add button: its accessibility label (the visible text is "Add" + plus).
    static let addAlternativeTitle = String(localized: "Add Alternative")
    static let addButtonTitle = String(localized: "Add")
    static let addButtonSymbol = "plus"
    static let versionsHeading = String(localized: "Versions of selected text")
    /// The section row's text size: the footer hint's.
    static let sectionFontSize: CGFloat = 11

    /// The section row's Add ink. Quieter than the Exit capsule's label (0.34 light / 0.98 dark):
    /// lighter in light chrome, darker in dark chrome; hover brightens it a little. Kept ≥ 3:1
    /// against the sidebar background (`HistorySidebarPresentationTests`).
    static func addButtonWhite(usesDarkChrome: Bool, isHovered: Bool) -> CGFloat {
        usesDarkChrome ? (isHovered ? 0.72 : 0.58) : (isHovered ? 0.38 : 0.47)
    }
    /// The field's trailing return button (does what Return does).
    static let addAlternativeCommitLabel = String(localized: "Add")
    static let addAlternativeCommitSymbol = "arrow.turn.down.left"
    /// The return button's diameter, and the gap the typed text keeps before it (the field scrolls
    /// horizontally rather than running under the button).
    static let commitButtonDiameter: CGFloat = 20
    static let commitButtonGap: CGFloat = 7
    static let replacementPlaceholder = String(localized: "Type a replacement")
    /// The leading inset every line of History prose sits on: the empty-state text and the hint.
    static let textInset: CGFloat = 14

    /// Focuses the replacement field one runloop turn after it was inserted. A `@FocusState`
    /// write in the same pass as the insertion (a bare `.onAppear`) is routinely dropped on
    /// macOS — the editor keeps first responder and the keystrokes meant for the field would
    /// reach the document.
    static func requestReplacementFieldFocus(
        schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        _ focus: @escaping () -> Void
    ) {
        schedule(focus)
    }

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

/// What the editor asks of an open replacement field when a key reached the editor instead.
enum HistoryReplacementFieldRequest: Equatable {
    case focus
    case cancel
}

/// Counters the sidebar watches; the editor bumps one per request.
struct HistoryReplacementFieldSignal: Equatable {
    var focus = 0
    var cancel = 0

    mutating func send(_ request: HistoryReplacementFieldRequest) {
        switch request {
        case .focus: focus += 1
        case .cancel: cancel += 1
        }
    }
}

struct HistorySidebarView: View {
    var model: HistorySidebarModel
    var usesDarkChrome: Bool
    var onSelectLevel: (HistoryLevel) -> Void
    var onSelectVersion: (Int) -> Void
    var onDeleteVersion: (Int) -> Void
    /// Return in the replacement field: the typed text and the passage the field was opened for
    /// (the controller refuses it when that is no longer the selection, trims it, and ignores an
    /// empty or unchanged one).
    var onAddReplacement: (String, UUID) -> Void = { _, _ in }
    /// The field closed (committed or cancelled): the editor takes the keys back, so ← → step
    /// versions again.
    var onReplacementFieldEnded: () -> Void = {}
    /// The field opened: the editor refuses keys while it is open (they belong to the field).
    var onReplacementFieldBegan: () -> Void = {}
    /// Bumped by the editor when a key reached it while the field is open: refocus the field
    /// (`focus`) or close it (`cancel`, Esc).
    var replacementFieldSignal = HistoryReplacementFieldSignal()

    @State private var replacementField = HistoryReplacementFieldState()
    @FocusState private var replacementFieldFocused: Bool

    var body: some View {
        // No header: the tab picker's History row above carries the title and the Exit capsule.
        VStack(spacing: 0) {
            if model.hasSelection {
                sectionRow
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
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            } else {
                Text(HistorySidebarPresentation.emptySelectionText)
                    .font(.system(size: 12))
                    .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, HistorySidebarPresentation.textInset)
                    // The Outline tab's gap under the divider.
                    .padding(.top, OutlineSidebarView.tabDividerGap)
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
        // Another passage (or none) is selected — a click in the text, a level button (which takes
        // no focus from the field): an open field belonged to the old one.
        .onChange(of: model.selectedPassageID) { _, id in
            if replacementField.selectionChanged(to: id) { onReplacementFieldEnded() }
        }
        // Torn down while open (sidebar hidden, History still on): the editor must get its keys
        // back, or `historyReplacementFieldIsOpen` stays set and every key is refused.
        .onDisappear(perform: closeReplacementField)
        .onChange(of: replacementFieldSignal.focus) { _, _ in
            guard replacementField.isOpen else { return }
            HistorySidebarPresentation.requestReplacementFieldFocus { replacementFieldFocused = true }
        }
        .onChange(of: replacementFieldSignal.cancel) { _, _ in closeReplacementField() }
    }

    /// "Versions of selected text" on the left, a quiet "Add +" on the right: the first row under
    /// the tab divider while a passage is selected. Add opens the field below the versions.
    private var sectionRow: some View {
        HStack(spacing: 8) {
            Text(HistorySidebarPresentation.versionsHeading)
                .font(.system(size: HistorySidebarPresentation.sectionFontSize))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HistoryAddAlternativeButton(usesDarkChrome: usesDarkChrome) {
                guard !replacementField.isOpen else {
                    HistorySidebarPresentation.requestReplacementFieldFocus { replacementFieldFocused = true }
                    return
                }
                if replacementField.open(for: model.selectedPassageID) { onReplacementFieldBegan() }
            }
        }
        .padding(.leading, HistorySidebarPresentation.textInset)
        // The button's own 4pt padding brings its glyph to the Exit capsule's trailing edge.
        .padding(.trailing, OutlineSidebarView.pillHorizontalInset - 4)
        .padding(.top, 10)
    }

    /// At the end of the versions: the field the section row's Add opens (nothing while closed).
    /// While the field has focus it owns the keys (arrows edit the text, Esc closes the field and
    /// leaves History on); Return adds the text as the passage's new current version.
    @ViewBuilder
    private var replacementControl: some View {
        if replacementField.isOpen {
            HStack(spacing: HistorySidebarPresentation.commitButtonGap) {
                TextField(
                    HistorySidebarPresentation.replacementPlaceholder,
                    text: $replacementField.draft,
                    prompt: Text(HistorySidebarPresentation.replacementPlaceholder)
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                .focused($replacementFieldFocused)
                .onSubmit(commitReplacement)
                .onExitCommand(perform: closeReplacementField)
                .frame(maxWidth: .infinity)
                HistoryCommitButton(isEnabled: replacementField.canCommit,
                                    usesDarkChrome: usesDarkChrome,
                                    action: commitReplacement)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
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
            .onChange(of: replacementFieldFocused) { _, focused in
                // Clicking away (into the text, another passage) closes the field unsaved.
                if !focused, replacementField.isOpen { closeReplacementField() }
            }
            .onAppear {
                HistorySidebarPresentation.requestReplacementFieldFocus { replacementFieldFocused = true }
            }
        }
    }

    private func commitReplacement() {
        guard let committed = replacementField.commit() else { return }
        onAddReplacement(committed.text, committed.passageID)
        onReplacementFieldEnded()
    }

    private func closeReplacementField() {
        if replacementField.close() { onReplacementFieldEnded() }
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
        .padding(.top, 6)
    }
}

/// The section row's quiet "Add +": borderless, muted ink (`addButtonWhite`), spoken as
/// "Add Alternative".
private struct HistoryAddAlternativeButton: View {
    var usesDarkChrome: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(HistorySidebarPresentation.addButtonTitle)
                    .font(.system(size: HistorySidebarPresentation.sectionFontSize, weight: .medium))
                Image(systemName: HistorySidebarPresentation.addButtonSymbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color(nsColor: NSColor(calibratedWhite: HistorySidebarPresentation.addButtonWhite(
                usesDarkChrome: usesDarkChrome, isHovered: isHovered), alpha: 1)))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .accessibilityLabel(HistorySidebarPresentation.addAlternativeTitle)
    }
}

/// The replacement field's trailing return button: a small circle with a return arrow that does
/// what Return does. It takes no focus (clicking it must not blur the field first, which would
/// close it unsaved), and it is disabled while the field is empty or whitespace.
private struct HistoryCommitButton: View {
    var isEnabled: Bool
    var usesDarkChrome: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let diameter = HistorySidebarPresentation.commitButtonDiameter
        let ink = OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
        Button(action: action) {
            Image(systemName: HistorySidebarPresentation.addAlternativeCommitSymbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ink.opacity(isEnabled ? 0.85 : 0.35))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(ink.opacity(isEnabled ? (isHovered ? 0.16 : 0.10) : 0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityLabel(HistorySidebarPresentation.addAlternativeCommitLabel)
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
