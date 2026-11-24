import LineformCore
import SwiftUI

/// The word menu: the iPhone's one place for files, the outline, Markdown Basics, themes,
/// settings, export, read aloud, history, the AI connection and About. The ⋯ button opens it over
/// the whole screen, on the Mac Settings window's wash (never the page's colour).
///
/// The word list sits low, where the thumb is: Files, Outline and Markdown Basics large; Themes
/// and Settings large and grey; the small words below. A status line at the top names the
/// document, its save state ("Saved" in the Mac's green) and its words. Tapping a word opens its
/// page AT ONCE — no flying words, fades or staggers, in either direction. The corner button
/// bottom right is ✕ on the word list and ← inside a page (folder → Files → words). Themes and
/// Read Aloud leave the menu instead: Themes opens the Styling sheet over the page, Read Aloud
/// starts reading and shows its pill beside the ⋯ button.
///
/// The menu is modal for VoiceOver; Esc (a hardware keyboard, or VoiceOver's scrub) goes back one
/// page, then closes. Pages reach the editor only through `EditorCommands`.
struct WordMenu: View {
    var document: OpenDocument
    var editor: any EditorCommands
    var files: FilesStore
    var settings: AppSettings
    /// The page's display profile: its darkness picks the light or dark wash.
    var profile: ReadingProfile
    var exportCommands: ExportCommands?
    var mode: EditorDisplayMode
    var aiStore: AIConnectionStore?
    var updateCommand: PhoneUpdateCommand = .shared
    var onClose: () -> Void
    /// Themes: the screen closes the menu and opens the Styling sheet.
    var onThemes: () -> Void
    /// Read Aloud: the screen closes the menu and starts reading.
    var onReadAloud: () -> Void
    /// History: the screen closes the menu and enters History mode on the passage.
    var onShowHistoryPassage: (UUID) -> Void
    /// Connect Your AI ▸ Ask AI… for the whole document (after the menu closes).
    var onAskAI: () -> Void

    @State private var navigation = WordMenuNavigation()
    @State private var fileActions = FilesItemActions()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var palette: WordMenuPalette { WordMenuPalette.forTheme(Theme.theme(for: profile)) }

    // MARK: - Status line

    /// "Saved" only while a file holds exactly the text on screen; "Unsaved changes" in the
    /// moment between a keystroke and its autosave (or after a failed save); and the Mac's "Not
    /// saved yet" for text no file holds. Every iPhone write is an autosave, so the Mac's
    /// "Autosaved" would tell the writer nothing more.
    static func saveStateText(hasFile: Bool, text: String, lastSyncedText: String) -> String {
        guard hasFile else { return notSavedYetText }
        return DocumentStatusText.saveState(isSaved: text == lastSyncedText, isAutosaved: false)
    }

    static func saveStateText(for document: OpenDocument) -> String {
        saveStateText(hasFile: document.url != nil, text: document.text, lastSyncedText: document.lastSyncedText)
    }

    /// Whether the save state is the green "Saved".
    static func isSaved(_ document: OpenDocument) -> Bool {
        document.url != nil && document.text == document.lastSyncedText
    }

    /// The Mac's label for an untitled document, with its translations.
    static var notSavedYetText: String { String(localized: "Not saved yet") }

    /// The document's name in the status line: its file name without the extension, or Untitled.
    static func documentTitle(for url: URL?) -> String {
        guard let url else { return String(localized: "Untitled") }
        return url.deletingPathExtension().lastPathComponent
    }

    /// "1,240 words", or characters for predominantly CJK text (whose word count would be a
    /// sentence count), as the Mac's counts are.
    static func countText(_ statistics: DocumentStatistics) -> String {
        if statistics.isPredominantlyCJK {
            return String(localized: "\(statistics.characterCount) characters")
        }
        return String(localized: "\(statistics.wordCount) words")
    }

    /// The status line as VoiceOver reads it: the name, the save state, then the counts in words.
    static func statusAccessibilityLabel(title: String, saveState: String, statistics: DocumentStatistics) -> String {
        let counts = DocumentStatusText.countsAccessibilityText(statistics)
        return String(localized: "\(title), \(saveState), \(counts)")
    }

    // MARK: - Body

