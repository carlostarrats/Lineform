import LineformCore
import SwiftUI

/// One heading in the Outline section: the parsed heading and how deep it sits in the heading tree
/// (`MarkdownOutlineTree`), which sets its indent.
struct OutlineRow: Identifiable, Equatable {
    var item: MarkdownOutlineItem
    var depth: Int
    var id: String { item.id }
}

/// The Outline section's heading list. Built at once from the text the sheet opens on, then
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

/// The Menu sheet's Outline: the heading tree of the current text. Tapping a heading closes the
/// sheet and scrolls the heading to the top of the surface on screen (Write, Read, or both Preview
/// panes) through `EditorCommands`, which uses the mode position keeper.
struct OutlineSection: View {
    var text: String
    var editor: any EditorCommands
    var onDismiss: () -> Void

    @State private var model: OutlineModel

    /// Points per level of indent.
    static let indentStep: CGFloat = 14

    init(text: String, editor: any EditorCommands, onDismiss: @escaping () -> Void) {
        self.text = text
        self.editor = editor
        self.onDismiss = onDismiss
        _model = State(initialValue: OutlineModel(text: text))
    }

    /// The Mac's empty-state wording.
    static var emptyText: String { String(localized: "Add # Title or ## Section to build an outline.") }

    /// A heading tap: the sheet goes first, then the heading is scrolled to the top.
    static func open(_ row: OutlineRow, editor: any EditorCommands, dismiss: () -> Void) {
        dismiss()
        editor.scrollToCharacterRange(row.item.characterRange)
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                Text(Self.emptyText)
                    .font(.callout)
                    .opacity(0.6)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 40)
            } else {
                List(model.rows) { row in
                    Button {
                        Self.open(row, editor: editor, dismiss: onDismiss)
                    } label: {
                        Text(row.item.title)
                            .font(row.depth == 0 ? .body.weight(.semibold) : .body)
                            .lineLimit(2)
                            .padding(.leading, CGFloat(row.depth) * Self.indentStep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: text) { _, newText in model.textChanged(newText) }
    }
}
