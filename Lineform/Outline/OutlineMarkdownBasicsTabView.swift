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

            // Only the code rows: a label row's cell is a translated UI word, not Markdown.
            // `copyAffordance()` is nil there, and `copyButton` takes the unwrapped value — so
            // deleting this check does not compile, let alone reintroduce the bug.
            if let copy = row.copyAffordance() {
                copyButton(rowID: row.id, copy: copy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.rowBackgroundColor(usesDarkChrome: usesDarkChrome))
        )
        // Collapsing the row is CORRECT: its AX value should be one coherent phrase
        // ("Bold. Syntax: **bold**"), not three fragments. But `children: .ignore` also
        // SUPPRESSES the copy `Button` — it stops existing for VoiceOver, Switch Control and Full
        // Keyboard Access. An affordance reachable only by pointer needs its action mirror
        // (Claude.md, accessibility invariants); the Files sidebar rows do the same thing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel())
        .accessibilityActions {
            if let copy = row.copyAffordance() {
                Button {
                    performCopy(rowID: row.id, copyText: copy.text)
                } label: {
                    // Already localized at its definition site — this position takes SwiftUI's
                    // verbatim overload.
                    Label(copy.label, systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// Takes the affordance as a non-optional value, supplied only by unwrapping
    /// `Row.copyAffordance()` — a label row cannot reach here.
    private func copyButton(rowID: String, copy: MarkdownReference.CopyAffordance) -> some View {
        CopyButton(
            // Identity is the row's STABLE id; the spoken label is its syntax. They were one value
            // until `Row.identifier` split them — keying "Copied" on translated text is the bug the
            // id exists to prevent, and speaking an internal slug is the bug on the other side.
            rowID: rowID,
            copyLabel: copy.label,
            copiedRowID: $copiedRowID,
            usesDarkChrome: usesDarkChrome,
            action: { performCopy(rowID: rowID, copyText: copy.text) }
        )
    }

    /// The ONE definition of "copy this row": the pasteboard write plus the copied-state
    /// bookkeeping that flips the button to a checkmark for 1.5s.
    ///
    /// Both the visual button and the row's accessibility-action mirror call it. Left inline in the
    /// button's closure, the mirror would have been a second copy of the same three steps — the
    /// shape this repo has been burned by repeatedly, and an AX mirror that has drifted from the
    /// real action is worse than none.
    private func performCopy(rowID: String, copyText: String) {
        Self.writeToPasteboard(copyText)
        copiedRowID = rowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedRowID == rowID {
                copiedRowID = nil
            }
        }
    }

    /// The pasteboard half on its own, with an injectable pasteboard so the DEFAULT test plan can
    /// assert what lands on it without hosting a window.
    static func writeToPasteboard(_ syntax: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(syntax, forType: .string)
    }
}

private struct CopyButton: View {
    let rowID: String
    /// Already localized (`MarkdownReference.Row.copyAffordance()`), and the SAME string the row's
    /// accessibility-action mirror uses.
    let copyLabel: String
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
        // non-disfavored overload, so the literal branch is unambiguously a localized position; the
        // other branch is already-localized text, so it is verbatim on purpose.
        .accessibilityLabel(isCopied ? Text("Copied") : Text(verbatim: copyLabel))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
