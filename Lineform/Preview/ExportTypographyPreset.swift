import AppKit

/// The body font faces an export preset may pin. System/bundled only — no new fonts.
enum ExportFontFace: String, Equatable, CaseIterable {
    case system        // San Francisco
    case serif         // New York (system serif)
    case atkinson      // Atkinson Hyperlegible (bundled)
    case openDyslexic  // OpenDyslexic (bundled)

    var fontID: FontID {
        switch self {
        case .system: return .sfPro
        case .serif: return .newYork
        case .atkinson: return .atkinsonHyperlegible
        case .openDyslexic: return .openDyslexic
        }
    }
}

/// A curated typographic style for PDF export / Print. Typography + layout ONLY; the page always
/// stays light with dark ink (`exportReadingProfile` pins `.system` + no high contrast, exactly
/// like the fixed export profile it replaces). `Standard` leaves `bodyFace`/`lineHeightMultiple`
/// nil so it inherits the user's reading profile and is a provable no-op.
struct ExportTypographyPreset: Identifiable {
    let id: String
    let displayName: String
    /// nil = inherit the user's reading-profile font face.
    let bodyFace: ExportFontFace?
    let bodyPointSize: CGFloat
    /// nil = inherit the line height of the profile this preset builds from.
    let lineHeightMultiple: CGFloat?
    /// Multiplier on the per-level heading size boost over body (1.0 = unchanged).
    let headingScale: CGFloat
    let pageMargins: NSEdgeInsets
    /// When false ("Normal"), the export ignores the user's reading profile entirely and builds from
    /// the neutral `.original` defaults. When true ("Styled"), it starts from the user's SELECTED
    /// reading profile so their font + line height carry through.
    let inheritsUserProfile: Bool
    /// When false ("Normal"), the export prints the RAW markdown SOURCE text (visible `#`, `**`, etc.)
    /// in a monospaced document face — a plain-markdown printout. When true ("Styled"), it renders the
    /// document the way Read mode does.
    let rendersMarkdown: Bool

    /// Plain document PDF ("Normal"): the system font, a small document body, and a document-tight
    /// line height so a normal amount of text fits per page. Ignores the user's reading style — this
    /// is the neutral default look.
    static let standard = ExportTypographyPreset(
        id: "standard",
        displayName: "Normal",
        bodyFace: .system,
        bodyPointSize: 10,
        lineHeightMultiple: 1.2,
        headingScale: 1.0,
        pageMargins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72),
        inheritsUserProfile: false,
        rendersMarkdown: false
    )

    /// Styled PDF: renders using the user's SELECTED reading style profile — their font face and
    /// line height (`nil` = inherit) — but at the same small document body size so it still fits a
    /// normal amount of text per page. The page always stays light with dark ink.
    static let styled = ExportTypographyPreset(
        id: "styled",
        displayName: "Styled",
        bodyFace: nil,
        bodyPointSize: 10,
        lineHeightMultiple: nil,
        headingScale: 1.0,
        pageMargins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72),
        inheritsUserProfile: true,
        rendersMarkdown: true
    )

    static let all: [ExportTypographyPreset] = [standard, styled]

    /// Resolve a persisted id to a preset; unknown/absent → `.standard`.
    static func preset(withID id: String?) -> ExportTypographyPreset {
        guard let id, let match = all.first(where: { $0.id == id }) else { return standard }
        return match
    }

    /// Build the export ReadingProfile: start from the user's profile, pin the light `.system`
    /// theme + no high contrast + the preset body size, and override face/line-height only when
    /// the preset declares them. `headingScale` and `pageMargins` are NOT ReadingProfile fields;
    /// they are threaded separately (renderer heading scale + DocumentExportRenderer margins).
    func exportReadingProfile(basedOn base: ReadingProfile) -> ReadingProfile {
        // "Normal" ignores the user's reading profile completely and renders plain markdown from the
        // neutral defaults; "Styled" carries the user's SELECTED profile through.
        var copy = inheritsUserProfile ? base : .original
        copy.themeID = .system
        copy.highContrastEnabled = false
        copy.fontSize = Double(bodyPointSize)
        if let bodyFace {
            copy.fontID = bodyFace.fontID
        }
        if let lineHeightMultiple {
            copy.lineHeightMultiple = Double(lineHeightMultiple)
        }
        return copy
    }
}
