import LineformCore
import SwiftUI

/// The word menu's History, like the Mac's History sidebar tab: one line saying what it is, then
/// the passages that have earlier versions, as grey cards in text order (the passage's text, its
/// version count, when it last changed). Tapping one closes the menu and enters History mode on
/// that passage (`PhoneHistoryController.showPassage`). The word is listed only while the document
/// has history.
struct HistorySection: View {
    var history: PhoneHistoryController?
    var text: String
    var onShow: (UUID) -> Void

    @Environment(\.wordMenuPalette) private var palette

    static var explanation: String {
        String(localized: "Earlier versions of passages you changed in this document. Your file only ever holds the current text.")
    }

    static var emptyText: String { String(localized: "No passages with earlier versions.") }

    /// "3 versions · 2 hr. ago".
    static func detail(for summary: PhoneHistoryController.PassageSummary) -> String {
        let versions = String(localized: "\(summary.versionCount) versions")
        let when = summary.lastTouched.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return String(localized: "\(versions) · \(when)")
    }

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.history.title) {
            WordMenuNote(text: Self.explanation)
            let summaries = history?.passageSummaries(text: text) ?? []
            if summaries.isEmpty {
                Text(Self.emptyText)
                    .font(.subheadline)
                    .foregroundStyle(palette.color(palette.secondary))
                    .padding(.horizontal, 4)
            }
            ForEach(summaries) { summary in
                Button {
                    onShow(summary.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: summary.excerpt)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.color(palette.ink))
                            .lineLimit(3)
                        Text(Self.detail(for: summary))
                            .font(.caption)
                            .foregroundStyle(palette.color(palette.secondary))
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                            .fill(palette.color(palette.soft))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(WordMenuPressStyle())
                .accessibilityHint(Text(String(localized: "Closes the menu and shows this passage's versions.")))
            }
        }
    }
}
