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

    /// The Mac card's sizes at the default text size; on iPhone each scales with Dynamic Type
    /// (the specimen and the height like `.title`, the title like `.caption`).
    static let minHeight: CGFloat = 82
    static let cornerRadius: CGFloat = LineformDesign.Radius.card
    static let specimenFontSize: CGFloat = 30
    static let titleFontSize: CGFloat = 12

    @ScaledMetric(relativeTo: .title) private var scaledMinHeight = StylingPresetCard.minHeight
    @ScaledMetric(relativeTo: .title) private var scaledSpecimenSize = StylingPresetCard.specimenFontSize
    @ScaledMetric(relativeTo: .caption) private var scaledTitleSize = StylingPresetCard.titleFontSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    static let selectedStrokeWidth: CGFloat = 2
    static let unselectedStrokeWidth: CGFloat = 1

    private var theme: Theme { Theme.theme(for: preset.profile) }

    var body: some View {
        let ink = Color(uiColor: theme.textColor)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        Button(action: apply) {
            VStack(spacing: 2) {
                Text(verbatim: "Aa")
                    .font(Self.previewFont(for: preset.profile.fontID, size: scaledSpecimenSize))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text(preset.title)
                    .font(Self.previewFont(for: preset.profile.fontID, size: scaledTitleSize))
                    .foregroundStyle(ink)
                    // One line, as on the Mac; at the accessibility sizes the title wraps instead
                    // of shrinking or truncating.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            .frame(maxWidth: .infinity, minHeight: scaledMinHeight)
            .background(shape.fill(Color(uiColor: theme.backgroundColor)))
            .overlay(
                shape.stroke(
                    Color(uiColor: isSelected
                        ? Self.selectedStrokeColor(usesDarkChrome: usesDarkChrome)
                        : Self.unselectedStrokeColor(usesDarkChrome: usesDarkChrome)),
                    lineWidth: isSelected ? Self.selectedStrokeWidth : Self.unselectedStrokeWidth
                )
            )
            // The chosen theme also carries a small blue check in its top-right corner (owner
            // review 6: the outline alone was hard to see on the dark cards).
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(uiColor: Self.selectedStrokeColor(usesDarkChrome: usesDarkChrome)))
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
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
            ? UIColor.white.withAlphaComponent(0.26)
            : UIColor.black.withAlphaComponent(0.08)
    }

    /// The Mac card's font mapping (`ReadingPresetCard.previewFont`). `size` is already scaled
    /// for Dynamic Type, so the custom faces take it as a fixed size (never scaled twice).
    static func previewFont(for fontID: FontID, size: CGFloat) -> Font {
        switch fontID {
        case .sfPro:
            return .system(size: size, weight: .regular)
        case .newYork:
            return .system(size: size, weight: .regular, design: .serif)
        case .jetBrainsMono:
            return .system(size: size, weight: .regular, design: .monospaced)
        case .atkinsonHyperlegible:
            return .custom("AtkinsonHyperlegible-Regular", fixedSize: size)
        case .openDyslexic:
            return .custom("OpenDyslexic-Regular", fixedSize: size)
        case .lexend, .comicSans:
            return .system(size: size, weight: .regular)
        }
    }
}
