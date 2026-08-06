import SwiftUI

/// The sidebar Markdown Basics tab: reference items from every section are shown as tinted rows
/// with their syntax and explanation, plus a small copy button that copies the literal syntax string.
struct OutlineMarkdownBasicsTabView: View {
    var usesDarkChrome: Bool
    @State private var copiedRowID: String?

    static let explanationLightWhiteComponent: CGFloat = 0.36
    static let rowBackgroundLightWhiteComponent: CGFloat = 0.96
    static let rowBackgroundDarkWhiteComponent: CGFloat = 0.22

    static func explanationColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome
                ? OutlineSidebarView.darkSecondaryTextWhiteComponent
                : explanationLightWhiteComponent,
            alpha: 1
        ))
    }

    static func rowBackgroundColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome
                ? rowBackgroundDarkWhiteComponent
                : rowBackgroundLightWhiteComponent,
            alpha: 1
        ))
    }

    private var sections: [MarkdownReference.Section] {
        MarkdownReference.sections
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        // Generous separation between sections (Markdown Basics, Diagrams, Math…).
                        Spacer().frame(height: 38)
                    }

                    Text(section.title)
                        // Match the Files "Sort folders by" label: size 12, medium, inactive-tab grey.
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OutlineSidebarView.tabTextColor(
                            usesDarkChrome: usesDarkChrome,
                            isSelected: false,
                            isHovered: false
                        ))
                        // Align the header with the box's syntax text (outer 14 + box inner 10 = 24),
                        // which is also the shared icon column.
                        .padding(.leading, 10)
                        .padding(.trailing, OutlineSidebarView.pillHorizontalInset)

                    // Breathing room between a header and the boxes it labels.
                    Spacer().frame(height: 18)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    }
                }
            }
            .padding(.horizontal, OutlineSidebarView.pillHorizontalInset)
            // +4 matches the Files sort row's internal top padding, so the first line of text sits
            // at the same y below the divider as the Files tab (both are size-12 medium).
            .padding(.top, OutlineSidebarView.tabDividerGap + 4)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Markdown basics")
    }

    private func rowView(_ row: MarkdownReference.Row) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.syntax)
                    .font(row.rendersSyntaxAsCode ? .system(.callout, design: .monospaced) : .callout)
                    .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .textSelection(.enabled)

                Text(row.explanation)
                    .font(.footnote)
                    .foregroundStyle(Self.explanationColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            copyButton(for: row)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.rowBackgroundColor(usesDarkChrome: usesDarkChrome))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel())
    }

    private func copyButton(for row: MarkdownReference.Row) -> some View {
        CopyButton(
            rowID: row.id,
            copiedRowID: $copiedRowID,
            usesDarkChrome: usesDarkChrome,
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.syntax, forType: .string)
                copiedRowID = row.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedRowID == row.id {
                        copiedRowID = nil
                    }
                }
            }
        )
    }
}

private struct CopyButton: View {
    let rowID: String
    @Binding var copiedRowID: String?
    // Threaded from the theme (see SidebarTabButton) rather than read from ambient colorScheme,
    // which a nested Button re-derives from the window's drift-prone effectiveAppearance.
    let usesDarkChrome: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var isCopied: Bool { copiedRowID == rowID }

    var body: some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    isCopied
                        ? Color(nsColor: NSColor(calibratedWhite: usesDarkChrome ? 0.85 : 0.35, alpha: 1))
                        : OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome)
                        .opacity(0.55)
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(isHovered ? 0.06 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Two `Text`s, not a ternary of two literals: a ternary's branches are type-checked as
        // one expression, and whether that lands on `LocalizedStringKey` or the `@_disfavoredOverload`
        // verbatim `StringProtocol` was never confirmed. `accessibilityLabel(_: Text)` is a distinct,
        // non-disfavored overload, so each branch is unambiguously a localized position.
        .accessibilityLabel(isCopied ? Text("Copied") : Text("Copy \(rowID)"))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
