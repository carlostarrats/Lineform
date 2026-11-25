import LineformCore
import SwiftUI
import UIKit

/// Which Basics row shows "Copied", and the copy itself.
@MainActor
@Observable
final class BasicsCopyState {
    private(set) var copiedRowID: String?
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    /// Says "Copied" to VoiceOver: the row's value changes too, but VoiceOver does not re-read a
    /// value on its own.
    @ObservationIgnored private let announce: @MainActor (String) -> Void

    init(announce: @escaping @MainActor (String) -> Void = { text in BasicsCopyState.announceToVoiceOver(text) }) {
        self.announce = announce
    }

    static func announceToVoiceOver(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Puts the row's `copyAffordance` text on `pasteboard` and shows "Copied" on that row for
    /// `BasicsSection.copiedDuration`. False, with nothing written, for a label row (its cell is a
    /// translated UI word, not Markdown).
    @discardableResult
    func copy(_ row: MarkdownReference.Row, to pasteboard: UIPasteboard = .general) -> Bool {
        guard let copy = row.copyAffordance() else { return false }
        pasteboard.string = copy.text
        copiedRowID = row.id
        announce(BasicsSection.copiedText)
        clearTask?.cancel()
        let rowID = row.id
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: BasicsSection.copiedDuration)
            guard !Task.isCancelled, let self, copiedRowID == rowID else { return }
            copiedRowID = nil
        }
        return true
    }
}

/// The word menu's Markdown Basics, as in the mockup (`word-menu.html`, `.mdgroup`): each group is
/// its own grey card (the soft fill, radius 14) under its small label, with a clear gap between
/// groups. Rows sit inside with hairline dividers; a code row has a copy button on the right that
/// turns into a blue check for a moment after copying its Markdown.
///
/// Exactly the mockup's groups and rows: Headings (Title, Section), Emphasis (Bold, Italic,
/// Strikethrough, Code), Lists (Bullets, Numbers, Checkbox), Links & images (Link, Image) and
/// Blocks (Quote, Table, Math, Diagram). Each row is the package's `MarkdownReference` row (the
/// Mac's reference syntax, word for word), picked by its identity; the reference's other rows are
/// not shown on iPhone, and its iPhone branch has no label rows (Tab, Block Spacing) or Spelling
/// and Search groups at all.
struct BasicsSection: View {
    @State private var state = BasicsCopyState()
    @Environment(\.wordMenuPalette) private var palette

    static var sections: [MarkdownReference.Section] { MarkdownReference.sections }
    static let copiedDuration: Duration = .seconds(1)
    static var copiedText: String { String(localized: "Copied") }

    /// One group on the page: its label and its rows.
    struct BasicsGroup: Identifiable {
        var id: String
        var title: String
        var rows: [MarkdownReference.Row]
    }

    /// The mockup's groups and their rows, by row identity (never translated text).
    static let basicsGroupRowIDs: [(id: String, rowIDs: [String])] = [
        ("headings", ["# Title", "## Section"]),
        ("emphasis", ["**bold**", "_italic_", "~~text~~", "`code`"]),
        ("lists", ["- bullet", "1. item", "- [ ] to do"]),
        ("links", ["[text](url)", "![alt](url)"]),
        ("blocks", ["> quote", "| a | b |", "$x^2 + y^2$", "```mermaid"]),
    ]

    static func groupTitle(_ id: String) -> String {
        switch id {
        case "headings": String(localized: "Headings")
        case "emphasis": String(localized: "Emphasis")
        case "lists": String(localized: "Lists")
        case "links": String(localized: "Links & images")
        default: String(localized: "Blocks")
        }
    }

    /// Every group in order, each row taken from whichever reference section holds it.
    static var groups: [BasicsGroup] {
        let rows = sections.flatMap(\.rows)
        return basicsGroupRowIDs.compactMap { id, rowIDs in
            let picked = rowIDs.compactMap { rowID in rows.first { $0.id == rowID } }
            return picked.isEmpty ? nil : BasicsGroup(id: id, title: groupTitle(id), rows: picked)
        }
    }

    /// The gap from one group's card to the next group's label (the owner's review of 2026-11-24:
    /// the groups sat too close). A label keeps its own card close (8 pt).
    static let groupGap: CGFloat = 30
    /// The first label's gap under the page title.
    static let firstGroupGap: CGFloat = 14

