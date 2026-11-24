import os
import QuartzCore
import LineformCore
import SwiftUI
import UIKit

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
    /// A page to open on instead of the word list (tests); nil in the app.
    var initialPage: WordMenuPage? = nil
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
    /// Bumped when a background count lands, so the status line shows it.
    @State private var countsGeneration = 0
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

    /// The software keyboard is up (a search field is being typed in).
    @State private var isKeyboardUp = false

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
            // Rows scrolling up pass under the status bar and Dynamic Island: the wash's top colour
            // covers that band and fades out just below it, as iOS's own scroll edges do.
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(palette.color(palette.washTop))
                        .frame(height: geometry.safeAreaInsets.top)
                    LinearGradient(
                        colors: [palette.color(palette.washTop), palette.color(palette.washTop).opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 18)
                }
                .ignoresSafeArea(edges: .top)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            WordMenuCornerButton(
                glyph: navigation.isOnWordList ? .close : .back,
                fill: palette.card,
                ink: palette.ink,
                isDark: palette.isDark,
                action: { back() }
            )
            .accessibilityIdentifier("wordMenu.corner")
            .padding(MarkdownEditor.chromeMargin)
            // While typing in a search field the keyboard (and iOS's suggestion bar above it) would
            // half-cover the corner button: it steps aside until the keyboard goes; Esc still goes back.
            .opacity(isKeyboardUp ? 0 : 1)
            .allowsHitTesting(!isKeyboardUp)
            .accessibilityHidden(isKeyboardUp)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardUp = false
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
        .onAppear {
            if let initialPage, navigation.isOnWordList { navigation.push(initialPage) }
        }
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
        .onAppear { WordMenuTiming.wordListAppeared() }
    }

    /// The status line. The counts walk the whole text (about 70 ms for 1 MB in the simulator,
    /// several times that on a phone), so they are never counted while the menu opens: the last
    /// count for the same text is reused (`WordMenuStatusCounts`), and otherwise the line shows
    /// the name and save state at once and the counts follow from a background count.
    private var statusLine: some View {
        _ = countsGeneration
        let title = Self.documentTitle(for: document.url)
        let saveState = Self.saveStateText(for: document)
        let text = document.text
        let statistics = WordMenuStatusCounts.cached(for: text)
        var line = AttributedString(title + " · ")
        line.foregroundColor = palette.color(palette.secondary)
        var state = AttributedString(saveState)
        state.foregroundColor = Self.isSaved(document) ? palette.color(palette.saved) : palette.color(palette.secondary)
        line += state
        if let statistics {
            var counts = AttributedString(" · " + Self.countText(statistics))
            counts.foregroundColor = palette.color(palette.secondary)
            line += counts
        }
        let label = statistics.map { Self.statusAccessibilityLabel(title: title, saveState: saveState, statistics: $0) }
            ?? "\(title), \(saveState)"
        return Text(line)
            .font(.subheadline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityIdentifier("wordMenu.status")
            .task(id: statistics == nil) {
                guard statistics == nil else { return }
                await WordMenuStatusCounts.count(text)
                countsGeneration += 1
            }
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
            SettingsSection(settings: settings, files: files)
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

/// How long the word menu takes to open: from the ⋯ tap to the word list's first frame on screen.
/// A signpost interval ("Open word menu", visible in Instruments' Points of Interest) and one log
/// line with the milliseconds (`log stream --predicate 'category == "WordMenuTiming"'`). Costs a
/// clock read; nothing is kept.
@MainActor
enum WordMenuTiming {
    private static let logger = Logger(subsystem: "com.lineform.app", category: "WordMenuTiming")
    private static let signposter = OSSignposter(subsystem: "com.lineform.app", category: .pointsOfInterest)
    private static var start: CFTimeInterval?
    private static var interval: OSSignpostIntervalState?

    /// The ⋯ button was tapped.
    static func tapped() {
        start = CACurrentMediaTime()
        interval = signposter.beginInterval("Open word menu")
    }

    /// The word list appeared: the interval ends once this frame is committed to the screen.
    static func wordListAppeared() {
        guard start != nil else { return }
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { finish() }
        }
    }

    private static func finish() {
        guard let start, let interval else { return }
        let milliseconds = (CACurrentMediaTime() - start) * 1000
        signposter.endInterval("Open word menu", interval)
        logger.log("Word menu open: \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        self.start = nil
        self.interval = nil
    }
}

/// The status line's counts, kept for the last text counted: opening the menu again on the same
/// text costs one string comparison, never a walk of the text. Counted off the main thread.
@MainActor
enum WordMenuStatusCounts {
    private static var last: (text: String, statistics: DocumentStatistics)?

    /// The counts for `text` when they are already known.
    static func cached(for text: String) -> DocumentStatistics? {
        guard let last, last.text == text else { return nil }
        return last.statistics
    }

    /// Counts `text` in the background and keeps the result.
    static func count(_ text: String) async {
        let statistics = await Task.detached(priority: .userInitiated) { DocumentStatistics(text: text) }.value
        last = (text, statistics)
    }
}
