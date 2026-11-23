import LineformCore
import SwiftUI

/// One version in the card's list: its first line, who wrote it, and whether it is current.
struct HistoryCardRow: Equatable, Identifiable {
    /// The version's index in the passage.
    let id: Int
    let text: String
    let author: HistoryAuthor
    let isCurrent: Bool

    /// First non-empty line, every whitespace run collapsed to one space (the Mac's rule).
    static func displayText(for version: String) -> String {
        let firstLine = version
            .split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        return firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first version is where the passage started.
    var isOriginal: Bool { id == 0 }

    /// The Mac's icons: the original a page, the writer's versions a pencil, AI versions a sparkle.
    var symbolName: String {
        if isOriginal { return "doc.text" }
        return author == .you ? "pencil" : "sparkles"
    }

    /// Spoken label (the Mac's strings). `position` is 1-based.
    func accessibilityLabel(position: Int, of count: Int) -> String {
        if isOriginal { return String(localized: "\(text), original, version \(position) of \(count)") }
        switch author {
        case .you: return String(localized: "\(text), by you, version \(position) of \(count)")
        case .ai: return String(localized: "\(text), by AI, version \(position) of \(count)")
        }
    }
}

/// What the History card shows, read from the controller. Pure, so tests read it without a view.
struct HistoryCardModel: Equatable {
    var levels: [HistoryLevel] = []
    var currentLevel: HistoryLevel?
    var rows: [HistoryCardRow] = []
    /// The passage the versions belong to; the replacement field belongs to it alone.
    var selectedPassageID: UUID?
    /// Replace With… asked for the field on the selected passage.
    var opensReplacementField = false

    var hasSelection: Bool { selectedPassageID != nil }

    /// The level switcher shows only when the selected passage's group has more than one level.
    var showsLevelSwitcher: Bool { levels.count > 1 }

    /// What VoiceOver hears when the selection or its version changes: the Mac's announcement.
    var announcement: String? {
        guard let level = currentLevel, let position = rows.firstIndex(where: \.isCurrent) else { return nil }
        return String(localized: "\(level.title), version \(position + 1) of \(rows.count)")
    }

    init() {}

    @MainActor
    init(controller: PhoneHistoryController) {
        guard controller.isHistoryModeActive, let passage = controller.selectedPassage else { return }
        selectedPassageID = passage.id
        currentLevel = passage.level
        levels = controller.levels(containing: passage.id)
        rows = passage.versions.enumerated().map { index, version in
            HistoryCardRow(
                id: index,
                text: HistoryCardRow.displayText(for: version.text),
                author: version.author,
                isCurrent: index == passage.currentIndex
            )
        }
        opensReplacementField = controller.pendingReplacementFieldID == passage.id
    }

    // MARK: Strings (the Mac's where the Mac has the same text)

    static var title: String { String(localized: "History") }
    static var doneTitle: String { String(localized: "Done") }
    static var emptySelectionText: String { String(localized: "Tap a highlighted passage to see its versions.") }
    static var replacementPlaceholder: String { String(localized: "Type a replacement") }
    static var addTitle: String { String(localized: "Add") }
    static var deleteVersionTitle: String { String(localized: "Delete from History") }
}

/// History mode's card (D10): at the bottom of the page, above the keyboard and the home
/// indicator, full width inside the app's margins, in the floating-card chrome the Menu button
/// and the quiet notice use. With nothing selected it says how to pick a passage; with one
/// selected it shows the level switcher (only when there is more than one level), the versions
/// (pencil = you, sparkle = AI, the current one marked), Delete on a version (its context menu and
/// the VoiceOver actions), and the "Type a replacement" field. Done leaves History mode.
///
/// Its callbacks are the controller's API: the screen passes the editor's current text.
struct HistoryCard: View {
    var model: HistoryCardModel
    var profile: ReadingProfile
    var onSelectLevel: (HistoryLevel) -> Void
    var onSelectVersion: (Int) -> Void
    var onDeleteVersion: (Int) -> Void
    /// Return in the field: the text and the passage the field was opened for.
    var onAddReplacement: (String, UUID) -> Void
    /// Replace With…'s request for the field was met (`PhoneHistoryController.replacementFieldDidOpen`).
    var onReplacementFieldOpened: () -> Void
    var onDone: () -> Void

    @State private var draft = ""
    /// The passage the draft belongs to; another selection clears it.
    @State private var draftPassageID: UUID?
    @FocusState private var fieldFocused: Bool

