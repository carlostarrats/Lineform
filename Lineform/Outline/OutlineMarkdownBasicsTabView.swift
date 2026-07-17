import SwiftUI

/// The sidebar Markdown Basics tab: reference items from every section are shown as tinted rows
/// with their syntax and explanation, plus a small copy button that copies the literal syntax string.
struct OutlineMarkdownBasicsTabView: View {
    var usesDarkChrome: Bool
    @State private var copiedRowID: String?

    static let explanationLightWhiteComponent: CGFloat = 0.36
    static let rowBackgroundLightWhiteComponent: CGFloat = 0.96
    static let rowBackgroundDarkWhiteComponent: CGFloat = 0.22
    static let headerLightWhiteComponent: CGFloat = 0.42
    static let headerDarkWhiteComponent: CGFloat = 0.62

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

    static func headerColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? headerDarkWhiteComponent : headerLightWhiteComponent,
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
                        Spacer().frame(height: 14)
                    }

                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.headerColor(usesDarkChrome: usesDarkChrome))
                        .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding + 6)

                    Spacer().frame(height: 6)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    }
                }
            }
            .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding)
            .padding(.top, 8)
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
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func copyButton(for row: MarkdownReference.Row) -> some View {
        CopyButton(
            rowID: row.id,
            copiedRowID: $copiedRowID,
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
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var usesDarkChrome: Bool { colorScheme == .dark }
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
        .accessibilityLabel(isCopied ? "Copied" : "Copy \(rowID)")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
