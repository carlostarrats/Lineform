import Foundation

/// The formats the iPhone exports, in the approved mockup's order (`word-menu.html`, Export &
/// Print): PDF, HTML and Markdown. PDF is the Mac's Normal PDF on the session's paper (the
/// region's everyday sheet, `ExportCommands.paper`); Markdown is the document's own text, as is.
/// The Mac's Styled PDF and Rich Text stay on the Mac.
enum PhoneExportFormat: String, CaseIterable {
    case pdf
    case html
    case markdown

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .html: return "html"
        case .markdown: return "md"
        }
    }

    /// The row's title on Export & Print.
    var title: String {
        switch self {
        case .pdf: return String(localized: "Export PDF\u{2026}")
        case .html: return String(localized: "Export HTML\u{2026}")
        case .markdown: return String(localized: "Export Markdown\u{2026}")
        }
    }

    /// Whether the export lays out pages, so a paper size applies.
    var usesPaper: Bool { self == .pdf }
}
