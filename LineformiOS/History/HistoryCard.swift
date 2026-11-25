import LineformCore
import SwiftUI

/// What History mode's bar shows, read from the controller. Pure, so tests read it without a view.
struct HistoryCardModel: Equatable {
    var levels: [HistoryLevel] = []
    var currentLevel: HistoryLevel?
    /// The selected passage's versions: how many, and which one the page shows (0-based).
    var versionCount = 0
    var currentVersionIndex = 0
    /// The passage the versions belong to; the replacement field belongs to it alone.
    var selectedPassageID: UUID?
    /// Replace With… asked for the field on the selected passage (focus it now).
    var opensReplacementField = false
    /// History mode came from Replace With…: the bar shows "Type a replacement". Never from
    /// ⋯ ▸ History.
    var offersReplacementField = false
    /// Select Next / Previous Passage, for VoiceOver and Switch Control (a passage is otherwise
    /// picked by tapping its wash).
    var navigator = HistoryPassageNavigator()
    /// VoiceOver moved the selection itself (the Passages rotor) and is reading it: the bar's
    /// announcement would talk over it.
    var announcesChanges = true

    var hasSelection: Bool { selectedPassageID != nil }

    /// The level tabs show only when the selected passage has more than one level available,
    /// and then only the available ones (never a greyed tab).
    var showsLevelSwitcher: Bool { levels.count > 1 }

    /// The field shows on a selected passage of a Replace With… session.
    var showsReplacementField: Bool { offersReplacementField && hasSelection }

    var canStepBack: Bool { hasSelection && currentVersionIndex > 0 }
    var canStepForward: Bool { hasSelection && currentVersionIndex < versionCount - 1 }

    /// The bar's compact "Version 2/2" (owner, 2026-11-24).
    var versionText: String? {
        guard hasSelection, versionCount > 0 else { return nil }
        return Self.versionText(position: currentVersionIndex + 1, of: versionCount)
    }

    static func versionText(position: Int, of count: Int) -> String {
        String(localized: "Version \(position)/\(count)")
    }

    /// What VoiceOver hears when the selection or its version changes, and the version line's
    /// spoken label: the Mac's announcement ("Sentence, version 2 of 2").
    var announcement: String? {
        guard let level = currentLevel, hasSelection, versionCount > 0 else { return nil }
        return String(localized: "\(level.title), version \(currentVersionIndex + 1) of \(versionCount)")
    }

    init() {}

    @MainActor
    init(controller: PhoneHistoryController) {
        navigator = HistoryPassageNavigator(controller: controller)
        announcesChanges = !controller.selectionIsSpokenElsewhere
        offersReplacementField = controller.isHistoryModeActive && controller.offersReplacementField
        guard controller.isHistoryModeActive, let passage = controller.selectedPassage else { return }
        selectedPassageID = passage.id
        currentLevel = passage.level
        levels = controller.levels(containing: passage.id)
        versionCount = passage.versions.count
        currentVersionIndex = passage.currentIndex
        opensReplacementField = controller.pendingReplacementFieldID == passage.id
    }

    // MARK: Strings (the Mac's where the Mac has the same text)

    /// The bar's name for VoiceOver (it draws no title).
    static var title: String { String(localized: "History") }
    static var doneTitle: String { String(localized: "Done") }
    static var emptySelectionText: String { String(localized: "Tap a highlighted passage to see its versions.") }
    static var replacementPlaceholder: String { String(localized: "Type a replacement") }
    static var addTitle: String { String(localized: "Add") }
    static var earlierVersionTitle: String { String(localized: "Earlier version") }
    static var laterVersionTitle: String { String(localized: "Later version") }
    static var nextPassageTitle: String { String(localized: "Select Next Passage") }
    static var previousPassageTitle: String { String(localized: "Select Previous Passage") }
    static var exitTitle: String { String(localized: "Exit History") }
}

/// The bar's way to the controller's passage navigation (the Mac's Select Next / Previous
/// Passage). Weak, and equal to any other navigator: it is not something the bar shows.
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

