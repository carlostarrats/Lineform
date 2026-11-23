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
/// (`SettingsSection`) follow. History sits after Search while the document has history; it is
/// not a page: choosing it closes the sheet and opens History mode (`onShowHistory`, D10).
struct MenuSheet: View {
    var document: OpenDocument
    var editor: any EditorCommands
    var files: FilesStore
    var settings: AppSettings
    var profile: ReadingProfile
    var onDismiss: () -> Void
    var exportCommands: ExportCommands?
    var selection: () -> NSRange?
    var mode: EditorDisplayMode
    /// Menu ▸ History: the screen closes the sheet, switches to Write and enters History mode.
    var onShowHistory: () -> Void
    /// The AI connection: the Document section shows Ask AI… while it is connected.
    var aiStore: AIConnectionStore?
    /// The Document section's Ask AI…, for the whole document (nil: no row).
    var onAskAI: (() -> Void)?

    static let sectionStorageKey = "menuSection"
    static let detents: Set<PresentationDetent> = [.medium, .large]

    /// At accessibility sizes the medium detent shows little more than the header and the section
    /// bar, so the sheet opens (and stays) at full height.
    static func detents(for dynamicTypeSize: DynamicTypeSize) -> Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.large] : detents
    }
    static let cornerRadius: CGFloat = LineformDesign.Radius.modal

    @SceneStorage(MenuSheet.sectionStorageKey) private var storedSection: MenuSection = .defaultSection
    /// The section on screen: the stored one, then every pick (written back to the scene). Plain
    /// state as well, because a sheet hosted outside a SwiftUI scene (a test) has no scene storage.
    @State private var shownSection: MenuSection?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var section: MenuSection {
        let section = shownSection ?? storedSection
        return section.isPage ? section : .defaultSection
    }

    init(
        document: OpenDocument,
        editor: any EditorCommands,
        files: FilesStore,
        settings: AppSettings = .shared,
        profile: ReadingProfile = .original,
        exportCommands: ExportCommands? = nil,
        selection: @escaping () -> NSRange? = { nil },
        mode: EditorDisplayMode = .write,
        onShowHistory: @escaping () -> Void = {},
        aiStore: AIConnectionStore? = nil,
        onAskAI: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.document = document
        self.editor = editor
        self.files = files
        self.settings = settings
        self.profile = profile
        self.onDismiss = onDismiss
        self.exportCommands = exportCommands
        self.selection = selection
        self.mode = mode
        self.onShowHistory = onShowHistory
        self.aiStore = aiStore
        self.onAskAI = onAskAI
    }

    // MARK: - Header text

    /// "Saved" only while a file holds exactly the text on screen; "Unsaved changes" in the
    /// moment between a keystroke and its autosave (or after a failed save); and the Mac's "Not
    /// saved yet" for text no file holds: a new document before its first save, or one whose
    /// file was deleted elsewhere (its text stays on screen, and the next change saves it as a
    /// new document). Every iPhone write is an autosave, so the Mac's "Autosaved" (its flash for
    /// an autosave as against ⌘S) would tell the writer nothing more.
    static func saveStateText(hasFile: Bool, text: String, lastSyncedText: String) -> String {
        guard hasFile else { return notSavedYetText }
        return DocumentStatusText.saveState(isSaved: text == lastSyncedText, isAutosaved: false)
    }

    static func saveStateText(for document: OpenDocument) -> String {
        saveStateText(hasFile: document.url != nil, text: document.text, lastSyncedText: document.lastSyncedText)
    }

    /// The Mac's label for an untitled document, with its translations.
    static var notSavedYetText: String { String(localized: "Not saved yet") }

    static func countsText(for text: String) -> String {
        DocumentStatusText.counts(DocumentStatistics(text: text))
    }

    /// The header as VoiceOver reads it: the save state, then the counts in words. A localized
    /// format (the Mac's "%@, %@"), so Japanese and Chinese get their own comma.
    static func headerAccessibilityLabel(saveState: String, statistics: DocumentStatistics) -> String {
        let counts = DocumentStatusText.countsAccessibilityText(statistics)
        return String(localized: "\(saveState), \(counts)")
    }

    /// The History section button's hint: it is not a page, it leaves the sheet.
    static var historyHint: String { String(localized: "Closes the menu and opens History.") }

    // MARK: - Body

    var body: some View {
        let theme = Theme.theme(for: profile)
        VStack(spacing: 0) {
            header(theme: theme)
            MenuSectionBar(
                selection: Binding(get: { section }, set: { picked in select(picked) }),
                sections: MenuSection.visible(hasHistory: document.history?.hasHistory == true),
                theme: theme
            )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Color(uiColor: theme.textColor))
        .environment(\.menuTheme, theme)
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        // A system sheet is already modal for VoiceOver; said here too, so nothing behind it is
        // reachable however it is hosted.
        .accessibilityAddTraits(.isModal)
        .presentationDetents(Self.detents(for: dynamicTypeSize))
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Self.cornerRadius)
        .presentationBackground {
            MenuSheetBackground(theme: theme)
        }
        .onAppear { shownSection = shownSection ?? storedSection }
    }

    private func select(_ picked: MenuSection) {
        guard picked.isPage else {
            onShowHistory()
            return
        }
        shownSection = picked
        storedSection = picked
    }

    private func header(theme: Theme) -> some View {
        let saveState = Self.saveStateText(for: document)
        let statistics = DocumentStatistics(text: document.text)
        let ink = PhoneInk.menu(theme)
        let status = VStack(alignment: .leading, spacing: 2) {
            Text(saveState)
                .font(.subheadline.weight(.medium))
            Text(DocumentStatusText.counts(statistics))
                .font(.footnote)
                .foregroundStyle(ink.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.headerAccessibilityLabel(saveState: saveState, statistics: statistics)))
        // Done's target reaches 44 pt inside the button; the negative padding outside gives the
        // room back, so the header keeps its height and Done its place.
        let done = Button(action: onDismiss) {
            Text(String(localized: "Done"))
                .padding(.vertical, Self.doneTargetPadding.height)
                .padding(.horizontal, Self.doneTargetPadding.width)
                .contentShape(Rectangle())
        }
        .font(.body.weight(.semibold))
        .padding(.vertical, -Self.doneTargetPadding.height)
        .padding(.horizontal, -Self.doneTargetPadding.width)
        return Group {
            // At accessibility sizes the save state and Done would collide on one line.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    status
                    done
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    status
                    Spacer(minLength: 0)
                    done
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    /// The room around Done's text that makes its target at least 44 × 44 pt.
    static let doneTargetPadding = CGSize(width: 8, height: 14)

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
            DocumentSection(
                document: document, editor: editor, files: files, onDismiss: onDismiss,
                exportCommands: exportCommands, selection: selection, mode: mode,
                aiStore: aiStore, onAskAI: onAskAI
            )
        case .settings:
            SettingsSection(settings: settings, usesDarkChrome: Theme.theme(for: profile).usesDarkChrome)
        case .history:
            // Never a page (`section` falls back to the default).
            EmptyView()
        }
    }
}