    /// The tallest the version list grows before it scrolls.
    static let versionListMaxHeight: CGFloat = 176
    static let rowHeight: CGFloat = 40

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        let secondary = Color(uiColor: theme.readableInk(theme.textColor.withAlphaComponent(0.6)))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(HistoryCardModel.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(HistoryCardModel.doneTitle, action: onDone)
                    .font(.body.weight(.semibold))
            }
            if model.hasSelection {
                if model.showsLevelSwitcher { levelSwitcher(ink: ink, secondary: secondary) }
                versionList(ink: ink, theme: theme)
                replacementField(ink: ink, secondary: secondary)
            } else {
                Text(HistoryCardModel.emptySelectionText)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(ink)
        .tint(ink)
        .padding(16)
        .background { HistoryCardBackground(theme: theme) }
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .onAppear(perform: openFieldIfRequested)
        .onChange(of: model.opensReplacementField) { _, _ in openFieldIfRequested() }
        .onChange(of: model.selectedPassageID) { _, id in
            guard id != draftPassageID else { return }
            draft = ""
            draftPassageID = id
            fieldFocused = false
        }
        .onChange(of: model.announcement) { _, text in
            // A step, a level or another passage: say where the selection is now.
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    // MARK: - Parts

    private func levelSwitcher(ink: Color, secondary: Color) -> some View {
        HStack(spacing: 18) {
            ForEach(model.levels, id: \.self) { level in
                let isCurrent = level == model.currentLevel
                Button {
                    onSelectLevel(level)
                } label: {
                    Text(level.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? ink : secondary)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func versionList(ink: Color, theme: Theme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        versionRow(row, position: index + 1, ink: ink)
                            .id(row.id)
                    }
                }
            }
            .frame(maxHeight: min(Self.versionListMaxHeight, CGFloat(model.rows.count) * (Self.rowHeight + 2)))
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: model.rows) { _, _ in scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        if let current = model.rows.first(where: \.isCurrent) { proxy.scrollTo(current.id) }
    }

    private func versionRow(_ row: HistoryCardRow, position: Int, ink: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
            Text(row.text)
                .font(.body.weight(row.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if row.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: LineformDesign.Radius.row, style: .continuous)
                .fill(ink.opacity(row.isCurrent ? 0.08 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelectVersion(row.id) }
        .contextMenu {
            Button(role: .destructive) {
                onDeleteVersion(row.id)
            } label: {
                Label(HistoryCardModel.deleteVersionTitle, systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(position: position, of: model.rows.count))
        .accessibilityAddTraits(row.isCurrent ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onSelectVersion(row.id) }
        // The context menu must not be the only path to Delete.
        .accessibilityAction(named: Text(HistoryCardModel.deleteVersionTitle)) { onDeleteVersion(row.id) }
    }

    private func replacementField(ink: Color, secondary: Color) -> some View {
        let canCommit = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            TextField(
                HistoryCardModel.replacementPlaceholder,
                text: $draft,
                prompt: Text(HistoryCardModel.replacementPlaceholder).foregroundStyle(secondary)
            )
            .focused($fieldFocused)
            .submitLabel(.done)
            .onSubmit(commit)
            .autocorrectionDisabled()
            // The replacement goes into the middle of a sentence: never capitalize it.
            .textInputAutocapitalization(.never)
            Button(action: commit) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ink.opacity(canCommit ? 0.85 : 0.35))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ink.opacity(canCommit ? 0.10 : 0.05)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .accessibilityLabel(HistoryCardModel.addTitle)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(minHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: LineformDesign.Radius.row, style: .continuous)
                .fill(ink.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: LineformDesign.Radius.row, style: .continuous)
                .strokeBorder(ink.opacity(0.22), lineWidth: 1)
        }
    }

    // MARK: - Field

    private func openFieldIfRequested() {
        guard model.opensReplacementField, let id = model.selectedPassageID else { return }
        draftPassageID = id
        draft = ""
        onReplacementFieldOpened()
        // A focus write in the same pass as the field's insertion can be dropped.
        Task { @MainActor in fieldFocused = true }
    }

    private func commit() {
        guard let id = model.selectedPassageID ?? draftPassageID else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        fieldFocused = false
        onAddReplacement(text, id)
    }
}

/// The card's chrome: the page colour with the floating-card hairline and soft shadow.
private struct HistoryCardBackground: View {
    var theme: Theme

    var body: some View {
        let isDark = theme.usesDarkChrome
        let shape = RoundedRectangle(cornerRadius: LineformDesign.FloatingCard.radius, style: .continuous)
        shape
            .fill(Color(uiColor: theme.backgroundColor))
            .overlay(
                shape.strokeBorder(
                    isDark
                        ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                        : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                    lineWidth: LineformDesign.FloatingCard.hairlineWidth
                )
            )
            .shadow(
                color: .black.opacity(
                    isDark ? LineformDesign.FloatingCard.shadowOpacityDark : LineformDesign.FloatingCard.shadowOpacityLight
                ),
                radius: LineformDesign.FloatingCard.shadowRadius,
                x: LineformDesign.FloatingCard.shadowOffset.width,
                y: LineformDesign.FloatingCard.shadowOffset.height
            )
    }
}
