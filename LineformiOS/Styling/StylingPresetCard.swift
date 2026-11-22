import LineformCore
import SwiftUI
import UIKit

/// One preset card in the Styling sheet's Themes grid — the Mac's `ReadingPresetCard`: "Aa" and
/// the preset's title in the preset's own font and ink, on its page colour.
struct StylingPresetCard: View {
    var preset: ReadingPreset
    var isSelected: Bool
    /// Threaded from the live theme, never read from the environment.
    var usesDarkChrome: Bool
    var apply: () -> Void

    static let minHeight: CGFloat = 82
    static let cornerRadius: CGFloat = LineformDesign.Radius.card
    static let specimenFontSize: CGFloat = 30
    static let titleFontSize: CGFloat = 12
    static let selectedStrokeWidth: CGFloat = 2
    static let unselectedStrokeWidth: CGFloat = 1

    private var theme: Theme { Theme.theme(for: preset.profile) }

    var body: some View {
        let ink = Color(uiColor: theme.textColor)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        Button(action: apply) {
            VStack(spacing: 2) {
                Text("Aa")
                    .font(Self.previewFont(for: preset.profile.fontID, size: Self.specimenFontSize))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text(preset.title)
                    .font(Self.previewFont(for: preset.profile.fontID, size: Self.titleFontSize))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: Self.minHeight)
            .background(shape.fill(Color(uiColor: theme.backgroundColor)))
            .overlay(
                shape.stroke(
                    Color(uiColor: isSelected
                        ? Self.selectedStrokeColor(usesDarkChrome: usesDarkChrome)
                        : Self.unselectedStrokeColor(usesDarkChrome: usesDarkChrome)),
                    lineWidth: isSelected ? Self.selectedStrokeWidth : Self.unselectedStrokeWidth
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(for: preset))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static func accessibilityLabel(for preset: ReadingPreset) -> String {
        String(localized: "\(preset.title) reading theme")
    }

    /// System blue resolved for the sheet's forced light or dark, not the phone's appearance.
    static func selectedStrokeColor(usesDarkChrome: Bool) -> UIColor {
        UIColor.systemBlue.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: usesDarkChrome ? .dark : .light)
        )
    }

    /// The Mac's unselected edge: a Quiet card on a Quiet sheet would vanish against black.
    static func unselectedStrokeColor(usesDarkChrome: Bool) -> UIColor {
        usesDarkChrome
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.08)
    }

    /// The Mac card's font mapping (`ReadingPresetCard.previewFont`).
    static func previewFont(for fontID: FontID, size: CGFloat) -> Font {
        switch fontID {
        case .sfPro:
            return .system(size: size, weight: .regular)
        case .newYork:
            return .system(size: size, weight: .regular, design: .serif)
        case .jetBrainsMono:
            return .system(size: size, weight: .regular, design: .monospaced)
        case .atkinsonHyperlegible:
            return .custom("AtkinsonHyperlegible-Regular", size: size)
        case .openDyslexic:
            return .custom("OpenDyslexic-Regular", size: size)
        case .lexend, .comicSans:
            return .system(size: size, weight: .regular)
        }
    }
}