/// History mode's bar, the approved mockup's one line (`word-menu.html`, `.hist`): at the bottom
/// of the page, 14 pt inside the screen's sides, on the soft surface (`PhoneInk.searchFieldWash`)
/// with 16 pt corners and a soft shadow. "Version 2/2", then ‹ › as round buttons
/// (`PhoneInk.readAloudButton`, the Read Aloud pill's), then Done as a pill in the ink with the
/// page colour for its text. Nothing selected, the line says how to pick a passage.
///
/// Above the bar, only when the selected passage has more than one level, its available levels
/// as tabs (Paragraph · Sentence · Word). Only in a Replace With… session, "Type a replacement"
/// sits inside the bar above the version line.
///
/// Fully operable without sight: the version line is adjustable (swipe up / down steps the
/// versions) and carries Select Next / Previous Passage and Exit History; ‹ › and Done are labelled
/// buttons; Escape leaves. A hardware keyboard's ← / → / Esc are the editor's.
///
/// Its callbacks are the controller's API: the screen passes the editor's current text.
struct HistoryCard: View {
    var model: HistoryCardModel
    var profile: ReadingProfile
    var onSelectLevel: (HistoryLevel) -> Void
    /// ‹ (-1) and › (+1): one version earlier or later.
    var onStep: (Int) -> Void
    /// Return in the field: the text and the passage the field was opened for.
    var onAddReplacement: (String, UUID) -> Void
    /// Replace With…'s request for the field was met (`PhoneHistoryController.replacementFieldDidOpen`).
    var onReplacementFieldOpened: () -> Void
    var onDone: () -> Void

    @State private var draft = ""
    /// The passage the draft belongs to; another selection clears it.
    @State private var draftPassageID: UUID?
    @FocusState private var fieldFocused: Bool
    /// VoiceOver lands on the version line when History mode opens.
    @AccessibilityFocusState private var lineFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // The mockup's values.
    static let sideInset: CGFloat = 14
    static let cornerRadius: CGFloat = 16
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let itemSpacing: CGFloat = 10
    static let buttonDiameter: CGFloat = 36
    static let shadowOpacity: CGFloat = 0.15
    static let shadowRadius: CGFloat = 10
    static let shadowY: CGFloat = 6
    /// The smallest touch target (Apple's 44 × 44 pt).
    static let minimumTarget: CGFloat = 44

    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var addGlyphSize: CGFloat = 13

    var body: some View {
        let theme = Theme.theme(for: profile)
        // The bar forces its scheme from the theme (below), so its inks resolve for that scheme.
        let inks = PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light)
        VStack(spacing: 8) {
            if model.showsLevelSwitcher { levelTabs(inks) }
            bar(inks)
        }
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .onAppear { openFieldIfRequested() }
        .task {
            // VoiceOver moves to the version line once it is laid out: after this appearance, and
            // after the editor's own first-responder change on entry (queued before the bar
            // appeared), never on a fixed clock.
            await Task.yield()
            lineFocused = true
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
            if let text, model.announcesChanges { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    // MARK: - The bar

    private func bar(_ inks: PhoneInk) -> some View {
        let ink = Color(uiColor: inks.theme.textColor)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: Self.itemSpacing) {
            if model.showsReplacementField { replacementField(inks) }
            HStack(spacing: Self.itemSpacing) {
                versionLine(inks)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.hasSelection {
                    stepButton(-1, inks)
                    stepButton(1, inks)
                }
                doneButton(inks)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(shape.fill(Color(uiColor: inks.searchFieldWash)))
        .shadow(color: .black.opacity(Self.shadowOpacity), radius: Self.shadowRadius, x: 0, y: Self.shadowY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HistoryCardModel.title)
        .accessibilityAction(.escape) { onDone() }
    }

    /// "Version 2/2", or the hint while nothing is selected. The bar's commands for VoiceOver sit
    /// here, where VoiceOver lands (a container's named actions do not reach its elements).
    @ViewBuilder
    private func versionLine(_ inks: PhoneInk) -> some View {
        if let versionText = model.versionText {
            Text(versionText)
                .font(.system(size: textSize))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // An adjustable control: its target is 44 pt tall, the reach taken back so the
                // bar keeps the mockup's height.
                .frame(maxWidth: .infinity, minHeight: Self.minimumTarget, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, -(Self.minimumTarget - Self.buttonDiameter) / 2)
                .accessibilityLabel(model.announcement ?? versionText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if model.canStepForward { onStep(1) }
                    case .decrement: if model.canStepBack { onStep(-1) }
                    @unknown default: break
                    }
                }
                .modifier(HistoryBarActions(model: model, onDone: onDone))
                .accessibilityFocused($lineFocused)
        } else {
            Text(HistoryCardModel.emptySelectionText)
                .font(.system(size: textSize))
                .foregroundStyle(inks.color(.secondaryOnSoftBar))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .modifier(HistoryBarActions(model: model, onDone: onDone))
                .accessibilityFocused($lineFocused)
        }
    }

    /// ‹ or ›: a 36 pt circle, a 44 pt target (the reach is taken back, so the bar keeps the
    /// mockup's height).
    private func stepButton(_ delta: Int, _ inks: PhoneInk) -> some View {
        let enabled = delta < 0 ? model.canStepBack : model.canStepForward
        let glyph = inks.color(.onReadAloudButton)
        return Button { onStep(delta) } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .medium))
                // Disabled, the glyph is exempt from the contrast floor (WCAG 1.4.11).
                .foregroundStyle(enabled ? glyph : glyph.opacity(0.35))
                .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                .background(Circle().fill(Color(uiColor: inks.readAloudButton)))
                .frame(width: Self.minimumTarget, height: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-(Self.minimumTarget - Self.buttonDiameter) / 2)
        .fixedSize()
        .layoutPriority(1)
        .disabled(!enabled)
        .accessibilityLabel(delta < 0 ? HistoryCardModel.earlierVersionTitle : HistoryCardModel.laterVersionTitle)
        .accessibilityIdentifier(delta < 0 ? "history.previous" : "history.next")
    }

