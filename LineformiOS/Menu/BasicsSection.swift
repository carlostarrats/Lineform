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

/// The word menu's Markdown Basics: the package's `MarkdownReference` sections, each a grey card
/// under its group label. A row shows the syntax (monospaced for a code row) over its
/// explanation, and a code row has a copy button on the right that turns into a blue check for a
/// moment after copying its Markdown.
struct BasicsSection: View {
    @State private var state = BasicsCopyState()
    @Environment(\.wordMenuPalette) private var palette

    static var sections: [MarkdownReference.Section] { MarkdownReference.sections }
    static let copiedDuration: Duration = .seconds(1)
    static var copiedText: String { String(localized: "Copied") }

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.basics.title) {
            ForEach(Self.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    // A group named like the page would only repeat its title.
                    if section.title != WordMenuItem.basics.title {
                        WordMenuGroupLabel(title: section.title)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Rectangle()
                                    .fill(palette.color(palette.hair))
                                    .frame(height: 0.5)
                                    .padding(.leading, 14)
                            }
                            rowView(row)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                            .fill(palette.color(palette.soft))
                    )
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MarkdownReference.Row) -> some View {
        let isCopied = state.copiedRowID == row.id
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.syntax)
                    .font(row.rendersSyntaxAsCode ? .system(.callout, design: .monospaced) : .callout)
                    .foregroundStyle(palette.color(palette.ink))
                Text(verbatim: row.explanation)
                    .font(.footnote)
                    .foregroundStyle(palette.color(palette.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One element for VoiceOver: the explanation, then the syntax.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.accessibilityLabel()))
            if let copy = row.copyAffordance() {
                Button {
                    state.copy(row)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.color(isCopied ? palette.blueMark : palette.icon))
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
        .padding(.vertical, 6)
        .frame(minHeight: WordMenuMetrics.minimumTarget)
    }
}
