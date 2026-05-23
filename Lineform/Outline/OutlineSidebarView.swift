import SwiftUI

struct OutlineSidebarView: View {
    var items: [MarkdownOutlineItem]
    var jumpToHeading: (MarkdownOutlineItem) -> Void

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    jumpToHeading(item)
                } label: {
                    Text(item.title)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(max(0, item.level - 1)) * 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to heading \(item.title)")
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
        .accessibilityLabel("Document outline")
    }
}