    var body: some View {
        let palette = palette
        ZStack(alignment: .bottomTrailing) {
            palette.wash
                .ignoresSafeArea()
            Group {
                if let page = navigation.top {
                    pageView(page)
                        .id(page)
                } else {
                    wordList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WordMenuCornerButton(
                glyph: navigation.isOnWordList ? .close : .back,
                fill: palette.card,
                ink: palette.ink,
                isDark: palette.isDark,
                action: { back() }
            )
            .accessibilityIdentifier("wordMenu.corner")
            .padding(MarkdownEditor.chromeMargin)
        }
        .environment(\.wordMenuPalette, palette)
        .environment(\.colorScheme, palette.colorScheme)
        .foregroundStyle(palette.color(palette.ink))
        .tint(palette.color(palette.blueFill))
        // Nothing of the document behind the menu is reachable.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { back() }
        .background {
            // Esc on a hardware keyboard.
            Button(String(localized: "Back")) { back() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .filesItemAlerts(fileActions, store: files)
        .onChange(of: showsFiles, initial: true) { _, shows in
            files.openDocument = document
            files.setVisible(shows, for: .files)
        }
        .task(id: showsFiles) {
            if showsFiles { await files.scanIfVisible() }
        }
        .onDisappear { files.setVisible(false, for: .files) }
    }

    private var showsFiles: Bool { navigation.top?.showsFiles == true }

    /// ← inside a page, ✕ on the word list.
    private func back() {
        if !navigation.back() { onClose() }
    }

    private func open(_ page: WordMenuPage) {
        navigation.push(page)
    }

    // MARK: - Word list

    private var wordList: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusLine
                        .padding(.top, WordMenuMetrics.headerTop)
                    Spacer(minLength: 24)
                    words
                        .padding(.bottom, WordMenuMetrics.cornerButtonDiameter + MarkdownEditor.chromeMargin + 24)
                }
                .padding(.horizontal, WordMenuMetrics.wordInset)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var statusLine: some View {
        let title = Self.documentTitle(for: document.url)
        let saveState = Self.saveStateText(for: document)
        let statistics = DocumentStatistics(text: document.text)
        var line = AttributedString(title + " · ")
        line.foregroundColor = palette.color(palette.secondary)
        var state = AttributedString(saveState)
        state.foregroundColor = Self.isSaved(document) ? palette.color(palette.saved) : palette.color(palette.secondary)
        var counts = AttributedString(" · " + Self.countText(statistics))
        counts.foregroundColor = palette.color(palette.secondary)
        line += state
        line += counts
        return Text(line)
            .font(.subheadline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.statusAccessibilityLabel(title: title, saveState: saveState, statistics: statistics)))
            .accessibilityIdentifier("wordMenu.status")
    }

    private var words: some View {
        let items = WordMenuItem.visible(hasHistory: document.history?.hasHistory == true)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(items.filter { $0.style != .small }) { item in
                WordMenuWordButton(item: item) { choose(item) }
            }
            Color.clear.frame(height: 14)
            ForEach(items.filter { $0.style == .small }) { item in
                WordMenuWordButton(item: item) { choose(item) }
            }
        }
    }

    private func choose(_ item: WordMenuItem) {
        switch item.destination {
        case .page(let page): open(page)
        case .themesSheet: onThemes()
        case .readAloud: onReadAloud()
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageView(_ page: WordMenuPage) -> some View {
        switch page {
        case .files:
            FilesSection(
                store: files, document: document, editor: editor, actions: fileActions,
                onOpenFolder: { route in open(.folder(route)) }, onDismiss: onClose
            )
        case .folder(let route):
            FolderView(
                store: files, document: document, route: route, actions: fileActions,
                onOpenFolder: { route in open(.folder(route)) }, onDismiss: onClose
            )
        case .outline:
            OutlineSection(text: document.text, editor: editor, onDismiss: onClose)
        case .basics:
            BasicsSection()
        case .settings:
            SettingsSection(settings: settings, files: files, editor: editor, onDismiss: onClose)
        case .exportPrint:
            ExportPrintSection(document: document, exportCommands: exportCommands, onDismiss: onClose)
        case .history:
            HistorySection(history: document.history, text: editor.currentText) { id in
                onShowHistoryPassage(id)
            }
        case .connectAI:
            ConnectAISection(
                store: aiStore ?? .shared,
                mode: mode,
                hasText: ExportPrintSection.hasText(document.text),
                onAskAI: onAskAI
            )
        case .about:
            AboutSection(updateCommand: updateCommand)
        }
    }
}

/// One word in the list: large (34 pt), large and grey, or small (19 pt, a 44 pt target). Dynamic
/// Type scales them.
struct WordMenuWordButton: View {
    var item: WordMenuItem
    var action: () -> Void

    @Environment(\.wordMenuPalette) private var palette
    @ScaledMetric(relativeTo: .largeTitle) private var largeSize = WordMenuMetrics.largeWordSize
    @ScaledMetric(relativeTo: .title3) private var smallSize = WordMenuMetrics.smallWordSize

    var body: some View {
        let isSmall = item.style == .small
        Button(action: action) {
            Text(item.title)
                .font(.system(size: isSmall ? smallSize : largeSize))
                .tracking(isSmall ? 0 : -0.68)
                .foregroundStyle(palette.color(ink))
                .multilineTextAlignment(.leading)
                .padding(.vertical, isSmall ? 6 : 3)
                .frame(minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityHint(item.accessibilityHint.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityIdentifier("wordMenu.\(item.rawValue)")
    }

    private var ink: UIColor {
        switch item.style {
        case .large: palette.ink
        case .largeGrey: palette.largeGrey
        case .small: palette.secondary
        }
    }
}