/// The sideways bar of section buttons at the top of the sheet.
struct MenuSectionBar: View {
    @Binding var selection: MenuSection
    var sections: [MenuSection] = MenuSection.visible(hasHistory: false)
    var theme: Theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sections) { section in
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
                            // The capsule is drawn at its text's height; the target reaches
                            // 44 pt, and the negative padding gives the room back to the bar.
                            .padding(.vertical, Self.targetPadding)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -Self.targetPadding)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityHint(section.isPage ? Text(verbatim: "") : Text(MenuSheet.historyHint))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    /// Above and below a section button's capsule, inside its target.
    static let targetPadding: CGFloat = 7
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
    static let systemImage = "line.3.horizontal"

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        Button(action: action) {
            Image(systemName: Self.systemImage)
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
        // Fixed-size floating chrome: a long press at accessibility sizes shows it enlarged.
        .accessibilityShowsLargeContentViewer {
            Label(Self.accessibilityTitle, systemImage: Self.systemImage)
        }
    }
}

extension EnvironmentValues {
    /// The Menu sheet's display theme, so its sections draw their quiet inks with `PhoneInk`.
    @Entry var menuTheme: Theme = Theme.theme(for: .original)
}

extension PhoneInk {
    /// The inks of a sheet drawn in `theme`: resolved for the colour scheme the sheet forces
    /// (`theme.usesDarkChrome`).
    static func menu(_ theme: Theme) -> PhoneInk {
        PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light)
    }
}
