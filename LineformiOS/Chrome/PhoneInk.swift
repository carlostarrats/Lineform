import LineformCore
import SwiftUI
import UIKit

/// Every chrome ink on iPhone that is not the theme's own body ink, made readable on the surface
/// it is drawn on. Each one goes through `Theme.readableInk`: text reaches 4.5:1 (WCAG AA, and a
/// placeholder is text), non-text (icons, a control's edge) reaches 3:1. A bare `.opacity(x)` or
/// `.secondary` on text fails AA on most themes (theme ink at 0.6 is 4.23:1 on Paper and Calm),
/// which is the defect the Mac fixed with `readableInk`.
///
/// The ink is resolved for one appearance. The high-contrast theme's colours are dynamic
/// (`.label` / `.systemBackground`), so they resolve for `userInterfaceStyle`; the system colours
/// (blue, red, green, the Form's grouped backgrounds) resolve for the THEME's chrome darkness,
/// because every iPhone sheet forces its colour scheme from `theme.usesDarkChrome`.
///
/// `PhoneInkContrastTests` measures every entry of `allInks(for:userInterfaceStyle:)` against its
/// surface with `Theme.contrastRatio`, the app's one definition.
@MainActor
struct PhoneInk {
    /// A named ink. The raw value is the name the contrast test reports.
    enum Role: String, CaseIterable, Sendable {
        /// Secondary text on the page: notes, dates, counts, hints.
        case secondary
        /// Quieter text on the page, placeholders included. Still text, so still 4.5:1.
        case tertiary
        /// Non-text marks on the page: icons, chevrons, glyphs that carry meaning.
        case icon
        /// The visible edge of a control (a field's hairline, an unselected ring).
        case controlEdge
        /// A menu's chevron beside its title (the selection row, the comment field's Action):
        /// theme ink at 0.6, a non-text mark.
        case chevron
        /// System blue as a non-text mark on the page: the Preview link button while linked.
        case linkGlyph
        /// The History card's Add glyph (ink at 0.85) on its circle (ink at
        /// `historyAddWashAlpha`), while it can be used. Disabled, it is exempt.
        case historyAddGlyph
        /// The Read view's Copy and Reconnect pills: the glyph and the "Reconnect" label (text),
        /// on the pill's resting fill (`ReadOverlayButton.fillAlpha`). The pressed fill is only
        /// the moment of a tap; on Quiet even the full ink reaches 4.2:1 there.
        case onReadPill
        /// Placeholder text on the comment field's wash.
        case tertiaryOnCommentField
        /// Secondary text on the search field's wash (ink at `searchFieldWashAlpha`).
        case secondaryOnSearchField
        /// Placeholder text on the search field's wash.
        case tertiaryOnSearchField
        /// Secondary text in a Connect Your AI Form cell.
        case formSecondary
        /// Footer text on the Form's grouped background.
        case formFooter
        /// Error text in a Form cell.
        case formDestructive
        /// "Connected" text in a Form cell.
        case formSuccess

        /// 4.5:1 for text, 3:1 for non-text marks (WCAG 1.4.3 / 1.4.11).
        var minimumRatio: CGFloat {
            switch self {
            case .icon, .controlEdge, .chevron, .linkGlyph, .historyAddGlyph: Self.nonTextMinimum
            default: Self.textMinimum
            }
        }

        static let textMinimum: CGFloat = 4.5
        static let nonTextMinimum: CGFloat = 3
    }

    /// One measured pair for the contrast test.
    struct Entry {
        var name: String
        var color: UIColor
        var surface: UIColor
        var minimumRatio: CGFloat
    }

    /// The comment field's wash: theme ink at this alpha over the card.
    static let commentFieldWashAlpha: CGFloat = 0.06
    /// The search fields' wash: ink at this alpha over the sheet.
    static let searchFieldWashAlpha: CGFloat = 0.07
    /// The History card's Add circle: ink at this alpha over the card.
    static let historyAddWashAlpha: CGFloat = 0.10

    /// The theme with its colours resolved for one appearance.
    let theme: Theme
    /// The theme's chrome is dark (the sheets force `.dark`).
    let isDark: Bool

