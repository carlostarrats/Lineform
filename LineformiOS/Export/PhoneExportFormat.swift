import Foundation

/// The formats the iPhone exports, the Mac's File ▸ Export As list in its order: HTML, Normal PDF,
/// Styled PDF and Rich Text. Titles are the Mac's menu strings (and translations).
enum PhoneExportFormat: String, CaseIterable {
    case html
    case pdf
    case styledPDF
    case rtf

    var fileExtension: String {
        switch self {
        case .html: return "html"
        case .pdf, .styledPDF: return "pdf"
        case .rtf: return "rtf"
        }
    }

    var title: String {
        switch self {
        case .html: return String(localized: "HTML")
        case .pdf: return String(localized: "PDF")
        case .styledPDF: return String(localized: "Styled PDF")
        case .rtf: return String(localized: "Rich Text (.rtf)")
        }
    }

    /// Whether the export lays out pages, so a paper size applies.
    var usesPaper: Bool {
        switch self {
        case .pdf, .styledPDF: return true
        case .html, .rtf: return false
        }
    }
}
