import LineformCore
import SwiftUI
import UIKit

/// The word menu's colours: the Mac Settings window's wash and the surfaces drawn on it. One light
/// look for every light theme and one dark look (Quiet's tones) for every dark theme; the menu
/// never takes the page's own colour, so the document screen never wears the wash.
///
/// Every ink is made readable on every surface it is drawn on with `Theme.readableInk` (text 4.5:1,
/// the large grey words 3:1 as large text, marks 3:1). `WordMenuPaletteTests` measures them.
struct WordMenuPalette {
    let isDark: Bool

    // MARK: Surfaces

    /// The wash, top to bottom: white → #F1F1F1, or #2A2A2A → #1C1C1C.
    let washTop: UIColor
    let washBottom: UIColor
    /// Rows, grey cards (Markdown Basics, History) and the Read Aloud pill.
    let soft: UIColor
    /// Document cards: white with a soft shadow in light; a lighter grey, no shadow, in dark.
    let card: UIColor
    /// The search and key fields: clearly darker than a card.
    let field: UIColor
    /// Hairlines and the outline's guide line.
    let hair: UIColor

    // MARK: Inks

    let ink: UIColor
    /// Notes, dates, counts, icons' text.
    let secondary: UIColor
    /// Group labels, the version line, placeholders.
    let tertiary: UIColor
    /// Themes and Settings: grey, still 3:1 as large text.
    let largeGrey: UIColor
    /// Icons and chevrons (non-text, 3:1).
    let icon: UIColor
    /// Lineform blue as a fill (the primary pill, switches), with white text on it (4.5:1).
    let blueFill: UIColor
    /// Lineform blue as a mark on the surfaces (the copy tick, the provider tick).
    let blueMark: UIColor
    /// Lineform blue as text on the surfaces (Choose, Change): 4.5:1.
    let blueText: UIColor
    /// Move to Trash and other destructive text.
    let destructive: UIColor
    /// "Saved" in the status line: the Mac's green.
    let saved: UIColor

    var cardHasShadow: Bool { !isDark }

