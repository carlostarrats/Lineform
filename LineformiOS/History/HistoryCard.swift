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
    /// Select Next / Previous Passage, for VoiceOver and Switch Control (a passage is otherwise
    /// picked by tapping its wash).
    var navigator = HistoryPassageNavigator()

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
        navigator = HistoryPassageNavigator(controller: controller)
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
    static var nextPassageTitle: String { String(localized: "Select Next Passage") }
    static var previousPassageTitle: String { String(localized: "Select Previous Passage") }
    static var exitTitle: String { String(localized: "Exit History") }
}

/// The card's way to the controller's passage navigation (the Mac's Select Next / Previous
/// Passage). Weak, and equal to any other navigator: it is not something the card shows.
struct HistoryPassageNavigator: Equatable {
    weak var controller: PhoneHistoryController?

    init(controller: PhoneHistoryController? = nil) {
        self.controller = controller
    }

    /// Selects the next (`delta` > 0) or previous located passage. False when there is none.
    @MainActor
    @discardableResult
    func move(by delta: Int) -> Bool {
        controller?.moveSelection(by: delta) != nil
    }

    static func == (lhs: HistoryPassageNavigator, rhs: HistoryPassageNavigator) -> Bool { true }
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
    /// VoiceOver lands on the card's title when History mode opens.
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The tallest the version list grows before it scrolls, and a row's height, at the default
    /// size; both scale with Dynamic Type.
    static let versionListMaxHeight: CGFloat = 176
    static let rowHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var scaledRowHeight: CGFloat = HistoryCard.rowHeight
    @ScaledMetric(relativeTo: .body) private var scaledListMaxHeight: CGFloat = HistoryCard.versionListMaxHeight
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var addGlyphSize: CGFloat = 13

    /// The smallest touch target (Apple's 44 × 44 pt).
    static let minimumTarget: CGFloat = 44

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        let phoneInk = PhoneInk(theme: theme)
        let secondary = phoneInk.secondary
        let stacks = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 12) {
            header(stacks: stacks)
            if model.hasSelection {
                if model.showsLevelSwitcher { levelSwitcher(ink: ink, secondary: secondary) }
                versionList(ink: ink, theme: theme)
                replacementField(ink: ink, secondary: secondary, edge: phoneInk.color(.controlEdge))
            } else {
                Text(HistoryCardModel.emptySelectionText)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The tap it asks for has a VoiceOver path: Select Next Passage, here, on the
                    // card and on the editor, and the editor's Passages rotor.
                    .accessibilityAction(named: Text(HistoryCardModel.nextPassageTitle)) { model.navigator.move(by: 1) }
            }
        }
        .foregroundStyle(ink)
        .tint(ink)
        .padding(16)
        .background { HistoryCardBackground(theme: theme) }
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(HistoryCardModel.nextPassageTitle)) { model.navigator.move(by: 1) }
        .accessibilityAction(named: Text(HistoryCardModel.previousPassageTitle)) { model.navigator.move(by: -1) }
        .accessibilityAction(named: Text(HistoryCardModel.exitTitle)) { onDone() }
        .accessibilityAction(.escape) { onDone() }
        .onAppear {
            openFieldIfRequested()
            // After the editor takes the focus on entry, VoiceOver is moved to the card.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                titleFocused = true
            }
        }
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

    /// "History" and Done; at accessibility sizes Done goes under the title.
    @ViewBuilder
    private func header(stacks: Bool) -> some View {
        let title = Text(HistoryCardModel.title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
        if stacks {
            VStack(alignment: .leading, spacing: 8) {
                title
                doneButton(reachesPastLayout: false)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: 0)
                doneButton(reachesPastLayout: true)
            }
        }
    }

    /// Done, with a 44 pt target; the reach is taken back with negative padding, so the header
    /// lays out as it always did.
    private func doneButton(reachesPastLayout: Bool) -> some View {
        Button(action: onDone) {
            Text(HistoryCardModel.doneTitle)
                .font(.body.weight(.semibold))
                .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.vertical, reachesPastLayout ? -11 : 0)
        .accessibilityIdentifier("history.done")
    }

    /// Paragraph · Sentence · Word in a row; one per line at accessibility sizes.
    private func levelSwitcher(ink: Color, secondary: Color) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            ForEach(model.levels, id: \.self) { level in
                let isCurrent = level == model.currentLevel
                Button {
                    onSelectLevel(level)
                } label: {
                    Text(level.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? ink : secondary)
                        .padding(.vertical, 4)
                        .frame(minHeight: Self.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The 44 pt target reaches past the drawn row; the row keeps its height.
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 0 : -8)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
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
            .frame(maxHeight: min(scaledListMaxHeight, CGFloat(model.rows.count) * (scaledRowHeight + 2)))
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
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: iconColumn)
            Text(row.text)
                .font(.body.weight(row.isCurrent ? .semibold : .regular))
                // At accessibility sizes a version gets room for more than a few words.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if row.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: scaledRowHeight, alignment: .leading)
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
        .accessibilityIdentifier("history.versionRow")
        .accessibilityAction { onSelectVersion(row.id) }
        // The context menu must not be the only path to Delete.
        .accessibilityAction(named: Text(HistoryCardModel.deleteVersionTitle)) { onDeleteVersion(row.id) }
    }

    private func replacementField(ink: Color, secondary: Color, edge: Color) -> some View {
        let canCommit = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            TextField(
                HistoryCardModel.replacementPlaceholder,
                text: $draft,
                prompt: Text(HistoryCardModel.replacementPlaceholder).foregroundStyle(secondary)
            )
            .focused($fieldFocused)
            .submitLabel(.done)
            .onSubmit { commit() }
            .autocorrectionDisabled()
            // The replacement goes into the middle of a sentence: never capitalize it.
            .textInputAutocapitalization(.never)
            Button { commit() } label: {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: addGlyphSize, weight: .bold))
                    .foregroundStyle(ink.opacity(canCommit ? 0.85 : 0.35))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ink.opacity(canCommit ? 0.10 : 0.05)))
                    .frame(width: Self.minimumTarget, height: Self.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A 30 pt circle drawn, a 44 pt target: the field keeps its height.
            .padding(-(Self.minimumTarget - 30) / 2)
            .disabled(!canCommit)
            .accessibilityLabel(HistoryCardModel.addTitle)
            .accessibilityIdentifier("history.add")
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
                .strokeBorder(edge, lineWidth: 1)
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
