import Foundation

/// The words of the word menu, in the order the list shows them: three large words, two large grey
/// words (things you set rather than places you go), then the small words. The raw value is
/// identity, never localized.
enum WordMenuItem: String, CaseIterable, Identifiable {
    case files
    case outline
    case basics
    case themes
    case settings
    case exportPrint
    case readAloud
    /// Only while the document has history (`visible(hasHistory:)`).
    case history
    case connectAI
    case about

    enum Style: Equatable {
        case large
        case largeGrey
        case small
    }

    /// What tapping the word does.
    enum Destination: Equatable {
        /// A section page inside the menu.
        case page(WordMenuPage)
        /// The menu closes and the Styling sheet opens.
        case themesSheet
        /// The menu closes and reading aloud starts (its pill shows on the page).
        case readAloud
    }

    var id: Self { self }

    static func visible(hasHistory: Bool) -> [WordMenuItem] {
        allCases.filter { $0 != .history || hasHistory }
    }

    var style: Style {
        switch self {
        case .files, .outline, .basics: .large
        case .themes, .settings: .largeGrey
        case .exportPrint, .readAloud, .history, .connectAI, .about: .small
        }
    }

    var destination: Destination {
        switch self {
        case .files: .page(.files)
        case .outline: .page(.outline)
        case .basics: .page(.basics)
        case .themes: .themesSheet
        case .settings: .page(.settings)
        case .exportPrint: .page(.exportPrint)
        case .readAloud: .readAloud
        case .history: .page(.history)
        case .connectAI: .page(.connectAI)
        case .about: .page(.about)
        }
    }

    /// Display name. The Mac's strings and translations where the English matches.
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .outline: String(localized: "Outline")
        case .basics: String(localized: "Markdown Basics")
        case .themes: String(localized: "Themes")
        case .settings: String(localized: "Settings")
        case .exportPrint: String(localized: "Export & Print")
        case .readAloud: String(localized: "Read Aloud")
        case .history: String(localized: "History")
        case .connectAI: String(localized: "Connect Your AI")
        case .about: String(localized: "About Lineform")
        }
    }

    /// What VoiceOver adds for a word that leaves the menu instead of opening a page.
    var accessibilityHint: String? {
        switch destination {
        case .page: nil
        case .themesSheet: String(localized: "Closes the menu and opens the reading themes.")
        case .readAloud: String(localized: "Closes the menu and reads the document aloud.")
        }
    }
}

/// A page inside the word menu. The corner button goes back one page at a time (folder → Files →
/// words).
enum WordMenuPage: Hashable {
    case files
    case folder(FilesFolderRoute)
    case outline
    case basics
    case settings
    case exportPrint
    case history
    case connectAI
    case about

    var title: String {
        switch self {
        case .files: WordMenuItem.files.title
        case .folder(let route): route.title
        case .outline: WordMenuItem.outline.title
        case .basics: WordMenuItem.basics.title
        case .settings: WordMenuItem.settings.title
        case .exportPrint: WordMenuItem.exportPrint.title
        case .history: WordMenuItem.history.title
        case .connectAI: WordMenuItem.connectAI.title
        case .about: WordMenuItem.about.title
        }
    }

    /// Files and its folders keep the Files store visible (scanning and watching).
    var showsFiles: Bool {
        switch self {
        case .files, .folder: true
        default: false
        }
    }
}

/// The word menu's navigation: a stack of pages over the word list. Every move is instant.
struct WordMenuNavigation: Equatable {
    private(set) var stack: [WordMenuPage] = []

    var top: WordMenuPage? { stack.last }
    var isOnWordList: Bool { stack.isEmpty }

    mutating func push(_ page: WordMenuPage) { stack.append(page) }

    /// Back one page. False on the word list (the corner button closes the menu there).
    @discardableResult
    mutating func back() -> Bool {
        guard !stack.isEmpty else { return false }
        stack.removeLast()
        return true
    }
}
