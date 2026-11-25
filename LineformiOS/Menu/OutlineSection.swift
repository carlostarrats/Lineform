import LineformCore
import SwiftUI

/// One heading in the Outline section: the parsed heading and how deep it sits in the heading tree
/// (`MarkdownOutlineTree`), which sets its indent.
struct OutlineRow: Identifiable, Equatable {
    var item: MarkdownOutlineItem
    var depth: Int
    var id: String { item.id }
}

/// The Outline section's heading list. Built at once from the text the menu opens on, then
/// rebuilt `rebuildDelay` after the text changes (each change restarts the wait, so the latest
/// text wins), as the Mac's derived refresh does.
@MainActor
@Observable
final class OutlineModel {
    static let rebuildDelay: Duration = .milliseconds(300)

    private(set) var rows: [OutlineRow]
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(text: String) {
        rows = Self.rows(for: text)
    }

    func textChanged(_ text: String) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.rebuildDelay)
            guard !Task.isCancelled, let self else { return }
            let rebuilt = Self.rows(for: text)
            if rebuilt != rows { rows = rebuilt }
        }
    }

    /// The headings of `text` in document order, each with its depth in the heading tree.
    static func rows(for text: String) -> [OutlineRow] {
        var rows: [OutlineRow] = []
        func walk(_ nodes: [MarkdownOutlineTree.Node], depth: Int) {
            for node in nodes {
                rows.append(OutlineRow(item: node.item, depth: depth))
                walk(node.children, depth: depth + 1)
            }
        }
        walk(MarkdownOutlineTree.tree(from: MarkdownOutlineParser().items(in: text)), depth: 0)
        return rows
    }
}

/// The word menu's Outline, like the Mac sidebar's: each heading with its level's icon
/// (`iconName(forHeadingLevel:)`), the top level heavier, nested rows indented with a thin guide
/// line down them. Tapping a heading closes the menu, scrolls the heading to the top of the
/// surface on screen (Write, Read, or both Preview panes) through `EditorCommands`, and flashes it
/// briefly.
struct OutlineSection: View {
    var text: String
    var editor: any EditorCommands
    var onDismiss: () -> Void

    /// Built once, when the section first appears, then kept current by its debounced rebuild:
    /// never in `init`, which SwiftUI runs on every update (each keystroke).
    @State private var model: OutlineModel?
    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Points per level of indent: the guide line sits under the parent's icon.
    static let indentStep: CGFloat = 17
    /// The guide line's width.
    static let guideWidth: CGFloat = 1.5

    /// The Mac's empty-state wording.
    static var emptyText: String { String(localized: "Add # Title or ## Section to build an outline.") }

    /// What VoiceOver says after a heading's title: its Markdown level (the indent says it to the
    /// eye).
    static func accessibilityValue(for row: OutlineRow) -> String {
        let level = row.item.level
        return String(localized: "Heading level \(level)")
    }

    /// Two lines for a heading; no limit at accessibility sizes, where two lines hold few words.
    static func lineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 2
    }

    /// The Mac sidebar's icon for a heading level (`OutlineSidebarView.iconName(forHeadingLevel:)`).
    static func iconName(forHeadingLevel level: Int) -> String {
        switch level {
        case 1: "textformat.size"
        case 2: "list.bullet.indent"
        default: "text.alignleft"
        }
    }

    /// A heading tap: the menu goes first, then the heading is scrolled to the top and flashed.
    static func open(_ row: OutlineRow, editor: any EditorCommands, dismiss: () -> Void) {
        dismiss()
        editor.scrollToCharacterRange(row.item.characterRange)
        editor.flashCharacterRange(row.item.characterRange)
    }

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.outline.title) {
            if let model {
                list(model)
            }
        }
        .onAppear {
            if model == nil { model = OutlineModel(text: text) }
        }
        .onChange(of: text) { _, newText in model?.textChanged(newText) }
    }

    @ViewBuilder
    private func list(_ model: OutlineModel) -> some View {
        if model.rows.isEmpty {
            Text(Self.emptyText)
                .font(.callout)
                .foregroundStyle(palette.color(palette.secondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    rowView(row)
                }
            }
        }
    }

    private func rowView(_ row: OutlineRow) -> some View {
        Button {
            Self.open(row, editor: editor, dismiss: onDismiss)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Self.iconName(forHeadingLevel: row.item.level))
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.icon))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(row.item.title)
                    .font(row.depth == 0 ? .body.weight(.semibold) : .body)
                    .foregroundStyle(palette.color(palette.ink))
                    .lineLimit(Self.lineLimit(for: dynamicTypeSize))
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(row.depth) * Self.indentStep)
            .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
            .background(alignment: .leading) { guides(depth: row.depth) }
            .contentShape(Rectangle())
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityValue(Text(Self.accessibilityValue(for: row)))
    }

    /// One thin vertical line per level above the row, under each ancestor's icon, so the lines
    /// run unbroken down a nested run.
    private func guides(depth: Int) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<max(0, depth), id: \.self) { level in
                Rectangle()
                    .fill(palette.color(palette.hair))
                    .frame(width: Self.guideWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: 8 + 8 + CGFloat(level) * Self.indentStep)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