    init(isDark: Bool) {
        self.isDark = isDark
        func rgb(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        if isDark {
            washTop = rgb(0x2A2A2A)
            washBottom = rgb(0x1C1C1C)
            soft = rgb(0x3B3B3B)
            card = rgb(0x3E3E3E)
            field = rgb(0x262626)
            hair = rgb(0x4A4A4A)
            ink = rgb(0xDBDBDB)
        } else {
            washTop = rgb(0xFFFFFF)
            washBottom = rgb(0xF1F1F1)
            soft = rgb(0xE9EAED)
            card = rgb(0xFFFFFF)
            field = rgb(0xE6E7EA)
            hair = rgb(0xD9DADE)
            ink = rgb(0x1F1F1F)
        }
        let surfaces = [washTop, washBottom, soft, card, field]
        func readable(_ base: UIColor, _ minimum: CGFloat, on grounds: [UIColor], ink: UIColor) -> UIColor {
            var color = base
            for ground in grounds {
                var theme = Theme.system
                theme.textColor = ink
                theme.backgroundColor = ground
                color = theme.readableInk(color, minimumRatio: minimum, on: ground)
            }
            return color
        }
        let ink = self.ink
        secondary = readable(isDark ? rgb(0xABABAB) : rgb(0x6A6C70), 4.5, on: surfaces, ink: ink)
        tertiary = readable(isDark ? rgb(0x9A9A9A) : rgb(0x74767A), 4.5, on: surfaces, ink: ink)
        largeGrey = readable(isDark ? rgb(0x8E8E8E) : rgb(0x808286), 3, on: [washTop, washBottom], ink: ink)
        icon = readable(isDark ? rgb(0x9A9A9A) : rgb(0x7A7C80), 3, on: surfaces, ink: ink)
        blueFill = rgb(0x2F6BDE)
        blueMark = readable(isDark ? rgb(0x7FA6F5) : rgb(0x2F6BDE), 3, on: surfaces, ink: ink)
        blueText = readable(isDark ? rgb(0x7FA6F5) : rgb(0x2F6BDE), 4.5, on: surfaces, ink: ink)
        destructive = readable(isDark ? rgb(0xFF8A80) : rgb(0xC93A3A), 4.5, on: surfaces, ink: ink)
        saved = readable(
            isDark ? EditorStatusGreen.dark : EditorStatusGreen.light, 4.5, on: [washTop, washBottom], ink: ink
        )
    }

    static func forTheme(_ theme: Theme) -> WordMenuPalette {
        WordMenuPalette(isDark: theme.usesDarkChrome)
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    // MARK: SwiftUI

    func color(_ ui: UIColor) -> Color { Color(uiColor: ui) }

    /// The Mac Settings wash, top to bottom.
    var wash: LinearGradient {
        LinearGradient(colors: [color(washTop), color(washBottom)], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Contrast listing

    struct Entry {
        var name: String
        var color: UIColor
        var surface: UIColor
        var minimumRatio: CGFloat
    }

    /// Every ink on every surface it is drawn on, for the contrast test.
    var entries: [Entry] {
        let surfaces: [(String, UIColor)] = [
            ("washTop", washTop), ("washBottom", washBottom), ("soft", soft), ("card", card), ("field", field),
        ]
        var entries: [Entry] = []
        for (surfaceName, surface) in surfaces {
            entries.append(Entry(name: "ink/\(surfaceName)", color: ink, surface: surface, minimumRatio: 4.5))
            entries.append(Entry(name: "secondary/\(surfaceName)", color: secondary, surface: surface, minimumRatio: 4.5))
            entries.append(Entry(name: "tertiary/\(surfaceName)", color: tertiary, surface: surface, minimumRatio: 4.5))
            entries.append(Entry(name: "icon/\(surfaceName)", color: icon, surface: surface, minimumRatio: 3))
            entries.append(Entry(name: "blueMark/\(surfaceName)", color: blueMark, surface: surface, minimumRatio: 3))
            entries.append(Entry(name: "blueText/\(surfaceName)", color: blueText, surface: surface, minimumRatio: 4.5))
            entries.append(Entry(name: "destructive/\(surfaceName)", color: destructive, surface: surface, minimumRatio: 4.5))
        }
        for (surfaceName, surface) in surfaces.prefix(2) {
            entries.append(Entry(name: "largeGrey/\(surfaceName)", color: largeGrey, surface: surface, minimumRatio: 3))
            entries.append(Entry(name: "saved/\(surfaceName)", color: saved, surface: surface, minimumRatio: 4.5))
        }
        entries.append(Entry(name: "onBlue", color: .white, surface: blueFill, minimumRatio: 4.5))
        return entries
    }
}

/// The Mac's save-confirmation green (`EditorStatusColors.saved`): #147A3D on light, #66D18C on
/// dark.
enum EditorStatusGreen {
    static let light = UIColor(red: 0.08, green: 0.47, blue: 0.24, alpha: 1)
    static let dark = UIColor(red: 0.40, green: 0.82, blue: 0.55, alpha: 1)
}

extension EnvironmentValues {
    /// The word menu's palette, for its pages and their rows.
    @Entry var wordMenuPalette = WordMenuPalette(isDark: false)
}

// MARK: - Layout constants

/// The word menu's measurements, from the approved mockup.
enum WordMenuMetrics {
    /// The words' and the status line's leading edge.
    static let wordInset: CGFloat = 28
    /// A section page's side margin.
    static let pageInset: CGFloat = 18
    /// The section title's side margin.
    static let titleInset: CGFloat = 24
    /// Above the status line and the section title, below the safe area.
    static let headerTop: CGFloat = 14
    static let largeWordSize: CGFloat = 34
    static let smallWordSize: CGFloat = 19
    static let smallWordMinHeight: CGFloat = 44
    static let sectionTitleSize: CGFloat = 30
    static let rowRadius: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let cardHeight: CGFloat = 150
    static let cardSpacing: CGFloat = 10
    static let minimumTarget: CGFloat = 44
    /// The round bottom-right button (⋯, ✕, ←).
    static let cornerButtonDiameter: CGFloat = 48
    /// Room below a page's last row for the corner button.
    static let bottomClearance: CGFloat = 110
}

// MARK: - Components

/// A section page: the title, then the rows in a scroll view, on the wash (drawn by the menu).
struct WordMenuPageScaffold<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.wordMenuPalette) private var palette
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = WordMenuMetrics.sectionTitleSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WordMenuMetrics.rowSpacing) {
                Text(title)
                    .font(.system(size: titleSize))
                    .tracking(-0.6)
                    .foregroundStyle(palette.color(palette.ink))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, WordMenuMetrics.titleInset - WordMenuMetrics.pageInset)
                    .padding(.top, WordMenuMetrics.headerTop)
                    .padding(.bottom, 8)
                content()
            }
            .padding(.horizontal, WordMenuMetrics.pageInset)
            .padding(.bottom, WordMenuMetrics.bottomClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// What sits at a row's trailing edge.
enum WordMenuRowAccessory {
    case none
    case chevron
    /// Opens outside the app (Safari).
    case external
    case text(String)
    case progress
}

/// One row: an optional icon, the title (and an optional note), and its accessory, on the soft
/// fill. At least 44 pt tall.
struct WordMenuRow: View {
    var title: String
    var note: String? = nil
    var systemImage: String? = nil
    var accessory: WordMenuRowAccessory = .chevron
    var isDestructive = false
    var action: () -> Void

    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            WordMenuRowLabel(
                title: title, note: note, systemImage: systemImage, accessory: accessory, isDestructive: isDestructive
            )
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityAddTraits(accessory.isExternal ? .isLink : [])
    }
}

extension WordMenuRowAccessory {
    var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

/// A row's look, shared by `WordMenuRow` and rows that are menus or links.
struct WordMenuRowLabel: View {
    var title: String
    var note: String? = nil
    var systemImage: String? = nil
    var accessory: WordMenuRowAccessory = .chevron
    var isDestructive = false
    /// A count beside the chevron (a folder's files).
    var count: Int? = nil

    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let ink = isDestructive ? palette.destructive : palette.ink
        HStack(alignment: .center, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(palette.color(isDestructive ? palette.destructive : palette.icon))
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(palette.color(ink))
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(palette.color(palette.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if let count {
                Text(count, format: .number)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.color(palette.secondary))
            }
            accessoryView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                .fill(palette.color(palette.soft))
        )
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous))
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.color(palette.icon))
                .accessibilityHidden(true)
        case .external:
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.color(palette.icon))
                .accessibilityHidden(true)
        case .text(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(palette.color(palette.secondary))
                .lineLimit(1)
        case .progress:
            ProgressView()
        }
    }
}