    /// The space a group adds above its label, on top of the page's `rowSpacing`.
    static func topPadding(isFirst: Bool) -> CGFloat {
        (isFirst ? firstGroupGap : groupGap) - WordMenuMetrics.rowSpacing
    }

    var body: some View {
        let groups = Self.groups
        WordMenuPageScaffold(title: WordMenuItem.basics.title) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    WordMenuGroupLabel(title: group.title, isTight: true)
                    VStack(spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Rectangle()
                                    .fill(palette.color(palette.hair).opacity(0.7))
                                    .frame(height: 1)
                            }
                            rowView(row)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                            .fill(palette.color(palette.soft))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous))
                }
                // With the page's 8 pt: `groupGap` from one card to the next label.
                .padding(.top, Self.topPadding(isFirst: group.id == groups.first?.id))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MarkdownReference.Row) -> some View {
        let isCopied = state.copiedRowID == row.id
        HStack(alignment: .center, spacing: 8) {
            // The mockup's row: the name, then the Markdown (monospaced, grey). A label row (Tab,
            // Spelling…) has no Markdown to show: its explanation takes that column.
            BasicsRowColumns {
                Text(verbatim: Self.name(for: row))
                    .font(.subheadline)
                    .foregroundStyle(palette.color(palette.ink))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if row.rendersSyntaxAsCode {
                        Text(verbatim: row.syntax)
                            .font(.system(.footnote, design: .monospaced))
                    } else {
                        Text(verbatim: row.explanation)
                            .font(.footnote)
                    }
                }
                .foregroundStyle(palette.color(palette.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The row's full height (44 pt inside its 48 pt row), so the element VoiceOver and
            // the accessibility audit see is a full-size target; the text stays centred as before.
            .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
            // One element for VoiceOver: the explanation, then the syntax.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.accessibilityLabel()))
            .accessibilityAddTraits(.isStaticText)
            if let copy = row.copyAffordance() {
                Button {
                    state.copy(row)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.color(isCopied ? palette.blueMark : palette.icon))
                        .frame(width: 36, height: 36)
                        .frame(width: WordMenuMetrics.minimumTarget, height: WordMenuMetrics.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: copy.label))
                .accessibilityValue(isCopied ? Text(Self.copiedText) : Text(verbatim: ""))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .frame(minHeight: 48)
    }

    /// A row's short name, as in the mockup ("Title", "Bold", "Bullets"). The full explanation
    /// stays in VoiceOver's label.
    static func name(for row: MarkdownReference.Row) -> String {
        switch row.id {
        case "# Title": return String(localized: "Title")
        case "## Section": return String(localized: "Section")
        case "**bold**": return String(localized: "Bold")
        case "_italic_": return String(localized: "Italic")
        case "~~text~~": return String(localized: "Strikethrough")
        case "`code`": return String(localized: "Code")
        case "- bullet": return String(localized: "Bullets")
        case "1. item": return String(localized: "Numbers")
        case "- [ ] to do": return String(localized: "Checkbox")
        case "> quote": return String(localized: "Quote")
        case "| a | b |": return String(localized: "Table")
        case "[text](url)": return String(localized: "Link")
        case "![alt](url)": return String(localized: "Image")
        case "$x^2 + y^2$": return String(localized: "Math")
        case "```mermaid": return String(localized: "Diagram")
        // A row added to the mockup's list later: its explanation's first phrase.
        default: return row.explanation.components(separatedBy: ".").first ?? row.explanation
        }
    }
}

/// A Basics row's two text columns in the mockup's proportions (`grid-template-columns: 1fr
/// 1.2fr`, 8 pt apart): the name, then the Markdown. Each takes its share of the width and wraps
/// inside it; the row is as tall as the taller one, both top-aligned.
private struct BasicsRowColumns: Layout {
    static let spacing: CGFloat = 8
    static let shares: [CGFloat] = [1, 1.2]

    private func widths(for total: CGFloat) -> [CGFloat] {
        let available = max(0, total - Self.spacing)
        let sum = Self.shares.reduce(0, +)
        return Self.shares.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 300
        let height = zip(subviews, widths(for: total)).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + Self.spacing
        }
    }
}
