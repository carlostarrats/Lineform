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
    /// nil = inherit the user's reading-profile font face (Standard).
    let bodyFace: ExportFontFace?
    let bodyPointSize: CGFloat
    /// nil = inherit the user's reading-profile line height (Standard).
    let lineHeightMultiple: CGFloat?
    /// Multiplier on the per-level heading size boost over body (1.0 = unchanged).
    let headingScale: CGFloat
    let pageMargins: NSEdgeInsets

    static let standard = ExportTypographyPreset(
        id: "standard",
        displayName: "Standard",
        bodyFace: nil,
        bodyPointSize: 12,
        lineHeightMultiple: nil,
        headingScale: 1.0,
        pageMargins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    )

    static let manuscript = ExportTypographyPreset(
        id: "manuscript",
        displayName: "Manuscript",
        bodyFace: .serif,
        bodyPointSize: 12,
        lineHeightMultiple: 2.0,
        headingScale: 1.0,
        pageMargins: NSEdgeInsets(top: 90, left: 90, bottom: 90, right: 90)
    )

    static let compact = ExportTypographyPreset(
        id: "compact",
        displayName: "Compact",
        bodyFace: .system,
        bodyPointSize: 10,
        lineHeightMultiple: 1.2,
        headingScale: 0.85,
        pageMargins: NSEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)
    )

    static let article = ExportTypographyPreset(
        id: "article",
        displayName: "Article",
        bodyFace: .serif,
        bodyPointSize: 12,
        lineHeightMultiple: 1.5,
        headingScale: 1.25,
        pageMargins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    )

    static let all: [ExportTypographyPreset] = [standard, manuscript, compact, article]

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
        var copy = base
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