/// A switch row: the title and its note, the switch tinted Lineform blue. VoiceOver reads the
/// title as the label and the note as the hint. At accessibility sizes the switch goes under the
/// text.
struct WordMenuToggleRow: View {
    var title: String
    var note: String?
    @Binding var isOn: Bool

    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(palette.color(palette.ink))
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    text
                    Toggle(isOn: $isOn) { Text(title) }
                        .labelsHidden()
                }
            } else {
                Toggle(isOn: $isOn) { text }
            }
        }
        .tint(palette.color(palette.blueFill))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                .fill(palette.color(palette.soft))
        )
        // A tap anywhere on the row flips the switch, as the row is one control.
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        // One switch for VoiceOver, the size of the whole row: the title is the label, the note
        // the hint (the drawn switch alone is a 51 × 31 target).
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { Text(title) }
        }
        .accessibilityHint(note.map { Text($0) } ?? Text(verbatim: ""))
    }
}

/// A small group label above a run of rows.
struct WordMenuGroupLabel: View {
    var title: String
    var systemImage: String? = nil
    @Environment(\.wordMenuPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
                .textCase(.uppercase)
                .tracking(0.6)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(palette.color(palette.tertiary))
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A short explanatory paragraph at the top of a page.
struct WordMenuNote: View {
    var text: String
    @Environment(\.wordMenuPalette) private var palette

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(palette.color(palette.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
    }
}

/// The one primary button style: a full-width Lineform-blue pill (Connect, New Document).
struct WordMenuPrimaryButton: View {
    var title: String
    var systemImage: String? = nil
    var action: () -> Void
    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .multilineTextAlignment(.center)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Capsule().fill(palette.color(palette.blueFill)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(WordMenuPressStyle())
        .padding(.top, 4)
    }
}

/// A search or key field: the field fill, darker than the cards.
struct WordMenuFieldBackground: ViewModifier {
    @Environment(\.wordMenuPalette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(minHeight: WordMenuMetrics.minimumTarget)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.color(palette.field))
            )
    }
}

extension View {
    func wordMenuField() -> some View { modifier(WordMenuFieldBackground()) }
}

/// A quiet press: the row dims while held. No motion.
struct WordMenuPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A grid of document cards: a lone card spans the full width; two or more are always half width,
/// two across, all the same height.
struct WordMenuCardGrid<Item: Identifiable, Card: View>: View {
    var items: [Item]
    @ViewBuilder var card: (Item) -> Card

