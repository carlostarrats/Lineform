import SwiftUI

/// The sidebar Info tab: the Markdown syntax reference, stacked for the narrow
/// column (monospaced syntax over a plain-English explanation), section-ruled,
/// and theme-aware. Static content — no scan, no laziness concern (unlike the
/// Files tab). It replaces the former blocking "Info" Muse modal.
struct OutlineInfoTabView: View {
    var usesDarkChrome: Bool

    // Only the LIGHT explanation tone needs to differ from the sidebar's secondary
    // color: the sidebar secondary dips to ~3.8:1 on the light page (fine for short
    // Files labels, too low for this longer-form reference copy), so the light tone
    // is bumped darker to clear WCAG AA (>= 4.5:1). The DARK secondary already clears
    // AA, so it is reused directly from the sidebar — no duplicated constant to drift.
    // The syntax line reuses the sidebar's primary color (>= 9:1 in both chromes).
    static let explanationLightWhiteComponent: CGFloat = 0.36

    static func explanationColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome
                ? OutlineSidebarView.darkSecondaryTextWhiteComponent
                : explanationLightWhiteComponent,
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
