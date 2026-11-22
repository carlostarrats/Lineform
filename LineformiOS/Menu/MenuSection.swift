import Foundation

/// The Menu sheet's sections, in the order the section bar shows them. The raw value is the
/// identity `@SceneStorage("menuSection")` keeps: never localized, never renamed.
enum MenuSection: String, CaseIterable, Identifiable {
    case files
    case outline
    case basics
    case search
    case document
    case settings

    /// The section a scene with nothing stored opens on.
    static let defaultSection: MenuSection = .files

    var id: Self { self }

    /// Display name. The Mac's strings and translations where the English matches.
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .outline: String(localized: "Outline")
        case .basics: String(localized: "Markdown Basics")
        case .search: String(localized: "Search")
        case .document: String(localized: "Document")
        case .settings: String(localized: "Settings")
        }
    }

    /// The Mac sidebar's symbols where the section exists there.
    var systemImage: String {
        switch self {
        case .files: "folder"
        case .outline: "list.bullet"
        case .basics: "curlybraces"
        case .search: "magnifyingglass"
        case .document: "doc.text"
        case .settings: "gearshape"
        }
    }
}
