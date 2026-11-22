import LineformCore
import SwiftUI

/// The Menu sheet: the iPhone's one place for files, the outline, Markdown Basics, search, the
/// document's tools and settings. A page-coloured card (the desktop modal look, radius
/// `LineformDesign.Radius.modal`) at medium or large height, with a header (the save state and
/// the counts) and the section bar, which scrolls sideways.
///
/// The section is kept with the scene (`@SceneStorage("menuSection")`, raw values never
/// localized) and opens on Files (`FilesSection`). Outline (`OutlineSection`), Markdown Basics
/// (`BasicsSection`), Search (`SearchSection`), Document (`DocumentSection`) and Settings
/// (`SettingsSection`) follow.
struct MenuSheet: View {
    var document: OpenDocument
    var editor: any EditorCommands
    var files: FilesStore
    var settings: AppSettings
    var profile: ReadingProfile
    var onDismiss: () -> Void

    static let sectionStorageKey = "menuSection"
    static let detents: Set<PresentationDetent> = [.medium, .large]
    static let cornerRadius: CGFloat = LineformDesign.Radius.modal

    @SceneStorage(MenuSheet.sectionStorageKey) private var storedSection: MenuSection = .defaultSection
    /// The section on screen: the stored one, then every pick (written back to the scene). Plain
    /// state as well, because a sheet hosted outside a SwiftUI scene (a test) has no scene storage.
    @State private var shownSection: MenuSection?
    private var section: MenuSection { shownSection ?? storedSection }

    init(
        document: OpenDocument,
        editor: any EditorCommands,
        files: FilesStore,
        settings: AppSettings = .shared,
        profile: ReadingProfile = .original,
        onDismiss: @escaping () -> Void
    ) {
        self.document = document
        self.editor = editor
        self.files = files
        self.settings = settings
        self.profile = profile
        self.onDismiss = onDismiss
    }

    // MARK: - Header text

    /// "Saved" while disk has the text, "Unsaved changes" in the moment between a keystroke and
    /// its autosave (or after a failed save). Every iPhone write is an autosave, so the Mac's
    /// "Autosaved" (its flash for an autosave as against ⌘S) would tell the writer nothing more.
    static func saveStateText(text: String, lastSyncedText: String) -> String {
        DocumentStatusText.saveState(isSaved: text == lastSyncedText, isAutosaved: false)
    }

    static func countsText(for text: String) -> String {
        DocumentStatusText.counts(DocumentStatistics(text: text))
    }

    // MARK: - Body

    var body: some View {
        let theme = Theme.theme(for: profile)
        VStack(spacing: 0) {
            header(theme: theme)
            MenuSectionBar(selection: Binding(get: { section }, set: select), theme: theme)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Color(uiColor: theme.textColor))
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .presentationDetents(Self.detents)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Self.cornerRadius)
        .presentationBackground {
            MenuSheetBackground(theme: theme)
        }
        .onAppear { shownSection = shownSection ?? storedSection }
    }

    private func select(_ picked: MenuSection) {
        shownSection = picked
        storedSection = picked
    }

    private func header(theme: Theme) -> some View {
        let saveState = Self.saveStateText(text: document.text, lastSyncedText: document.lastSyncedText)
        let statistics = DocumentStatistics(text: document.text)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saveState)
                    .font(.subheadline.weight(.medium))
                Text(DocumentStatusText.counts(statistics))
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: theme.textColor).opacity(0.6))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(saveState), \(DocumentStatusText.countsAccessibilityText(statistics))"))
            Spacer(minLength: 0)
            Button(String(localized: "Done"), action: onDismiss)
                .font(.body.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .files:
            FilesSection(store: files, document: document, onDismiss: onDismiss)
        case .outline:
            OutlineSection(text: document.text, editor: editor, onDismiss: onDismiss)
        case .basics:
            BasicsSection()
        case .search:
            SearchSection(document: document, editor: editor, files: files, onDismiss: onDismiss)
        case .document:
            DocumentSection(document: document, editor: editor, files: files, onDismiss: onDismiss)
        case .settings:
            SettingsSection(settings: settings)
        }
    }
}

/// The sideways bar of section buttons at the top of the sheet.
struct MenuSectionBar: View {
    @Binding var selection: MenuSection
    var theme: Theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MenuSection.allCases) { section in
                    let isSelected = section == selection
                    Button {
                        selection = section
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color(uiColor: theme.textColor).opacity(isSelected ? 0.1 : 0))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }
}

/// The sheet's card: the page colour with the floating-card hairline and soft shadow.
private struct MenuSheetBackground: View {
    var theme: Theme

    var body: some View {
        let isDark = theme.usesDarkChrome
        let shape = RoundedRectangle(cornerRadius: MenuSheet.cornerRadius, style: .continuous)
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
            .ignoresSafeArea()
    }
}

/// The Menu button: a circular floating control in the bottom-right corner, drawn with the same
/// floating-card chrome as the Mac's announcement card. It opens the Menu sheet.
struct MenuButton: View {
    var profile: ReadingProfile
    var action: () -> Void

    static let diameter: CGFloat = 44
    static var accessibilityTitle: String { String(localized: "Menu") }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.textColor))
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(Color(uiColor: theme.backgroundColor)))
                .overlay(
                    Circle().strokeBorder(
                        isDark
                            ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                            : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                        lineWidth: LineformDesign.FloatingCard.hairlineWidth
                    )
                )
                .shadow(
                    color: .black.opacity(
                        isDark ? LineformDesign.FloatingCard.shadowOpacityDark
                            : LineformDesign.FloatingCard.shadowOpacityLight
                    ),
                    radius: LineformDesign.FloatingCard.shadowRadius,
                    x: LineformDesign.FloatingCard.shadowOffset.width,
                    y: LineformDesign.FloatingCard.shadowOffset.height
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityTitle)
    }
}