    /// Done: the ink as a pill, its text in the page colour; a 44 pt target.
    private func doneButton(_ inks: PhoneInk) -> some View {
        Button(action: onDone) {
            Text(HistoryCardModel.doneTitle)
                .font(.system(size: textSize))
                .foregroundStyle(Color(uiColor: inks.page))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(uiColor: inks.theme.textColor)))
                .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -(Self.minimumTarget - Self.buttonDiameter) / 2)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityIdentifier("history.done")
    }

    // MARK: - Levels

    /// The passage's available levels (Paragraph · Sentence · Word), on the bar's surface, above
    /// it. One per line at accessibility sizes.
    private func levelTabs(_ inks: PhoneInk) -> some View {
        let ink = Color(uiColor: inks.theme.textColor)
        let secondary = inks.color(.secondaryOnSoftBar)
        let stacks = dynamicTypeSize.isAccessibilitySize
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ForEach(model.levels, id: \.self) { level in
                let isCurrent = level == model.currentLevel
                Button {
                    onSelectLevel(level)
                } label: {
                    Text(level.title)
                        .font(.system(size: textSize, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? ink : secondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: Self.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        // The tabs' 44 pt targets reach past the drawn 36 pt surface.
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(uiColor: inks.searchFieldWash))
                .padding(.vertical, stacks ? 0 : (Self.minimumTarget - Self.buttonDiameter) / 2)
                .shadow(color: .black.opacity(Self.shadowOpacity), radius: Self.shadowRadius, x: 0, y: Self.shadowY)
        }
    }

    // MARK: - Field

    private func replacementField(_ inks: PhoneInk) -> some View {
        let canCommit = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ink = Color(uiColor: inks.theme.textColor)
        return HStack(spacing: 8) {
            TextField(
                HistoryCardModel.replacementPlaceholder,
                text: $draft,
                prompt: Text(HistoryCardModel.replacementPlaceholder).foregroundStyle(inks.secondary)
            )
            .font(.system(size: textSize + 1))
            .focused($fieldFocused)
            .submitLabel(.done)
            .onSubmit { commit() }
            .autocorrectionDisabled()
            // The replacement goes into the middle of a sentence: never capitalize it.
            .textInputAutocapitalization(.never)
            Button { commit() } label: {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: addGlyphSize, weight: .bold))
                    // Disabled, the glyph is exempt from the contrast floor (WCAG 1.4.11).
                    .foregroundStyle(canCommit ? inks.color(.historyAddGlyph) : ink.opacity(0.35))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ink.opacity(canCommit ? PhoneInk.historyAddWashAlpha : 0.05)))
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
                .fill(Color(uiColor: inks.page))
        }
        .overlay {
            RoundedRectangle(cornerRadius: LineformDesign.Radius.row, style: .continuous)
                .strokeBorder(inks.color(.controlEdge), lineWidth: 1)
        }
    }

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

/// The bar's commands for VoiceOver and Switch Control, on the element VoiceOver lands on.
private struct HistoryBarActions: ViewModifier {
    var model: HistoryCardModel
    var onDone: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text(HistoryCardModel.nextPassageTitle)) { model.navigator.move(by: 1) }
            .accessibilityAction(named: Text(HistoryCardModel.previousPassageTitle)) { model.navigator.move(by: -1) }
            .accessibilityAction(named: Text(HistoryCardModel.exitTitle)) { onDone() }
    }
}