    /// - Parameters:
    ///   - theme: the display theme (`Theme.theme(for: displayProfile)`).
    ///   - userInterfaceStyle: the appearance the surface is drawn in, which resolves the
    ///     high-contrast theme's dynamic colours. Required: SwiftUI's `body` gives no guarantee
    ///     that `UITraitCollection.current` is the view's (or a sheet's forced) scheme, so a view
    ///     passes its `@Environment(\.colorScheme)` (`init(theme:colorScheme:)`) or the scheme it
    ///     forces, and a UIKit view its own `traitCollection`. `.unspecified` is read as light.
    init(theme: Theme, userInterfaceStyle: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: userInterfaceStyle == .dark ? .dark : .light)
        var resolved = theme
        resolved.textColor = theme.textColor.resolvedColor(with: traits)
        resolved.backgroundColor = theme.backgroundColor.resolvedColor(with: traits)
        resolved.caretColor = theme.caretColor.resolvedColor(with: traits)
        self.theme = resolved
        isDark = resolved.usesDarkChrome
    }

    /// The inks for a SwiftUI view drawn in `colorScheme` (its environment's).
    init(theme: Theme, colorScheme: ColorScheme) {
        self.init(theme: theme, userInterfaceStyle: colorScheme == .dark ? .dark : .light)
    }

    // MARK: - Surfaces

    /// The page, and every card and sheet drawn in the page colour.
    var page: UIColor { theme.backgroundColor }

    /// The comment field's wash flattened over the card.
    var commentFieldWash: UIColor { Self.flatten(theme.textColor, alpha: Self.commentFieldWashAlpha, over: page) }

    /// The search field's wash flattened over the sheet.
    var searchFieldWash: UIColor { Self.flatten(theme.textColor, alpha: Self.searchFieldWashAlpha, over: page) }

    /// The History card's Add circle flattened over the card.
    var historyAddWash: UIColor { Self.flatten(theme.textColor, alpha: Self.historyAddWashAlpha, over: page) }

    /// A Read pill's resting fill flattened over the page.
    var readPill: UIColor {
        Self.flatten(isDark ? .white : .black, alpha: ReadOverlayButton.fillAlpha(usesDarkChrome: isDark, pressed: false), over: page)
    }

    /// A Form cell (`secondarySystemGroupedBackground`) in the sheet's forced scheme.
    var formCell: UIColor { systemColor(.secondarySystemGroupedBackground) }

    /// The Form's grouped background (`systemGroupedBackground`), where section footers sit.
    var formBackground: UIColor { systemColor(.systemGroupedBackground) }

    /// The surface `role` is measured against.
    func surface(for role: Role) -> UIColor {
        switch role {
        case .secondary, .tertiary, .icon, .controlEdge, .chevron, .linkGlyph: page
        case .historyAddGlyph: historyAddWash
        case .onReadPill: readPill
        case .tertiaryOnCommentField: commentFieldWash
        case .secondaryOnSearchField, .tertiaryOnSearchField: searchFieldWash
        case .formSecondary, .formDestructive, .formSuccess: formCell
        case .formFooter: formBackground
        }
    }

    // MARK: - Inks

    /// The opaque, readable ink for `role`.
    func uiColor(_ role: Role) -> UIColor {
        let ink = theme.textColor
        let minimum = role.minimumRatio
        switch role {
        case .secondary:
            return theme.readableInk(ink.withAlphaComponent(0.6), minimumRatio: minimum)
        case .tertiary:
            return theme.readableInk(ink.withAlphaComponent(0.45), minimumRatio: minimum)
        case .icon:
            return theme.readableInk(ink.withAlphaComponent(0.45), minimumRatio: minimum)
        case .controlEdge:
            return theme.readableInk(ink.withAlphaComponent(0.3), minimumRatio: minimum)
        case .chevron:
            return theme.readableInk(ink.withAlphaComponent(0.6), minimumRatio: minimum)
        case .linkGlyph:
            return theme.readableInk(systemColor(.systemBlue), minimumRatio: minimum)
        case .historyAddGlyph:
            return theme.readableInk(ink.withAlphaComponent(0.85), minimumRatio: minimum, on: surface(for: role))
        case .onReadPill:
            return theme.readableInk(ink.withAlphaComponent(0.85), minimumRatio: minimum, on: surface(for: role))
        case .secondaryOnSearchField:
            return theme.readableInk(ink.withAlphaComponent(0.6), minimumRatio: minimum, on: surface(for: role))
        case .tertiaryOnCommentField, .tertiaryOnSearchField:
            return theme.readableInk(ink.withAlphaComponent(0.45), minimumRatio: minimum, on: surface(for: role))
        case .formSecondary:
            return formTheme.readableInk(systemColor(.secondaryLabel), minimumRatio: minimum, on: formCell)
        case .formFooter:
            return formTheme.readableInk(systemColor(.secondaryLabel), minimumRatio: minimum, on: formBackground)
        case .formDestructive:
            return formTheme.readableInk(systemColor(.systemRed), minimumRatio: minimum, on: formCell)
        case .formSuccess:
            return formTheme.readableInk(systemColor(.systemGreen), minimumRatio: minimum, on: formCell)
        }
    }

    /// `uiColor(role)` for SwiftUI.
    func color(_ role: Role) -> Color { Color(uiColor: uiColor(role)) }

    var secondary: Color { color(.secondary) }
    var tertiary: Color { color(.tertiary) }
    var icon: Color { color(.icon) }

    // MARK: - Contrast test listing

    /// Every ink with the surface it is drawn on and the ratio it must reach.
    static func allInks(for theme: Theme, userInterfaceStyle: UIUserInterfaceStyle) -> [Entry] {
        let inks = PhoneInk(theme: theme, userInterfaceStyle: userInterfaceStyle)
        return Role.allCases.map { role in
            Entry(name: role.rawValue, color: inks.uiColor(role), surface: inks.surface(for: role), minimumRatio: role.minimumRatio)
        }
    }

    // MARK: - Helpers

    /// A Form is drawn with the system label ink, not the theme's, so a Form ink blends toward
    /// `.label` when it needs darkening (or lightening).
    private var formTheme: Theme {
        var form = theme
        form.textColor = systemColor(.label)
        form.backgroundColor = formCell
        return form
    }

    private func systemColor(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
    }

    /// `ink` at `alpha` over the opaque `ground`, as one opaque colour.
    static func flatten(_ ink: UIColor, alpha: CGFloat, over ground: UIColor) -> UIColor {
        var ir: CGFloat = 0, ig: CGFloat = 0, ib: CGFloat = 0, ia: CGFloat = 0
        var gr: CGFloat = 0, gg: CGFloat = 0, gb: CGFloat = 0, ga: CGFloat = 0
        ink.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
        ground.getRed(&gr, green: &gg, blue: &gb, alpha: &ga)
        let a = alpha * ia
        return UIColor(red: gr + (ir - gr) * a, green: gg + (ig - gg) * a, blue: gb + (ib - gb) * a, alpha: 1)
    }
}
