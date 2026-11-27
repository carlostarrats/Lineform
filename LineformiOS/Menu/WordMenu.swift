import os
import QuartzCore
import LineformCore
import SwiftUI
import UIKit

/// The word menu: the iPhone's one place for files, the outline, Markdown Basics, themes,
/// settings, export, read aloud, history, the AI connection and About, on the Mac Settings
/// window's wash (never the page's colour).
///
/// It is a slide-over (owner, 2026-11-26, `Lineform-mobile/docs/mockups/popover-and-split.html`):
/// the ⋯ button shrinks the page card to 90 % and moves it right until an 84 pt strip shows, and
/// the words are behind it (`Layer.words`). The word list sits low, where the thumb is: Files,
/// Outline and Markdown Basics large; Themes and Settings large and grey; the small words below.
/// A status line at the top names the document, its save state ("Saved" in the Mac's green) and
/// its words. Tapping a word opens its section INSIDE the card, which slides back over the words
/// ("Page becomes it", `Layer.pages`); the ← at the bottom left goes back (folder → Files → the
/// words, the card sliding out again) and the round page button at the bottom right goes straight
/// back to the document. Themes, Read Aloud and History slide the card back first, then act.
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
    /// Where the writer is (the screen's, so the menu can be reopened there); nil: the menu's own.
    var session: WordMenuSession? = nil
    /// Which half of the slide-over this view draws (both read the same session).
    var layer: Layer = .pages
    /// A word opened its page: the screen slides the card back over the words, showing it.
    var onPageOpened: () -> Void = {}
    /// ← left the first page: the screen slides the card out to the words again.
    var onBackToWords: () -> Void = {}

    /// The menu is a slide-over (owner, 2026-11-26): the page card shrinks and moves right to
    /// show the words behind it, and a section opens INSIDE the card, which slides back.
    enum Layer {
        /// The wash and the word list, behind the card.
        case words
        /// The section on top of the session's page stack, inside the card (nothing on the words).
        case pages
    }

    @State private var ownSession = WordMenuSession()
    private var currentSession: WordMenuSession { session ?? ownSession }
    private var navigation: WordMenuNavigation {
        get { currentSession.navigation }
        nonmutating set { currentSession.navigation = newValue }
    }
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
    /// How far the on-screen keyboard reaches above the home indicator's band: the corner buttons
    /// ride above it, always visible (owner review 5: they vanished while a search field was in
    /// use, leaving no way back).
    @State private var keyboardLift: CGFloat = 0

    var body: some View {
        switch layer {
        case .words: wordsLayer
        case .pages: pagesLayer
        }
    }

    /// The words, behind the page card: the wash, the status line and the word list. No corner
    /// button: the page strip on the right (the screen's) closes the menu.
    private var wordsLayer: some View {
        let palette = palette
        return ZStack {
            palette.wash
                .ignoresSafeArea()
            // The word list has no field of its own: opened while the page's keyboard is still
            // going down, it must not be laid out short and then jump (owner review 6).
            wordList
                .ignoresSafeArea(.keyboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            topWashBand(palette)
        }
        .modifier(WordMenuLayerChrome(palette: palette, session: currentSession))
        .accessibilityAction(.escape) { onClose() }
        .background {
            // Esc on a hardware keyboard closes the menu from the words.
            Button(String(localized: "Close menu")) { onClose() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .task { await WordMenuWarmUp.run() }
    }

    /// A section, inside the page card ("Page becomes it", owner, 2026-11-26): the ← at the
    /// bottom left goes back (folder → Files → the words, where the card slides out again), and
    /// the round page button at the bottom right goes straight back to the document.
    private var pagesLayer: some View {
        let palette = palette
        return ZStack(alignment: .bottomTrailing) {
            palette.wash
                .ignoresSafeArea()
            Group {
                if let page = navigation.top {
                    pageView(page)
                        .environment(\.wordMenuPageDepth, navigation.stack.count)
                        .id(page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            topWashBand(palette)
            // The ← sits alone at the bottom left; the page button never moves (owner review 4,
            // and 2026-11-26: the ← stays where it was).
            WordMenuCornerButton(
                glyph: .back,
                ink: palette.ink,
                isDark: palette.isDark,
                action: { back() }
            )
            .accessibilityIdentifier("wordMenu.corner")
            .padding(MarkdownEditor.chromeMargin)
            .padding(.bottom, keyboardLift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            // The lift is measured here; SwiftUI's own keyboard avoidance would add it twice
            // (owner review 6: the buttons sat far up under the search bar).
            .ignoresSafeArea(.keyboard)
            WordMenuCornerButton(
                glyph: .document,
                ink: palette.ink,
                isDark: palette.isDark,
                action: { onClose() }
            )
            .accessibilityIdentifier("wordMenu.document")
            .padding(MarkdownEditor.chromeMargin)
            .padding(.bottom, keyboardLift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea(.keyboard)
        }
        .transaction { $0.animation = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            keyboardLift = Self.keyboardLift(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardLift = 0
        }
        .modifier(WordMenuLayerChrome(palette: palette, session: currentSession))
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

    /// Rows scrolling up pass under the status bar and Dynamic Island: the wash's top colour
    /// covers that band and fades out just below it, as iOS's own scroll edges do. The band is
    /// the wash itself (the same full-screen frame as the one behind), shown through a mask: a
    /// solid band colour would not match the wash's diagonals.
    private func topWashBand(_ palette: WordMenuPalette) -> some View {
        GeometryReader { geometry in
            palette.wash
                .ignoresSafeArea()
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Rectangle()
                            .frame(height: geometry.safeAreaInsets.top)
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(edges: .top)
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The keyboard's height above the bottom safe area, from a frame notification (0 when it is
    /// off screen or only a hardware keyboard's short bar).
    static func keyboardLift(from note: Notification) -> CGFloat {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow)
        else { return 0 }
        let overlap = max(0, window.bounds.maxY - window.convert(frame, from: window.screen.coordinateSpace).minY)
        return max(0, overlap - window.safeAreaInsets.bottom)
    }

    private var showsFiles: Bool { navigation.top?.showsFiles == true }

    /// ← inside a page: back one page; from the first page, back to the words (the screen
    /// slides the card out again).
    private func back() {
        if !navigation.back() { return onClose() }
        // The page left is gone: a page opened at its depth later starts at the top.
        let depth = navigation.stack.count
        currentSession.scrollOffsets = currentSession.scrollOffsets.filter { $0.key <= depth }
        if navigation.isOnWordList { onBackToWords() }
    }

    private func open(_ page: WordMenuPage) {
        WordMenuTiming.begin(.openPage)
        let fromWords = navigation.isOnWordList
        navigation.push(page)
        if fromWords { onPageOpened() }
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
    @ViewBuilder
    private var statusLine: some View {
        if Self.showsTitleOnly(hasFile: document.url != nil, text: document.text) {
            // An empty page with no file: just "Untitled" (no "Not saved yet · 0 words").
            Text(Self.documentTitle(for: nil))
                .font(.subheadline)
                .foregroundStyle(palette.color(palette.secondary))
                .accessibilityIdentifier("wordMenu.status")
        } else {
            fullStatusLine
        }
    }

    /// The status line is the name alone: the page is empty (nothing but white space) and has no
    /// file. Stops at the first non-space character, so it never walks a long document.
    static func showsTitleOnly(hasFile: Bool, text: String) -> Bool {
        !hasFile && !text.contains { !$0.isWhitespace }
    }

    private var fullStatusLine: some View {
        _ = countsGeneration
        let title = Self.documentTitle(for: document.url)
        let saveState = Self.saveStateText(for: document)
        let text = document.text
        let statistics = WordMenuStatusCounts.cached(for: text)
        // The name is plain text here: Rename… lives on the page itself (`DocumentNameTag`,
        // owner review 4: the menu's tappable name was not discoverable).
        var line = AttributedString(title)
        line.foregroundColor = palette.color(palette.secondary)
        var separator = AttributedString(" · ")
        separator.foregroundColor = palette.color(palette.secondary)
        line += separator
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
        let lineText = Text(line)
            .font(.subheadline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .multilineTextAlignment(.leading)
        return lineText
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        // Plain text, not a control: a grouped element has no trait of its own, and the audit
        // then measured it as a (too small) tap target.
        .accessibilityAddTraits(.isStaticText)
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
                session: currentSession,
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
            ExportPrintSection(document: document, files: files, exportCommands: exportCommands, onDismiss: onClose)
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

    /// How far a small word's target reaches past its drawn 40 pt row, above and below.
    static let smallTargetReach = (WordMenuMetrics.minimumTarget - WordMenuMetrics.smallWordRowHeight) / 2

    var body: some View {
        let isSmall = item.style == .small
        Button(action: action) {
            Text(item.title)
                .font(.system(size: isSmall ? smallSize : largeSize))
                .tracking(isSmall ? 0 : -0.68)
                .foregroundStyle(palette.color(ink))
                .multilineTextAlignment(.leading)
                .padding(.vertical, isSmall ? 8 : 3)
                // A small word's row is drawn 40 pt (§19); its target still reaches 44 pt, the
                // extra 2 pt above and below taken back so the rows keep the mockup's pitch.
                .frame(minHeight: isSmall ? WordMenuMetrics.smallWordRowHeight : WordMenuMetrics.minimumTarget, alignment: .leading)
                .padding(.vertical, isSmall ? Self.smallTargetReach : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(WordMenuPressStyle())
        .padding(.vertical, isSmall ? -Self.smallTargetReach : 0)
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

    // MARK: - The other menu moves

    /// What else is measured, each from the tap (or keystroke) to the frame that shows its result.
    enum Step: String {
        case openPage = "Open menu page"
        case search = "Files search results"
        case scope = "Switch search scope"
        case openCard = "Open document from card"
        case themes = "Open Themes"
    }

    private static var steps: [Step: (start: CFTimeInterval, interval: OSSignpostIntervalState)] = [:]

    /// `step` begins now (a later begin restarts it: the latest keystroke wins).
    static func begin(_ step: Step) {
        if let running = steps[step] { signposter.endInterval("menuStep", running.interval) }
        steps[step] = (CACurrentMediaTime(), signposter.beginInterval("menuStep", "\(step.rawValue)"))
    }

    /// `step`'s result is in this update: the interval ends on the main queue's next turn, after
    /// this update's frame is committed (not after any animation it starts, such as a sheet's
    /// slide, which runs off the main thread).
    static func end(_ step: Step) {
        guard steps[step] != nil else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let running = steps.removeValue(forKey: step) else { return }
                let milliseconds = (CACurrentMediaTime() - running.start) * 1000
                signposter.endInterval("menuStep", running.interval)
                logger.log("\(step.rawValue, privacy: .public): \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
            }
        }
    }
}

/// While the menu is open, the fonts the Themes sheet draws with (its preset cards and its font
/// list) are loaded once off the main thread, so the sheet's first open does not pay for them.
@MainActor
enum WordMenuWarmUp {
    private static var hasRun = false

    static func run() async {
        guard !hasRun else { return }
        hasRun = true
        await Task.detached(priority: .utility) {
            _ = FontOption.availableGroupedOptions
            for name in ["AtkinsonHyperlegible-Regular", "OpenDyslexic-Regular"] {
                _ = UIFont(name: name, size: 17)
            }
        }.value
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

/// What both halves of the slide-over share: the palette's inks and scheme, the session in the
/// environment, and VoiceOver modality (nothing of the document behind is reachable).
private struct WordMenuLayerChrome: ViewModifier {
    var palette: WordMenuPalette
    var session: WordMenuSession

    func body(content: Content) -> some View {
        content
            // iOS 26's soft scroll edge shaded the band behind the time and battery darker than
            // the wash; the masked wash band already covers rows passing under it (owner review 6).
            .scrollEdgeEffectHidden(true, for: .top)
            .environment(\.wordMenuPalette, palette)
            .environment(\.wordMenuSession, session)
            .environment(\.colorScheme, palette.colorScheme)
            .foregroundStyle(palette.color(palette.ink))
            .tint(palette.color(palette.blueFill))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

// MARK: - The slide-over

/// The slide-over's numbers (owner, 2026-11-26, from the mockup at ×3 speed).
enum MenuSlideOverMotion {
    /// How much of the page card shows at the right while the words are out.
    static let strip: CGFloat = 84
    /// The card's size while the words are out.
    static let scale: CGFloat = 0.9
    /// The card's corner radius while the words are out (as drawn, after the scale).
    static let cornerRadius: CGFloat = 40
    /// How far the words slide in from as the card moves.
    static let wordsTravel: CGFloat = 36

    /// The ⋯ open (the mockup's stiffness 320 × 3: about 0.2 s).
    static func open(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 2 * .pi / (960).squareRoot(), dampingFraction: 0.81)
    }

    /// Every other move: a section sliding back, the card sliding out again, closing (the
    /// mockup's 600 × 3: about 0.15 s). Themes, Files, Outline and the rest all move alike.
    static func move(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 2 * .pi / (1800).squareRoot(), dampingFraction: 0.81)
    }

    /// The card's scale at `reveal` (0: the page fills the screen; 1: the strip shows).
    static func cardScale(_ reveal: CGFloat) -> CGFloat {
        1 - (1 - scale) * min(max(reveal, 0), 1)
    }

    /// How far right the card's left edge sits at `reveal` in a screen `width` wide.
    static func cardOffset(_ reveal: CGFloat, width: CGFloat) -> CGFloat {
        max(reveal, -0.05) * (width - strip)
    }

    /// The words' opacity: they come in once the card is a little way out.
    static func wordsOpacity(_ reveal: CGFloat) -> CGFloat {
        min(max((reveal - 0.15) / 0.6, 0), 1)
    }

    /// The light bump at an open and at a section's choice (like X's).
    @MainActor
    static func bump() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// The document screen as the slide-over's card: `words` lies behind it, `page` (a section)
/// shows inside it. `reveal` 0 is the page full screen; 1 is the card at the strip. The card's
/// own content keeps its identity throughout (the editor is never rebuilt). While the words are
/// out, the strip is one button, Close menu, and dragging it left closes too.
struct MenuSlideOver<Words: View, Page: View>: ViewModifier, @preconcurrency Animatable {
    var reveal: CGFloat
    var isActive: Bool
    var showsPage: Bool
    var cardColor: Color
    /// What shows round the card's corners: the words' wash (the card is never clipped — a clip
    /// moves the editor's text up under the mode switch — so its corners are covered instead).
    var cornerFill: AnyView
    var words: Words
    var page: Page
    var onStripTap: () -> Void
    /// A drag on the strip: the reveal it moves the card to.
    var onStripDrag: (CGFloat) -> Void
    /// The drag ended: the reveal it would coast to.
    var onStripDragEnd: (CGFloat) -> Void

    @State private var width: CGFloat = 402
    /// The card's frame stops at the safe area while the page colour runs under the status bar
    /// and home indicator: the clip reaches out by these.
    @State private var outsets = EdgeInsets()
    @State private var height: CGFloat = 874

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func body(content: Content) -> some View {
        let k = min(max(reveal, 0), 1)
        let scale = MenuSlideOverMotion.cardScale(reveal)
        let offset = MenuSlideOverMotion.cardOffset(reveal, width: width)
        let radius = MenuSlideOverMotion.cornerRadius * k / scale
        let out = isActive && reveal > 0.001
        let travel = max(1, width - MenuSlideOverMotion.strip)
        let shape = CardShape(cornerRadius: radius, outsets: outsets)
        // The card on screen: scaled about its frame's leading centre, then moved right.
        let centreY = outsets.top + (height - outsets.top - outsets.bottom) / 2
        let cardRect = CGRect(x: offset, y: centreY * (1 - scale), width: width * scale, height: height * scale)
        content
            .accessibilityHidden(isActive)
            // While the menu is up the page takes no touches: a tap on the words during the open
            // reached the editor under them (it is hit-tested at its final frame, not the drawn one)
            // and raised the keyboard over the menu.
            .allowsHitTesting(!isActive)
            .overlay {
                if isActive && showsPage {
                    page.transition(.opacity)
                }
            }
            .overlay {
                if out {
                    Button(action: onStripTap) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { onStripDrag(1 + $0.translation.width / travel) }
                            .onEnded { onStripDragEnd(1 + $0.predictedEndTranslation.width / travel) }
                    )
                    .accessibilityLabel(WordMenuCornerButton.Glyph.close.accessibilityLabel)
                    .accessibilityIdentifier("wordMenu.corner")
                    .ignoresSafeArea()
                }
            }
            .scaleEffect(scale, anchor: .leading)
            .offset(x: offset)
            .overlay {
                if out {
                    // The wash, plus the card's own shadow redrawn over it: the cover hides the
                    // shadow cast behind the corners, which otherwise shows as a light square.
                    ZStack {
                        cornerFill
                        Path(roundedRect: cardRect, cornerRadius: MenuSlideOverMotion.cornerRadius * k, style: .continuous)
                            .fill(cardColor)
                            .shadow(color: .black.opacity(0.18 * k), radius: 20 * k * scale)
                    }
                        .mask { CornerFillets(rect: cardRect, radius: MenuSlideOverMotion.cornerRadius * k).fill(style: FillStyle(eoFill: true)) }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width + $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: { width = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { height = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { outsets = $0 }
            .background {
                if out {
                    shape
                        .fill(cardColor)
                        .shadow(color: .black.opacity(0.18 * k), radius: 20 * k)
                        .scaleEffect(scale, anchor: .leading)
                        .offset(x: offset)
                        .accessibilityHidden(true)
                }
            }
            .background {
                if isActive {
                    words
                        .offset(x: -MenuSlideOverMotion.wordsTravel * (1 - k))
                        .opacity(showsPage && k < 0.001 ? 0 : MenuSlideOverMotion.wordsOpacity(reveal))
                        .allowsHitTesting(out && !showsPage)
                        .accessibilityHidden(showsPage && !out)
                }
            }
    }
}

/// The page card's outline: a rounded rectangle reaching `outsets` past the frame it is laid out
/// in (the page colour runs under the status bar and home indicator).
private struct CardShape: Shape {
    var cornerRadius: CGFloat
    var outsets: EdgeInsets

    func path(in rect: CGRect) -> Path {
        let full = CGRect(
            x: rect.minX - outsets.leading,
            y: rect.minY - outsets.top,
            width: rect.width + outsets.leading + outsets.trailing,
            height: rect.height + outsets.top + outsets.bottom
        )
        return Path(roundedRect: full, cornerRadius: cornerRadius, style: .continuous)
    }
}

/// The corners of `rect` outside its rounded version (fill with the even-odd rule): what covers a
/// card's corners instead of a clip.
struct CornerFillets: Shape {
    var rect: CGRect
    var radius: CGFloat
    var topRadius: CGFloat? = nil

    func path(in _: CGRect) -> Path {
        var path = Path(rect)
        let top = topRadius ?? radius
        path.addPath(Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: top, bottomLeading: radius, bottomTrailing: radius, topTrailing: top
        ), style: .continuous))
        return path
    }
}
