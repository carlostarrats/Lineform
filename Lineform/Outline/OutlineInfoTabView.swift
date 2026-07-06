import SwiftUI

/// The sidebar Info tab: the Markdown syntax reference, stacked for the narrow
/// column (monospaced syntax over a plain-English explanation), section-ruled,
/// and theme-aware. Static content — no scan, no laziness concern (unlike the
/// Files tab). It replaces the former blocking "Info" Muse modal.
struct OutlineInfoTabView: View {
    var usesDarkChrome: Bool

    // The explanation text uses a muted tone that still clears WCAG AA (>= 4.5:1)
    // against the sidebar background in BOTH chromes. The sidebar's own secondary
    // color is fine for short Files labels but dips to ~3.8:1 on the light page —
    // too low for this longer-form reference copy — so the Info tab picks a slightly
    // darker light tone (dark chrome already clears AA and is unchanged). The syntax
    // line reuses the sidebar's primary color (>= 9:1 in both chromes).
    static let explanationLightWhiteComponent: CGFloat = 0.36
    static let explanationDarkWhiteComponent: CGFloat = 0.68

    static func explanationColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? explanationDarkWhiteComponent : explanationLightWhiteComponent,
            alpha: 1
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(MarkdownReference.sections) { section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Markdown reference")
    }

    private func sectionView(_ section: MarkdownReference.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)

                    if index < section.rows.count - 1 {
                        Divider()
                            .overlay(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.08))
                    }
                }
            }
        }
    }

    private func rowView(_ row: MarkdownReference.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.syntax)
                .font(row.rendersSyntaxAsCode ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                .textSelection(.enabled)

            Text(row.explanation)
                .font(.footnote)
                .foregroundStyle(Self.explanationColor(usesDarkChrome: usesDarkChrome))
                .fixedSize(horizontal: false, vertical: true) // wrap, never truncate
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
