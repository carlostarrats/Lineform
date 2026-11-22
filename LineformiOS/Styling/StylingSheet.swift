import LineformCore
import SwiftUI

/// The Styling sheet: the Mac's Reading Experience panel in a bottom sheet, opened by the "Aa"
/// button (`StylingButton`). Every control writes through `ReadingProfileStore`, which
/// `DocumentScreen` observes, so the editor and the Read view restyle live.
///
/// `DocumentScreen` presents it with `stylingSheetChrome(theme:)` for the live profile's theme:
/// the page colour, and the theme's own light or dark, never the system appearance, so a dark
/// preset draws a dark sheet with readable labels whatever the phone is set to.
struct StylingSheet: View {
    @ObservedObject var store: ReadingProfileStore

    static let detents: Set<PresentationDetent> = [.medium, .large]
    static let cornerRadius: CGFloat = LineformDesign.Radius.modal
    static let headerTitleFontSize: CGFloat = 15
    /// The Mac panel's section spacing and padding.
    static let sectionSpacing: CGFloat = 18
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 16
    static var headerTitle: String { String(localized: "Reading") }

    /// The theme's own light or dark, independent of the trait collection.
    static func colorScheme(for theme: Theme) -> ColorScheme {
        theme.usesDarkChrome ? .dark : .light
    }

    private var theme: Theme { Theme.theme(for: store.activeProfile) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    // The controls (Task 3).
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(Color(uiColor: theme.textColor))
    }

    private var header: some View {
        Text(Self.headerTitle)
            .font(.system(size: Self.headerTitleFontSize, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity)
            .padding(.top, Self.verticalPadding + 8)
            .padding(.horizontal, Self.horizontalPadding)
    }
}

extension View {
    /// The Styling sheet's presentation: medium and large detents, the theme's page colour, the
    /// modal corner radius, a visible drag indicator, and the theme's own colour scheme.
    func stylingSheetChrome(theme: Theme) -> some View {
        presentationDetents(StylingSheet.detents)
            .presentationBackground(Color(uiColor: theme.backgroundColor))
            .presentationCornerRadius(StylingSheet.cornerRadius)
            .presentationDragIndicator(.visible)
            .environment(\.colorScheme, StylingSheet.colorScheme(for: theme))
    }
}
