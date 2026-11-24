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

/// The Menu sheet's Markdown Basics: the package's `MarkdownReference` sections, with the Mac
/// view's section headers and row layout (the syntax, monospaced for a code row, over its
/// explanation), as a List. Tapping a code row copies its Markdown and shows "Copied" for 1 s.
struct BasicsSection: View {
    @State private var state = BasicsCopyState()
    @Environment(\.menuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var sections: [MarkdownReference.Section] { MarkdownReference.sections }
    static let copiedDuration: Duration = .seconds(1)
    static var copiedText: String { String(localized: "Copied") }

    var body: some View {
        List {
            ForEach(Self.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        rowView(row)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(section.title)
                        .font(.footnote.weight(.medium))
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rowView(_ row: MarkdownReference.Row) -> some View {
        let ink = PhoneInk.menu(theme)
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.syntax)
                    .font(row.rendersSyntaxAsCode ? .system(.callout, design: .monospaced) : .callout)
                Text(verbatim: row.explanation)
                    .font(.footnote)
                    .foregroundStyle(ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if row.copyAffordance() != nil {
                if state.copiedRowID == row.id {
                    Text(Self.copiedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ink.secondary)
                        .transition(.opacity)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(ink.icon)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(EditorMotionPolicy.animation(.easeOut(duration: 0.15), reduceMotion: reduceMotion), value: state.copiedRowID)

        // Only a code row is a button: a label row has nothing to copy. One element for
        // VoiceOver: the explanation, then the syntax; the copy is its action, named by the
        // affordance's own localized label.
        if let copy = row.copyAffordance() {
            Button {
                state.copy(row)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.accessibilityLabel()))
            .accessibilityValue(state.copiedRowID == row.id ? Text(Self.copiedText) : Text(verbatim: ""))
            .accessibilityHint(Text(verbatim: copy.label))
            .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: row.accessibilityLabel()))
        }
    }
}