    static func columnCount(for itemCount: Int) -> Int { itemCount == 1 ? 1 : 2 }

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: WordMenuMetrics.cardSpacing, alignment: .top),
            count: Self.columnCount(for: items.count)
        )
        LazyVGrid(columns: columns, alignment: .leading, spacing: WordMenuMetrics.cardSpacing) {
            ForEach(items) { item in
                card(item)
                    .frame(height: WordMenuMetrics.cardHeight)
            }
        }
    }
}

/// The round button in the bottom-right corner of the document and the menu: ⋯ on the document,
/// ✕ on the word list, ← inside a section. Drawn with the floating-card chrome of the theme (on the
/// document) or the menu's surfaces (in the menu).
struct WordMenuCornerButton: View {
    enum Glyph {
        case more, close, back

        var systemImage: String {
            switch self {
            case .more: "ellipsis"
            case .close: "xmark"
            case .back: "arrow.left"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .more: String(localized: "Menu")
            case .close: String(localized: "Close menu")
            case .back: String(localized: "Back")
            }
        }
    }

    var glyph: Glyph
    var fill: UIColor
    var ink: UIColor
    var isDark: Bool
    var action: () -> Void

    static let diameter = WordMenuMetrics.cornerButtonDiameter

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph.systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(uiColor: ink))
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(Color(uiColor: fill)))
                .overlay(
                    Circle().strokeBorder(
                        isDark
                            ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                            : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                        lineWidth: LineformDesign.FloatingCard.hairlineWidth
                    )
                )
                .shadow(
                    color: .black.opacity(
                        isDark ? LineformDesign.FloatingCard.shadowOpacityDark : LineformDesign.FloatingCard.shadowOpacityLight
                    ),
                    radius: LineformDesign.FloatingCard.shadowRadius,
                    x: LineformDesign.FloatingCard.shadowOffset.width,
                    y: LineformDesign.FloatingCard.shadowOffset.height
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(glyph.accessibilityLabel)
        // Fixed-size floating chrome: a long press at accessibility sizes shows it enlarged.
        .accessibilityShowsLargeContentViewer {
            Label(glyph.accessibilityLabel, systemImage: glyph.systemImage)
        }
    }
}

/// The ⋯ button on the document: opens the word menu. It replaces the Menu and Aa buttons.
struct MoreButton: View {
    var profile: ReadingProfile
    var action: () -> Void

    static let diameter = WordMenuMetrics.cornerButtonDiameter
    static var accessibilityTitle: String { WordMenuCornerButton.Glyph.more.accessibilityLabel }

    var body: some View {
        let theme = Theme.theme(for: profile)
        WordMenuCornerButton(
            glyph: .more,
            fill: theme.backgroundColor,
            ink: theme.textColor,
            isDark: theme.usesDarkChrome,
            action: action
        )
        .accessibilityIdentifier("document.more")
    }
}
